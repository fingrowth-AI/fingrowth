"""Tests for the P4-04 paper-trading HTTP surface.

The tool-level client is covered by ``test_paper_trading.py``; here we focus
on the FastAPI router contract — request validation, status-code mapping for
each error class, and the wire shape returned to the iOS client.

We patch the imported callables in ``app.routers.paper_trading`` rather than
the originals in ``app.tools.paper_trading``. FastAPI imported the names into
the router module at import time, so patching the bound reference is what
the endpoint actually sees.
"""

from __future__ import annotations

from datetime import date, datetime, timezone

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app
from app.models.database import DEFAULT_USER_ID
from app.models.market import PriceBar
from app.models.trading import Order, PortfolioHistory, PortfolioHistoryPoint, Position
from app.routers import paper_trading as router_module
from app.tools.paper_trading import LiveEndpointError, MissingCredentialsError

BASE = "http://test"


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


def _order(**overrides) -> Order:
    payload = {
        "id": "904837e3-3b76-47ec-b432-046db621571b",
        "client_order_id": "904837e3-3b76-47ec-b432-046db621571b",
        "symbol": "AAPL",
        "qty": 10.0,
        "side": "buy",
        "order_type": "market",
        "time_in_force": "day",
        "status": "accepted",
        "submitted_at": datetime(2024, 1, 15, 15, 30, tzinfo=timezone.utc),
        "filled_qty": 0.0,
        "filled_avg_price": None,
    }
    payload.update(overrides)
    return Order(**payload)


def _position(symbol: str = "AAPL", qty: float = 5.0) -> Position:
    return Position(
        symbol=symbol,
        qty=qty,
        side="long",
        avg_entry_price=180.5,
        market_value=qty * 181.5,
        cost_basis=qty * 180.5,
        unrealized_pl=qty * 1.0,
    )


# ---------------------------------------------------------------------------
# POST /paper-trades/orders
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_place_order_returns_accepted_order(monkeypatch, client: AsyncClient):
    captured: dict = {}

    async def fake_place(*args, **kwargs):
        captured["args"] = args
        captured["kwargs"] = kwargs
        return _order()

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "buy"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["symbol"] == "AAPL"
    assert body["status"] == "accepted"
    assert body["side"] == "buy"
    assert captured["args"] == ("AAPL", 10.0, "buy")
    assert captured["kwargs"]["order_type"] == "market"
    assert captured["kwargs"]["time_in_force"] == "day"
    # V8-02: the order is tagged with the resolved user (default user here).
    assert captured["kwargs"]["user_id"] == DEFAULT_USER_ID


@pytest.mark.asyncio
async def test_place_order_rejects_invalid_side(client: AsyncClient):
    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "long"},
    )
    assert resp.status_code == 422  # Pydantic Literal violation


@pytest.mark.asyncio
async def test_place_order_rejects_zero_quantity(client: AsyncClient):
    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 0, "side": "buy"},
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_place_order_missing_credentials_returns_401(
    monkeypatch, client: AsyncClient
):
    async def fake_place(*args, **kwargs):
        raise MissingCredentialsError("ALPACA_API_KEY missing")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )
    assert resp.status_code == 401
    assert "credentials" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_place_order_live_endpoint_returns_503(
    monkeypatch, client: AsyncClient
):
    async def fake_place(*args, **kwargs):
        raise LiveEndpointError("refused live endpoint")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )
    assert resp.status_code == 503
    assert "paper" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_place_order_upstream_http_error_returns_502(
    monkeypatch, client: AsyncClient
):
    async def fake_place(*args, **kwargs):
        request = httpx.Request("POST", "https://paper-api.alpaca.markets/v2/orders")
        response = httpx.Response(403, request=request)
        raise httpx.HTTPStatusError("forbidden", request=request, response=response)

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )
    assert resp.status_code == 502
    assert "403" in resp.json()["detail"]


# ---------------------------------------------------------------------------
# GET /paper/positions
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_positions_returns_positions(monkeypatch, client: AsyncClient):
    captured: dict = {}

    async def fake_get_positions(user_id):
        captured["user_id"] = user_id
        return [_position("AAPL", 5.0), _position("MSFT", 2.0)]

    monkeypatch.setattr(router_module, "get_user_positions", fake_get_positions)

    resp = await client.get("/api/v1/paper/positions")
    assert resp.status_code == 200
    body = resp.json()
    assert [r["symbol"] for r in body["positions"]] == ["AAPL", "MSFT"]
    # V8-02: positions are scoped to the resolved user.
    assert captured["user_id"] == DEFAULT_USER_ID


