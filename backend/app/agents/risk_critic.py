"""Risk Critic agent (P3-04).

Mandatory guardrail on every :class:`AnalysisReport`. Scans the LLM-authored
narrative for compliance violations — forward-looking price claims, buy/sell
recommendations, and language that overstates certainty — and either approves
the narrative as-is, flags it, or replaces it with a safe default. The
regulatory disclaimer is attached to every review regardless of outcome.

Implemented as deterministic pattern matching, not another LLM call: a
guardrail that hallucinates is no guardrail. Each detector is a small,
auditable regex; every flag carries the offending substring so a human
reviewer can spot-check a decision without re-running anything.
"""

from __future__ import annotations

import math
import re
from typing import Any

from app.models.analysis import AnalysisReport
from app.models.risk import (
    STANDARD_DISCLAIMER,
    RiskFlag,
    RiskFlagCode,
    RiskReview,
)

# ---------------------------------------------------------------------------
# Detection patterns
# ---------------------------------------------------------------------------
# Each pattern targets a specific compliance violation. We err narrow so that
# hedged, retrospective language passes: "the 12-month moving average" is OK,
# but "a 12-month price target" is not.

_FUTURE_PRICE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\bprice\s+targets?\b", re.IGNORECASE),
    re.compile(r"\b\d{1,2}-?\s*month\s+target\b", re.IGNORECASE),
    # V10-04: any forward-looking projection of a numeric level — hedged or not,
    # "$"-prefixed or bare — is a forward claim and is rejected. The analyst only
    # ever describes the *present* ("RSI is 79.87"), never projects a value to a
    # future level, so this can't false-flag a genuine interpretation. Covers
    # "may reach 300", "could trade at $300", "is going to hit $250", etc.
    re.compile(
        r"\b(?:will|going\s+to|expect(?:s|ed)?\s+to|forecast(?:s|ed)?\s+to|"
        r"could|may|might|should|likely\s+to|poised\s+to|set\s+to|on\s+track\s+to)\s+"
        r"(?:reach|hit|rise\s+to|climb\s+to|drop\s+to|fall\s+to|go\s+to|"
        r"trade\s+at|trading\s+at|be\s+worth|be\s+valued\s+at|change\s+hands\s+at)"
        r"\s+\$?\d",
        re.IGNORECASE,
    ),
    re.compile(
        r"\btarget(?:s|ing|ed)?\s+(?:price\s+)?(?:of\s+)?\$\d",
        re.IGNORECASE,
    ),
    re.compile(r"\bPT\s+of\s+\$?\d", re.IGNORECASE),
)

_BUY_SELL_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(
        r"\b(?:strong\s+)?(?:buy|sell)\s+"
        r"(?:now|immediately|this(?:\s+stock)?|the\s+stock)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:we|i|you)\s+(?:recommend|suggest|advise)\s+"
        r"(?:buying|selling|shorting|going\s+long)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\brecommendation:?\s+"
        r"(?:buy|sell|short|hold|strong\s+(?:buy|sell))\b",
        re.IGNORECASE,
    ),
    # V10-04: directive aimed at any investor subject, not just "you" — richer
    # narratives drift into "investors should sell" / "one should exit".
    re.compile(
        r"\b(?:investors?|traders?|shareholders?|you|we|one|people)\s+should\s+"
        r"(?:buy|sell|short|exit|avoid|dump|hold|get\s+out)\b",
        re.IGNORECASE,
    ),
    # V10-04: portfolio-action directives ("reduce exposure", "trim your position").
    re.compile(
        r"\b(?:reduce|trim|increase|lighten|boost|add\s+to)\s+(?:your\s+)?"
        r"(?:exposure|position|holdings?|stake|allocation)\b",
        re.IGNORECASE,
    ),
    # V10-04: soft directives still nudge an action ("consider selling",
    # "it's time to buy") — honest framing ("consider the trend") is unaffected
    # because the verb must be a trade action.
    re.compile(r"\bconsider\s+(?:buying|selling|shorting|exiting)\b", re.IGNORECASE),
    re.compile(
        r"\b(?:it'?s\s+)?time\s+to\s+(?:buy|sell|short|exit|get\s+out)\b",
        re.IGNORECASE,
    ),
    # V10-04: a standalone rating ("this is a strong buy", "rated a sell").
    re.compile(
        r"\b(?:is|are|rated|remains?)\s+a\s+(?:strong\s+|clear\s+)?(?:buy|sell)\b",
        re.IGNORECASE,
    ),
    # V10-04: explicit position-action directives.
    re.compile(
        r"\b(?:take\s+profits?|cut\s+(?:your\s+)?losses|lock\s+in\s+(?:gains|profits))\b",
        re.IGNORECASE,
    ),
)

