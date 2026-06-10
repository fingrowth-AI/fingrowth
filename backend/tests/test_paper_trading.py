"""Tests for P2-05: Alpaca paper trading client.

Acceptance:
* place_paper_order('AAPL', 10, 'buy') returns Order with status='accepted'
* All calls use paper-api.alpaca.markets, never live endpoint
"""

from __future__ import annotations

import json
import uuid
from datetime import date

import httpx
import pytest

from app.config import settings
from app.models.trading import Order, Position
from app.tools.paper_trading import (
    PAPER_DOMAIN,
    SEED_EQUITY,
    LiveEndpointError,
    MissingCredentialsError,
    get_order_history,
    get_portfolio_history,
    get_positions,
    get_user_order_history,
    get_user_portfolio_history,
    get_user_positions,
    make_client_order_id,
    order_belongs_to_user,
    place_paper_order,
    reconstruct_cash,
    reconstruct_equity_series,
    reconstruct_portfolio_history,
    reconstruct_positions,
    reconstruct_realized_pnl,
)

USER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
USER_B = uuid.UUID("22222222-2222-2222-2222-222222222222")

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
@pytest.mark.parametrize(
    "hostile_url",
    [
        "https://paper-api.alpaca.markets.evil.com",
        "https://paper-api.alpaca.markets.evil.com/v2",
        "https://evil.com/paper-api.alpaca.markets",
        "https://user:paper-api.alpaca.markets@evil.com",
        "ftp://paper-api.alpaca.markets",
    ],
)
async def test_place_paper_order_refuses_lookalike_hosts(monkeypatch, hostile_url):
    """Safety: substring matches must not satisfy the paper-only guard."""
    monkeypatch.setattr(settings, "alpaca_base_url", hostile_url)

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be touched on look-alike host")

    async with _make_client(handler) as client:
        with pytest.raises(LiveEndpointError):
            await place_paper_order("AAPL", 10, "buy", client=client)


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
# Portfolio history
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_portfolio_history_flattens_series():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(
            200,
            json={
                # 4 days; the first is a pre-funding 0.0, the third is null.
                "timestamp": [1705190400, 1705276800, 1705363200, 1705449600],
                "equity": [0.0, 10000.0, None, 10250.5],
                "profit_loss": [0.0, 0.0, None, 250.5],
                "base_value": 10000.0,
                "timeframe": "1D",
            },
        )

    async with _make_client(handler) as client:
        history = await get_portfolio_history(client=client)

    # The pre-funding 0.0 and the null sample are both dropped.
    assert history.base_value == 10000.0
    assert [p.equity for p in history.points] == [10000.0, 10250.5]
    assert history.points[0].date == "2024-01-15"
    assert captured[0].url.host == PAPER_DOMAIN
    assert captured[0].url.path == "/v2/account/portfolio/history"
    assert captured[0].url.params.get("period") == "1M"
    assert captured[0].url.params.get("timeframe") == "1D"


@pytest.mark.asyncio
async def test_get_portfolio_history_rejects_bad_period():
    with pytest.raises(ValueError, match="period"):
        await get_portfolio_history(period="forever")


@pytest.mark.asyncio
async def test_get_portfolio_history_rejects_bad_timeframe():
    with pytest.raises(ValueError, match="timeframe"):
        await get_portfolio_history(timeframe="1Year")


@pytest.mark.asyncio
async def test_get_portfolio_history_refuses_live_endpoint(monkeypatch):
    monkeypatch.setattr(settings, "alpaca_base_url", "https://api.alpaca.markets")
    with pytest.raises(LiveEndpointError):
        await get_portfolio_history()


# ---------------------------------------------------------------------------
# V8-02: per-user trade tagging and reconstruction
# ---------------------------------------------------------------------------


def _filled_order_payload(
    user_id,
    *,
    symbol: str,
    side: str,
    qty: float,
    price: float,
    submitted_at: str = "2024-01-15T15:30:00Z",
) -> dict:
    return {
        "id": uuid.uuid4().hex,
        "client_order_id": f"{user_id}_{uuid.uuid4().hex}",
        "submitted_at": submitted_at,
        "symbol": symbol,
        "qty": str(qty),
        "filled_qty": str(qty),
        "filled_avg_price": str(price),
        "type": "market",
        "side": side,
        "time_in_force": "day",
        "status": "filled",
    }


def test_make_client_order_id_encodes_user_and_is_unique():
    first = make_client_order_id(USER_A)
    second = make_client_order_id(USER_A)
    assert first.startswith(f"{USER_A}_")
    assert first != second  # unique per order


