"""HTTP surface for paper trading (P4-04).

Thin REST wrappers around the Alpaca client in :mod:`app.tools.paper_trading`.
Three endpoints — list positions, list orders, place an order — covering the
acceptance criteria for the iOS Portfolio tab.

Safety: the underlying client raises :class:`LiveEndpointError` if
``ALPACA_BASE_URL`` is not the paper domain. We surface that as **503**
(service unavailable) so the iOS client can distinguish "we refused, fix
config" from "Alpaca is down".

Errors are mapped, not leaked:

    * ``MissingCredentialsError`` → 401 (server misconfig, but the message
      tells the operator what to fix)
    * ``LiveEndpointError``       → 503
    * ``httpx.HTTPStatusError``   → 502 (upstream rejected us)
    * ``ValueError``              → 400 (bad request)

Everything else becomes a 500 via FastAPI's default handler.
"""

from __future__ import annotations

import logging
from typing import Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import CurrentUser
from app.db import get_session
from app.models.trading import Order, PortfolioHistory, Position
from app.services.virtual_balance import available_buying_power, get_balance
from app.tools.market_data import (
    MarketDataError,
    MissingAPIKeyError,
    RateLimitError,
    StalePriceDataError,
    get_daily_prices,
)
from app.tools.paper_trading import (
    ALLOWED_SIDES,
    LiveEndpointError,
    MissingCredentialsError,
    get_user_order_history,
    get_user_portfolio_history,
    get_user_positions,
    place_paper_order,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/paper", tags=["paper-trading"])


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class PlaceOrderRequest(BaseModel):
    """Body for POST /paper/order.

    Field names follow the design-doc contract (§7.3): ``ticker``,
    ``quantity``, ``side``. ``order_type`` and ``time_in_force`` mirror
    Alpaca's defaults. ``side`` is a constrained literal so validation errors
    surface a clear message that mentions the value the client sent.
    """

    ticker: str = Field(..., min_length=1, max_length=10)
    quantity: float = Field(..., gt=0)
    side: Literal["buy", "sell"]
    order_type: str = Field(default="market", min_length=1)
    time_in_force: str = Field(default="day", min_length=1)


class PositionsResponse(BaseModel):
    """GET /paper/positions envelope — matches design-doc §7.3."""

    positions: list[Position]


class OrdersResponse(BaseModel):
    """GET /paper/orders envelope — matches design-doc §7.3."""

    orders: list[Order]


class BalanceResponse(BaseModel):
    """GET /paper/balance — the user's tracked virtual cash (V8-03)."""

    starting_cash: float
    cash: float


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


async def _reference_price(ticker: str) -> float:
    """Latest daily close for ``ticker``, used to value a market buy up front.

    Market orders have no fill price at submit time, so buying-power validation
    needs a price estimate. The most-recent close is the server's source of
    truth (already cached, and the same series the Performance chart uses).
    Market-data failures are mapped to a clear HTTP status rather than silently
    skipping the balance check — V8-03 validates *before* reaching Alpaca.
    """
    try:
        bars = await get_daily_prices(ticker, days=1)
    except MissingAPIKeyError as exc:
        raise HTTPException(
            status_code=503,
            detail="Cannot validate buying power: market-data API key is not configured.",
        ) from exc
    except RateLimitError as exc:
        raise HTTPException(
            status_code=429,
            detail="Cannot validate buying power right now: market data is rate-limited.",
        ) from exc
    except StalePriceDataError as exc:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot validate buying power: price data is stale ({exc}).",
        ) from exc
    except MarketDataError as exc:
        raise HTTPException(
            status_code=502, detail=f"Cannot validate buying power: {exc}"
        ) from exc
    except httpx.HTTPStatusError as exc:
        # raise_for_status() inside the market-data client (e.g. AV 5xx).
        raise HTTPException(
            status_code=502,
            detail=(
                "Cannot validate buying power: market data provider returned "
                f"HTTP {exc.response.status_code}."
            ),
        ) from exc
    except httpx.RequestError as exc:
        # Transport failure (DNS/connect/timeout). Fail closed — we never skip
        # the balance check just because pricing was unreachable.
        raise HTTPException(
            status_code=503,
            detail="Cannot validate buying power: market data is unreachable.",
        ) from exc
    if not bars:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot validate buying power: no price available for {ticker.upper()}.",
        )
    return bars[0].close


