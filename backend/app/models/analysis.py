"""Domain models for the Analyst agent (P3-03).

The Analyst produces an :class:`AnalysisReport` that pairs deterministically
computed technical indicators with an LLM-authored narrative. The two halves
stay separated — numbers come from :mod:`app.tools.technical`, interpretation
comes from the LLM — so the Risk Critic (P3-04) can audit the narrative
against the indicators without ever recomputing math itself.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

# confidence_level values are constrained to this set; anything else means a
# bug in the agent. Order in the Literal is informational only.
ConfidenceLevel = Literal["high", "medium", "low", "insufficient_data"]


class MACDIndicator(BaseModel):
    """MACD triple (line / signal / histogram) — see :func:`calculate_macd`."""

    macd: float
    signal: float
    histogram: float


class BollingerIndicator(BaseModel):
    """Bollinger band triple — see :func:`calculate_bollinger`."""

    upper: float
    middle: float
    lower: float


class TechnicalIndicators(BaseModel):
    """Container for the deterministic indicator outputs.

    Every field is optional: shorter price histories may yield RSI without
    MACD, etc. Downstream code should treat ``None`` as "not enough data for
    this indicator" rather than as a zero value.
    """

    rsi: float | None = None
    macd: MACDIndicator | None = None
    sma_20: float | None = None
    bollinger: BollingerIndicator | None = None
    latest_close: float | None = None
    sample_size: int = 0


class AnalysisReport(BaseModel):
    """Structured output of the Analyst agent (P3-03).

    ``technical_indicators`` is purely numeric and reproducible from the
    price series. ``narrative`` is the LLM's plain-English interpretation of
    those numbers — it must never introduce values not already present in
    ``technical_indicators``. ``confidence_level`` summarises data quality.
    """

    ticker: str
    technical_indicators: TechnicalIndicators
    narrative: str
    confidence_level: ConfidenceLevel
    notes: list[str] = Field(default_factory=list)
