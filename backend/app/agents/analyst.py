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
import math
import re
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
    "You are a financial research assistant. Interpret the deterministic "
    "technical indicators you are given — do not just restate their values. "
    "Explain what each key signal means (e.g. what an overbought RSI or a "
    "positive MACD histogram implies for momentum) and explicitly call out "
    "when signals agree or conflict (e.g. RSI overbought while MACD is still "
    "positive). Anchor every interpretive claim to a provided indicator value "
    "by quoting that value, so the reader can verify it. Never state a number "
    "that is not in the provided indicators, never recompute or predict prices, "
    "and never recommend buy or sell. Use hedging language. Output 3-5 "
    "sentences of plain English."
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
    # V9-03: a focused (single/specific-ticker) query carries the query-relevant
    # holdings instead of a portfolio-wide breakdown. Surface them first — they
    # are the most directly relevant context. Tier 2 only (ticker / sector /
    # size bucket); never identity.
    focus = portfolio_profile.get("focus")
    if focus:
        named = ", ".join(
            f"{f.get('ticker')} ({f.get('sector')}, {f.get('position_size')})"
            for f in focus
            if isinstance(f, dict) and f.get("ticker")
        )
        if named:
            bits.append(f"holding {named}")
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


# RSI(14) >= 70 is the conventional overbought line, <= 30 oversold. The
# "lean" (bullish / bearish / neutral) lets us compare RSI against MACD to spot
# agreement vs. conflict without recomputing anything.
_RSI_OVERBOUGHT = 70.0
_RSI_OVERSOLD = 30.0


def _rsi_reading(rsi: float) -> tuple[str, str]:
    """Return ``(lean, meaning)`` for an RSI value — interpretation, not restatement."""
    if rsi >= _RSI_OVERBOUGHT:
        return ("bearish", "in overbought territory (above 70), which often means "
                "buying has run hot and upside momentum may be stretched")
    if rsi <= _RSI_OVERSOLD:
        return ("bullish", "in oversold territory (below 30), which often means "
                "selling has run hot and downside momentum may be stretched")
    return ("neutral", "in neutral territory (between 30 and 70), neither "
            "overbought nor oversold")


def _macd_reading(macd: MACDIndicator) -> tuple[str, str]:
    """Return ``(lean, meaning)`` for a MACD reading from the histogram sign."""
    if macd.histogram > 0:
        return ("bullish", "above its signal line (positive histogram), pointing "
                "to upward momentum")
    if macd.histogram < 0:
        return ("bearish", "below its signal line (negative histogram), pointing "
                "to downward momentum")
    return ("neutral", "level with its signal line, pointing to flat momentum")


def _signal_relationship(rsi_lean: str, macd_lean: str) -> str | None:
    """A sentence on whether RSI and MACD agree or conflict (V10-01).

    Conflict is the directional disagreement the design names — e.g. RSI
    overbought (bearish lean) while MACD is still positive (bullish lean).
    """
    directional = {"bullish", "bearish"}
    if rsi_lean in directional and macd_lean in directional:
        if rsi_lean != macd_lean:
            return (
                f"These signals conflict: RSI leans {rsi_lean} while MACD leans "
                f"{macd_lean}, so the move may be stretched even as momentum runs "
                "the other way — read them together, not in isolation."
            )
        return (
            f"RSI and MACD agree, both leaning {rsi_lean}, which reinforces the "
            "read rather than contradicting it."
        )
    return None