async def _user_long_quantity(user_id: str, ticker: str) -> float:
    """Shares of ``ticker`` the user currently holds long (0 if none).

    Reconstructed from the user's own filled orders (V8-02), so it never sees
    another user's position in the shared account.
    """
    positions = await get_user_positions(user_id)
    symbol = ticker.upper()
    for p in positions:
        if p.symbol == symbol and p.side == "long":
            return p.qty
    return 0.0


def _map_client_error(exc: Exception) -> HTTPException:
    """Translate paper-trading client errors into HTTPException."""
    if isinstance(exc, MissingCredentialsError):
        return HTTPException(
            status_code=401,
            detail="Alpaca credentials are not configured on the backend.",
        )
    if isinstance(exc, LiveEndpointError):
        return HTTPException(
            status_code=503,
            detail=(
                "Backend refused to call a non-paper Alpaca endpoint; "
                "set ALPACA_BASE_URL to the paper domain."
            ),
        )
    if isinstance(exc, httpx.HTTPStatusError):
        return HTTPException(
            status_code=502,
            detail=f"Alpaca rejected the request (HTTP {exc.response.status_code}).",
        )
    if isinstance(exc, httpx.RequestError):
        # Transport failure reaching Alpaca (DNS/connect/timeout) — distinct from
        # a 5xx it returned. Surface as unavailable rather than an opaque 500.
        return HTTPException(
            status_code=503, detail="Alpaca is unreachable; try again shortly."
        )
    if isinstance(exc, ValueError):
        return HTTPException(status_code=400, detail=str(exc))
    return HTTPException(status_code=500, detail="paper trading client failed")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/order", response_model=Order)
async def place_order(
    body: PlaceOrderRequest,
    current_user: CurrentUser,
    session: AsyncSession = Depends(get_session),
) -> Order:
    """Submit a paper order. Returns the created Order (typically ``accepted``).

    Validation that's cheap to do client-side (``side`` enum, positive
    quantity) happens in Pydantic; the request never hits Alpaca if the body
    is invalid.

    V8-03: a buy is validated against the user's tracked virtual buying power
    *before* it reaches Alpaca. An order that would cost more than the user's
    available cash is rejected with 402, so one user can never drain the shared
    account's pool.

    A sell may not exceed the long quantity the user currently holds: short
    selling is refused (409). Without that guard a naked short would credit
    virtual cash (sells add to the reconstructed balance), letting a user mint
    buying power out of nothing and bypass the buy check above.
    """
    if body.side not in ALLOWED_SIDES:
        # Defensive: Literal[...] already enforces this, but we keep the
        # explicit check so a future schema relaxation can't open a hole.
        raise HTTPException(
            status_code=400,
            detail=f"side must be one of {sorted(ALLOWED_SIDES)}",
        )

    if body.side == "buy":
        price = await _reference_price(body.ticker)
        estimated_cost = body.quantity * price
        try:
            available = await available_buying_power(session, current_user)
        except HTTPException:
            raise
        except Exception as exc:
            logger.exception("available_buying_power failed")
            raise _map_client_error(exc) from exc
        if estimated_cost > available:
            raise HTTPException(
                status_code=402,
                detail=(
                    f"Insufficient virtual buying power: {body.ticker.upper()} "
                    f"order needs about ${estimated_cost:,.2f} but only "
                    f"${available:,.2f} is available."
                ),
            )
    else:  # sell
        try:
            held_long = await _user_long_quantity(current_user, body.ticker)
        except HTTPException:
            raise
        except Exception as exc:
            logger.exception("get_user_positions failed during sell validation")
            raise _map_client_error(exc) from exc
        if body.quantity > held_long:
            raise HTTPException(
                status_code=409,
                detail=(
                    f"Cannot sell {body.quantity} {body.ticker.upper()}: only "
                    f"{held_long} held long. Short selling is not supported."
                ),
            )

    try:
        # V8-02: tag the order with the current user so it can be attributed
        # back to them in the shared Alpaca account.
        return await place_paper_order(
            body.ticker,
            body.quantity,
            body.side,
            order_type=body.order_type,
            time_in_force=body.time_in_force,
            user_id=current_user,
        )
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("place_paper_order failed")
        raise _map_client_error(exc) from exc


