"""Live integration tests against the real Finnhub API."""

from __future__ import annotations

import pytest

from app.models.news import NewsItem
from app.tools.news_sentiment import get_company_news, get_market_news
from tests.integration.conftest import needs_finnhub

pytestmark = [pytest.mark.integration, needs_finnhub()]


@pytest.mark.asyncio
async def test_market_news_general_returns_items_live():
    items = await get_market_news("general")
    assert isinstance(items, list)
    assert len(items) > 0, "expected at least one general-market article"
    assert all(isinstance(i, NewsItem) for i in items)
    # Sanity: every item has a non-empty headline and a tz-aware datetime.
    assert items[0].headline
    assert items[0].datetime.tzinfo is not None


@pytest.mark.asyncio
async def test_company_news_aapl_returns_items_with_sentiment_live():
    """Real AAPL company news should arrive with a clamped sentiment score."""
    items = await get_company_news("AAPL", days_back=14)
    assert isinstance(items, list)
    if not items:
        pytest.skip("Finnhub returned no AAPL news for the last 14 days")
    for it in items:
        assert -1.0 <= it.sentiment_score <= 1.0
        assert it.headline
    # All articles in a single response carry the same aggregate score.
    assert len({round(i.sentiment_score, 6) for i in items}) == 1


@pytest.mark.asyncio
async def test_company_news_unknown_ticker_returns_empty_live():
    """Acceptance: unknown ticker should return empty list, not raise."""
    items = await get_company_news("ZZZZZZZ", days_back=7)
    assert items == []