_EXCESSIVE_CONFIDENCE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\bguarantee(?:s|d)?\b", re.IGNORECASE),
    re.compile(r"\b(?:absolutely|definitely|certainly)\s+will\b", re.IGNORECASE),
    re.compile(r"\bno\s+risk\b", re.IGNORECASE),
    re.compile(r"\brisk[- ]free\b", re.IGNORECASE),
    re.compile(r"\bcan(?:not|'t)\s+lose\b", re.IGNORECASE),
    re.compile(r"\bsure[- ]thing\b", re.IGNORECASE),
    re.compile(r"\balways\s+wins?\b", re.IGNORECASE),
)

# Hedging vocabulary that satisfies the "narrative tone is appropriately
# qualified" check. We treat hedging as an acceptable substitute for the
# literal disclaimer text inside the narrative — the regulatory disclaimer
# itself is always attached to the review separately.
_HEDGING_VOCAB = re.compile(
    r"\b(?:may|might|could|appears?|suggests?|indicat(?:es?|ed)|"
    r"possibly|likely|potential(?:ly)?|tends?\s+to|tended\s+to|"
    r"research\s+purposes?|not\s+(?:investment|financial)\s+advice|"
    r"informational\s+purposes?|hedg(?:e|ing|ed))\b",
    re.IGNORECASE,
)

# Tokens in the narrative that *look* like prices or computed indicator values.
# Two shapes only:
#   * dollar-prefixed amounts:   $150, $103.21
#   * decimals with 2+ fractional digits: 0.4321, 102.34
# Plain integers (years, indicator periods like RSI(14), SMA(20), news counts)
# are intentionally excluded — they swamp the signal with legitimate context
# numbers, and the analyst never quotes a *computed* indicator as a bare int.
_NUMERIC_TOKEN_PATTERN = re.compile(
    r"\$\s*(?P<dollar>\d+(?:\.\d+)?)"
    r"|"
    r"(?<![\d.$])(?P<decimal>\d+\.\d{2,})(?!\d)"
)

# Half a unit at .2f precision (the analyst's default format for prices, RSI
# and SMA). Tight enough to flag fabricated values, wide enough to absorb the
# rounding that any %f formatter introduces.
_NUMERIC_TOLERANCE = 0.01

# Flag codes that escalate to a rejection. Other codes are advisory.
_REJECTION_CODES: frozenset[RiskFlagCode] = frozenset(
    {
        "future_price_claim",
        "buy_sell_recommendation",
        "excessive_confidence",
    }
)

# The standard rejection message. Kept literal (no f-string interpolation of
# user input) so a hostile narrative cannot influence the safe default.
_SAFE_DEFAULT_RESPONSE = (
    "We cannot share this analysis as written because it contains "
    "forward-looking claims, explicit buy/sell guidance, or language that "
    "overstates certainty — all of which fall outside our research-only "
    "scope. Please rephrase your question to focus on retrospective data "
    "and technical indicators."
)


def _collect(text: str, patterns: tuple[re.Pattern[str], ...]) -> list[str]:
    """Return offending substrings, one per pattern hit, preserving order."""
    return [m.group(0) for pat in patterns for m in pat.finditer(text)]


def _make_flags(code: RiskFlagCode, hits: list[str]) -> list[RiskFlag]:
    return [RiskFlag(code=code, detail=hit) for hit in hits]


def _allowed_numeric_values(report: AnalysisReport) -> list[float]:
    """Numbers the narrative may quote without triggering a hallucination flag.

    Mirrors the deterministic values the Analyst emits: the
    :class:`TechnicalIndicators` fields plus, on the fundamental route, the
    report's :class:`FundamentalsSnapshot` (which admits its own scaled display
    forms — "$26.04 billion" — via ``allowed_numbers``). If a new computed
    value is added there, mirror it here so the critic can recognise
    legitimate references to it.
    """
    indicators = report.technical_indicators
    vals: list[float] = []
    if report.fundamentals is not None:
        vals.extend(report.fundamentals.allowed_numbers())
    if indicators.rsi is not None:
        vals.append(indicators.rsi)
    if indicators.macd is not None:
        vals.extend(
            [
                indicators.macd.macd,
                indicators.macd.signal,
                indicators.macd.histogram,
            ]
        )
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


