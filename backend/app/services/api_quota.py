"""Per-user daily Alpha Vantage quota (V8-05).

The free Alpha Vantage tier is 25 calls/day on one shared key, so without a
guard a single active user drains it for everyone. This module allocates each
user a per-day slice and counts only *real upstream calls* — cache hits are
free — so popular tickers (and the shared SPY benchmark) are fetched once and
reused across users while no one can exceed their allocation.

Counts live in Redis in production: ``INCR`` is atomic across workers and the
key auto-expires at the UTC day boundary, so the allocation resets daily with
no sweep job. This is the first feature to actually use the Redis container
that's been provisioned since P1-01. When Redis isn't configured or is
unreachable the backend transparently falls back to an in-memory counter —
correct within a single process and exactly what the test suite uses, so tests
need no Redis. A counter outage never blocks research: we degrade *open*.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from app.config import settings

logger = logging.getLogger(__name__)


def _utc_now() -> datetime:
    return datetime.now(tz=timezone.utc)


def _day_key(now: datetime) -> str:
    return now.date().isoformat()


def _seconds_until_utc_midnight(now: datetime) -> int:
    tomorrow = (now + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return max(1, int((tomorrow - now).total_seconds()))


class _InMemoryBackend:
    """Process-local fallback counter. Resets when the UTC day rolls over."""

    def __init__(self) -> None:
        self._day: str | None = None
        self._counts: dict[str, int] = {}

    def _roll(self, day: str) -> None:
        if day != self._day:
            self._day = day
            self._counts = {}

    async def incr(self, user_id: str, day: str, ttl: int) -> int:
        self._roll(day)
        self._counts[user_id] = self._counts.get(user_id, 0) + 1
        return self._counts[user_id]

    async def decr(self, user_id: str, day: str) -> None:
        self._roll(day)
        if self._counts.get(user_id, 0) > 0:
            self._counts[user_id] -= 1

    async def reset(self) -> None:
        self._day = None
        self._counts = {}

    async def close(self) -> None:
        pass


class _RedisBackend:
    """Atomic, auto-expiring per-user/day counter shared across workers."""

    def __init__(self, redis) -> None:
        self._redis = redis

    def _key(self, user_id: str, day: str) -> str:
        return f"avquota:{day}:{user_id}"

    async def incr(self, user_id: str, day: str, ttl: int) -> int:
        key = self._key(user_id, day)
        n = await self._redis.incr(key)
        if n == 1:
            # First call of the day for this user — expire the key at midnight
            # so the allocation resets without a sweep job.
            await self._redis.expire(key, ttl)
        return int(n)

    async def decr(self, user_id: str, day: str) -> None:
        await self._redis.decr(self._key(user_id, day))

    async def reset(self) -> None:  # pragma: no cover - tests use in-memory
        pass

    async def close(self) -> None:
        await self._redis.aclose()


# Hermetic default: in-memory. ``startup()`` swaps in Redis when configured.
_backend: _InMemoryBackend | _RedisBackend = _InMemoryBackend()


def set_backend(backend: _InMemoryBackend | _RedisBackend) -> None:
    """Override the active backend (tests / startup)."""
    global _backend
    _backend = backend


async def startup() -> None:
    """Wire the Redis backend if ``redis_url`` is set and reachable.

    Called from the app lifespan. Failure to reach Redis is non-fatal: we log
    and keep the in-memory counter so the service still boots and still limits
    per-process.
    """
    global _backend
    url = settings.redis_url
    if not url:
        logger.info("api_quota: no redis_url configured; using in-memory counter")
        return
    try:
        import redis.asyncio as aioredis

        client = aioredis.from_url(url, encoding="utf-8", decode_responses=True)
        await client.ping()
        _backend = _RedisBackend(client)
        logger.info("api_quota: using Redis quota counter")
    except Exception:
        logger.warning(
            "api_quota: Redis unreachable; falling back to in-memory counter",
            exc_info=True,
        )


async def shutdown() -> None:
    await _backend.close()


async def reset() -> None:
    """Clear all counts. Test helper."""
    await _backend.reset()


async def try_consume(user_id: object, *, limit: int) -> bool:
    """Count one upstream call against ``user_id``'s daily allocation.

    Returns ``True`` if the call is within the user's quota (and has now been
    counted), ``False`` if it would exceed it — in which case the rejected
    attempt is rolled back so a blocked user isn't charged for calls that never
    happened. A non-positive ``limit`` disables the quota (always allowed).

    A counter-store failure degrades *open* (returns ``True``): a flaky Redis
    must never take down research.
    """
    if limit <= 0:
        return True
    now = _utc_now()
    day = _day_key(now)
    ttl = _seconds_until_utc_midnight(now)
    backend = _backend
    try:
        count = await backend.incr(str(user_id), day, ttl)
    except Exception:
        logger.warning("api_quota: counter unavailable; allowing call", exc_info=True)
        return True
    if count > limit:
        await _rollback(backend, str(user_id), day)
        return False
    return True


async def refund(user_id: object) -> None:
    """Return one consumed call to ``user_id`` (the upstream attempt failed).

    Keeps the counter honest: only successful, usable fetches stay charged, so a
    missing key / network error / rate-limit / parse failure doesn't burn a
    user's allocation. A non-positive quota means nothing was charged, so this
    is a no-op there.
    """
    if settings.alpha_vantage_daily_quota_per_user <= 0:
        return
    await _rollback(_backend, str(user_id), _day_key(_utc_now()))


async def _rollback(backend, user_id: str, day: str) -> None:
    try:
        await backend.decr(user_id, day)
    except Exception:
        logger.warning("api_quota: rollback failed", exc_info=True)
