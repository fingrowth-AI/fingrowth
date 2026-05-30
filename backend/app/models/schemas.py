from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Any

from pydantic import BaseModel, Field

# Re-export the canonical disclaimer + RiskReview from the risk module so the
# API contract and the Risk Critic guardrail (P3-04) share a single source of
# truth — they cannot drift apart even if the disclaimer text is amended.
from app.models.risk import STANDARD_DISCLAIMER as DISCLAIMER
from app.models.risk import RiskFlag, RiskReview

__all__ = [
    "DISCLAIMER",
    "RiskFlag",
    "RiskReview",
    "PortfolioProfile",
    "DataFreshness",
    "ResearchData",
    "AnalysisData",
    "AnalysisQuery",
    "AnalysisResponse",
    "HealthResponse",
]


# ---------------------------------------------------------------------------
# Shared / nested models
# ---------------------------------------------------------------------------


class PortfolioProfile(BaseModel):
    """Anonymized portfolio context sent from the iOS client via DifferentialPrivacy."""

    sector_weights: dict[str, float] = Field(default_factory=dict)
    largest_position: str | None = None
    diversification: str | None = None
    risk_orientation: str | None = None


class DataFreshness(BaseModel):
    """When the underlying research data is 'as of' (V7-03).

    ``price_as_of`` is the trading day of the most-recent price bar — intrinsic
    to the data, so it is identical whether the series was just fetched or
    served from cache, and is what the result renders as "as of close M/D".
    ``price_fetched_at`` is the original wall-clock fetch time of that series
    (cache-aware: a cache hit reports the first fetch, not the serve time).
    ``news_as_of`` is when company news was last fetched (news is uncached, so
    this is always the live fetch time).
    """

    price_as_of: date | None = None
    price_fetched_at: datetime | None = None
    news_as_of: datetime | None = None


class ResearchData(BaseModel):
    filings: list[Any] = Field(default_factory=list)
    news: list[Any] = Field(default_factory=list)
    freshness: DataFreshness = Field(default_factory=DataFreshness)


class AnalysisData(BaseModel):
    technical: dict[str, Any] = Field(default_factory=dict)
    narrative: str = ""
    # "high" | "medium" | "low" | "insufficient_data"
    confidence: str = "insufficient_data"


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class AnalysisQuery(BaseModel):
    """Request body for POST /api/v1/analysis/query."""

    query: str = Field(..., min_length=1)
    ticker: str = Field(..., min_length=1, max_length=10)
    # "fundamental" | "technical" | "general"
    analysis_type: str = Field(..., pattern=r"^(fundamental|technical|general)$")
    session_id: uuid.UUID | None = None
    portfolio_profile: PortfolioProfile | None = None


class AnalysisResponse(BaseModel):
    """Final result payload — matches the SSE 'final_result' event and the sync stub."""

    session_id: uuid.UUID
    ticker: str
    research: ResearchData = Field(default_factory=ResearchData)
    analysis: AnalysisData = Field(default_factory=AnalysisData)
    risk_review: RiskReview = Field(default_factory=RiskReview)
    disclaimer: str = DISCLAIMER


class HealthResponse(BaseModel):
    status: str
    db: str
    redis: str = "unknown"
