"""Tests for the V7-05 auth-shaped API contract.

The single resolution point (get_current_user) returns the default user and
tolerates any Bearer token until V8. Every /api/v1 endpoint accepts the header.
"""

from __future__ import annotations

import pytest
from fastapi.security import HTTPAuthorizationCredentials
from httpx import ASGITransport, AsyncClient

from app.auth import bearer_scheme, get_current_user
from app.main import app
from app.models.database import DEFAULT_USER_ID
from app.routers import paper_trading as router_module

BASE = "http://test"


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


# ---------------------------------------------------------------------------
# get_current_user — the single resolution point
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_current_user_returns_default_without_credentials():
    assert await get_current_user(None) == DEFAULT_USER_ID


@pytest.mark.asyncio
async def test_get_current_user_tolerates_any_bearer_token():
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="anything.at.all")
    # The token is accepted but not yet verified — still the default user.
    assert await get_current_user(creds) == DEFAULT_USER_ID


def test_bearer_scheme_does_not_auto_error():
    """auto_error=False keeps the header optional so a missing token never 403s."""
    assert bearer_scheme.auto_error is False


# ---------------------------------------------------------------------------
# Endpoints accept (and tolerate) the Bearer header
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_endpoint_accepts_bearer_header(monkeypatch, client: AsyncClient):
    """A Bearer header is accepted on an /api/v1 endpoint (not rejected)."""

    async def fake_place(*args, **kwargs):
        from datetime import datetime, timezone

        from app.models.trading import Order

        return Order(
            id="1",
            client_order_id="1",
            symbol="AAPL",
            qty=1.0,
            side="buy",
            order_type="market",
            time_in_force="day",
            status="accepted",
            submitted_at=datetime(2024, 1, 1, tzinfo=timezone.utc),
            filled_qty=0.0,
            filled_avg_price=None,
        )

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    # V8-03 added a buy-side buying-power check that prices the order and reads
    # the user's balance. Stub both seams so this auth-contract test stays
    # offline (no Alpha Vantage / Alpaca / DB) and focuses on header handling.
    async def fake_bp(session, user_id, *a, **k):
        return 1_000_000.0

    async def fake_price(ticker, days=1, **k):
        from datetime import date

        from app.models.market import PriceBar

        return [
            PriceBar(
                ticker=ticker.upper(),
                date=date(2024, 1, 1),
                open=100.0,
                high=101.0,
                low=99.0,
                close=100.0,
                volume=1000,
            )
        ]

    monkeypatch.setattr(router_module, "available_buying_power", fake_bp)
    monkeypatch.setattr(router_module, "get_daily_prices", fake_price)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
        headers={"Authorization": "Bearer placeholder-token"},
    )

    # The auth layer neither rejects the token nor requires it — 200, not 401/403.
    assert resp.status_code == 200
    assert resp.json()["symbol"] == "AAPL"


def test_all_api_v1_endpoints_accept_bearer_header():
    """Every authenticated /api/v1 route depends on get_current_user, so the
    OpenAPI schema advertises the bearer scheme on each. The /auth bootstrap
    endpoint is exempt — it issues the token, so it can't require one."""
    schema = app.openapi()
    api_v1_paths = {
        path: item
        for path, item in schema["paths"].items()
        if path.startswith("/api/v1/") and not path.startswith("/api/v1/auth/")
    }
    assert api_v1_paths, "expected at least one /api/v1 path"

    for path, operations in api_v1_paths.items():
        for method, operation in operations.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            assert "security" in operation, f"{method.upper()} {path} missing security"
            schemes = {key for entry in operation["security"] for key in entry}
            assert "HTTPBearer" in schemes, (
                f"{method.upper()} {path} does not accept a Bearer header"
            )