def test_order_belongs_to_user_matches_prefix_only():
    order = Order.model_validate(
        _filled_order_payload(USER_A, symbol="AAPL", side="buy", qty=5, price=100)
    )
    assert order_belongs_to_user(order, USER_A)
    assert not order_belongs_to_user(order, USER_B)


def test_untagged_order_belongs_to_no_user():
    order = Order.model_validate(_order_payload())  # client_order_id is a bare uuid
    assert not order_belongs_to_user(order, USER_A)


@pytest.mark.asyncio
async def test_place_paper_order_tags_client_order_id():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200, json=_order_payload())

    async with _make_client(handler) as client:
        await place_paper_order("AAPL", 1, "buy", user_id=USER_A, client=client)

    body = json.loads(captured[0].content.decode())
    assert body["client_order_id"].startswith(f"{USER_A}_")


@pytest.mark.asyncio
async def test_place_paper_order_without_user_sends_no_client_order_id():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200, json=_order_payload())

    async with _make_client(handler) as client:
        await place_paper_order("AAPL", 1, "buy", client=client)

    body = json.loads(captured[0].content.decode())
    assert "client_order_id" not in body


def test_reconstruct_positions_nets_buys_and_sells_with_average_cost():
    orders = [
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side="buy", qty=10, price=100,
            submitted_at="2024-01-01T00:00:00Z")),
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side="buy", qty=10, price=120,
            submitted_at="2024-01-02T00:00:00Z")),
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side="sell", qty=5, price=130,
            submitted_at="2024-01-03T00:00:00Z")),
    ]
    positions = reconstruct_positions(orders)

    assert len(positions) == 1
    pos = positions[0]
    assert pos.symbol == "AAPL"
    assert pos.qty == pytest.approx(15.0)  # 10 + 10 - 5
    assert pos.side == "long"
    assert pos.avg_entry_price == pytest.approx(110.0)  # (100*10 + 120*10)/20
    assert pos.cost_basis == pytest.approx(110.0 * 15)


def test_reconstruct_positions_drops_fully_closed():
    orders = [
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side="buy", qty=5, price=100,
            submitted_at="2024-01-01T00:00:00Z")),
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side="sell", qty=5, price=110,
            submitted_at="2024-01-02T00:00:00Z")),
    ]
    assert reconstruct_positions(orders) == []


@pytest.mark.asyncio
async def test_get_user_positions_isolates_users_on_same_ticker():
    """Acceptance: two users trading the same ticker never see each other's."""
    payloads = [
        _filled_order_payload(USER_A, symbol="AAPL", side="buy", qty=10, price=100),
        _filled_order_payload(USER_B, symbol="AAPL", side="buy", qty=3, price=100),
        _filled_order_payload(USER_B, symbol="TSLA", side="buy", qty=7, price=200),
    ]

    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.path.endswith("/v2/orders")
        return httpx.Response(200, json=payloads)

    async with _make_client(handler) as client:
        a_positions = await get_user_positions(USER_A, client=client)
        b_positions = await get_user_positions(USER_B, client=client)

    assert {p.symbol: p.qty for p in a_positions} == {"AAPL": 10.0}
    assert {p.symbol: p.qty for p in b_positions} == {"AAPL": 3.0, "TSLA": 7.0}


@pytest.mark.asyncio
async def test_get_user_order_history_partitions_and_limits():
    """Acceptance: order history is correctly partitioned by user."""
    payloads = [
        _filled_order_payload(USER_A, symbol="AAPL", side="buy", qty=1, price=100),
        _filled_order_payload(USER_B, symbol="AAPL", side="buy", qty=1, price=100),
        _filled_order_payload(USER_A, symbol="MSFT", side="buy", qty=1, price=100),
        _filled_order_payload(USER_B, symbol="TSLA", side="buy", qty=1, price=100),
        _filled_order_payload(USER_A, symbol="NVDA", side="buy", qty=1, price=100),
    ]

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payloads)

    async with _make_client(handler) as client:
        a_orders = await get_user_order_history(USER_A, limit=10, client=client)
        a_limited = await get_user_order_history(USER_A, limit=2, client=client)

    assert len(a_orders) == 3  # only A's three orders
    assert all(order_belongs_to_user(o, USER_A) for o in a_orders)
    assert len(a_limited) == 2  # limit slices after filtering


@pytest.mark.asyncio
async def test_get_user_order_history_rejects_non_positive_limit():
    with pytest.raises(ValueError):
        await get_user_order_history(USER_A, limit=0)


