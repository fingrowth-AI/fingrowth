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
from app.services.virtual_balance import Balance
from app.tools.market_data import RateLimitError
from app.tools.paper_trading import LiveEndpointError, MissingCredentialsError

BASE = "http://test"


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


@pytest.fixture(autouse=True)
def _ample_buying_power(monkeypatch):
    """Default the V8-03 buy guard to 'plenty of cash' so the existing place-order
    tests exercise submission, not balance math. Tests that care about the guard
    override these two seams explicitly.

    Patched on the router module (where the names are bound) rather than the
    service, matching how the other callables here are stubbed.
    """

    async def _bp(session, user_id, *args, **kwargs):
        return 1_000_000.0

    async def _price(ticker, days=1, **kwargs):
        return [
            PriceBar(
                ticker=ticker.upper(),
                date=date(2024, 1, 15),
                open=100.0,
                high=101.0,
                low=99.0,
                close=100.0,
                volume=1000,
            )
        ]

    monkeypatch.setattr(router_module, "available_buying_power", _bp)
    monkeypatch.setattr(router_module, "get_daily_prices", _price)


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
# V8-03: buying-power validation before Alpaca
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_buy_exceeding_balance_rejected_before_alpaca(
    monkeypatch, client: AsyncClient
):
    """Acceptance: an order exceeding the user's balance is rejected (402) and
    never reaches Alpaca."""

    async def _broke(session, user_id, *args, **kwargs):
        return 500.0  # only $500 available

    monkeypatch.setattr(router_module, "available_buying_power", _broke)

    reached_alpaca = False

    async def fake_place(*args, **kwargs):
        nonlocal reached_alpaca
        reached_alpaca = True
        return _order()

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    # 10 shares * $100 reference price = $1000 > $500 available.
    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "buy"},
    )

    assert resp.status_code == 402
    assert "buying power" in resp.json()["detail"].lower()
    assert reached_alpaca is False  # rejected before submission


@pytest.mark.asyncio
async def test_affordable_buy_passes_guard_and_submits(monkeypatch, client: AsyncClient):
    async def _some_cash(session, user_id, *args, **kwargs):
        return 1500.0  # enough for 10 * $100

    monkeypatch.setattr(router_module, "available_buying_power", _some_cash)

    submitted = {}

    async def fake_place(*args, **kwargs):
        submitted["hit"] = True
        return _order()

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "buy"},
    )

    assert resp.status_code == 200
    assert submitted.get("hit") is True


@pytest.mark.asyncio
async def test_sell_within_long_is_allowed_and_not_balance_gated(
    monkeypatch, client: AsyncClient
):
    """A sell that closes part of a long is allowed and must never consult the
    buying-power guard (selling frees cash, it doesn't consume it)."""

    async def _broke(session, user_id, *args, **kwargs):
        raise AssertionError("sell path must not check buying power")

    monkeypatch.setattr(router_module, "available_buying_power", _broke)

    async def fake_positions(user_id):
        return [_position("AAPL", 25.0)]  # holds 25 long

    monkeypatch.setattr(router_module, "get_user_positions", fake_positions)

    async def fake_place(*args, **kwargs):
        return _order(side="sell")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "sell"},  # 10 <= 25
    )

    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_sell_exceeding_long_is_rejected_as_short(monkeypatch, client: AsyncClient):
    """Acceptance hardening (P1): a sell beyond the held long would open a short
    and mint virtual cash — refuse it (409) before Alpaca."""

    async def fake_positions(user_id):
        return [_position("AAPL", 5.0)]  # only 5 held long

    monkeypatch.setattr(router_module, "get_user_positions", fake_positions)

    reached_alpaca = False

    async def fake_place(*args, **kwargs):
        nonlocal reached_alpaca
        reached_alpaca = True
        return _order(side="sell")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 10, "side": "sell"},  # 10 > 5
    )

    assert resp.status_code == 409
    assert "short" in resp.json()["detail"].lower()
    assert reached_alpaca is False


