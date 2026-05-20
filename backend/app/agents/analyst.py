"""Analyst agent (P3-03).

Reads a :class:`ResearchPacket` off the graph state, runs the deterministic
P2-04 technical-analysis functions on its price history, and asks an LLM to
narrate the numbers. The split is strict: every number in the report comes
from a Python function — the LLM only writes English about numbers we hand
it.

Why a deterministic fallback narrator?
    Tests run offline and the local-dev ``settings`` ships with an empty
    ``openai_api_key``. Falling back to a template means the analyst is
    runnable end-to-end without secrets, and the acceptance contract
    ("narrative references computed indicators") holds in both modes.
"""

from __future__ import annotations

import logging
from typing import Any

from app.config import settings
from app.models.analysis import (
    AnalysisReport,
    BollingerIndicator,
    ConfidenceLevel,
    MACDIndicator,
    TechnicalIndicators,
)
from app.models.research import ResearchPacket
from app.tools.technical import (
    calculate_bollinger,
    calculate_macd,
    calculate_rsi,
    calculate_sma,
)

logger = logging.getLogger(__name__)

# Minimum bar counts mirror the requirements inside tools/technical.py.
# Keep them as named constants so confidence assessment and indicator gating
# stay in sync if the underlying periods are ever tuned.
_RSI_MIN_BARS = 15  # period + 1 for diff
_MACD_MIN_BARS = 34  # slow(26) + signal(9) - 1
_SMA_MIN_BARS = 20
_BOLLINGER_MIN_BARS = 20

_NARRATIVE_SYSTEM_PROMPT = (
    "You are a financial research assistant interpreting deterministic "
    "technical indicators. Reference each provided indicator by name and "
    "value. Use hedging language. Do NOT compute, predict prices, or "
    "recommend buy/sell. Output 3-5 sentences of plain English."
)


def _closes(packet: ResearchPacket) -> list[float]:
    """Closing prices, sorted oldest -> newest (technical-lib convention)."""
    bars = sorted(packet.price_data, key=lambda b: b.date)
    return [float(b.close) for b in bars]


def _compute_indicators(
    closes: list[float],
) -> tuple[TechnicalIndicators, list[str]]:
    """Run every applicable P2-04 function; record which ones were skipped."""
    notes: list[str] = []
    rsi: float | None = None
    macd_result: MACDIndicator | None = None
    sma: float | None = None
    boll: BollingerIndicator | None = None

    if len(closes) >= _RSI_MIN_BARS:
        rsi = calculate_rsi(closes)
    else:
        notes.append(
            f"RSI requires >= {_RSI_MIN_BARS} closing bars (got {len(closes)})"
        )

    if len(closes) >= _MACD_MIN_BARS:
        m = calculate_macd(closes)
        macd_result = MACDIndicator(
            macd=m.macd, signal=m.signal, histogram=m.histogram
        )
    else:
        notes.append(
            f"MACD requires >= {_MACD_MIN_BARS} closing bars (got {len(closes)})"
        )

    if len(closes) >= _SMA_MIN_BARS:
        sma = calculate_sma(closes)
    if len(closes) >= _BOLLINGER_MIN_BARS:
        b = calculate_bollinger(closes)
        boll = BollingerIndicator(upper=b.upper, middle=b.middle, lower=b.lower)

    return (
        TechnicalIndicators(
            rsi=rsi,
            macd=macd_result,
            sma_20=sma,
            bollinger=boll,
            latest_close=closes[-1] if closes else None,
            sample_size=len(closes),
        ),
        notes,
    )


def _assess_confidence(
    packet: ResearchPacket, indicators: TechnicalIndicators
) -> ConfidenceLevel:
    """Map (data availability, source health) onto a confidence level.

    Boundaries:
      * ``insufficient_data`` — RSI itself could not be computed
      * ``low``               — RSI yes, MACD no (15-33 bars)
      * ``medium``            — all indicators OK but a non-price source failed
      * ``high``              — all indicators OK and every source returned
    """
    if indicators.rsi is None:
        return "insufficient_data"
    if indicators.macd is None:
        return "low"
    if packet.degraded:
        return "medium"
    return "high"


def _portfolio_context_sentence(
    portfolio_profile: dict[str, Any] | None,
) -> str | None:
    """Render the (already-anonymized) portfolio profile as a single sentence.

    Returns ``None`` when no profile was provided so callers can simply skip
    the segment instead of emitting an empty clause. The sentence picks up the
    three fields the design doc names — risk orientation, diversification,
    and the largest-position label — because those are the ones the iOS
    DifferentialPrivacy layer guarantees are coarse-grained / non-identifying.
    """
    if not portfolio_profile:
        return None
    bits: list[str] = []
    risk = portfolio_profile.get("risk_orientation")
    div = portfolio_profile.get("diversification")
    largest = portfolio_profile.get("largest_position")
    if risk:
        bits.append(f"risk orientation '{risk}'")
    if div:
        bits.append(f"{div} diversification")
    if largest:
        bits.append(f"largest position is {largest}")
    if not bits:
        return None
    return "Portfolio context: " + ", ".join(bits) + "."