@pytest.mark.asyncio
async def test_list_positions_empty_list(monkeypatch, client: AsyncClient):
    async def fake_get_positions(user_id):
        return []

    monkeypatch.setattr(router_module, "get_user_positions", fake_get_positions)

    resp = await client.get("/api/v1/paper/positions")
    assert resp.status_code == 200
    assert resp.json() == {"positions": []}


# ---------------------------------------------------------------------------
# GET /paper/orders
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_orders_passes_limit_and_status(monkeypatch, client: AsyncClient):
    captured: dict = {}

    async def fake_get_orders(user_id, limit=50, status="all"):
        captured["user_id"] = user_id
        captured["limit"] = limit
        captured["status"] = status
        return [_order(status="filled"), _order(status="accepted")]

    monkeypatch.setattr(router_module, "get_user_order_history", fake_get_orders)

    resp = await client.get("/api/v1/paper/orders?limit=20&status=closed")
    assert resp.status_code == 200
    assert captured == {"user_id": DEFAULT_USER_ID, "limit": 20, "status": "closed"}
    body = resp.json()
    assert len(body["orders"]) == 2


@pytest.mark.asyncio
async def test_list_orders_rejects_non_positive_limit(client: AsyncClient):
    resp = await client.get("/api/v1/paper/orders?limit=0")
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# GET /paper-trades/benchmark
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_benchmark_returns_sorted_close_series(monkeypatch, client: AsyncClient):
    captured: dict = {}

    async def fake_get_daily(ticker, days=30, **_):
        captured["ticker"] = ticker
        captured["days"] = days
        return [
            PriceBar(
                ticker=ticker.upper(),
                date=date(2024, 1, 3),
                open=100.0,
                high=101.0,
                low=99.0,
                close=100.5,
                volume=1000,
            ),
            PriceBar(
                ticker=ticker.upper(),
                date=date(2024, 1, 2),
                open=99.0,
                high=100.0,
                low=98.0,
                close=99.5,
                volume=1100,
            ),
        ]

    monkeypatch.setattr(router_module, "get_daily_prices", fake_get_daily)

    resp = await client.get("/api/v1/paper/benchmark?days=2")
    assert resp.status_code == 200
    body = resp.json()
    assert body["symbol"] == "SPY"
    assert [p["date"] for p in body["points"]] == ["2024-01-02", "2024-01-03"]
    assert body["points"][0]["close"] == pytest.approx(99.5)
    assert captured == {"ticker": "SPY", "days": 2}


@pytest.mark.asyncio
async def test_benchmark_rejects_non_positive_days(client: AsyncClient):
    resp = await client.get("/api/v1/paper/benchmark?days=0")
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# GET /paper/portfolio-history
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_portfolio_history_returns_user_equity_series(
    monkeypatch, client: AsyncClient
):
    captured: dict = {}

    async def fake_history(user_id):
        captured["user_id"] = user_id
        return PortfolioHistory(
            base_value=100000.0,
            points=[
                PortfolioHistoryPoint(date="2024-01-15", equity=100000.0),
                PortfolioHistoryPoint(date="2024-01-16", equity=100250.5),
            ],
        )

    monkeypatch.setattr(router_module, "get_user_portfolio_history", fake_history)

    resp = await client.get("/api/v1/paper/portfolio-history?period=3M&timeframe=1D")
    assert resp.status_code == 200
    body = resp.json()
    assert body["base_value"] == 100000.0
    assert [p["equity"] for p in body["points"]] == [100000.0, 100250.5]
    # V8-02: the curve is scoped to the resolved user, not the shared account.
    assert captured["user_id"] == DEFAULT_USER_ID


@pytest.mark.asyncio
async def test_portfolio_history_tolerates_advisory_period(
    monkeypatch, client: AsyncClient
):
    # period/timeframe are advisory now (per-user reconstruction is daily), so
    # an unusual period is accepted rather than 400'd.
    async def fake_history(user_id):
        return PortfolioHistory(base_value=100000.0, points=[])

    monkeypatch.setattr(router_module, "get_user_portfolio_history", fake_history)

    resp = await client.get("/api/v1/paper/portfolio-history?period=forever")
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_portfolio_history_live_endpoint_returns_503(
    monkeypatch, client: AsyncClient
):
    async def fake_history(user_id):
        raise LiveEndpointError("nope")

    monkeypatch.setattr(router_module, "get_user_portfolio_history", fake_history)

    resp = await client.get("/api/v1/paper/portfolio-history")
    assert resp.status_code == 503