@pytest.mark.asyncio
async def test_naked_short_with_no_position_is_rejected(monkeypatch, client: AsyncClient):
    async def fake_positions(user_id):
        return []  # holds nothing

    monkeypatch.setattr(router_module, "get_user_positions", fake_positions)

    async def fake_place(*args, **kwargs):  # pragma: no cover - must not run
        raise AssertionError("must not submit a naked short")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "TSLA", "quantity": 1, "side": "sell"},
    )

    assert resp.status_code == 409


@pytest.mark.asyncio
async def test_buy_fails_closed_on_market_data_transport_error(
    monkeypatch, client: AsyncClient
):
    """A raw transport failure while pricing must become a clean 503, not a 500,
    and must not reach Alpaca."""

    async def _boom(ticker, days=1, **kwargs):
        raise httpx.ConnectError("dns boom")

    monkeypatch.setattr(router_module, "get_daily_prices", _boom)

    async def fake_place(*args, **kwargs):  # pragma: no cover - must not run
        raise AssertionError("must not submit when pricing failed")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )

    assert resp.status_code == 503
    assert "unreachable" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_buy_maps_market_data_http_error_to_502(monkeypatch, client: AsyncClient):
    async def _bad_status(ticker, days=1, **kwargs):
        request = httpx.Request("GET", "https://www.alphavantage.co/query")
        response = httpx.Response(503, request=request)
        raise httpx.HTTPStatusError("upstream", request=request, response=response)

    monkeypatch.setattr(router_module, "get_daily_prices", _bad_status)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )

    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_buy_rejected_when_price_unavailable(monkeypatch, client: AsyncClient):
    """If we can't price the order we can't validate buying power, so the buy is
    refused rather than silently bypassing the check."""

    async def _no_price(ticker, days=1, **kwargs):
        return []

    monkeypatch.setattr(router_module, "get_daily_prices", _no_price)

    async def fake_place(*args, **kwargs):  # pragma: no cover - must not run
        raise AssertionError("must not submit when price is unavailable")

    monkeypatch.setattr(router_module, "place_paper_order", fake_place)

    resp = await client.post(
        "/api/v1/paper/order",
        json={"ticker": "AAPL", "quantity": 1, "side": "buy"},
    )

    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# GET /paper/balance (V8-03)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_balance_returns_tracked_cash(monkeypatch, client: AsyncClient):
    captured: dict = {}

    async def fake_balance(session, user_id, *args, **kwargs):
        captured["user_id"] = user_id
        return Balance(starting_cash=100000.0, cash=98750.0)

    monkeypatch.setattr(router_module, "get_balance", fake_balance)

    resp = await client.get("/api/v1/paper/balance")

    assert resp.status_code == 200
    assert resp.json() == {"starting_cash": 100000.0, "cash": 98750.0}
    # Balance is scoped to the resolved user (default user here).
    assert captured["user_id"] == DEFAULT_USER_ID


# ---------------------------------------------------------------------------
# GET /paper/performance (V8-04)
# ---------------------------------------------------------------------------


def _bars(ticker: str, *day_closes: tuple[int, float]) -> list[PriceBar]:
    return [
        PriceBar(ticker=ticker, date=date(2024, 1, d), open=p, high=p, low=p,
                 close=p, volume=1)
        for d, p in day_closes
    ]


def _spy_bars():
    return _bars("SPY", (1, 400.0), (2, 410.0), (3, 420.0))


