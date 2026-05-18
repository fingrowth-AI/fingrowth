"""Domain models for the Researcher agent (P3-02).

The Researcher gathers filings, prices and news from the Phase 2 data tools
and packages them into a single :class:`ResearchPacket`. Every data source is
attributed in ``sources`` with a URL and a retrieval timestamp so downstream
agents — and the Privacy Audit Log — can trace exactly where each fact came
from.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

from app.models.market import PriceBar
from app.models.news import NewsItem
from app.models.sec import Filing


class Source(BaseModel):
    """Provenance for one data source consulted by the Researcher.

    A ``Source`` is recorded whether the fetch succeeded or failed — a failed
    source carries ``ok=False`` and an ``error`` message, which is how graceful
    degradation stays visible to downstream agents instead of silently
    disappearing.
    """

    name: str  # human-readable, e.g. "SEC EDGAR"
    url: str  # canonical URL for the data that was requested
    retrieved_at: datetime
    ok: bool = True
    error: str | None = None
    item_count: int = 0


class ResearchPacket(BaseModel):
    """Structured research output with full source attribution."""

    ticker: str
    query: str
    filings: list[Filing] = Field(default_factory=list)
    news: list[NewsItem] = Field(default_factory=list)
    price_data: list[PriceBar] = Field(default_factory=list)
    sources: list[Source] = Field(default_factory=list)

    @property
    def degraded(self) -> bool:
        """True if any data source failed — i.e. the packet is partial."""
        return any(not s.ok for s in self.sources)
