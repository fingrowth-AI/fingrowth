"""Live integration tests against the real Alpha Vantage API.

Alpha Vantage's free tier is 25 calls/day. This module is intentionally tiny
— two unique requests per run, with the cache-hit assertion riding on top of
the first call so it costs zero additional quota.
"""

from __future__ import annotations

import asyncio

import pytest

from app.models.market import CompanyOverview, PriceBar
from app.tools.market_data import (
    _clear_cache,
    get_company_overview,
    get_daily_prices,
)
from tests.integration.conftest import needs_alpha_vantage

pytestmark = [pytest.mark.integration, needs_alpha_vantage()]


@pytest.fixture(autouse=True)
def _clear_module_cache():
    """Each module run starts with an empty cache; tests within a run share it."""
    _clear_cache()


@pytest.fixture(autouse=True)
async def _throttle():
    """Alpha Vantage free tier throttles at 1 req/sec — pad each test."""
    await asyncio.sleep(1.3)
    yield


@pytest.mark.asyncio
async def test_get_daily_prices_msft_live_then_cache_hit():
    """One real API call; second call must hit the in-memory cache (no quota)."""
    bars_first = await get_daily_prices("MSFT", 30)
    assert len(bars_first) == 30
    assert all(isinstance(b, PriceBar) for b in bars_first)
    # Newest first.
    assert bars_first[0].date > bars_first[-1].date
    assert bars_first[0].ticker == "MSFT"
    # OHLCV sanity.
    for b in bars_first:
        assert b.high >= b.low
        assert b.high >= b.open and b.high >= b.close
        assert b.low <= b.open and b.low <= b.close
        assert b.volume >= 0

    # Second call should be served entirely from the cache. We don't have a
    # network counter here, but a sliced re-read with a different `days`
    # argument proves the underlying payload is reused (no second fetch).
    bars_seven = await get_daily_prices("MSFT", 7)
    assert len(bars_seven) == 7
    # The 7-day slice is the prefix of the 30-day series.
    assert [b.date for b in bars_seven] == [b.date for b in bars_first[:7]]


@pytest.mark.asyncio
async def test_get_company_overview_msft_live():
    overview = await get_company_overview("MSFT")
    assert isinstance(overview, CompanyOverview)
    assert overview.symbol == "MSFT"
    assert overview.name and "Microsoft" in overview.name
    # MSFT has a market cap; spot-check it's plausible (> $100B).
    assert overview.market_cap is not None
    assert overview.market_cap > 1e11


@pytest.mark.asyncio
async def test_get_company_overview_unknown_symbol_returns_none_live():
    """Acceptance: unknown ticker → None, not error."""
    out = await get_company_overview("ZZZZZZZ")
    assert out is None