@router.get("/positions", response_model=PositionsResponse)
async def list_positions(current_user: CurrentUser) -> PositionsResponse:
    """Return the current user's paper positions, empty list if none.

    Reconstructed from the user's own orders (V8-02) — never the shared
    account's aggregate positions, which would mix users together.
    """
    try:
        return PositionsResponse(positions=await get_user_positions(current_user))
    except Exception as exc:
        logger.exception("get_user_positions failed")
        raise _map_client_error(exc) from exc


@router.get("/orders", response_model=OrdersResponse)
async def list_orders(
    current_user: CurrentUser, limit: int = 50, status: str = "all"
) -> OrdersResponse:
    """Return the current user's paper order history (V8-02 partitioned)."""
    if limit <= 0:
        raise HTTPException(status_code=400, detail="limit must be > 0")
    try:
        orders = await get_user_order_history(current_user, limit=limit, status=status)
        return OrdersResponse(orders=orders)
    except Exception as exc:
        logger.exception("get_user_order_history failed")
        raise _map_client_error(exc) from exc


@router.get("/balance", response_model=BalanceResponse)
async def balance(
    current_user: CurrentUser,
    session: AsyncSession = Depends(get_session),
) -> BalanceResponse:
    """The current user's tracked virtual cash (V8-03).

    ``starting_cash`` is the seed capital ($100K); ``cash`` is what remains
    after replaying the user's own filled orders against it — never the shared
    Alpaca account's pooled buying power.
    """
    try:
        bal = await get_balance(session, current_user)
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("get_balance failed")
        raise _map_client_error(exc) from exc
    return BalanceResponse(starting_cash=bal.starting_cash, cash=bal.cash)


@router.get("/portfolio-history", response_model=PortfolioHistory)
async def portfolio_history(
    current_user: CurrentUser, period: str = "1M", timeframe: str = "1D"
) -> PortfolioHistory:
    """The current user's equity curve for the Performance tracker.

    Reconstructed from the user's own trades (V8-02) — never Alpaca's
    account-level history, which would fold in every other user's paper trades.
    ``period`` / ``timeframe`` are accepted for API compatibility; per-user
    windowing and open-position mark-to-market are completed in V8-04.
    """
    try:
        return await get_user_portfolio_history(current_user)
    except Exception as exc:
        logger.exception("get_user_portfolio_history failed")
        raise _map_client_error(exc) from exc


# ---------------------------------------------------------------------------
# Benchmark prices (SPY) for the Performance tracker
# ---------------------------------------------------------------------------


class BenchmarkPoint(BaseModel):
    """One day on the benchmark closing-price series."""

    date: str  # ISO yyyy-mm-dd
    close: float


class BenchmarkResponse(BaseModel):
    """Wire model for the benchmark series powering the Performance chart."""

    symbol: str
    points: list[BenchmarkPoint]


@router.get("/benchmark", response_model=BenchmarkResponse)
async def benchmark(
    current_user: CurrentUser, symbol: str = "SPY", days: int = 30
) -> BenchmarkResponse:
    """Return ``days`` of daily closing prices for ``symbol`` (default SPY).

    Designed for the iOS Portfolio "Performance" sub-view (P4-04 acceptance:
    "cumulative return vs. S&P 500"). Uses the same Alpha Vantage client as
    the analyst — output is already cached.
    """
    if days <= 0:
        raise HTTPException(status_code=400, detail="days must be > 0")
    if days > 365 * 5:
        raise HTTPException(status_code=400, detail="days must be <= 1825")
    try:
        bars = await get_daily_prices(symbol, days=days)
    except MissingAPIKeyError as exc:
        raise HTTPException(
            status_code=401,
            detail="Alpha Vantage API key is not configured on the backend.",
        ) from exc
    except RateLimitError as exc:
        raise HTTPException(
            status_code=429,
            detail="Benchmark data is rate-limited; try again later.",
        ) from exc
    except MarketDataError as exc:
        logger.exception("benchmark fetch failed")
        raise HTTPException(
            status_code=502, detail=f"Benchmark fetch failed: {exc}"
        ) from exc
    # AV returns newest-first; reverse so the chart can iterate left-to-right.
    bars = sorted(bars, key=lambda b: b.date)
    points = [BenchmarkPoint(date=b.date.isoformat(), close=b.close) for b in bars]
    return BenchmarkResponse(symbol=symbol.upper(), points=points)