# ---------------------------------------------------------------------------
# Short-cover / flip accounting (P3 fix)
# ---------------------------------------------------------------------------


def _orders(*specs) -> list[Order]:
    # specs: (side, qty, price, day)
    return [
        Order.model_validate(_filled_order_payload(
            USER_A, symbol="AAPL", side=side, qty=qty, price=price,
            submitted_at=f"2024-01-{day:02d}T00:00:00Z"))
        for side, qty, price, day in specs
    ]


def test_short_cover_keeps_short_basis():
    # Short 10 @100, buy 5 @90 -> still short 5, basis stays 100 (not 110).
    positions = reconstruct_positions(_orders(("sell", 10, 100, 1), ("buy", 5, 90, 2)))
    assert len(positions) == 1
    pos = positions[0]
    assert pos.side == "short"
    assert pos.qty == pytest.approx(5.0)
    assert pos.avg_entry_price == pytest.approx(100.0)


def test_adding_to_short_uses_weighted_average():
    # Short 10 @100 then short 5 @120 -> short 15 @ (100*10+120*5)/15.
    positions = reconstruct_positions(_orders(("sell", 10, 100, 1), ("sell", 5, 120, 2)))
    assert positions[0].side == "short"
    assert positions[0].qty == pytest.approx(15.0)
    assert positions[0].avg_entry_price == pytest.approx((1000 + 600) / 15)


def test_flip_short_to_long_rebases_at_fill_price():
    # Short 10 @100, buy 15 @90 -> long 5 @90.
    positions = reconstruct_positions(_orders(("sell", 10, 100, 1), ("buy", 15, 90, 2)))
    assert positions[0].side == "long"
    assert positions[0].qty == pytest.approx(5.0)
    assert positions[0].avg_entry_price == pytest.approx(90.0)


def test_flip_long_to_short_rebases_at_fill_price():
    # Long 10 @100, sell 15 @110 -> short 5 @110.
    positions = reconstruct_positions(_orders(("buy", 10, 100, 1), ("sell", 15, 110, 2)))
    assert positions[0].side == "short"
    assert positions[0].qty == pytest.approx(5.0)
    assert positions[0].avg_entry_price == pytest.approx(110.0)


# ---------------------------------------------------------------------------
# Order paging beyond 500 (P2 fix)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_reconstruction_pages_past_500_account_orders():
    """An old user buy beyond the first 500-order page is still captured."""
    # Page 1: 500 orders from USER_B (newer). Page 2 (via `until`): one older
    # USER_A buy that backs an open position.
    page1 = [
        _filled_order_payload(
            USER_B, symbol="TSLA", side="buy", qty=1, price=200,
            submitted_at="2024-02-01T00:00:00Z")
        for _ in range(500)
    ]
    page2 = [
        _filled_order_payload(
            USER_A, symbol="AAPL", side="buy", qty=10, price=100,
            submitted_at="2024-01-01T00:00:00Z")
    ]

    def handler(req: httpx.Request) -> httpx.Response:
        body = page2 if "until" in req.url.params else page1
        return httpx.Response(200, json=body)

    async with _make_client(handler) as client:
        positions = await get_user_positions(USER_A, client=client)

    assert {p.symbol: p.qty for p in positions} == {"AAPL": 10.0}


# ---------------------------------------------------------------------------
# Per-user portfolio history (P1 leak fix)
# ---------------------------------------------------------------------------


def test_reconstruct_portfolio_history_tracks_realized_pnl():
    orders = _orders(("buy", 10, 100, 1), ("sell", 10, 110, 2))
    history = reconstruct_portfolio_history(orders)

    assert history.base_value == SEED_EQUITY
    equities = {p.date: p.equity for p in history.points}
    assert equities["2024-01-01"] == pytest.approx(SEED_EQUITY)            # after buy
    assert equities["2024-01-02"] == pytest.approx(SEED_EQUITY + 100.0)    # +$100 realized


