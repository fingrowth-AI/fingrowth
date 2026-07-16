"""Tests for app.services.usage_limits (request rate limits).

Exercise the in-memory backend (the hermetic default — no Redis needed):
fixed-window enforcement, window expiry, scope/key isolation, the
disable-switch, Retry-After sizing, and fail-open on a broken counter store.
"""

from __future__ import annotations

import pytest

from app.services import usage_limits

USER_A = "11111111-1111-1111-1111-111111111111"
USER_B = "22222222-2222-2222-2222-222222222222"


@pytest.fixture(autouse=True)
async def _reset_limits():
    usage_limits.set_backend(usage_limits._InMemoryBackend())
    await usage_limits.reset()
    yield
    usage_limits.set_backend(usage_limits._InMemoryBackend())


@pytest.mark.asyncio
async def test_allows_up_to_limit_then_blocks():
    decisions = [
        await usage_limits.check("s", USER_A, limit=3, window_seconds=60)
        for _ in range(4)
    ]
    assert [d.allowed for d in decisions] == [True, True, True, False]


@pytest.mark.asyncio
async def test_denied_decision_carries_retry_after_within_window():
    for _ in range(2):
        await usage_limits.check("s", USER_A, limit=1, window_seconds=60)
    denied = await usage_limits.check("s", USER_A, limit=1, window_seconds=60)
    assert denied.allowed is False
    # The window is 60s, so the reset can never be further away than that
    # (plus the 1s rounding cushion).
    assert 1 <= denied.retry_after <= 61


@pytest.mark.asyncio
async def test_non_positive_limit_disables_check():
    for limit in (0, -5):
        for _ in range(50):
            decision = await usage_limits.check(
                "s", USER_A, limit=limit, window_seconds=60
            )
            assert decision.allowed is True


@pytest.mark.asyncio
async def test_scopes_and_keys_are_isolated():
    assert (await usage_limits.check("a", USER_A, limit=1, window_seconds=60)).allowed
    # Same key, different scope: untouched.
    assert (await usage_limits.check("b", USER_A, limit=1, window_seconds=60)).allowed
    # Same scope, different key: untouched.
    assert (await usage_limits.check("a", USER_B, limit=1, window_seconds=60)).allowed
    # But the original (scope, key) is now exhausted.
    denied = await usage_limits.check("a", USER_A, limit=1, window_seconds=60)
    assert denied.allowed is False


@pytest.mark.asyncio
async def test_window_rollover_resets_the_count(monkeypatch: pytest.MonkeyPatch):
    clock = {"now": 1_000_000.0}
    monkeypatch.setattr(usage_limits.time, "time", lambda: clock["now"])

    assert (await usage_limits.check("s", USER_A, limit=1, window_seconds=60)).allowed
    denied = await usage_limits.check("s", USER_A, limit=1, window_seconds=60)
    assert denied.allowed is False

    # Advance past the window boundary: a fresh window, a fresh allowance.
    clock["now"] += 60
    assert (await usage_limits.check("s", USER_A, limit=1, window_seconds=60)).allowed


@pytest.mark.asyncio
async def test_counter_failure_degrades_open():
    class _BrokenBackend:
        async def incr(self, key: str, ttl: int) -> int:
            raise ConnectionError("redis down")

        async def reset(self) -> None:
            pass

        async def close(self) -> None:
            pass

    usage_limits.set_backend(_BrokenBackend())
    decision = await usage_limits.check("s", USER_A, limit=1, window_seconds=60)
    assert decision.allowed is True


@pytest.mark.asyncio
async def test_in_memory_backend_prunes_expired_windows(
    monkeypatch: pytest.MonkeyPatch,
):
    clock = {"now": 1_000_000.0}
    monkeypatch.setattr(usage_limits.time, "time", lambda: clock["now"])
    monkeypatch.setattr(usage_limits, "_PRUNE_THRESHOLD", 4)

    backend = usage_limits._InMemoryBackend()
    for i in range(5):
        await backend.incr(f"rl:s:0:{i}", ttl=10)
    assert len(backend._counts) == 5

    # All five keys expire; the next incr past the threshold sweeps them out.
    clock["now"] += 11
    await backend.incr("rl:s:1:fresh", ttl=10)
    assert set(backend._counts) == {"rl:s:1:fresh"}
