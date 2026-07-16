"""Market data client (P2-02).

Alpha Vantage free tier: 25 calls/day, with burst throttling around one request
per second on the free key. We sit in front of those endpoints with an in-memory
TTL cache so repeat reads cost zero network requests, pace cache misses, and
surface rate-limit responses (which AV emits as ``Note`` / ``Information`` keys
with HTTP 200) as :class:`RateLimitError`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import UTC, date, datetime
from typing import Any

import httpx

from app.config import settings
from app.models.market import CompanyOverview, PriceBar
from app.services import api_quota

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ALPHA_VANTAGE_BASE = "https://www.alphavantage.co/query"
DEFAULT_TIMEOUT = httpx.Timeout(20.0, connect=10.0)
DEFAULT_TTL_SECONDS = 60 * 60  # 1 hour
DEFAULT_MIN_REQUEST_INTERVAL_SECONDS = 1.1
# Alpha Vantage's TIME_SERIES_DAILY `compact` output returns ~100 bars; beyond
# that we must request `full`. Used to pick output size and to key the cache by
# it so a compact payload never under-serves a wider window.
_COMPACT_MAX_BARS = 100


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class MarketDataError(Exception):
    """Base error for market_data failures."""


class RateLimitError(MarketDataError):
    """Alpha Vantage returned a rate-limit notice instead of data."""


class MissingAPIKeyError(MarketDataError):
    """ALPHA_VANTAGE_API_KEY is not configured."""


class QuotaExceededError(MarketDataError):
    """The user has used their daily Alpha Vantage allocation (V8-05).

    A ``MarketDataError`` subclass on purpose: callers (the researcher) already
    degrade gracefully on market-data failures, so an exhausted quota surfaces
    as a clear, non-fatal "source unavailable" message rather than a crash.
    """


class StalePriceDataError(MarketDataError):
    """The most-recent price bar is older than the configured staleness threshold.

    Raised instead of returning data so a stale close is never presented as the
    current market price (V7-02). Upstream graceful degradation turns this into
    a failed price source rather than a wrong number.
    """


# ---------------------------------------------------------------------------
# In-memory TTL cache (key -> (value, expires_at_monotonic))
# ---------------------------------------------------------------------------

# Cache entry: (value, expires_at_monotonic, fetched_at_wall). ``fetched_at`` is
# the wall-clock time of the original fetch and is preserved across cache hits
# so data freshness reflects when it was actually retrieved, not when it was
# served from cache (V7-03).
_cache: dict[str, tuple[Any, float, datetime]] = {}
_cache_lock = asyncio.Lock()
_rate_limit_lock = asyncio.Lock()
_last_request_at = 0.0


def _cache_get(key: str) -> Any | None:
    entry = _cache.get(key)
    if entry is None:
        return None
    value, expires_at, _fetched_at = entry
    if time.monotonic() >= expires_at:
        _cache.pop(key, None)
        return None
    return value


def _now_wall() -> datetime:
    """Wall-clock indirection so the cache fetch timestamp is pinnable in tests."""
    return datetime.now(tz=UTC)


def _cache_set(
    key: str, value: Any, ttl: float, fetched_at: datetime | None = None
) -> None:
    _cache[key] = (value, time.monotonic() + ttl, fetched_at or _now_wall())


# ---------------------------------------------------------------------------
# Optional Redis L2 behind the in-process cache
# ---------------------------------------------------------------------------
#
# The in-process dict dies with the process — and in development the process
# restarts on every code reload, so each restart re-fetched SPY and every
# traded ticker from Alpha Vantage and burned the 25-calls/day free tier
# within hours. With Redis as a second layer the payloads survive restarts and
# are shared across workers: one fetch really does serve everyone, all day.
# Wired from the app lifespan; unreachable/unconfigured Redis degrades to the
# in-process cache only, which is also what keeps the test suite hermetic.

_REDIS_PREFIX = "mdcache:"
_redis: Any | None = None


def set_redis(client: Any | None) -> None:
    """Override the L2 client (tests / startup)."""
    global _redis
    _redis = client


async def startup_cache() -> None:
    """Wire the Redis L2 if ``redis_url`` is set and reachable (non-fatal)."""
    global _redis
    url = settings.redis_url
    if not url:
        logger.info("market_data: no redis_url configured; in-process cache only")
        return
    try:
        import redis.asyncio as aioredis

        client = aioredis.from_url(url, encoding="utf-8", decode_responses=True)
        await client.ping()
        _redis = client
        logger.info("market_data: using Redis-backed payload cache")
    except Exception:
        logger.warning(
            "market_data: Redis unreachable; in-process cache only", exc_info=True
        )


async def shutdown_cache() -> None:
    global _redis
    if _redis is not None:
        try:
            await _redis.aclose()
        finally:
            _redis = None


async def _cache_load(key: str) -> Any | None:
    """L1 (in-process) then L2 (Redis) lookup, hydrating L1 on an L2 hit.

    The L2 entry carries the original fetch timestamp and its remaining TTL,
    both preserved into L1, so data freshness (V7-03) still reports when the
    payload was actually retrieved — not when this process first saw it.
    """
    async with _cache_lock:
        value = _cache_get(key)
    if value is not None or _redis is None:
        return value
    try:
        raw = await _redis.get(_REDIS_PREFIX + key)
        if raw is None:
            return None
        ttl_ms = await _redis.pttl(_REDIS_PREFIX + key)
        entry = json.loads(raw)
        payload = entry["payload"]
        fetched_at = datetime.fromisoformat(entry["fetched_at"])
    except Exception:
        logger.warning("market_data: Redis cache read failed", exc_info=True)
        return None
    if isinstance(ttl_ms, int) and ttl_ms > 0:
        async with _cache_lock:
            _cache[key] = (payload, time.monotonic() + ttl_ms / 1000.0, fetched_at)
    return payload


async def _cache_store(key: str, value: Any, ttl: float) -> None:
    """Write through to L1 and (best-effort) L2 with one shared fetch time."""
    fetched_at = _now_wall()
    async with _cache_lock:
        _cache_set(key, value, ttl, fetched_at=fetched_at)
    if _redis is None:
        return
    try:
        entry = json.dumps({"payload": value, "fetched_at": fetched_at.isoformat()})
        await _redis.set(_REDIS_PREFIX + key, entry, px=max(1, int(ttl * 1000)))
    except Exception:
        logger.warning("market_data: Redis cache write failed", exc_info=True)


def daily_prices_fetched_at(ticker: str) -> datetime | None:
    """Wall-clock time the cached daily series for ``ticker`` was first fetched.

    Returns the original fetch time even when the series is currently served
    from cache (V7-03); ``None`` if nothing is cached for the symbol. Prefers the
    full series' timestamp, matching the lookup order in get_daily_prices.
    """
    symbol = ticker.upper()
    entry = _cache.get(f"daily:{symbol}:full") or _cache.get(f"daily:{symbol}:compact")
    return entry[2] if entry else None


def _clear_cache() -> None:
    """Reset the cache. Test helper."""
    global _last_request_at
    _cache.clear()
    _last_request_at = 0.0


def _monotonic() -> float:
    return time.monotonic()


def _today() -> date:
    """Indirection so the staleness check can be pinned in tests."""
    return datetime.now(tz=UTC).date()


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


async def _enforce_quota(user_id: object | None) -> None:
    """Charge one upstream call to ``user_id``'s daily allocation (V8-05).

    Called only on a cache *miss* (a real upstream call), so cache hits never
    consume quota — that's what lets one user's fetch serve everyone for free.
    A ``None`` user is exempt: server-side/shared fetches such as the SPY
    benchmark are never billed to any user. Raises :class:`QuotaExceededError`
    when the user is already at their allocation.
    """
    if user_id is None:
        return
    allowed = await api_quota.try_consume(
        user_id, limit=settings.alpha_vantage_daily_quota_per_user
    )
    if not allowed:
        raise QuotaExceededError(
            "Daily market-data limit reached for your account. Cached data is "
            "still available, and your allowance resets tomorrow (UTC)."
        )


async def _refund_quota(user_id: object | None) -> None:
    """Give back a unit charged by :func:`_enforce_quota` when the call failed.

    A cache miss reserves quota *before* the request; if that request never
    yields usable, cacheable data (missing key, transport error, upstream 5xx,
    rate-limit notice, parse failure) the user shouldn't be charged for it.
    """
    if user_id is None:
        return
    await api_quota.refund(user_id)


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
    max_staleness_days: int | None = None,
    user_id: object | None = None,
    client: httpx.AsyncClient | None = None,
) -> list[PriceBar]:
    """Return the most-recent ``days`` daily OHLCV bars for ``ticker``.

    The full AV response is cached per-ticker; varying ``days`` slices off the
    cached series without re-issuing a request. The cache is keyed by ticker
    alone, so a series fetched for one user serves every user with zero further
    upstream calls (V8-05).

    ``user_id`` (V8-05) bills cache *misses* against that user's daily Alpha
    Vantage allocation and raises :class:`QuotaExceededError` once they're out;
    cache hits are free. Pass ``None`` for server-side/shared fetches (e.g. the
    SPY benchmark), which are never billed to a user.

    ``max_staleness_days`` bounds how old the newest bar may be (V7-02). ``None``
    uses :attr:`Settings.max_price_staleness_days`; a non-positive value disables
    the check. If the newest bar is older than the threshold the call raises
    :class:`StalePriceDataError` rather than returning a price that no longer
    reflects the market.
    """
    if days <= 0:
        raise ValueError("days must be > 0")
    symbol = ticker.upper()
    # `compact` returns ~100 bars; `full` returns 20+ years. The output size is
    # part of the cache key, otherwise a compact payload cached for one caller
    # would under-serve a later caller asking for > 100 days. A cached *full*
    # series satisfies any window, so prefer it before falling back to compact.
    size = "full" if days > _COMPACT_MAX_BARS else "compact"

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        payload = await _cache_load(f"daily:{symbol}:full")
        if payload is None and size == "compact":
            payload = await _cache_load(f"daily:{symbol}:compact")
        if payload is None:
            await _enforce_quota(user_id)
            try:
                payload = await _request(
                    client,
                    {
                        "function": "TIME_SERIES_DAILY",
                        "symbol": symbol,
                        "outputsize": size,
                    },
                )
            except BaseException:
                # The reserved call never produced usable data — refund it.
                await _refund_quota(user_id)
                raise
            await _cache_store(f"daily:{symbol}:{size}", payload, ttl)

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
        _reject_if_stale(symbol, bars, max_staleness_days)
        return bars
    finally:
        if own_client:
            await client.aclose()


def _reject_if_stale(
    symbol: str,
    bars: list[PriceBar],
    max_staleness_days: int | None,
) -> None:
    """Raise :class:`StalePriceDataError` if the newest bar is too old (V7-02).

    ``bars`` arrive newest-first. An empty series is left to the caller (it is
    an absence of data, not stale data). A non-positive threshold disables the
    check.
    """
    if not bars:
        return
    threshold = (
        settings.max_price_staleness_days
        if max_staleness_days is None
        else max_staleness_days
    )
    if threshold <= 0:
        return
    newest = bars[0].date
    age_days = (_today() - newest).days
    if age_days > threshold:
        raise StalePriceDataError(
            f"{symbol} latest close is {age_days} days old "
            f"(bar {newest.isoformat()}), exceeds {threshold}-day threshold"
        )


async def get_company_overview(
    ticker: str,
    *,
    ttl: float = DEFAULT_TTL_SECONDS,
    user_id: object | None = None,
    client: httpx.AsyncClient | None = None,
) -> CompanyOverview | None:
    """Return company fundamentals from AV's ``OVERVIEW`` endpoint.

    Returns ``None`` for unknown tickers — Alpha Vantage answers those with an
    empty object rather than a 404. ``user_id`` bills cache misses against the
    user's daily allocation (V8-05); cache hits are free.
    """
    symbol = ticker.upper()
    cache_key = f"overview:{symbol}"

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        payload = await _cache_load(cache_key)
        if payload is None:
            await _enforce_quota(user_id)
            try:
                payload = await _request(
                    client,
                    {"function": "OVERVIEW", "symbol": symbol},
                )
            except BaseException:
                await _refund_quota(user_id)
                raise
            await _cache_store(cache_key, payload, ttl)

        if not payload or not payload.get("Symbol"):
            return None
        return CompanyOverview.model_validate(payload)
    finally:
        if own_client:
            await client.aclose()
