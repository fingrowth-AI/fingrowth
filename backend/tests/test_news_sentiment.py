"""Tests for P2-03: Finnhub news + sentiment client.

Acceptance:
* get_company_news('TSLA') returns articles with sentiment
* Sentiment scores between -1.0 and 1.0
* Empty results return empty list, not error
"""

from __future__ import annotations

import httpx
import pytest

from app.config import settings
from app.models.news import NewsItem
from app.tools.news_sentiment import (
    ALLOWED_CATEGORIES,
    MissingAPIKeyError,
    _clamp_score,
    get_company_news,
    get_market_news,
)

# ---------------------------------------------------------------------------
# Fixtures + helpers
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _api_key(monkeypatch):
    monkeypatch.setattr(settings, "finnhub_api_key", "test-key")


def _company_articles(n: int = 5, symbol: str = "TSLA") -> list[dict]:
    return [
        {
            "category": "company",
            "datetime": 1_709_251_200 + i * 3600,
            "headline": f"Tesla story #{i}",
            "id": 130928134 + i,
            "image": f"https://img/{i}.jpg",
            "related": symbol,
            "source": "Reuters",
            "summary": f"Summary text #{i}",
            "url": f"https://news/{i}",
        }
        for i in range(n)
    ]


def _sentiment_payload(bullish: float = 0.7, bearish: float = 0.3) -> dict:
    return {
        "buzz": {"articlesInLastWeek": 50, "buzz": 1.2, "weeklyAverage": 41.6},
        "companyNewsScore": 0.8,
        "sectorAverageBullishPercent": 0.5,
        "sectorAverageNewsScore": 0.6,
        "sentiment": {"bearishPercent": bearish, "bullishPercent": bullish},
        "symbol": "TSLA",
    }


def _market_articles(n: int = 3) -> list[dict]:
    return [
        {
            "category": "general",
            "datetime": 1_709_251_200 + i * 3600,
            "headline": f"Market headline #{i}",
            "id": i,
            "image": "",
            "related": "",
            "source": "Bloomberg",
            "summary": f"Summary #{i}",
            "url": f"https://m/{i}",
        }
        for i in range(n)
    ]


def _make_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# ---------------------------------------------------------------------------
# get_company_news — primary acceptance criterion
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_company_news_tsla_returns_articles_with_sentiment():
    """Acceptance: get_company_news('TSLA') returns articles with sentiment."""

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            assert req.url.params.get("symbol") == "TSLA"
            return httpx.Response(200, json=_sentiment_payload())
        if req.url.path == "/api/v1/company-news":
            assert req.url.params.get("symbol") == "TSLA"
            assert req.url.params.get("from")  # date present
            assert req.url.params.get("to")
            return httpx.Response(200, json=_company_articles(n=5))
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("tsla", client=client)

    assert len(items) == 5
    assert all(isinstance(i, NewsItem) for i in items)
    # Acceptance: sentiment in [-1, 1] for every article.
    for it in items:
        assert -1.0 <= it.sentiment_score <= 1.0
    # Sentiment is bullish (0.7) - bearish (0.3) = 0.4
    assert items[0].sentiment_score == pytest.approx(0.4)
    assert items[0].headline == "Tesla story #0"
    assert items[0].source == "Reuters"
    assert items[0].related == "TSLA"


@pytest.mark.asyncio
async def test_get_company_news_empty_returns_empty_list():
    """Acceptance: empty results return empty list, not error."""

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            return httpx.Response(200, json=_sentiment_payload())
        if req.url.path == "/api/v1/company-news":
            return httpx.Response(200, json=[])  # no articles
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("ZZZZ", client=client)

    assert items == []


@pytest.mark.asyncio
async def test_company_news_clamps_extreme_sentiment():
    """If Finnhub ever returns out-of-range, we clamp to [-1, 1]."""

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            # Wildly broken values to prove clamping works.
            return httpx.Response(
                200,
                json=_sentiment_payload(bullish=2.0, bearish=0.0),
            )
        if req.url.path == "/api/v1/company-news":
            return httpx.Response(200, json=_company_articles(n=2))
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("TSLA", client=client)

    assert items
    for it in items:
        assert -1.0 <= it.sentiment_score <= 1.0


@pytest.mark.asyncio
async def test_company_news_falls_back_to_score_when_pct_missing():
    """No bullish/bearish → use companyNewsScore mapped from [0,1] to [-1,1]."""

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            return httpx.Response(
                200,
                json={"companyNewsScore": 0.75, "symbol": "TSLA"},
            )
        if req.url.path == "/api/v1/company-news":
            return httpx.Response(200, json=_company_articles(n=1))
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("TSLA", client=client)

    # 0.75 * 2 - 1 = 0.5
    assert items[0].sentiment_score == pytest.approx(0.5)


@pytest.mark.asyncio
async def test_company_news_sentiment_failure_falls_back_to_zero():
    """If sentiment endpoint errors, articles still return with score=0.0."""

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            return httpx.Response(500, text="server error")
        if req.url.path == "/api/v1/company-news":
            return httpx.Response(200, json=_company_articles(n=2))
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("TSLA", client=client)

    assert len(items) == 2
    assert all(it.sentiment_score == 0.0 for it in items)


@pytest.mark.asyncio
async def test_company_news_parses_unix_datetime():
    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path == "/api/v1/news-sentiment":
            return httpx.Response(200, json=_sentiment_payload())
        if req.url.path == "/api/v1/company-news":
            return httpx.Response(200, json=_company_articles(n=1))
        return httpx.Response(404)

    async with _make_client(handler) as client:
        items = await get_company_news("TSLA", client=client)

    # 1_709_251_200 → 2024-03-01 00:00:00 UTC
    assert items[0].datetime.year == 2024
    assert items[0].datetime.month == 3
    assert items[0].datetime.tzinfo is not None


@pytest.mark.asyncio
async def test_company_news_rejects_zero_days_back():
    with pytest.raises(ValueError):
        await get_company_news("TSLA", days_back=0)


# ---------------------------------------------------------------------------
# get_market_news
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_market_news_returns_items():
    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.path == "/api/v1/news"
        assert req.url.params.get("category") == "general"
        return httpx.Response(200, json=_market_articles(n=3))

    async with _make_client(handler) as client:
        items = await get_market_news("general", client=client)

    assert len(items) == 3
    # Market news has no per-ticker context → 0.0 sentiment
    assert all(it.sentiment_score == 0.0 for it in items)
    assert items[0].source == "Bloomberg"


@pytest.mark.asyncio
async def test_get_market_news_empty_returns_empty():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    async with _make_client(handler) as client:
        items = await get_market_news("crypto", client=client)

    assert items == []


@pytest.mark.asyncio
async def test_get_market_news_rejects_unknown_category():
    with pytest.raises(ValueError):
        await get_market_news("nonsense")


def test_allowed_categories_set():
    """Sanity: the public allowed-categories set matches Finnhub's contract."""
    assert ALLOWED_CATEGORIES == frozenset({"general", "forex", "crypto", "merger"})


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_api_key_raises(monkeypatch):
    monkeypatch.setattr(settings, "finnhub_api_key", "")

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be hit when key is missing")

    async with _make_client(handler) as client:
        with pytest.raises(MissingAPIKeyError):
            await get_market_news("general", client=client)


def test_clamp_score_handles_nan_and_extremes():
    assert _clamp_score(float("nan")) == 0.0
    assert _clamp_score(2.5) == 1.0
    assert _clamp_score(-3.0) == -1.0
    assert _clamp_score(0.5) == 0.5