def _fallback_narrative(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
) -> str:
    """Deterministic interpretive narrative used when no LLM is configured (V10-01).

    Explains what each computed signal *means* and whether the signals agree or
    conflict — it never restates a value without context. Every claim is anchored
    to the exact computed number (formatted identically to the indicator output),
    so the narrative stays auditable, can't state a figure that differs from the
    deterministic math, and the "references computed indicators" contract holds
    offline.
    """
    parts: list[str] = [
        f"Technical read for {ticker} from {indicators.sample_size} daily closes."
    ]

    rsi_lean: str | None = None
    macd_lean: str | None = None

    if indicators.rsi is not None:
        rsi_lean, rsi_meaning = _rsi_reading(indicators.rsi)
        parts.append(f"RSI(14) at {indicators.rsi:.2f} is {rsi_meaning}.")
    if indicators.macd is not None:
        macd_lean, macd_meaning = _macd_reading(indicators.macd)
        parts.append(
            f"MACD(12/26/9) — line {indicators.macd.macd:.4f}, signal "
            f"{indicators.macd.signal:.4f}, histogram {indicators.macd.histogram:.4f} "
            f"— sits {macd_meaning}."
        )
    if rsi_lean is not None and macd_lean is not None:
        relationship = _signal_relationship(rsi_lean, macd_lean)
        if relationship:
            parts.append(relationship)

    if indicators.sma_20 is not None and indicators.latest_close is not None:
        if indicators.latest_close > indicators.sma_20:
            trend = "above its 20-day average, a mild uptrend cue"
        elif indicators.latest_close < indicators.sma_20:
            trend = "below its 20-day average, a mild downtrend cue"
        else:
            trend = "right at its 20-day average, a flat trend cue"
        parts.append(
            f"The latest close {indicators.latest_close:.2f} is {trend} "
            f"(SMA(20) {indicators.sma_20:.2f})."
        )
    if indicators.bollinger is not None and indicators.latest_close is not None:
        if indicators.latest_close > indicators.bollinger.upper:
            band = (f"above the upper Bollinger band ({indicators.bollinger.upper:.2f}), "
                    "an unusually stretched reading")
        elif indicators.latest_close < indicators.bollinger.lower:
            band = (f"below the lower Bollinger band ({indicators.bollinger.lower:.2f}), "
                    "an unusually stretched reading")
        else:
            band = (f"within its Bollinger bands ({indicators.bollinger.lower:.2f} to "
                    f"{indicators.bollinger.upper:.2f}), a normal range")
        parts.append(f"Price is {band}.")

    parts.append(
        "No single indicator predicts where the price goes next; these describe "
        "current conditions, not a recommendation."
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


# Numeric tokens that *look* like a price or computed indicator: a dollar
# amount, or a decimal with 2+ fractional digits. Plain integers (RSI(14),
# SMA(20), thresholds 70/30, news counts) are excluded — the analyst never
# quotes a *computed* value as a bare int. Mirrors the Risk Critic's detector;
# this gate just routes a fabricating LLM to the clean deterministic fallback
# *before* the critic ever sees it, so criterion 4 holds on the live path too.
_NUMERIC_TOKEN_RE = re.compile(
    r"\$\s*(?P<dollar>\d+(?:\.\d+)?)"
    r"|"
    r"(?<![\d.$])(?P<decimal>\d+\.\d{2,})(?!\d)"
)
_NUMERIC_TOLERANCE = 0.01


def _allowed_numbers(indicators: TechnicalIndicators) -> list[float]:
    """Every number the narrative may legitimately quote — the computed values."""
    vals: list[float] = []
    if indicators.rsi is not None:
        vals.append(indicators.rsi)
    if indicators.macd is not None:
        vals.extend([indicators.macd.macd, indicators.macd.signal, indicators.macd.histogram])
    if indicators.sma_20 is not None:
        vals.append(indicators.sma_20)
    if indicators.bollinger is not None:
        vals.extend(
            [
                indicators.bollinger.upper,
                indicators.bollinger.middle,
                indicators.bollinger.lower,
            ]
        )
    if indicators.latest_close is not None:
        vals.append(indicators.latest_close)
    return vals


def _states_unsupported_number(text: str, indicators: TechnicalIndicators) -> bool:
    """True if the text quotes a price-like number that matches no computed value.

    This is the criterion-4 guard for the live LLM path: a narrative that states
    a figure differing from the deterministic output is rejected (→ fallback).
    """
    allowed = _allowed_numbers(indicators)
    for match in _NUMERIC_TOKEN_RE.finditer(text):
        raw = match.group("dollar") or match.group("decimal")
        if raw is None:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if not any(
            math.isclose(value, a, abs_tol=_NUMERIC_TOLERANCE, rel_tol=0.0)
            for a in allowed
        ):
            return True
    return False


def _narrative_references_indicators(
    text: str, indicators: TechnicalIndicators
) -> bool:
    """Whether the narrative names and quotes each computed indicator.

    The deterministic fallback satisfies the design-doc acceptance contract
    ("narrative references computed indicators") by construction. The LLM
    does not, so we post-validate its output. For each non-None indicator
    we require:
      * the indicator name (RSI / MACD / SMA / Bollinger) to appear, AND
      * the numeric value to appear at a precision near the fallback's
        formatter — we accept one digit of slack either side so typical
        LLM formatting choices don't trigger a needless fallback while
        clearly-fabricated values (e.g. 88.88 for a true RSI of 55.12)
        still fail to match.

    Returning False routes the caller into :func:`_fallback_narrative`,
    keeping the narrative auditable even when the LLM goes off-script.
    """
    if not text:
        return False
    upper = text.upper()

    def _value_quoted(value: float, precision: int) -> bool:
        return any(
            f"{value:.{p}f}" in text
            for p in range(max(precision - 1, 0), precision + 2)
        )

    if indicators.rsi is not None:
        if "RSI" not in upper or not _value_quoted(indicators.rsi, 2):
            return False
    if indicators.macd is not None:
        if "MACD" not in upper:
            return False
        # Any of the three MACD components quoted is sufficient — the LLM
        # is allowed to lead with whichever it finds most informative.
        if not (
            _value_quoted(indicators.macd.macd, 4)
            or _value_quoted(indicators.macd.signal, 4)
            or _value_quoted(indicators.macd.histogram, 4)
        ):
            return False
    # SMA and Bollinger must be named *and* value-anchored when computed — every
    # interpretive claim is tied to a number the user can verify (V10-01 AC3).
    if indicators.sma_20 is not None:
        if ("SMA" not in upper and "MOVING AVERAGE" not in upper) or not _value_quoted(
            indicators.sma_20, 2
        ):
            return False
    if indicators.bollinger is not None:
        if "BOLLINGER" not in upper or not (
            _value_quoted(indicators.bollinger.upper, 2)
            or _value_quoted(indicators.bollinger.middle, 2)
            or _value_quoted(indicators.bollinger.lower, 2)
        ):
            return False
    # No price-like number may appear that isn't a computed value (V10-01 AC4):
    # a fabricated extra figure routes the narrative to the deterministic fallback.
    if _states_unsupported_number(text, indicators):
        return False
    return True


def narrate(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
) -> str:
    """LLM narration of the indicators, with a deterministic fallback.

    Tests monkeypatch this function directly to keep the suite offline. If
    ``openai_api_key`` is unset, the LLM call raises, or the LLM's output
    fails to reference the computed indicators, the deterministic template
    is used instead so the agent never crashes the pipeline and the
    "narrative references computed indicators" acceptance contract holds
    in every path.
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
            "Write an interpretive narrative: explain what the indicators mean "
            "together — where they agree, where they conflict — quoting each "
            "value you reference so the reader can verify it. If a portfolio "
            "profile is provided, briefly tailor the language to its risk "
            "orientation and diversification without recomputing any numbers."
        )
        result = llm.invoke(
            [
                SystemMessage(content=_NARRATIVE_SYSTEM_PROMPT),
                HumanMessage(content=prompt),
            ]
        )
        text = str(result.content).strip()
        if not _narrative_references_indicators(text, indicators):
            logger.warning(
                "LLM narrative did not reference all computed indicators; "
                "falling back to deterministic template"
            )
            return _fallback_narrative(
                ticker, indicators, packet, portfolio_profile
            )
        return text
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
