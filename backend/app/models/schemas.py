from __future__ import annotations

import uuid
from typing import Any

from pydantic import BaseModel, Field

DISCLAIMER = (
    "This is a research tool, not investment advice. "
    "The information provided is for educational and research purposes only. "
    "Past performance does not guarantee future results. "
    "Always consult a qualified financial advisor before making investment decisions."
)


# ---------------------------------------------------------------------------
# Shared / nested models
# ---------------------------------------------------------------------------


class PortfolioProfile(BaseModel):
    """Anonymized portfolio context sent from the iOS client via DifferentialPrivacy."""

    sector_weights: dict[str, float] = Field(default_factory=dict)
    largest_position: str | None = None
    diversification: str | None = None
    risk_orientation: str | None = None


class ResearchData(BaseModel):
    filings: list[Any] = Field(default_factory=list)
    news: list[Any] = Field(default_factory=list)


class AnalysisData(BaseModel):
    technical: dict[str, Any] = Field(default_factory=dict)
    narrative: str = ""
    # "high" | "medium" | "low" | "insufficient_data"
    confidence: str = "insufficient_data"


class RiskReview(BaseModel):
    approved: bool = True
    flags: list[str] = Field(default_factory=list)


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
