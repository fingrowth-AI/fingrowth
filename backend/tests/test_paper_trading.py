"""Tests for P2-05: Alpaca paper trading client.

Acceptance:
* place_paper_order('AAPL', 10, 'buy') returns Order with status='accepted'
* All calls use paper-api.alpaca.markets, never live endpoint
"""

from __future__ import annotations

import json

import httpx
import pytest

from app.config import settings
from app.models.trading import Order, Position
from app.tools.paper_trading import (
    PAPER_DOMAIN,
    LiveEndpointError,
    MissingCredentialsError,
    get_order_history,
    get_positions,
    place_paper_order,
)

# ---------------------------------------------------------------------------
# Fixtures + helpers
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _alpaca_creds(monkeypatch):
    """Default to paper-api with stubbed creds. Tests can override base URL."""
    monkeypatch.setattr(settings, "alpaca_api_key", "test-key-id")
    monkeypatch.setattr(settings, "alpaca_secret_key", "test-secret")
    monkeypatch.setattr(
        settings, "alpaca_base_url", "https://paper-api.alpaca.markets"
    )


def _order_payload(
    *,
    symbol: str = "AAPL",
    qty: str = "10",
    side: str = "buy",
    status: str = "accepted",
) -> dict:
    return {
        "id": "904837e3-3b76-47ec-b432-046db621571b",
        "client_order_id": "904837e3-3b76-47ec-b432-046db621571b",
        "created_at": "2024-01-15T15:30:00Z",
        "updated_at": "2024-01-15T15:30:00Z",
        "submitted_at": "2024-01-15T15:30:00Z",
        "filled_at": None,
        "asset_id": "b0b6dd9d-8b9b-48a9-ba46-b9d54906e415",
        "symbol": symbol,
        "asset_class": "us_equity",
        "qty": qty,
        "filled_qty": "0",
        "filled_avg_price": None,
        "type": "market",
        "side": side,
        "time_in_force": "day",
        "status": status,
    }


def _position_payload(symbol: str = "AAPL", qty: str = "5") -> dict:
    return {
        "asset_id": "b0b6dd9d-8b9b-48a9-ba46-b9d54906e415",
        "symbol": symbol,
        "exchange": "NASDAQ",
        "asset_class": "us_equity",
        "avg_entry_price": "180.50",
        "qty": qty,
        "side": "long",
        "market_value": "907.50",
        "cost_basis": "902.50",
        "unrealized_pl": "5.00",
    }


def _make_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# ---------------------------------------------------------------------------
# place_paper_order — primary acceptance criteria
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_place_paper_order_returns_accepted_order():
    """Acceptance: place_paper_order('AAPL', 10, 'buy') returns Order with status='accepted'."""
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200, json=_order_payload(status="accepted"))

    async with _make_client(handler) as client:
        order = await place_paper_order("aapl", 10, "buy", client=client)

    assert isinstance(order, Order)
    assert order.status == "accepted"
    assert order.symbol == "AAPL"
    assert order.qty == 10.0
    assert order.side == "buy"
    assert order.order_type == "market"

    # Verify the request body matches Alpaca's expected shape.
    sent = captured[0]
    assert sent.method == "POST"
    body = json.loads(sent.content.decode())
    assert body == {
        "symbol": "AAPL",
        "qty": "10",
        "side": "buy",
        "type": "market",
        "time_in_force": "day",
    }


@pytest.mark.asyncio
async def test_place_paper_order_uses_paper_endpoint():
    """Acceptance: all calls use paper-api.alpaca.markets, never live endpoint."""
    captured: list[httpx.URL] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req.url)
        return httpx.Response(200, json=_order_payload())

    async with _make_client(handler) as client:
        await place_paper_order("AAPL", 10, "buy", client=client)

    assert captured[0].host == PAPER_DOMAIN
    assert captured[0].path == "/v2/orders"


@pytest.mark.asyncio
async def test_place_paper_order_sends_auth_headers():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200, json=_order_payload())

    async with _make_client(handler) as client:
        await place_paper_order("AAPL", 10, "buy", client=client)

    headers = captured[0].headers
    assert headers["apca-api-key-id"] == "test-key-id"
    assert headers["apca-api-secret-key"] == "test-secret"


@pytest.mark.asyncio
async def test_place_paper_order_invalid_side_rejected():
    with pytest.raises(ValueError, match="side"):
        await place_paper_order("AAPL", 10, "long")


@pytest.mark.asyncio
async def test_place_paper_order_zero_qty_rejected():
    with pytest.raises(ValueError, match="qty"):
        await place_paper_order("AAPL", 0, "buy")


