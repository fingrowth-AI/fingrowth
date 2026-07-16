"""Endpoint-level tests for the request rate limits.

The suite-wide conftest disables every limit; each test here re-enables just
the limit under test via monkeypatch. The analysis pipeline is stubbed to an
empty graph stream so an *allowed* request completes without touching agents
or data providers; *blocked* requests must be rejected before the pipeline
(or Alpaca) is reached at all, which is exactly what the assertions rely on.
"""

from __future__ import annotations

from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import settings
from app.main import app
from app.models.database import DEFAULT_USER_ID
from app.services import usage_limits

BASE = "http://test"
ANALYSIS = "/api/v1/analysis/query"
ORDER = "/api/v1/paper/order"

QUERY_BODY = {
    "query": "How is AAPL doing?",
    "ticker": "AAPL",
    "analysis_type": "general",
}


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


@pytest.fixture
def stub_pipeline(monkeypatch: pytest.MonkeyPatch):
    """Replace the graph with an empty stream: allowed requests finish cheaply."""

    async def _empty_stream(_state: dict[str, Any]):
        return
        yield  # pragma: no cover - makes this an async generator

    monkeypatch.setattr("app.routers.analysis.agent_graph.astream", _empty_stream)


async def test_burst_limit_returns_429_with_retry_after(
    client: AsyncClient, stub_pipeline, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(settings, "analysis_requests_per_minute_per_user", 1)

    ok = await client.post(ANALYSIS, json=QUERY_BODY)
    assert ok.status_code == 200

    blocked = await client.post(ANALYSIS, json=QUERY_BODY)
    assert blocked.status_code == 429
    assert "too quickly" in blocked.json()["detail"]
    assert int(blocked.headers["Retry-After"]) >= 1


async def test_daily_limit_returns_429(
    client: AsyncClient, stub_pipeline, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(settings, "analysis_requests_per_day_per_user", 1)

    ok = await client.post(ANALYSIS, json=QUERY_BODY)
    assert ok.status_code == 200

    blocked = await client.post(ANALYSIS, json=QUERY_BODY)
    assert blocked.status_code == 429
    assert "research limit" in blocked.json()["detail"]


async def test_global_daily_limit_returns_429(
    client: AsyncClient, stub_pipeline, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(settings, "analysis_requests_per_day_global", 1)

    ok = await client.post(ANALYSIS, json=QUERY_BODY)
    assert ok.status_code == 200

    blocked = await client.post(ANALYSIS, json=QUERY_BODY)
    assert blocked.status_code == 429
    assert "capacity" in blocked.json()["detail"]


async def test_blocked_request_never_starts_the_pipeline(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(settings, "analysis_requests_per_minute_per_user", 1)

    async def _boom(_state: dict[str, Any]):
        raise AssertionError("pipeline must not run for a rate-limited request")
        yield  # pragma: no cover

    # Exhaust the allowance out of band, then verify the endpoint rejects
    # before ever touching the (booby-trapped) graph.
    await usage_limits.check(
        "analysis-minute", str(DEFAULT_USER_ID), limit=1, window_seconds=60
    )
    monkeypatch.setattr("app.routers.analysis.agent_graph.astream", _boom)

    blocked = await client.post(ANALYSIS, json=QUERY_BODY)
    assert blocked.status_code == 429


async def test_query_length_is_bounded(client: AsyncClient, stub_pipeline):
    too_long = dict(QUERY_BODY, query="x" * 2001)
    response = await client.post(ANALYSIS, json=too_long)
    assert response.status_code == 422


async def test_order_burst_limit_returns_429(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
):
    monkeypatch.setattr(settings, "orders_per_minute_per_user", 1)

    # Exhaust the allowance out of band so the blocked request is rejected
    # before any Alpaca / market-data code runs (no stubs needed).
    await usage_limits.check(
        "orders-minute", str(DEFAULT_USER_ID), limit=1, window_seconds=60
    )

    blocked = await client.post(
        ORDER, json={"ticker": "AAPL", "quantity": 1, "side": "buy"}
    )
    assert blocked.status_code == 429
    assert "Too many orders" in blocked.json()["detail"]
    assert int(blocked.headers["Retry-After"]) >= 1
