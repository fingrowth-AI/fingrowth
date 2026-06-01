"""Tests for V8-05 per-user daily quota (app.services.api_quota).

Exercise the in-memory backend (the hermetic default — no Redis needed):
allocation enforcement, rejected-attempt rollback, daily reset, the
disable-switch, and per-user isolation.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.services import api_quota

USER_A = "11111111-1111-1111-1111-111111111111"
USER_B = "22222222-2222-2222-2222-222222222222"


@pytest.fixture(autouse=True)
async def _reset_quota():
    api_quota.set_backend(api_quota._InMemoryBackend())
    await api_quota.reset()
    yield
    # Restore a clean in-memory backend (a test may have swapped in a fake one).
    api_quota.set_backend(api_quota._InMemoryBackend())


@pytest.mark.asyncio
async def test_allows_up_to_limit_then_blocks():
    allowed = [await api_quota.try_consume(USER_A, limit=3) for _ in range(3)]
    assert allowed == [True, True, True]
    # The 4th call exceeds the allocation.
    assert await api_quota.try_consume(USER_A, limit=3) is False


@pytest.mark.asyncio
async def test_rejected_attempt_is_rolled_back_not_charged():
    for _ in range(3):
        assert await api_quota.try_consume(USER_A, limit=3) is True
    # Several over-limit attempts...
    assert await api_quota.try_consume(USER_A, limit=3) is False
    assert await api_quota.try_consume(USER_A, limit=3) is False
    # ...must not inflate the count, so raising the limit by 1 frees exactly one.
    assert await api_quota.try_consume(USER_A, limit=4) is True
    assert await api_quota.try_consume(USER_A, limit=4) is False


@pytest.mark.asyncio
async def test_non_positive_limit_disables_quota():
    for limit in (0, -5):
        for _ in range(100):
            assert await api_quota.try_consume(USER_A, limit=limit) is True


@pytest.mark.asyncio
async def test_users_have_independent_allocations():
    assert await api_quota.try_consume(USER_A, limit=1) is True
    assert await api_quota.try_consume(USER_A, limit=1) is False  # A exhausted
    # B is untouched by A's spend.
    assert await api_quota.try_consume(USER_B, limit=1) is True


@pytest.mark.asyncio
async def test_allocation_resets_on_new_utc_day(monkeypatch):
    day1 = datetime(2026, 6, 1, 23, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(api_quota, "_utc_now", lambda: day1)
    assert await api_quota.try_consume(USER_A, limit=1) is True
    assert await api_quota.try_consume(USER_A, limit=1) is False

    day2 = datetime(2026, 6, 2, 0, 30, tzinfo=timezone.utc)
    monkeypatch.setattr(api_quota, "_utc_now", lambda: day2)
    # Fresh day → fresh allocation.
    assert await api_quota.try_consume(USER_A, limit=1) is True


@pytest.mark.asyncio
async def test_counter_failure_degrades_open(monkeypatch):
    class _Boom:
        async def incr(self, *a, **k):
            raise RuntimeError("redis down")

        async def decr(self, *a, **k):
            raise RuntimeError("redis down")

    api_quota.set_backend(_Boom())
    # A failing store must never block research.
    assert await api_quota.try_consume(USER_A, limit=1) is True
