"""Shared test fixtures.

Request rate limits (app.services.usage_limits) are disabled for the whole
suite: the limiter counts per-user requests in a process-global backend, and
nearly every router test issues requests as the shared default user — with
production limits on, unrelated tests would start 429-ing each other. Tests
that exercise the limits themselves re-enable them explicitly via monkeypatch
(see tests/test_rate_limits_router.py).
"""

from __future__ import annotations

import pytest

from app.config import settings
from app.services import usage_limits


@pytest.fixture(autouse=True)
def _disable_request_limits(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "analysis_requests_per_minute_per_user", 0)
    monkeypatch.setattr(settings, "analysis_requests_per_day_per_user", 0)
    monkeypatch.setattr(settings, "analysis_requests_per_day_global", 0)
    monkeypatch.setattr(settings, "orders_per_minute_per_user", 0)
    # Fresh counter store per test so no state crosses test boundaries.
    usage_limits.set_backend(usage_limits._InMemoryBackend())
    yield
    usage_limits.set_backend(usage_limits._InMemoryBackend())