def _fallback_narrative(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
) -> str:
    """Deterministic template used when no LLM is configured.

    Every computed indicator is mentioned by name *and* numeric value so the
    output remains auditable and the "narrative references computed
    indicators" acceptance test passes without any network calls.
    """
    parts: list[str] = [
        f"Technical snapshot for {ticker} based on "
        f"{indicators.sample_size} daily closes."
    ]
    if indicators.rsi is not None:
        parts.append(f"RSI(14) is {indicators.rsi:.2f}.")
    if indicators.macd is not None:
        parts.append(
            f"MACD(12/26/9): line {indicators.macd.macd:.4f}, "
            f"signal {indicators.macd.signal:.4f}, "
            f"histogram {indicators.macd.histogram:.4f}."
        )
    if indicators.sma_20 is not None and indicators.latest_close is not None:
        parts.append(
            f"Latest close {indicators.latest_close:.2f} "
            f"versus SMA(20) {indicators.sma_20:.2f}."
        )
    if indicators.bollinger is not None:
        parts.append(
            f"Bollinger(20, 2σ) band: lower {indicators.bollinger.lower:.2f}, "
            f"middle {indicators.bollinger.middle:.2f}, "
            f"upper {indicators.bollinger.upper:.2f}."
        )
    if packet.news:
        parts.append(
            f"Context: {len(packet.news)} recent news items considered."
        )
    if packet.degraded:
        parts.append(
            "Note: one or more data sources degraded; signals are partial."
        )
    profile_sentence = _portfolio_context_sentence(portfolio_profile)
    if profile_sentence:
        parts.append(profile_sentence)
    return " ".join(parts)


def narrate(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
) -> str:
    """LLM narration of the indicators, with a deterministic fallback.

    Tests monkeypatch this function directly to keep the suite offline. If
    ``openai_api_key`` is unset, or the LLM call raises for any reason, the
    deterministic template is used instead so the agent never crashes the
    pipeline because of an external dependency.
    """
    if not settings.openai_api_key:
        return _fallback_narrative(ticker, indicators, packet, portfolio_profile)
    try:
        # Lazy import so tests / environments without langchain_openai
        # installed (or without an API key) never touch the import.
        from langchain_core.messages import HumanMessage, SystemMessage
        from langchain_openai import ChatOpenAI

        llm = ChatOpenAI(
            model="gpt-4o-mini",
            api_key=settings.openai_api_key,
            temperature=0,
        )
        prompt = (
            f"Ticker: {ticker}\n"
            f"Indicators: {indicators.model_dump_json()}\n"
            f"Recent headlines: {[n.headline for n in packet.news[:5]]}\n"
            f"Sources degraded: {packet.degraded}\n"
            f"Portfolio profile: {portfolio_profile or 'not provided'}\n"
            "Write the narrative. If a portfolio profile is provided, briefly "
            "tailor the language to its risk orientation and diversification "
            "without recomputing any numbers."
        )
        result = llm.invoke(
            [
                SystemMessage(content=_NARRATIVE_SYSTEM_PROMPT),
                HumanMessage(content=prompt),
            ]
        )
        text = str(result.content).strip()
        return text or _fallback_narrative(
            ticker, indicators, packet, portfolio_profile
        )
    except Exception as exc:
        logger.warning(
            "LLM narration failed, using deterministic fallback: %s", exc
        )
        return _fallback_narrative(ticker, indicators, packet, portfolio_profile)


def analyze(
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
) -> AnalysisReport:
    """Produce an :class:`AnalysisReport` from a :class:`ResearchPacket`.

    The only side effect is the LLM call inside :func:`narrate`; everything
    else is a deterministic function of ``packet`` and ``portfolio_profile``.
    """
    closes = _closes(packet)
    indicators, notes = _compute_indicators(closes)
    confidence = _assess_confidence(packet, indicators)
    narrative = narrate(packet.ticker, indicators, packet, portfolio_profile)
    return AnalysisReport(
        ticker=packet.ticker,
        technical_indicators=indicators,
        narrative=narrative,
        confidence_level=confidence,
        notes=notes,
    )


def analyst_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: read ResearchPacket from state, attach AnalysisReport."""
    research = state.get("research") or {}
    portfolio_profile = state.get("portfolio_profile")
    if not research:
        # Researcher contributed nothing — emit a clearly-degraded report
        # instead of crashing, so the Risk Critic still gets a typed input.
        report = AnalysisReport(
            ticker=state.get("ticker", ""),
            technical_indicators=TechnicalIndicators(),
            narrative="No research data available; analysis cannot proceed.",
            confidence_level="insufficient_data",
            notes=["no research data in graph state"],
        )
        return {"path": ["analyst"], "analysis": report.model_dump(mode="json")}

    packet = ResearchPacket.model_validate(research)
    report = analyze(packet, portfolio_profile)
    return {"path": ["analyst"], "analysis": report.model_dump(mode="json")}
