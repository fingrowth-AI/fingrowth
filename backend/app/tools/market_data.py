"""Market data client (P2-02).

Alpha Vantage free tier: 25 calls/day, with burst throttling around one request
per second on the free key. We sit in front of those endpoints with an in-memory
TTL cache so repeat reads cost zero network requests, pace cache misses, and
surface rate-limit responses (which AV emits as ``Note`` / ``Information`` keys
with HTTP 200) as :class:`RateLimitError`.
"""

from __future__ import annotations

import asyncio
import time
from datetime import date
from typing import Any

import httpx

from app.config import settings
from app.models.market import CompanyOverview, PriceBar

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ALPHA_VANTAGE_BASE = "https://www.alphavantage.co/query"
DEFAULT_TIMEOUT = httpx.Timeout(20.0, connect=10.0)
DEFAULT_TTL_SECONDS = 60 * 60  # 1 hour
DEFAULT_MIN_REQUEST_INTERVAL_SECONDS = 1.1


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class MarketDataError(Exception):
    """Base error for market_data failures."""


class RateLimitError(MarketDataError):
    """Alpha Vantage returned a rate-limit notice instead of data."""


class MissingAPIKeyError(MarketDataError):
    """ALPHA_VANTAGE_API_KEY is not configured."""


# ---------------------------------------------------------------------------
# In-memory TTL cache (key -> (value, expires_at_monotonic))
# ---------------------------------------------------------------------------

_cache: dict[str, tuple[Any, float]] = {}
_cache_lock = asyncio.Lock()
_rate_limit_lock = asyncio.Lock()
_last_request_at = 0.0


def _cache_get(key: str) -> Any | None:
    entry = _cache.get(key)
    if entry is None:
        return None
    value, expires_at = entry
    if time.monotonic() >= expires_at:
        _cache.pop(key, None)
        return None
    return value


def _cache_set(key: str, value: Any, ttl: float) -> None:
    _cache[key] = (value, time.monotonic() + ttl)


def _clear_cache() -> None:
    """Reset the cache. Test helper."""
    global _last_request_at
    _cache.clear()
    _last_request_at = 0.0


def _monotonic() -> float:
    return time.monotonic()


async def _rate_limit_sleep(delay: float) -> None:
    await asyncio.sleep(delay)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def _is_rate_limit_response(payload: dict) -> bool:
    """AV embeds rate-limit messages in ``Note`` or ``Information`` (HTTP 200)."""
    note = str(payload.get("Note") or "").lower()
    info = str(payload.get("Information") or "").lower()
    blob = f"{note} {info}"
    return any(
        s in blob
        for s in ("rate limit", "api call frequency", "call volume", "premium plan")
    )


async def _request(
    client: httpx.AsyncClient,
    params: dict[str, str],
) -> dict:
    api_key = settings.alpha_vantage_api_key
    if not api_key:
        raise MissingAPIKeyError("ALPHA_VANTAGE_API_KEY is not configured")
    await _respect_rate_limit()
    full_params = {**params, "apikey": api_key}
    resp = await client.get(ALPHA_VANTAGE_BASE, params=full_params)
    resp.raise_for_status()
    payload = resp.json()
    if _is_rate_limit_response(payload):
        raise RateLimitError(
            payload.get("Note") or payload.get("Information") or "rate limit hit"
        )
    return payload


async def _respect_rate_limit() -> None:
    """Serialize live Alpha Vantage cache misses to avoid free-tier burst limits."""
    global _last_request_at
    interval = DEFAULT_MIN_REQUEST_INTERVAL_SECONDS
    if interval <= 0:
        return

    async with _rate_limit_lock:
        now = _monotonic()
        wait = (_last_request_at + interval) - now
        if wait > 0:
            await _rate_limit_sleep(wait)
            now = _monotonic()
        _last_request_at = now


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_daily_prices(
    ticker: str,
    days: int = 90,
    *,
    ttl: float = DEFAULT_TTL_SECONDS,
    client: httpx.AsyncClient | None = None,
) -> list[PriceBar]:
    """Return the most-recent ``days`` daily OHLCV bars for ``ticker``.

    The full AV response is cached per-ticker; varying ``days`` slices off the
    cached series without re-issuing a request.
    """
    if days <= 0:
        raise ValueError("days must be > 0")
    symbol = ticker.upper()
    cache_key = f"daily:{symbol}"

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        async with _cache_lock:
            payload = _cache_get(cache_key)
        if payload is None:
            payload = await _request(
                client,
                {
                    "function": "TIME_SERIES_DAILY",
                    "symbol": symbol,
                    # `compact` returns ~100 bars; `full` returns 20+ years.
                    "outputsize": "full" if days > 100 else "compact",
                },
            )
            async with _cache_lock:
                _cache_set(cache_key, payload, ttl)

        series: dict[str, dict[str, str]] = payload.get("Time Series (Daily)") or {}
        # Keys are ISO-formatted dates; sort descending and take the top N.
        keys = sorted(series.keys(), reverse=True)[:days]
        bars: list[PriceBar] = []
        for d in keys:
            row = series[d]
            bars.append(
                PriceBar(
                    ticker=symbol,
                    date=date.fromisoformat(d),
                    open=float(row["1. open"]),
                    high=float(row["2. high"]),
                    low=float(row["3. low"]),
                    close=float(row["4. close"]),
                    volume=int(row["5. volume"]),
                )
            )
        return bars
    finally:
        if own_client:
            await client.aclose()


async def get_company_overview(
    ticker: str,
    *,
    ttl: float = DEFAULT_TTL_SECONDS,
    client: httpx.AsyncClient | None = None,
) -> CompanyOverview | None:
    """Return company fundamentals from AV's ``OVERVIEW`` endpoint.

    Returns ``None`` for unknown tickers — Alpha Vantage answers those with an
    empty object rather than a 404.
    """
    symbol = ticker.upper()
    cache_key = f"overview:{symbol}"

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        async with _cache_lock:
            payload = _cache_get(cache_key)
        if payload is None:
            payload = await _request(
                client,
                {"function": "OVERVIEW", "symbol": symbol},
            )
            async with _cache_lock:
                _cache_set(cache_key, payload, ttl)

        if not payload or not payload.get("Symbol"):
            return None
        return CompanyOverview.model_validate(payload)
    finally:
        if own_client:
            await client.aclose()