@pytest.mark.asyncio
async def test_performance_overlays_user_curve_on_benchmark(
    monkeypatch, client: AsyncClient
):
    """Acceptance: per-user curve, closed trades preserved, comparable to SPY
    over the same window."""
    captured: dict = {}

    async def fake_spy(symbol, days=30, **kwargs):
        if symbol == "SPY":
            captured["symbol"] = symbol
            return _spy_bars()
        # The held symbol's closes: day-1 close equals the fill price, so the
        # open position carries no mark before it's sold on day 2.
        return _bars(symbol, (1, 100.0), (2, 110.0), (3, 120.0))

    async def fake_cash(session, user_id):
        return 100000.0

    async def fake_orders(user_id, *, status="all", client=None):
        captured["user_id"] = user_id
        # Buy then sell at a $100 gain, realized on 2024-01-02.
        return [
            _order(
                side="buy", filled_qty=10.0, filled_avg_price=100.0,
                submitted_at=datetime(2024, 1, 1, tzinfo=timezone.utc),
            ),
            _order(
                side="sell", filled_qty=10.0, filled_avg_price=110.0,
                submitted_at=datetime(2024, 1, 2, tzinfo=timezone.utc),
            ),
        ]

    monkeypatch.setattr(router_module, "get_daily_prices", fake_spy)
    monkeypatch.setattr(router_module, "get_or_create_starting_cash", fake_cash)
    monkeypatch.setattr(router_module, "get_user_orders", fake_orders)

    resp = await client.get("/api/v1/paper/performance?days=3")

    assert resp.status_code == 200
    body = resp.json()
    assert body["benchmark_symbol"] == "SPY"
    assert body["base_equity"] == pytest.approx(100000.0)
    # The curve is scoped to the resolved user (default user here).
    assert captured["user_id"] == DEFAULT_USER_ID

    pts = body["points"]
    # Same window/x-axis as the benchmark.
    assert [p["date"] for p in pts] == ["2024-01-01", "2024-01-02", "2024-01-03"]
    # Portfolio: 100000 -> 100100 -> 100100 (closed gain preserved on day 3).
    assert pts[2]["equity"] == pytest.approx(100100.0)
    assert pts[0]["portfolio_return"] == pytest.approx(0.0)
    assert pts[1]["portfolio_return"] == pytest.approx(0.001)
    assert pts[2]["portfolio_return"] == pytest.approx(0.001)
    # Benchmark: 400 -> 410 -> 420 == 0, +2.5%, +5%.
    assert pts[1]["benchmark_return"] == pytest.approx(0.025)
    assert pts[2]["benchmark_return"] == pytest.approx(0.05)


@pytest.mark.asyncio
async def test_performance_marks_open_positions_to_market(
    monkeypatch, client: AsyncClient
):
    """An unclosed position must move the curve with the market — a portfolio
    of open trades previously read 0% until the first sell."""

    async def fake_prices(symbol, days=30, **kwargs):
        if symbol == "SPY":
            return _spy_bars()
        return _bars(symbol, (1, 100.0), (2, 110.0), (3, 120.0))

    async def fake_cash(session, user_id):
        return 100000.0

    async def fake_orders(user_id, *, status="all", client=None):
        # One open buy, never sold.
        return [
            _order(
                side="buy", filled_qty=10.0, filled_avg_price=100.0,
                submitted_at=datetime(2024, 1, 1, tzinfo=timezone.utc),
            ),
        ]

    monkeypatch.setattr(router_module, "get_daily_prices", fake_prices)
    monkeypatch.setattr(router_module, "get_or_create_starting_cash", fake_cash)
    monkeypatch.setattr(router_module, "get_user_orders", fake_orders)

    resp = await client.get("/api/v1/paper/performance?days=3")

    assert resp.status_code == 200
    pts = resp.json()["points"]
    # 10 shares bought @100: closes 100 / 110 / 120 → +0, +$100, +$200.
    assert pts[0]["portfolio_return"] == pytest.approx(0.0)
    assert pts[1]["portfolio_return"] == pytest.approx(0.001)
    assert pts[2]["portfolio_return"] == pytest.approx(0.002)
    assert pts[2]["equity"] == pytest.approx(100200.0)


