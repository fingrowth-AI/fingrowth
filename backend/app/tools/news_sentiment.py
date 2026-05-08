"""News + sentiment client (P2-03).

Finnhub free tier. Two endpoints:

* ``/news?category=...`` — market-wide news by category
* ``/company-news?symbol=...&from=...&to=...`` — ticker-specific news

Finnhub does not return per-article sentiment from those endpoints. We fetch
the aggregate ``/news-sentiment?symbol=...`` value and attach it to every
company-news article so downstream agents see a single normalized score in
``[-1, 1]``. Market news has no per-ticker context and ships with score 0.0.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from typing import Any

import httpx

from app.config import settings
from app.models.news import NewsItem

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FINNHUB_BASE = "https://finnhub.io/api/v1"
DEFAULT_TIMEOUT = httpx.Timeout(15.0, connect=10.0)
ALLOWED_CATEGORIES = frozenset({"general", "forex", "crypto", "merger"})


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class NewsSentimentError(Exception):
    """Base error for news_sentiment client failures."""


class MissingAPIKeyError(NewsSentimentError):
    """FINNHUB_API_KEY is not configured."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _clamp_score(score: float) -> float:
    """Clamp a sentiment score into ``[-1.0, 1.0]``."""
    if score != score:  # NaN guard
        return 0.0
    return max(-1.0, min(1.0, score))


def _require_api_key() -> str:
    key = settings.finnhub_api_key
    if not key:
        raise MissingAPIKeyError("FINNHUB_API_KEY is not configured")
    return key


async def _request_json(
    client: httpx.AsyncClient,
    path: str,
    params: dict[str, str],
) -> Any:
    full = {**params, "token": _require_api_key()}
    resp = await client.get(f"{FINNHUB_BASE}{path}", params=full)
    resp.raise_for_status()
    return resp.json()


def _today() -> date:
    """Indirection so tests can monkeypatch the date window."""
    return date.today()


def _parse_article(row: dict, *, sentiment_score: float, fallback_related: str = "") -> NewsItem:
    ts = row.get("datetime")
    if isinstance(ts, (int, float)) and ts > 0:
        dt = datetime.fromtimestamp(float(ts), tz=UTC)
    else:
        dt = datetime.now(tz=UTC)
    related = row.get("related") or fallback_related
    return NewsItem(
        headline=str(row.get("headline") or ""),
        summary=str(row.get("summary") or ""),
        source=str(row.get("source") or ""),
        sentiment_score=_clamp_score(sentiment_score),
        datetime=dt,
        url=row.get("url"),
        image=row.get("image"),
        related=related or None,
    )


async def _fetch_company_sentiment(
    client: httpx.AsyncClient,
    symbol: str,
) -> float:
    """Aggregate sentiment for a ticker, normalized to ``[-1, 1]``.

    Tries ``bullishPercent - bearishPercent`` first (already in ``[-1, 1]``);
    falls back to ``companyNewsScore`` mapped from ``[0, 1]`` to ``[-1, 1]``;
    returns 0.0 on any error so news fetching itself is never blocked by an
    unrelated sentiment failure.
    """
    try:
        payload = await _request_json(client, "/news-sentiment", {"symbol": symbol})
    except (httpx.HTTPError, NewsSentimentError):
        return 0.0
    if not isinstance(payload, dict):
        return 0.0

    sentiment = payload.get("sentiment") or {}
    bull = sentiment.get("bullishPercent")
    bear = sentiment.get("bearishPercent")
    if bull is not None or bear is not None:
        try:
            return _clamp_score(float(bull or 0.0) - float(bear or 0.0))
        except (TypeError, ValueError):
            return 0.0

    score = payload.get("companyNewsScore")
    if score is None:
        return 0.0
    try:
        return _clamp_score(float(score) * 2.0 - 1.0)
    except (TypeError, ValueError):
        return 0.0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_market_news(
    category: str = "general",
    *,
    client: httpx.AsyncClient | None = None,
) -> list[NewsItem]:
    """Return market-wide news for a Finnhub category.

    Categories: ``general``, ``forex``, ``crypto``, ``merger``.
    """
    if category not in ALLOWED_CATEGORIES:
        raise ValueError(
            f"Unknown category: {category!r}; expected one of {sorted(ALLOWED_CATEGORIES)}"
        )
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        data = await _request_json(client, "/news", {"category": category})
        if not data:
            return []
        return [
            _parse_article(row, sentiment_score=0.0, fallback_related=category)
            for row in data
        ]
    finally:
        if own_client:
            await client.aclose()


async def get_company_news(
    ticker: str,
    days_back: int = 7,
    *,
    client: httpx.AsyncClient | None = None,
) -> list[NewsItem]:
    """Return company-news articles for ``ticker`` over the last ``days_back``.

    Each article carries the aggregate sentiment score for the ticker (same
    score across all articles in the response, since Finnhub does not break
    sentiment down per article on the free tier).
    """
    if days_back <= 0:
        raise ValueError("days_back must be > 0")
    symbol = ticker.upper()
    end_d = _today()
    start_d = end_d - timedelta(days=days_back)

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        sentiment_score = await _fetch_company_sentiment(client, symbol)
        articles = await _request_json(
            client,
            "/company-news",
            {
                "symbol": symbol,
                "from": start_d.isoformat(),
                "to": end_d.isoformat(),
            },
        )
        if not articles:
            return []
        return [
            _parse_article(
                row,
                sentiment_score=sentiment_score,
                fallback_related=symbol,
            )
            for row in articles
        ]
    finally:
        if own_client:
            await client.aclose()