def _is_supported(value: float, allowed: list[float]) -> bool:
    # Compare magnitudes: the token pattern can't capture a leading minus sign,
    # so "signal -0.4402" surfaces as 0.4402 — still a legitimate reference to
    # the computed (negative) value.
    return any(
        math.isclose(abs(value), abs(a), abs_tol=_NUMERIC_TOLERANCE, rel_tol=0.0)
        for a in allowed
    )


def _detect_unsupported_numerics(
    narrative: str, report: AnalysisReport
) -> list[str]:
    """Return narrative tokens that look like prices/indicators but match nothing computed.

    The check is intentionally conservative — only dollar amounts and decimal
    values with two or more fractional digits are inspected, because plain
    integers in financial prose almost always refer to periods, dates, or
    counts rather than fabricated indicator values.
    """
    if not narrative:
        return []
    allowed = _allowed_numeric_values(report)
    unsupported: list[str] = []
    for m in _NUMERIC_TOKEN_PATTERN.finditer(narrative):
        raw = m.group("dollar") or m.group("decimal")
        if raw is None:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if not _is_supported(value, allowed):
            unsupported.append(m.group(0))
    return unsupported


def critique(report: AnalysisReport) -> RiskReview:
    """Audit an :class:`AnalysisReport` and produce a :class:`RiskReview`.

    Approval semantics:
      * any ``future_price_claim``, ``buy_sell_recommendation`` or
        ``excessive_confidence`` flag triggers rejection
      * ``missing_disclaimer`` and ``unsupported_numeric_claim`` are
        advisory — they surface to the audit log but do not, on their own,
        replace the narrative
    """
    narrative = report.narrative or ""

    flags: list[RiskFlag] = []
    flags.extend(
        _make_flags(
            "future_price_claim",
            _collect(narrative, _FUTURE_PRICE_PATTERNS),
        )
    )
    flags.extend(
        _make_flags(
            "buy_sell_recommendation",
            _collect(narrative, _BUY_SELL_PATTERNS),
        )
    )
    flags.extend(
        _make_flags(
            "excessive_confidence",
            _collect(narrative, _EXCESSIVE_CONFIDENCE_PATTERNS),
        )
    )
    flags.extend(
        _make_flags(
            "unsupported_numeric_claim",
            _detect_unsupported_numerics(narrative, report),
        )
    )

    if narrative and not _HEDGING_VOCAB.search(narrative):
        flags.append(
            RiskFlag(
                code="missing_disclaimer",
                detail="narrative lacks hedging vocabulary (may/could/suggests/...)",
            )
        )

    rejected = any(f.code in _REJECTION_CODES for f in flags)
    if rejected:
        modified_response = _SAFE_DEFAULT_RESPONSE
    elif narrative:
        modified_response = narrative
    else:
        modified_response = "No analysis is available for this query."

    return RiskReview(
        approved=not rejected,
        flags=flags,
        modified_response=modified_response,
        disclaimer=STANDARD_DISCLAIMER,
    )


def risk_critic_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: review the analysis on the state and attach a RiskReview.

    Two input shapes are accepted:

    * an ``analysis`` dict (the normal Analyst → Risk Critic path) — the
      critic audits it and returns the full review
    * no ``analysis`` (the ``general_research`` route bypasses the Analyst)
      — the critic still emits a typed, disclaimer-bearing RiskReview so the
      downstream API never has to special-case "no review"
    """
    analysis = state.get("analysis") or None
    if not analysis:
        review = RiskReview(
            approved=True,
            flags=[],
            modified_response="",
            disclaimer=STANDARD_DISCLAIMER,
        )
        return {
            "path": ["risk_critic"],
            "risk_review": review.model_dump(mode="json"),
        }
    report = AnalysisReport.model_validate(analysis)
    review = critique(report)
    return {
        "path": ["risk_critic"],
        "risk_review": review.model_dump(mode="json"),
    }