@pytest.mark.asyncio
async def test_get_user_portfolio_history_is_per_user():
    """Acceptance (V8-04 precursor): the curve reflects only the user's trades,
    never the shared account — closing the cross-user leak."""
    payloads = [
        # USER_A: +$100 realized.
        _filled_order_payload(USER_A, symbol="AAPL", side="buy", qty=10, price=100,
                              submitted_at="2024-01-01T00:00:00Z"),
        _filled_order_payload(USER_A, symbol="AAPL", side="sell", qty=10, price=110,
                              submitted_at="2024-01-02T00:00:00Z"),
        # USER_B: a big win that must NOT show up on A's curve.
        _filled_order_payload(USER_B, symbol="TSLA", side="buy", qty=100, price=100,
                              submitted_at="2024-01-01T00:00:00Z"),
        _filled_order_payload(USER_B, symbol="TSLA", side="sell", qty=100, price=200,
                              submitted_at="2024-01-02T00:00:00Z"),
    ]

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payloads)

    async with _make_client(handler) as client:
        history = await get_user_portfolio_history(USER_A, client=client)

    # A's realized gain is $100, not the $10,000 from B's trades.
    assert history.points[-1].equity == pytest.approx(SEED_EQUITY + 100.0)


# ---------------------------------------------------------------------------
# V8-03: virtual cash reconstruction and reconciliation
# ---------------------------------------------------------------------------


def test_reconstruct_cash_debits_buys_and_credits_sells():
    orders = _orders(("buy", 10, 100, 1), ("sell", 5, 130, 2))
    # SEED - (10*100) + (5*130)
    assert reconstruct_cash(orders, SEED_EQUITY) == pytest.approx(
        SEED_EQUITY - 1000 + 650
    )


def test_reconstruct_cash_respects_custom_starting_cash():
    orders = _orders(("buy", 1, 250, 1))
    assert reconstruct_cash(orders, 5_000.0) == pytest.approx(5_000.0 - 250)


def test_no_orders_leaves_full_starting_cash():
    assert reconstruct_cash([], SEED_EQUITY) == pytest.approx(SEED_EQUITY)


def test_cash_reconciles_with_open_positions():
    """Acceptance: virtual balance reconciles with the reconstructed position
    value. For longs: cash + sum(cost_basis) == starting + realized P/L."""
    orders = _orders(("buy", 10, 100, 1), ("buy", 10, 120, 2), ("sell", 5, 130, 3))

    cash = reconstruct_cash(orders, SEED_EQUITY)
    positions = reconstruct_positions(orders)
    realized = reconstruct_realized_pnl(orders)
    cost_basis = sum(p.cost_basis for p in positions)

    assert cash + cost_basis == pytest.approx(SEED_EQUITY + realized)


def test_cash_reconciles_after_fully_closing_a_position():
    """A round-trip leaves no position; realized P/L lands entirely in cash."""
    orders = _orders(("buy", 10, 100, 1), ("sell", 10, 110, 2))

    cash = reconstruct_cash(orders, SEED_EQUITY)
    positions = reconstruct_positions(orders)
    realized = reconstruct_realized_pnl(orders)

    assert positions == []
    assert realized == pytest.approx(100.0)
    assert cash == pytest.approx(SEED_EQUITY + 100.0)


# ---------------------------------------------------------------------------
# V8-04: per-user equity curve sampled on benchmark trading days
# ---------------------------------------------------------------------------


def test_equity_series_flat_at_seed_before_first_trade():
    orders = _orders(("buy", 10, 100, 5))  # first fill 2024-01-05
    dates = [date(2024, 1, 1), date(2024, 1, 2), date(2024, 1, 3)]
    series = reconstruct_equity_series(orders, dates, SEED_EQUITY)
    assert [p.equity for p in series] == [pytest.approx(SEED_EQUITY)] * 3


def test_equity_series_preserves_closed_trade_gain():
    """Acceptance: closed (realized) trades remain in the cumulative curve."""
    orders = _orders(("buy", 10, 100, 1), ("sell", 10, 110, 2))
    dates = [date(2024, 1, 1), date(2024, 1, 2), date(2024, 1, 3)]
    eq = {p.date: p.equity for p in reconstruct_equity_series(orders, dates, SEED_EQUITY)}
    assert eq["2024-01-01"] == pytest.approx(SEED_EQUITY)        # after buy, unrealized
    assert eq["2024-01-02"] == pytest.approx(SEED_EQUITY + 100)  # +$100 realized
    assert eq["2024-01-03"] == pytest.approx(SEED_EQUITY + 100)  # persists — never vanishes


def test_equity_series_forward_fills_idle_days():
    orders = _orders(("buy", 10, 100, 1), ("sell", 5, 120, 3))
    dates = [date(2024, 1, d) for d in (1, 2, 3, 4)]
    eq = {p.date: p.equity for p in reconstruct_equity_series(orders, dates, SEED_EQUITY)}
    assert eq["2024-01-02"] == pytest.approx(SEED_EQUITY)        # idle day holds prior
    assert eq["2024-01-03"] == pytest.approx(SEED_EQUITY + 100)  # sell 5 @120 vs 100 avg
    assert eq["2024-01-04"] == pytest.approx(SEED_EQUITY + 100)


