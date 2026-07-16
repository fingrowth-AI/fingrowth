"""Per-user and global request limits (cost protection).

``api_quota`` (V8-05) protects the shared Alpha Vantage key; this module
protects everything else that costs money per request — chiefly the analyst's
LLM call and the data-provider fan-out behind ``POST /analysis/query``. Every
limit is a fixed window aligned to the epoch (a 86400-second window therefore
resets at UTC midnight, matching api_quota's day boundary), counted per
``(scope, key)`` so the same machinery serves per-user bursts, per-user daily
allowances, and the global daily kill switch.

Counts live in Redis in production (atomic across workers, keys self-expire);
without Redis we fall back to a process-local counter, exactly like
``api_quota``. A counter-store outage degrades *open*: flaky Redis must never
take down research. Limits themselves are configured in ``app.config`` and a
non-positive limit disables that check.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

from app.config import settings

logger = logging.getLogger(__name__)

# In-memory backend: drop expired windows once the table grows past this.
_PRUNE_THRESHOLD = 4096


@dataclass(frozen=True)
class Decision:
    """Outcome of one limit check."""

    allowed: bool
    # Seconds until the current window resets — sent as ``Retry-After`` so
    # well-behaved clients know when it is worth trying again.
    retry_after: int


class _InMemoryBackend:
    """Process-local fallback counter with per-key expiry."""

    def __init__(self) -> None:
        self._counts: dict[str, tuple[int, float]] = {}

    async def incr(self, key: str, ttl: int) -> int:
        now = time.time()
        if len(self._counts) > _PRUNE_THRESHOLD:
            self._counts = {
                k: v for k, v in self._counts.items() if v[1] > now
            }
        count, expires_at = self._counts.get(key, (0, now + ttl))
        if expires_at <= now:
            count, expires_at = 0, now + ttl
        count += 1
        self._counts[key] = (count, expires_at)
        return count

    async def reset(self) -> None:
        self._counts = {}

    async def close(self) -> None:
        pass


class _RedisBackend:
    """Atomic, self-expiring counter shared across workers."""

    def __init__(self, redis) -> None:
        self._redis = redis

    async def incr(self, key: str, ttl: int) -> int:
        n = await self._redis.incr(key)
        if n == 1:
            # First hit in this window — expire the key when the window ends.
            await self._redis.expire(key, ttl)
        return int(n)

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
    """Wire the Redis backend if ``redis_url`` is set and reachable."""
    global _backend
    url = settings.redis_url
    if not url:
        logger.info("usage_limits: no redis_url configured; using in-memory counter")
        return
    try:
        import redis.asyncio as aioredis

        client = aioredis.from_url(url, encoding="utf-8", decode_responses=True)
        await client.ping()
        _backend = _RedisBackend(client)
        logger.info("usage_limits: using Redis counters")
    except Exception:
        logger.warning(
            "usage_limits: Redis unreachable; falling back to in-memory counters",
            exc_info=True,
        )


async def shutdown() -> None:
    await _backend.close()


async def reset() -> None:
    """Clear all counts. Test helper."""
    await _backend.reset()


async def check(
    scope: str, key: object, *, limit: int, window_seconds: int
) -> Decision:
    """Count one request against ``(scope, key)``'s fixed-window allowance.

    Returns an allowed :class:`Decision` when the request is within ``limit``
    for the current window, a denied one (with ``retry_after``) otherwise.
    Denied requests still tick the counter — a blocked caller is already over
    the line, and not rolling back keeps this one round-trip per check. A
    non-positive ``limit`` disables the check; a counter-store failure
    degrades open.
    """
    now = time.time()
    window_start = int(now // window_seconds) * window_seconds
    window_end = window_start + window_seconds
    retry_after = max(1, int(window_end - now) + 1)
    if limit <= 0:
        return Decision(allowed=True, retry_after=0)
    full_key = f"rl:{scope}:{window_start}:{key}"
    try:
        count = await _backend.incr(full_key, retry_after)
    except Exception:
        logger.warning(
            "usage_limits: counter unavailable; allowing request", exc_info=True
        )
        return Decision(allowed=True, retry_after=0)
    if count > limit:
        return Decision(allowed=False, retry_after=retry_after)
    return Decision(allowed=True, retry_after=0)
