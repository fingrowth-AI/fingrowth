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
from app.models.fundamentals import FundamentalsSnapshot
from app.models.research import ResearchPacket
from app.tools.fundamentals import format_compact_usd
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

# Question-first framing shared by both routes: the user's actual question is a
# first-class input, and the answer to it leads the narrative. The data rules
# differ per route, so each route carries its own system prompt.
_TECHNICAL_SYSTEM_PROMPT = (
    "You are a financial research assistant. You are given the user's "
    "question and deterministic technical indicators. Lead with a direct, "
    "factual answer to the user's specific question based on that data, then "
    "interpret the indicators as supporting context — do not just restate "
    "their values. Explain what each key signal means (e.g. what an "
    "overbought RSI or a positive MACD histogram implies for momentum) and "
    "explicitly call out when signals agree or conflict. Anchor every "
    "interpretive claim to a provided indicator value by quoting that value, "
    "so the reader can verify it. Never state a number that is not in the "
    "provided data, never recompute or predict prices, and never recommend "
    "buy or sell — if the question asks for a buy/sell decision or a "
    "prediction, say that is outside research scope and describe the current "
    "data instead. Use hedging language. Output 3-5 sentences of plain "
    "English."
)
_FUNDAMENTAL_SYSTEM_PROMPT = (
    "You are a financial research assistant. You are given the user's "
    "question, the company's latest reported quarterly figures (revenue, net "
    "income, EPS, year-over-year changes), valuation context, and technical "
    "indicators. Lead with a direct, factual answer to the user's specific "
    "question using the fundamentals — e.g. for an earnings question, state "
    "how the latest reported quarter actually went, quoting the provided "
    "figures exactly as given. Technical indicators are supporting context "
    "only; mention them briefly at most. Never state a number that is not in "
    "the provided data, never recompute or predict prices or results, and "
    "never recommend buy or sell — if the question asks for a buy/sell "
    "decision or a prediction, say that is outside research scope and "
    "describe the reported data instead. Use hedging language for "
    "interpretation (reported facts may be stated plainly). Output 3-6 "
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


def _prior_context_sentence(
    prior_analyses: list[dict[str, Any]] | None,
) -> str | None:
    """V12-06: render the user's recalled prior analyses as one sentence.

    Returns ``None`` when nothing was recalled, so the segment is simply skipped.
    Only the already-anonymized analysis content (the narrative summary) is shown
    — the same PII-free text the cloud produced — so a follow-up visibly builds
    on what the user asked before ("how does this compare to last week?"). Recall
    is user-scoped upstream; this only formats what was handed back.
    """
    if not prior_analyses:
        return None
    snippets: list[str] = []
    for item in prior_analyses[:3]:
        if not isinstance(item, dict):
            continue
        text = str(item.get("content_summary") or item.get("narrative") or "").strip()
        if not text:
            continue
        snippet = text[:140].rstrip()
        similarity = item.get("similarity")
        if isinstance(similarity, (int, float)):
            snippets.append(f"“{snippet}” ({round(float(similarity) * 100)}% similar)")
        else:
            snippets.append(f"“{snippet}”")
    if not snippets:
        return None
    return (
        "Prior context: this builds on related analyses you ran earlier — "
        + "; ".join(snippets)
        + "."
    )


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


# ---------------------------------------------------------------------------
# Result-screen redesign: deterministic, number-free verdict + chunked read.
# These interpret the same computed indicators the card shows; they never quote
# a computed value (the card carries the numbers) and are descriptive only.
# ---------------------------------------------------------------------------


def _rsi_state(rsi: float | None) -> str | None:
    """overbought / oversold / neutral — the *state*, no value."""
    if rsi is None:
        return None
    if rsi >= _RSI_OVERBOUGHT:
        return "overbought"
    if rsi <= _RSI_OVERSOLD:
        return "oversold"
    return "neutral"


def _macd_state(macd: MACDIndicator | None) -> str | None:
    """positive / negative / flat — momentum direction, no value."""
    if macd is None:
        return None
    if macd.histogram > 0:
        return "positive"
    if macd.histogram < 0:
        return "negative"
    return "flat"


def build_verdict(
    ticker: str,
    indicators: TechnicalIndicators,
    analysis_type: str = "technical",
    fundamentals: FundamentalsSnapshot | None = None,
) -> str:
    """A one-line, number-free, descriptive takeaway (<= ~15 words).

    Descriptive only — it characterizes the current read ("looks stretched"),
    never a directive ("buy"/"sell"/"should"). Deterministic from the data.
    On the fundamental route the verdict reflects the latest reported quarter,
    so an earnings question gets an earnings takeaway, not a momentum one.
    """
    subject = ticker.upper() if ticker else "This"

    if analysis_type == "fundamental":
        return _fundamental_verdict(subject, fundamentals)

    rsi = _rsi_state(indicators.rsi)
    macd = _macd_state(indicators.macd)
    if rsi is None:
        return f"{subject}: not enough recent data for a confident read."

    if rsi == "overbought":
        if macd == "positive":
            return (
                f"{subject} looks stretched — momentum is still positive, "
                "but RSI signals it's run hot."
            )
        if macd == "negative":
            return f"{subject} looks stretched — RSI is overbought and momentum has turned down."
        return f"{subject} looks stretched — RSI is overbought after a strong run."
    if rsi == "oversold":
        if macd == "negative":
            return f"{subject} looks washed out — RSI is oversold with momentum still negative."
        if macd == "positive":
            return f"{subject} may be stabilizing — oversold RSI with momentum ticking up."
        return f"{subject} looks washed out — RSI is oversold after heavy selling."
    # neutral RSI
    if macd == "positive":
        return f"{subject} looks steady, with positive momentum and a neutral RSI."
    if macd == "negative":
        return f"{subject} looks soft — a neutral RSI and negative momentum."
    return f"{subject} looks rangebound — a neutral RSI and little momentum either way."


def _fundamental_verdict(
    subject: str, fundamentals: FundamentalsSnapshot | None
) -> str:
    """Number-free latest-quarter takeaway (the narrative carries the figures)."""
    if fundamentals is None or not fundamentals.has_quarter:
        return (
            f"{subject}: latest financials unavailable — see filings and "
            "headlines below."
        )
    revenue_word = _direction_word(fundamentals.revenue_yoy_pct)
    income_word = _direction_word(fundamentals.net_income_yoy_pct)
    if revenue_word and income_word:
        return (
            f"{subject}'s latest quarter: revenue {revenue_word} and profit "
            f"{income_word} year over year."
        )
    if revenue_word:
        return f"{subject}'s latest quarter: revenue {revenue_word} year over year."
    if income_word:
        return f"{subject}'s latest quarter: profit {income_word} year over year."
    return f"{subject}'s latest reported quarter is summarized below."


def _direction_word(yoy_pct: float | None) -> str | None:
    if yoy_pct is None:
        return None
    if yoy_pct > 0:
        return "grew"
    if yoy_pct < 0:
        return "declined"
    return "held flat"


def build_interpretation(
    indicators: TechnicalIndicators,
    analysis_type: str = "technical",
    fundamentals: FundamentalsSnapshot | None = None,
) -> list:
    """Number-free labeled chunks (only those with data).

    Technical route: Momentum / Trend / Range. Fundamental route: Earnings /
    Valuation first — what the question asked about — with Momentum demoted to
    supporting context. Returns a list of :class:`InterpretationSection`;
    imported lazily to avoid a models import cycle. Each body is 1-2 sentences
    of meaning — the precise values stay in the narrative and the indicator card.
    """
    from app.models.analysis import InterpretationSection

    sections: list[InterpretationSection] = []

    if analysis_type == "fundamental":
        sections.extend(_fundamental_sections(fundamentals))

    rsi = _rsi_state(indicators.rsi)
    macd = _macd_state(indicators.macd)
    if rsi is not None:
        if rsi == "overbought":
            momentum = "RSI is overbought, a sign buying has run hot."
        elif rsi == "oversold":
            momentum = "RSI is oversold, a sign selling has run hot."
        else:
            momentum = "RSI sits in neutral territory."
        if macd == "positive":
            momentum += " MACD momentum is still positive."
        elif macd == "negative":
            momentum += " MACD momentum has turned negative."
        elif macd == "flat":
            momentum += " MACD momentum is flat."
        # Call out the classic conflict (overbought but momentum still up, etc.).
        conflict = (rsi == "overbought" and macd == "positive") or (
            rsi == "oversold" and macd == "negative"
        )
        if conflict:
            momentum += " The two pull in different directions, so read them together."
        sections.append(InterpretationSection(label="Momentum", body=momentum))

    # Trend/Range stay technical-route detail; on the fundamental route the
    # Momentum chunk above is already the supporting context.
    if analysis_type != "fundamental":
        if indicators.sma_20 is not None and indicators.latest_close is not None:
            if indicators.latest_close > indicators.sma_20:
                trend = "Price is trading above its 20-day average — a mild uptrend."
            elif indicators.latest_close < indicators.sma_20:
                trend = "Price is trading below its 20-day average — a mild downtrend."
            else:
                trend = "Price is sitting right on its 20-day average — a flat trend."
            sections.append(InterpretationSection(label="Trend", body=trend))

        if indicators.bollinger is not None and indicators.latest_close is not None:
            if indicators.latest_close > indicators.bollinger.upper:
                rng = "Price is above its upper Bollinger band — an unusually stretched reading."
            elif indicators.latest_close < indicators.bollinger.lower:
                rng = "Price is below its lower Bollinger band — an unusually stretched reading."
            else:
                rng = "Price is within its Bollinger bands — a normal trading range."
            sections.append(InterpretationSection(label="Range", body=rng))

    return sections


def _fundamental_sections(fundamentals: FundamentalsSnapshot | None) -> list:
    """Number-free Earnings / Valuation chunks for the fundamental route."""
    from app.models.analysis import InterpretationSection

    sections: list[InterpretationSection] = []
    if fundamentals is None:
        return sections

    if fundamentals.has_quarter:
        revenue_word = _direction_word(fundamentals.revenue_yoy_pct)
        income_word = _direction_word(fundamentals.net_income_yoy_pct)
        bits: list[str] = []
        if revenue_word:
            bits.append(f"revenue {revenue_word}")
        if income_word:
            bits.append(f"net income {income_word}")
        if bits:
            earnings = (
                "In the most recently reported quarter, "
                + " and ".join(bits)
                + " versus the same quarter a year earlier."
            )
        else:
            earnings = (
                "The most recent reported quarter's results are summarized "
                "in the narrative above."
            )
        sections.append(InterpretationSection(label="Earnings", body=earnings))

    valuation_bits: list[str] = []
    if fundamentals.pe_ratio is not None:
        if fundamentals.pe_ratio <= 0:
            multiple = "shares have no meaningful earnings multiple right now"
        elif fundamentals.pe_ratio >= 40:
            multiple = "shares trade at a rich earnings multiple"
        elif fundamentals.pe_ratio >= 15:
            multiple = "shares trade at a moderate earnings multiple"
        else:
            multiple = "shares trade at a low earnings multiple"
        valuation_bits.append(multiple)
    if fundamentals.dividend_yield is not None and fundamentals.dividend_yield > 0:
        valuation_bits.append("the company pays a dividend")
    if valuation_bits:
        valuation = (
            ", and ".join(valuation_bits).capitalize()
            + " — context for the results, not a signal on its own."
        )
        sections.append(InterpretationSection(label="Valuation", body=valuation))

    return sections


def _fundamental_lead(ticker: str, fundamentals: FundamentalsSnapshot) -> list[str]:
    """Deterministic earnings-answer sentences for the fundamental fallback.

    Every figure is formatted via :func:`format_compact_usd` or at a precision
    the snapshot's ``allowed_numbers`` admits, so the numeric guards (analyst
    gate and Risk Critic) recognize each one as legitimate.
    """
    parts: list[str] = []
    if fundamentals.has_quarter:
        quarter_bits: list[str] = []
        if fundamentals.revenue is not None:
            revenue = format_compact_usd(fundamentals.revenue)
            if fundamentals.revenue_yoy_pct is not None:
                word = "up" if fundamentals.revenue_yoy_pct >= 0 else "down"
                revenue += (
                    f" ({word} {abs(fundamentals.revenue_yoy_pct):.1f}% year over year)"
                )
            quarter_bits.append(f"revenue of {revenue}")
        if fundamentals.net_income is not None:
            income = format_compact_usd(fundamentals.net_income)
            if fundamentals.net_income_yoy_pct is not None:
                word = "up" if fundamentals.net_income_yoy_pct >= 0 else "down"
                income += (
                    f" ({word} {abs(fundamentals.net_income_yoy_pct):.1f}% year over year)"
                )
            quarter_bits.append(f"net income of {income}")
        if fundamentals.eps_diluted is not None:
            quarter_bits.append(f"diluted EPS of ${fundamentals.eps_diluted:.2f}")
        when = (
            f"For the quarter ended {fundamentals.period_end:%B %d, %Y}, "
            if fundamentals.period_end
            else "In its most recently reported quarter, "
        )
        parts.append(f"{when}{ticker} reported " + ", ".join(quarter_bits) + ".")
    valuation_bits: list[str] = []
    if fundamentals.pe_ratio is not None and fundamentals.pe_ratio > 0:
        valuation_bits.append(f"a P/E ratio of {fundamentals.pe_ratio:.2f}")
    if fundamentals.market_cap is not None:
        valuation_bits.append(
            f"a market capitalization of {format_compact_usd(fundamentals.market_cap)}"
        )
    if valuation_bits:
        parts.append(f"Shares carry {' and '.join(valuation_bits)}.")
    return parts


def _fallback_narrative(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
    prior_analyses: list[dict[str, Any]] | None = None,
    analysis_type: str = "technical",
) -> str:
    """Deterministic interpretive narrative used when no LLM is configured (V10-01).

    Explains what each computed signal *means* and whether the signals agree or
    conflict — it never restates a value without context. Every claim is anchored
    to the exact computed number (formatted identically to the indicator output),
    so the narrative stays auditable, can't state a figure that differs from the
    deterministic math, and the "references computed indicators" contract holds
    offline.

    On the fundamental route the narrative *leads with the earnings answer* —
    the latest reported quarter's figures — and the technical read follows as
    supporting context, so an earnings question is answered with earnings data
    even offline.
    """
    parts: list[str] = []
    if analysis_type == "fundamental":
        fundamentals = packet.fundamentals
        if fundamentals is not None and (
            fundamentals.has_quarter or fundamentals.pe_ratio is not None
        ):
            parts.extend(_fundamental_lead(ticker, fundamentals))
            parts.append(
                "These are the latest reported figures; they describe how the "
                "most recent period went and suggest nothing about future "
                "results. The technical context below is supporting detail."
            )
        else:
            parts.append(
                f"We couldn't retrieve {ticker}'s latest reported financials, "
                "so the earnings question can't be answered with figures right "
                "now; recent filings and headlines are listed below, and the "
                "technical read follows as general context."
            )

    parts.append(
        f"Technical read for {ticker} from {indicators.sample_size} daily closes."
    )

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
    prior_sentence = _prior_context_sentence(prior_analyses)
    if prior_sentence:
        parts.append(prior_sentence)
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


def _allowed_numbers(
    indicators: TechnicalIndicators,
    fundamentals: FundamentalsSnapshot | None = None,
) -> list[float]:
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
    if fundamentals is not None:
        vals.extend(fundamentals.allowed_numbers())
    return vals


def _states_unsupported_number(
    text: str,
    indicators: TechnicalIndicators,
    fundamentals: FundamentalsSnapshot | None = None,
) -> bool:
    """True if the text quotes a price-like number that matches no computed value.

    This is the criterion-4 guard for the live LLM path: a narrative that states
    a figure differing from the deterministic output is rejected (→ fallback).
    """
    allowed = _allowed_numbers(indicators, fundamentals)
    for match in _NUMERIC_TOKEN_RE.finditer(text):
        raw = match.group("dollar") or match.group("decimal")
        if raw is None:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        # Compare magnitudes — the token pattern can't capture a leading minus
        # sign, so a quoted negative value surfaces unsigned.
        if not any(
            math.isclose(abs(value), abs(a), abs_tol=_NUMERIC_TOLERANCE, rel_tol=0.0)
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


def _llm_output_valid(
    text: str,
    indicators: TechnicalIndicators,
    fundamentals: FundamentalsSnapshot | None,
    analysis_type: str,
) -> bool:
    """Post-validate LLM output per route.

    Technical: the narrative is *about* the indicators, so it must name and
    quote each computed one (the V10-01 contract). Fundamental: the narrative
    is about the question — indicators are optional supporting context — so
    the only hard requirement is that every price-like number it quotes is one
    of the deterministic values (indicators or fundamentals).
    """
    if not text:
        return False
    if analysis_type == "fundamental":
        return not _states_unsupported_number(text, indicators, fundamentals)
    return _narrative_references_indicators(text, indicators)


def narrate(
    ticker: str,
    indicators: TechnicalIndicators,
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
    prior_analyses: list[dict[str, Any]] | None = None,
    analysis_type: str = "technical",
) -> str:
    """LLM narration answering the user's question, with a deterministic fallback.

    The user's actual question (``packet.query``) is a first-class input: the
    LLM is instructed to lead with a direct answer to it, with the deterministic
    data as evidence. Tests monkeypatch this function directly to keep the
    suite offline. If ``openai_api_key`` is unset, the LLM call raises, or the
    LLM's output fails validation for its route, the deterministic template is
    used instead so the agent never crashes the pipeline and the acceptance
    contracts hold in every path.
    """
    if not settings.openai_api_key:
        return _fallback_narrative(
            ticker, indicators, packet, portfolio_profile, prior_analyses,
            analysis_type,
        )
    try:
        # Lazy import so tests / environments without langchain_openai
        # installed (or without an API key) never touch the import.
        from langchain_core.messages import HumanMessage, SystemMessage
        from langchain_openai import ChatOpenAI

        llm = ChatOpenAI(
            model="gpt-4o-mini",
            api_key=settings.openai_api_key,
            temperature=0,
            # A narrative is a short paragraph; capping the completion bounds
            # the worst-case cost of a single call (validation below rejects
            # degenerate output anyway, so a truncated ramble buys nothing).
            max_tokens=700,
        )
        fundamentals = packet.fundamentals
        fundamentals_line = (
            f"Latest reported quarter & valuation: {fundamentals.model_dump_json()}\n"
            if fundamentals is not None
            else ""
        )
        prompt = (
            f"User's question: {packet.query or 'not provided'}\n"
            f"Ticker: {ticker}\n"
            f"{fundamentals_line}"
            f"Indicators: {indicators.model_dump_json()}\n"
            f"Recent headlines: {[n.headline for n in packet.news[:5]]}\n"
            f"Sources degraded: {packet.degraded}\n"
            f"Portfolio profile: {portfolio_profile or 'not provided'}\n"
            f"Prior analyses (the user's earlier related questions): "
            f"{_prior_context_sentence(prior_analyses) or 'none'}\n"
            "Answer the user's question directly in your first sentence using "
            "only the data above, then add the supporting interpretation — "
            "quoting each value you reference so the reader can verify it. If "
            "a portfolio profile is provided, briefly tailor the language to "
            "its risk orientation and diversification without recomputing any "
            "numbers. If prior analyses are provided, note briefly how this "
            "relates to them."
        )
        system_prompt = (
            _FUNDAMENTAL_SYSTEM_PROMPT
            if analysis_type == "fundamental"
            else _TECHNICAL_SYSTEM_PROMPT
        )
        result = llm.invoke(
            [
                SystemMessage(content=system_prompt),
                HumanMessage(content=prompt),
            ]
        )
        text = str(result.content).strip()
        if not _llm_output_valid(text, indicators, fundamentals, analysis_type):
            logger.warning(
                "LLM narrative failed %s-route validation; "
                "falling back to deterministic template",
                analysis_type,
            )
            return _fallback_narrative(
                ticker, indicators, packet, portfolio_profile, prior_analyses,
                analysis_type,
            )
        return text
    except Exception as exc:
        logger.warning(
            "LLM narration failed, using deterministic fallback: %s", exc
        )
        return _fallback_narrative(
            ticker, indicators, packet, portfolio_profile, prior_analyses,
            analysis_type,
        )


def analyze(
    packet: ResearchPacket,
    portfolio_profile: dict[str, Any] | None = None,
    prior_analyses: list[dict[str, Any]] | None = None,
    analysis_type: str = "technical",
) -> AnalysisReport:
    """Produce an :class:`AnalysisReport` from a :class:`ResearchPacket`.

    ``analysis_type`` ("technical" | "fundamental") selects what the narrative,
    verdict and interpretation lead with — the question's subject — while the
    deterministic indicators are always computed and attached. The only side
    effect is the LLM call inside :func:`narrate`; everything else is a
    deterministic function of the inputs.
    """
    closes = _closes(packet)
    indicators, notes = _compute_indicators(closes)
    confidence = _assess_confidence(packet, indicators)
    narrative = narrate(
        packet.ticker, indicators, packet, portfolio_profile, prior_analyses,
        analysis_type,
    )
    return AnalysisReport(
        ticker=packet.ticker,
        technical_indicators=indicators,
        narrative=narrative,
        confidence_level=confidence,
        notes=notes,
        verdict=build_verdict(
            packet.ticker, indicators, analysis_type, packet.fundamentals
        ),
        interpretation=build_interpretation(
            indicators, analysis_type, packet.fundamentals
        ),
        fundamentals=packet.fundamentals,
    )


def analyst_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: read ResearchPacket from state, attach AnalysisReport."""
    research = state.get("research") or {}
    portfolio_profile = state.get("portfolio_profile")
    prior_analyses = state.get("prior_analyses")
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
    # The route decides what the report leads with: fundamental answers with
    # earnings/valuation data, technical with the indicator read.
    analysis_type = (
        "fundamental"
        if state.get("route") == "fundamental_analysis"
        else "technical"
    )
    report = analyze(packet, portfolio_profile, prior_analyses, analysis_type)
    return {"path": ["analyst"], "analysis": report.model_dump(mode="json")}