@pytest.mark.asyncio
async def test_performance_falls_back_to_cost_when_symbol_prices_unavailable(
    monkeypatch, client: AsyncClient
):
    """A rate-limited held symbol degrades to cost valuation (the realized-only
    floor) instead of failing the endpoint."""

    async def fake_prices(symbol, days=30, **kwargs):
        if symbol == "SPY":
            return _spy_bars()
        raise RateLimitError("slow down")

    async def fake_cash(session, user_id):
        return 100000.0

    async def fake_orders(user_id, *, status="all", client=None):
        return [
            _order(
                side="buy", filled_qty=10.0, filled_avg_price=100.0,
                submitted_at=datetime(2024, 1, 1, tzinfo=timezone.utc),
            ),
        ]

    monkeypatch.setattr(router_module, "get_daily_prices", fake_prices)
    monkeypatch.setattr(router_module, "get_or_create_starting_cash", fake_cash)
    monkeypatch.setattr(router_module, "get_user_orders", fake_orders)

    resp = await client.get("/api/v1/paper/performance?days=3")

    assert resp.status_code == 200
    pts = resp.json()["points"]
    assert [p["portfolio_return"] for p in pts] == [pytest.approx(0.0)] * 3


@pytest.mark.asyncio
async def test_performance_empty_benchmark_returns_empty_curve(
    monkeypatch, client: AsyncClient
):
    async def fake_empty(symbol, days=30, **kwargs):
        return []

    monkeypatch.setattr(router_module, "get_daily_prices", fake_empty)

    resp = await client.get("/api/v1/paper/performance?days=3")
    assert resp.status_code == 200
    body = resp.json()
    assert body["points"] == []
    assert body["base_equity"] == 0.0


@pytest.mark.asyncio
async def test_performance_maps_market_data_rate_limit(monkeypatch, client: AsyncClient):
    async def fake_rl(symbol, days=30, **kwargs):
        raise RateLimitError("slow down")

    monkeypatch.setattr(router_module, "get_daily_prices", fake_rl)

    resp = await client.get("/api/v1/paper/performance?days=3")
    assert resp.status_code == 429


@pytest.mark.asyncio
async def test_performance_rejects_non_positive_days(client: AsyncClient):
    resp = await client.get("/api/v1/paper/performance?days=0")
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# V8-05 (P1): benchmark symbol allowlist — close the unbilled-fetch bypass
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_benchmark_rejects_arbitrary_symbol(monkeypatch, client: AsyncClient):
    """A non-benchmark ticker can't be fetched (unbilled) via /benchmark."""

    async def _must_not_fetch(*a, **k):  # pragma: no cover - must not run
        raise AssertionError("arbitrary symbol must be rejected before fetch")

    monkeypatch.setattr(router_module, "get_daily_prices", _must_not_fetch)

    resp = await client.get("/api/v1/paper/benchmark?symbol=NVDA&days=5")
    assert resp.status_code == 400
    assert "benchmark" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_performance_rejects_arbitrary_symbol(monkeypatch, client: AsyncClient):
    async def _must_not_fetch(*a, **k):  # pragma: no cover - must not run
        raise AssertionError("arbitrary symbol must be rejected before fetch")

    monkeypatch.setattr(router_module, "get_daily_prices", _must_not_fetch)

    resp = await client.get("/api/v1/paper/performance?symbol=AAPL&days=5")
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_benchmark_allows_allowlisted_symbol(monkeypatch, client: AsyncClient):
    async def fake_bars(symbol, days=30, **kwargs):
        return [
            PriceBar(ticker=symbol.upper(), date=date(2024, 1, 2), open=1.0,
                     high=1.0, low=1.0, close=1.0, volume=1)
        ]

    monkeypatch.setattr(router_module, "get_daily_prices", fake_bars)

    resp = await client.get("/api/v1/paper/benchmark?symbol=QQQ&days=5")
    assert resp.status_code == 200
    assert resp.json()["symbol"] == "QQQ"


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