@pytest.mark.asyncio
async def test_place_paper_order_negative_qty_rejected():
    with pytest.raises(ValueError, match="qty"):
        await place_paper_order("AAPL", -5, "buy")


@pytest.mark.asyncio
async def test_place_paper_order_refuses_live_endpoint(monkeypatch):
    """Safety: live endpoint raises before any network I/O."""
    monkeypatch.setattr(settings, "alpaca_base_url", "https://api.alpaca.markets")

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be touched on live endpoint")

    async with _make_client(handler) as client:
        with pytest.raises(LiveEndpointError):
            await place_paper_order("AAPL", 10, "buy", client=client)


@pytest.mark.asyncio
async def test_place_paper_order_refuses_empty_base_url(monkeypatch):
    monkeypatch.setattr(settings, "alpaca_base_url", "")
    with pytest.raises(LiveEndpointError):
        await place_paper_order("AAPL", 10, "buy")


@pytest.mark.asyncio
async def test_place_paper_order_missing_credentials(monkeypatch):
    monkeypatch.setattr(settings, "alpaca_secret_key", "")

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be touched without creds")

    async with _make_client(handler) as client:
        with pytest.raises(MissingCredentialsError):
            await place_paper_order("AAPL", 10, "buy", client=client)


# ---------------------------------------------------------------------------
# get_positions
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_positions_returns_list():
    captured: list[httpx.URL] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req.url)
        return httpx.Response(
            200,
            json=[_position_payload("AAPL", "5"), _position_payload("MSFT", "10")],
        )

    async with _make_client(handler) as client:
        positions = await get_positions(client=client)

    assert len(positions) == 2
    assert all(isinstance(p, Position) for p in positions)
    assert positions[0].symbol == "AAPL"
    assert positions[0].qty == 5.0
    assert positions[0].avg_entry_price == 180.50
    assert positions[0].side == "long"
    # Acceptance: paper endpoint
    assert captured[0].host == PAPER_DOMAIN
    assert captured[0].path == "/v2/positions"


@pytest.mark.asyncio
async def test_get_positions_empty():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    async with _make_client(handler) as client:
        positions = await get_positions(client=client)

    assert positions == []


@pytest.mark.asyncio
async def test_get_positions_handles_non_list_response():
    """Defensive: if Alpaca returns an error envelope, we degrade to []."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"error": "unexpected"})

    async with _make_client(handler) as client:
        positions = await get_positions(client=client)

    assert positions == []


@pytest.mark.asyncio
async def test_get_positions_refuses_live_endpoint(monkeypatch):
    monkeypatch.setattr(settings, "alpaca_base_url", "https://api.alpaca.markets")
    with pytest.raises(LiveEndpointError):
        await get_positions()


# ---------------------------------------------------------------------------
# get_order_history
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_order_history_returns_orders():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(
            200,
            json=[
                _order_payload(symbol="AAPL", status="filled"),
                _order_payload(symbol="MSFT", status="canceled"),
            ],
        )

    async with _make_client(handler) as client:
        orders = await get_order_history(limit=25, client=client)

    assert len(orders) == 2
    assert orders[0].status == "filled"
    assert orders[1].status == "canceled"
    # Acceptance: paper endpoint
    assert captured[0].url.host == PAPER_DOMAIN
    assert captured[0].url.path == "/v2/orders"
    assert captured[0].url.params.get("limit") == "25"
    assert captured[0].url.params.get("status") == "all"


@pytest.mark.asyncio
async def test_get_order_history_default_limit():
    captured: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req.url.params.get("limit"))
        return httpx.Response(200, json=[])

    async with _make_client(handler) as client:
        await get_order_history(client=client)

    assert captured[0] == "50"


@pytest.mark.asyncio
async def test_get_order_history_invalid_limit_rejected():
    with pytest.raises(ValueError, match="limit"):
        await get_order_history(limit=0)


@pytest.mark.asyncio
async def test_get_order_history_handles_non_list_response():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"error": "boom"})

    async with _make_client(handler) as client:
        orders = await get_order_history(client=client)

    assert orders == []


@pytest.mark.asyncio
async def test_get_order_history_refuses_live_endpoint(monkeypatch):
    monkeypatch.setattr(settings, "alpaca_base_url", "https://api.alpaca.markets")
    with pytest.raises(LiveEndpointError):
        await get_order_history()


# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------


def test_paper_domain_constant():
    """Sanity: the paper-only sentinel matches Alpaca's documented hostname."""
    assert PAPER_DOMAIN == "paper-api.alpaca.markets"