def test_equity_series_respects_custom_starting_cash_and_sorts_dates():
    series = reconstruct_equity_series([], [date(2024, 1, 3), date(2024, 1, 1)], 5_000.0)
    assert [p.date for p in series] == ["2024-01-01", "2024-01-03"]
    assert all(p.equity == pytest.approx(5_000.0) for p in series)


def test_equity_series_marks_open_position_to_close():
    """An unclosed position moves the curve with its daily closes — the curve
    must not sit at the seed until the first sell."""
    orders = _orders(("buy", 10, 100, 1))
    dates = [date(2024, 1, d) for d in (1, 2, 3)]
    closes = {"AAPL": {
        date(2024, 1, 1): 100.0, date(2024, 1, 2): 110.0, date(2024, 1, 3): 105.0,
    }}
    eq = {p.date: p.equity for p in
          reconstruct_equity_series(orders, dates, SEED_EQUITY, closes=closes)}
    assert eq["2024-01-01"] == pytest.approx(SEED_EQUITY)         # close == cost
    assert eq["2024-01-02"] == pytest.approx(SEED_EQUITY + 100)   # 10 × (110−100)
    assert eq["2024-01-03"] == pytest.approx(SEED_EQUITY + 50)    # 10 × (105−100)


def test_equity_series_forward_fills_missing_close_days():
    """A day with no close for the symbol uses the most recent prior close."""
    orders = _orders(("buy", 10, 100, 1))
    dates = [date(2024, 1, d) for d in (1, 2, 3)]
    closes = {"AAPL": {date(2024, 1, 1): 120.0}}  # nothing for the 2nd/3rd
    series = reconstruct_equity_series(orders, dates, SEED_EQUITY, closes=closes)
    assert [p.equity for p in series] == [pytest.approx(SEED_EQUITY + 200)] * 3


def test_equity_series_values_symbol_without_closes_at_cost():
    """No closes for a held symbol → cost valuation (the realized-only floor)."""
    orders = _orders(("buy", 10, 100, 1))
    dates = [date(2024, 1, 1), date(2024, 1, 2)]
    series = reconstruct_equity_series(
        orders, dates, SEED_EQUITY, closes={"MSFT": {date(2024, 1, 1): 9.0}}
    )
    assert all(p.equity == pytest.approx(SEED_EQUITY) for p in series)


def test_equity_series_marks_short_positions():
    """Signed-quantity mark: a short gains when the close falls below basis."""
    orders = _orders(("sell", 10, 100, 1))
    dates = [date(2024, 1, 1), date(2024, 1, 2)]
    closes = {"AAPL": {date(2024, 1, 1): 100.0, date(2024, 1, 2): 90.0}}
    eq = {p.date: p.equity for p in
          reconstruct_equity_series(orders, dates, SEED_EQUITY, closes=closes)}
    assert eq["2024-01-01"] == pytest.approx(SEED_EQUITY)
    assert eq["2024-01-02"] == pytest.approx(SEED_EQUITY + 100)  # −10 × (90−100)


def test_equity_series_combines_realized_and_marked_unrealized():
    """Partial close: realized P/L and the remaining position's mark both count."""
    # Buy 10 @100; sell 5 @120 on day 2 (realized +100); close 130 on day 3.
    orders = _orders(("buy", 10, 100, 1), ("sell", 5, 120, 2))
    dates = [date(2024, 1, d) for d in (1, 2, 3)]
    closes = {"AAPL": {
        date(2024, 1, 1): 100.0, date(2024, 1, 2): 120.0, date(2024, 1, 3): 130.0,
    }}
    eq = {p.date: p.equity for p in
          reconstruct_equity_series(orders, dates, SEED_EQUITY, closes=closes)}
    # Day 2: +100 realized, remaining 5 marked at 120 → +100 unrealized.
    assert eq["2024-01-02"] == pytest.approx(SEED_EQUITY + 200)
    # Day 3: +100 realized, remaining 5 marked at 130 → +150 unrealized.
    assert eq["2024-01-03"] == pytest.approx(SEED_EQUITY + 250)


# ---------------------------------------------------------------------------
# Sanity
# ---------------------------------------------------------------------------


def test_paper_domain_constant():
    """Sanity: the paper-only sentinel matches Alpaca's documented hostname."""
    assert PAPER_DOMAIN == "paper-api.alpaca.markets"
