"""Paper trading client (P2-05).

Wraps Alpaca's REST API at the paper-trading endpoint. Hard safety rule:
every call validates that ``settings.alpaca_base_url`` references the
``paper-api.alpaca.markets`` domain — if it doesn't, we raise
:class:`LiveEndpointError` *before* sending any request.

This module is intentionally minimal. It exposes only the three primitives
the design doc enumerates (place order, list positions, list orders). Bracket
orders, OCO/OTO, and trailing-stop variants are left to a follow-up.
"""

from __future__ import annotations

import bisect
import uuid
from collections.abc import Mapping
from datetime import date, datetime, timezone
from urllib.parse import urlparse

import httpx

from app.config import settings
from app.models.trading import (
    Order,
    PortfolioHistory,
    PortfolioHistoryPoint,
    Position,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PAPER_DOMAIN = "paper-api.alpaca.markets"
DEFAULT_TIMEOUT = httpx.Timeout(15.0, connect=10.0)
ALLOWED_SIDES = frozenset({"buy", "sell"})
# Alpaca caps each /v2/orders response at 500 and offers no server-side
# client_order_id-prefix filter, so per-user reconstruction pages backward
# through the shared account's feed and filters client-side (V8-02). This is
# the overall ceiling on how far back we page — it must exceed ORDER_PAGE_SIZE
# (the per-response cap), otherwise the loop stops after one page and an older
# order still backing a user's open position is hidden by newer orders from
# other users.
MAX_ACCOUNT_ORDER_FETCH = 5000


# ---------------------------------------------------------------------------
# Per-user trade tagging (V8-02)
# ---------------------------------------------------------------------------


def make_client_order_id(user_id: uuid.UUID | str) -> str:
    """Encode the owning user in an Alpaca client_order_id: ``{user_id}_{uuid}``.

    user_id is a 36-char UUID containing no underscores, so the ``{user_id}_``
    prefix is unambiguous — one user's prefix can never match another's order.
    """
    return f"{user_id}_{uuid.uuid4().hex}"


def user_order_prefix(user_id: uuid.UUID | str) -> str:
    """The client_order_id prefix identifying ``user_id``'s orders."""
    return f"{user_id}_"


def order_belongs_to_user(order: Order, user_id: uuid.UUID | str) -> bool:
    """True if ``order`` was tagged for ``user_id`` via its client_order_id."""
    return (order.client_order_id or "").startswith(user_order_prefix(user_id))


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class PaperTradingError(Exception):
    """Base error for the paper trading client."""


class LiveEndpointError(PaperTradingError):
    """Refused to call a non-paper Alpaca endpoint.

    This is a safety guard, not a transport error: it fires before any
    network I/O if ``ALPACA_BASE_URL`` does not reference the paper domain.
    """


class MissingCredentialsError(PaperTradingError):
    """``ALPACA_API_KEY`` / ``ALPACA_SECRET_KEY`` are not configured."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _require_paper_endpoint() -> str:
    """Return the trimmed Alpaca base URL after asserting it's paper-only.

    Alpaca's docs are inconsistent about whether ``/v2`` belongs in the base
    URL or the path; we accept either by stripping a trailing ``/v2`` so our
    callers can always append ``/v2/<resource>``.

    The paper-only guard parses the URL and requires the host to be *exactly*
    the paper domain. A substring check would accept a hostile look-alike such
    as ``paper-api.alpaca.markets.evil.com`` or ``paper-api.alpaca.markets``
    embedded in a path/userinfo segment.
    """
    base = (settings.alpaca_base_url or "").rstrip("/")
    parsed = urlparse(base)
    if parsed.scheme not in ("http", "https") or parsed.hostname != PAPER_DOMAIN:
        raise LiveEndpointError(
            f"refusing to call non-paper endpoint: {base!r}; "
            f"ALPACA_BASE_URL host must be exactly {PAPER_DOMAIN}"
        )
    if base.endswith("/v2"):
        base = base[: -len("/v2")]
    return base


def _auth_headers() -> dict[str, str]:
    if not settings.alpaca_api_key or not settings.alpaca_secret_key:
        raise MissingCredentialsError(
            "ALPACA_API_KEY / ALPACA_SECRET_KEY are not configured"
        )
    return {
        "APCA-API-KEY-ID": settings.alpaca_api_key,
        "APCA-API-SECRET-KEY": settings.alpaca_secret_key,
        "Accept": "application/json",
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def place_paper_order(
    ticker: str,
    qty: float,
    side: str,
    *,
    order_type: str = "market",
    time_in_force: str = "day",
    user_id: uuid.UUID | str | None = None,
    client: httpx.AsyncClient | None = None,
) -> Order:
    """Place a paper order. Always paper — live endpoint will raise.

    When ``user_id`` is given the order carries a user-prefixed client_order_id
    (V8-02) so it can later be attributed back to its owner in the shared Alpaca
    account.
    """
    if side not in ALLOWED_SIDES:
        raise ValueError(f"side must be one of {sorted(ALLOWED_SIDES)}, got {side!r}")
    if qty <= 0:
        raise ValueError("qty must be > 0")
    base = _require_paper_endpoint()

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        body = {
            "symbol": ticker.upper(),
            "qty": str(qty),
            "side": side,
            "type": order_type,
            "time_in_force": time_in_force,
        }
        if user_id is not None:
            body["client_order_id"] = make_client_order_id(user_id)
        resp = await client.post(
            f"{base}/v2/orders",
            json=body,
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        return Order.model_validate(resp.json())
    finally:
        if own_client:
            await client.aclose()


async def get_positions(
    *,
    client: httpx.AsyncClient | None = None,
) -> list[Position]:
    """Return the current paper positions list (empty when none held)."""
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        resp = await client.get(f"{base}/v2/positions", headers=_auth_headers())
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, list):
            return []
        return [Position.model_validate(p) for p in data]
    finally:
        if own_client:
            await client.aclose()


async def get_order_history(
    limit: int = 50,
    *,
    status: str = "all",
    client: httpx.AsyncClient | None = None,
) -> list[Order]:
    """Return the most recent ``limit`` orders.

    ``status`` follows Alpaca's filter (``open`` / ``closed`` / ``all``).
    """
    if limit <= 0:
        raise ValueError("limit must be > 0")
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        params = {"limit": str(limit), "status": status}
        resp = await client.get(
            f"{base}/v2/orders",
            params=params,
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, list):
            return []
        return [Order.model_validate(o) for o in data]
    finally:
        if own_client:
            await client.aclose()


# ---------------------------------------------------------------------------
# Per-user reconstruction (V8-02)
#
# The Alpaca account is shared, so its /v2/positions and account-level
# portfolio-history endpoints aggregate every user. A user's own
# positions/history are instead reconstructed from their orders, identified by
# the client_order_id prefix.
#
# NOTE: reconstructing from the shared order feed is the interim approach. The
# durable per-user accounting moves into our own DB in V8-03/V8-04 (virtual cash
# + a stored trade log), which removes the dependence on the shared feed
# entirely.
# ---------------------------------------------------------------------------


_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
ORDER_PAGE_SIZE = 500
# Seed equity for the per-user curve. V8-03 formalizes this as tracked virtual
# cash; kept here as the shared baseline so the interim curve is meaningful.
SEED_EQUITY = 100_000.0


async def _fetch_account_orders(
    status: str,
    *,
    client: httpx.AsyncClient | None = None,
    max_orders: int = MAX_ACCOUNT_ORDER_FETCH,
) -> list[Order]:
    """Page backward through the shared account's orders, newest first.

    Alpaca caps each /v2/orders response at 500 and offers no client_order_id
    filter, so per-user reconstruction must scan the account feed. Paging via
    ``until`` (exclusive) walks past the 500 cap so an older order that still
    backs a user's open position isn't hidden by newer orders from other users
    (V8-02 hardening), bounded by ``max_orders``.
    """
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    collected: list[Order] = []
    until: str | None = None
    try:
        while len(collected) < max_orders:
            params = {
                "limit": str(ORDER_PAGE_SIZE),
                "status": status,
                "direction": "desc",
            }
            if until is not None:
                params["until"] = until
            resp = await client.get(
                f"{base}/v2/orders", params=params, headers=_auth_headers()
            )
            resp.raise_for_status()
            data = resp.json()
            if not isinstance(data, list) or not data:
                break
            page = [Order.model_validate(o) for o in data]
            collected.extend(page)
            if len(data) < ORDER_PAGE_SIZE:
                break  # last page
            oldest = page[-1].submitted_at
            if oldest is None:
                break  # can't page without a cursor
            until = oldest.isoformat()
        return collected[:max_orders]
    finally:
        if own_client:
            await client.aclose()


async def get_user_order_history(
    user_id: uuid.UUID | str,
    limit: int = 50,
    *,
    status: str = "all",
    client: httpx.AsyncClient | None = None,
) -> list[Order]:
    """Return up to ``limit`` of ``user_id``'s most recent orders.

    Keeps only orders whose client_order_id carries the user's prefix, so one
    user never sees another's.
    """
    if limit <= 0:
        raise ValueError("limit must be > 0")
    orders = await _fetch_account_orders(status, client=client)
    mine = [o for o in orders if order_belongs_to_user(o, user_id)]
    return mine[:limit]


async def get_user_orders(
    user_id: uuid.UUID | str,
    *,
    status: str = "all",
    client: httpx.AsyncClient | None = None,
) -> list[Order]:
    """All of ``user_id``'s orders from the shared account, prefix-filtered.

    Unlike :func:`get_user_order_history` this applies no ``limit`` slice — it
    returns the user's full window so position, cash, and equity reconstruction
    see every fill.
    """
    orders = await _fetch_account_orders(status, client=client)
    return [o for o in orders if order_belongs_to_user(o, user_id)]


async def get_user_positions(
    user_id: uuid.UUID | str,
    *,
    client: httpx.AsyncClient | None = None,
) -> list[Position]:
    """Reconstruct ``user_id``'s open positions from their filled orders."""
    return reconstruct_positions(await get_user_orders(user_id, client=client))


async def get_user_portfolio_history(
    user_id: uuid.UUID | str,
    *,
    client: httpx.AsyncClient | None = None,
) -> PortfolioHistory:
    """Per-user equity curve reconstructed from the user's filled orders.

    Replaces the account-level portfolio-history call, which aggregated every
    user (a cross-user leak). The curve is ``SEED_EQUITY`` plus cumulative
    realized P/L, so closed trades stay in the curve. Open-position
    mark-to-market and benchmark windowing are the remit of V8-04; this is the
    non-leaking interim.
    """
    return reconstruct_portfolio_history(await get_user_orders(user_id, client=client))


def _apply_fill(
    qty: float, avg: float, side: str, fill: float, price: float
) -> tuple[float, float, float]:
    """Apply one fill under average-cost accounting.

    Returns ``(new_qty, new_avg, realized_pnl)`` and handles every direction —
    adding to a long/short, reducing it, fully closing, and flipping through
    zero — so short covers keep the short's basis and flips re-base at the fill
    price. ``qty`` is signed (long > 0, short < 0).
    """
    delta = fill if side == "buy" else -fill
    new_qty = qty + delta

    if qty == 0:
        # Opening from flat.
        return new_qty, price, 0.0

    increasing = (qty > 0) == (delta > 0)
    if increasing:
        total = abs(qty) + abs(delta)
        new_avg = (avg * abs(qty) + price * abs(delta)) / total
        return new_qty, new_avg, 0.0

    # Opposite direction: reducing, closing, or flipping the position.
    closed = min(abs(delta), abs(qty))
    realized = (price - avg) * closed if qty > 0 else (avg - price) * closed
    if abs(delta) < abs(qty):
        return new_qty, avg, realized  # partial reduce — basis unchanged
    if abs(delta) == abs(qty):
        return 0.0, 0.0, realized  # fully closed
    return new_qty, price, realized  # flipped — remainder opens at the fill price


def _filled_chronological(orders: list[Order]) -> list[Order]:
    filled = [o for o in orders if (o.filled_qty or 0) > 0]
    filled.sort(key=lambda o: o.submitted_at or _EPOCH)
    return filled


def _net_fills(orders: list[Order]) -> tuple[dict[str, tuple[float, float]], float]:
    """Replay filled orders into ``(symbol -> (signed_qty, avg_price), realized_pnl)``.

    The single source of truth for average-cost accounting, shared by position,
    cash, and equity reconstruction so they can never disagree.
    """
    state: dict[str, tuple[float, float]] = {}
    realized = 0.0
    for order in _filled_chronological(orders):
        qty, avg = state.get(order.symbol, (0.0, 0.0))
        new_qty, new_avg, pnl = _apply_fill(
            qty, avg, order.side, float(order.filled_qty), float(order.filled_avg_price or 0.0)
        )
        state[order.symbol] = (new_qty, new_avg)
        realized += pnl
    return state, realized


def reconstruct_realized_pnl(orders: list[Order]) -> float:
    """Cumulative realized P/L across a user's filled orders (closed trades)."""
    _state, realized = _net_fills(orders)
    return realized


def reconstruct_cash(orders: list[Order], starting_cash: float = SEED_EQUITY) -> float:
    """Available virtual cash after replaying a user's fills against the seed (V8-03).

    Buys debit cash by their fill notional, sells credit it. Derived from the
    same fill log as :func:`reconstruct_positions`, so cash and positions
    reconcile by construction: for long positions,
    ``cash + sum(cost_basis) == starting_cash + realized_pnl``.

    Note: this counts *filled* notional. Resting (unfilled) buy orders are not
    yet reserved against cash — a refinement left to follow-up, consistent with
    the interim reconstruction approach. Paper market orders fill effectively
    immediately, so the window is small.
    """
    cash = starting_cash
    for order in _filled_chronological(orders):
        notional = float(order.filled_qty) * float(order.filled_avg_price or 0.0)
        cash += -notional if order.side == "buy" else notional
    return cash


def reconstruct_positions(orders: list[Order]) -> list[Position]:
    """Net a user's filled orders into current open positions (average-cost).

    Symbols that net to zero are dropped. Live valuation (market_value /
    unrealized_pl) is left to V8-04; here we report the deterministic,
    order-derived figures.
    """
    state, _realized = _net_fills(orders)
    positions: list[Position] = []
    for symbol, (qty, avg) in sorted(state.items()):
        if abs(qty) < 1e-9:
            continue
        positions.append(
            Position(
                symbol=symbol,
                qty=abs(qty),
                side="long" if qty > 0 else "short",
                avg_entry_price=avg,
                cost_basis=avg * abs(qty),
                market_value=None,
                unrealized_pl=None,
            )
        )
    return positions


def reconstruct_portfolio_history(orders: list[Order]) -> PortfolioHistory:
    """Build a per-user equity curve (SEED + cumulative realized P/L) by day."""
    state: dict[str, tuple[float, float]] = {}
    cumulative_realized = 0.0
    daily: dict[str, float] = {}
    for order in _filled_chronological(orders):
        qty, avg = state.get(order.symbol, (0.0, 0.0))
        new_qty, new_avg, realized = _apply_fill(
            qty, avg, order.side, float(order.filled_qty), float(order.filled_avg_price or 0.0)
        )
        state[order.symbol] = (new_qty, new_avg)
        cumulative_realized += realized
        day = (order.submitted_at or _EPOCH).date().isoformat()
        daily[day] = SEED_EQUITY + cumulative_realized

    points = [
        PortfolioHistoryPoint(date=day, equity=equity)
        for day, equity in sorted(daily.items())
    ]
    return PortfolioHistory(base_value=SEED_EQUITY, points=points)


def reconstruct_equity_series(
    orders: list[Order],
    dates: list[date],
    starting_cash: float = SEED_EQUITY,
    closes: Mapping[str, Mapping[date, float]] | None = None,
) -> list[PortfolioHistoryPoint]:
    """Sample a user's equity at each date in ``dates`` (V8-04).

    Equity is ``starting_cash + cumulative realized P/L + unrealized P/L`` as of
    each date — derived from the reconstructed trade log and virtual cash, never
    from Alpaca's account-level history. Consequences the acceptance criteria
    call for:

    * **Per-user**: ``orders`` are the caller's own (prefix-filtered) fills, so
      the curve reflects only their trades.
    * **Closed trades persist**: realized P/L is accumulated and carried
      forward, so a completed winning trade permanently lifts the curve instead
      of vanishing when its proceeds are spent.
    * **Open trades move the curve**: positions still open are marked to the
      day's close from ``closes`` (``symbol -> day -> close``, forward-filled to
      the most recent close on or before each sampled day). A symbol with no
      usable close — or ``closes=None`` — is valued at cost, so the curve
      degrades to the realized-only floor rather than failing.

    Sampling on a supplied date list (rather than only trade days) lets the
    curve be overlaid on a benchmark series that shares those trading days —
    every date gets a point via forward-fill. Dates before the first fill read
    the untouched ``starting_cash``.
    """
    filled = _filled_chronological(orders)
    state: dict[str, tuple[float, float]] = {}
    realized = 0.0
    i = 0
    points: list[PortfolioHistoryPoint] = []
    # Pre-sorted close dates per symbol for the forward-fill lookups.
    close_dates: dict[str, list[date]] = {
        symbol: sorted(series) for symbol, series in (closes or {}).items()
    }
    for day in sorted(dates):
        # Fold in every fill submitted on or before this day, once.
        while i < len(filled) and (filled[i].submitted_at or _EPOCH).date() <= day:
            order = filled[i]
            qty, avg = state.get(order.symbol, (0.0, 0.0))
            new_qty, new_avg, pnl = _apply_fill(
                qty, avg, order.side, float(order.filled_qty),
                float(order.filled_avg_price or 0.0),
            )
            state[order.symbol] = (new_qty, new_avg)
            realized += pnl
            i += 1
        # Mark open positions to the latest close on or before this day. Signed
        # qty makes the same expression correct for shorts.
        unrealized = 0.0
        if closes:
            for symbol, (qty, avg) in state.items():
                if abs(qty) < 1e-9:
                    continue
                close = _close_on_or_before(
                    close_dates.get(symbol, []), closes.get(symbol, {}), day
                )
                if close is not None:
                    unrealized += qty * (close - avg)
        points.append(
            PortfolioHistoryPoint(
                date=day.isoformat(), equity=starting_cash + realized + unrealized
            )
        )
    return points


def _close_on_or_before(
    sorted_days: list[date], series: Mapping[date, float], day: date
) -> float | None:
    """The most recent close at or before ``day``; None when none exists yet."""
    index = bisect.bisect_right(sorted_days, day) - 1
    if index < 0:
        return None
    return series[sorted_days[index]]


# Alpaca accepts a fixed vocabulary for these; we validate up front so a typo
# becomes a 400 rather than an opaque upstream 422.
ALLOWED_HISTORY_PERIODS = frozenset(
    {"1D", "1W", "1M", "3M", "6M", "1A", "2A", "5A", "all"}
)
ALLOWED_HISTORY_TIMEFRAMES = frozenset({"1Min", "5Min", "15Min", "1H", "1D"})


async def get_portfolio_history(
    *,
    period: str = "1M",
    timeframe: str = "1D",
    client: httpx.AsyncClient | None = None,
) -> PortfolioHistory:
    """Return the account's equity curve from Alpaca's portfolio history.

    Unlike summing current positions, this reflects *realised* outcomes too:
    when a paper position is closed, its gain/loss is baked into account
    equity, so the curve never loses a completed trade.
    """
    if period not in ALLOWED_HISTORY_PERIODS:
        raise ValueError(
            f"period must be one of {sorted(ALLOWED_HISTORY_PERIODS)}, got {period!r}"
        )
    if timeframe not in ALLOWED_HISTORY_TIMEFRAMES:
        raise ValueError(
            f"timeframe must be one of {sorted(ALLOWED_HISTORY_TIMEFRAMES)}, "
            f"got {timeframe!r}"
        )
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        params = {"period": period, "timeframe": timeframe}
        resp = await client.get(
            f"{base}/v2/account/portfolio/history",
            params=params,
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        return _parse_portfolio_history(resp.json())
    finally:
        if own_client:
            await client.aclose()


def _parse_portfolio_history(data: object) -> PortfolioHistory:
    """Flatten Alpaca's parallel timestamp/equity arrays into typed points.

    Alpaca pads the series with ``null`` (sessions with no data) and ``0.0``
    equities (days before the account was funded). We drop both so the client
    never plots a phantom zero or a misleading -100% return at the start.
    """
    if not isinstance(data, dict):
        return PortfolioHistory(base_value=0.0, points=[])
    timestamps = data.get("timestamp") or []
    equities = data.get("equity") or []
    points: list[PortfolioHistoryPoint] = []
    for ts, eq in zip(timestamps, equities):
        if eq is None or ts is None or float(eq) <= 0:
            continue
        day = datetime.fromtimestamp(ts, tz=timezone.utc).date().isoformat()
        points.append(PortfolioHistoryPoint(date=day, equity=float(eq)))
    base_value = data.get("base_value")
    return PortfolioHistory(
        base_value=float(base_value) if base_value is not None else 0.0,
        points=points,
    )
