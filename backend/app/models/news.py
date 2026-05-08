"""Domain model for news + sentiment data (P2-03)."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class NewsItem(BaseModel):
    """A single news article with attached sentiment.

    ``sentiment_score`` is normalized to ``[-1.0, 1.0]`` regardless of source.
    Negative = bearish, positive = bullish, zero = neutral / unknown.
    """

    headline: str
    summary: str = ""
    source: str = ""
    sentiment_score: float
    datetime: datetime
    url: str | None = None
    image: str | None = None
    related: str | None = None  # ticker or category string
