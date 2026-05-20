"""Tests for P3-04: Risk Critic agent.

Acceptance criteria (from the design doc, section 5.3):
  * Report claiming specific future prices: flagged and rejected
  * Missing disclaimer: appended automatically
  * Valid analysis with hedging: passes
  * Every output includes the standard disclaimer
"""

from __future__ import annotations

import pytest

from app.agents.risk_critic import critique, risk_critic_node
from app.models.analysis import (
    AnalysisReport,
    BollingerIndicator,
    MACDIndicator,
    TechnicalIndicators,
)
from app.models.risk import STANDARD_DISCLAIMER, RiskReview

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _full_indicators() -> TechnicalIndicators:
    """A populated TechnicalIndicators — useful when the test only cares
    about the narrative side of the audit."""
    return TechnicalIndicators(
        rsi=55.12,
        macd=MACDIndicator(macd=0.5432, signal=0.4321, histogram=0.1111),
        sma_20=102.34,
        bollinger=BollingerIndicator(upper=110.0, middle=102.34, lower=94.68),
        latest_close=103.21,
        sample_size=60,
    )


def _report(narrative: str, *, ticker: str = "AAPL") -> AnalysisReport:
    return AnalysisReport(
        ticker=ticker,
        technical_indicators=_full_indicators(),
        narrative=narrative,
        confidence_level="high",
    )


# ---------------------------------------------------------------------------
# Acceptance: future price claims → flagged and rejected
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "narrative",
    [
        "Our 12-month price target is $150 based on the indicators.",
        "AAPL will reach $200 by Q4 based on MACD momentum.",
        "We set a price target of $175 for this name.",
        "PT of $180 reflects the upside in the RSI trend.",
        "The stock is going to hit $250 in the coming months.",
    ],
)
def test_future_price_claims_are_flagged_and_rejected(narrative: str):
    review = critique(_report(narrative))

    assert review.approved is False
    codes = {f.code for f in review.flags}
    assert "future_price_claim" in codes
    # Rejection replaces the narrative with the safe default.
    assert review.modified_response != narrative
    assert "cannot share this analysis" in review.modified_response.lower()
    # Disclaimer still attached on rejection.
    assert review.disclaimer == STANDARD_DISCLAIMER


# ---------------------------------------------------------------------------
# Acceptance: buy/sell recommendations → flagged and rejected
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "narrative",
    [
        "Recommendation: buy. The RSI suggests strength.",
        "We recommend buying this stock immediately.",
        "You should sell this position before earnings.",
        "Strong buy this stock — the MACD is bullish.",
    ],
)
def test_buy_sell_recommendations_are_flagged_and_rejected(narrative: str):
    review = critique(_report(narrative))

    assert review.approved is False
    codes = {f.code for f in review.flags}
    assert "buy_sell_recommendation" in codes
    assert review.disclaimer == STANDARD_DISCLAIMER


# ---------------------------------------------------------------------------
# Acceptance: excessive confidence → flagged and rejected
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "narrative",
    [
        "This trade is guaranteed to be profitable based on the RSI.",
        "A risk-free opportunity given the MACD crossover.",
        "It is a sure thing the price will rise.",
        "This stock always wins after a Bollinger squeeze.",
    ],
)
def test_excessive_confidence_phrases_are_flagged_and_rejected(narrative: str):
    review = critique(_report(narrative))

    assert review.approved is False
    codes = {f.code for f in review.flags}
    assert "excessive_confidence" in codes


# ---------------------------------------------------------------------------
# Acceptance: valid analysis with hedging → passes
# ---------------------------------------------------------------------------


def test_hedged_narrative_with_indicators_passes():
    narrative = (
        "RSI(14) of 55.12 may indicate neutral momentum; the MACD signal "
        "of 0.4321 suggests a mild uptrend. These observations are for "
        "research purposes only and could change as new data arrives."
    )
    review = critique(_report(narrative))

    assert review.approved is True
    assert review.flags == []
    # On approval the modified_response mirrors the original narrative.
    assert review.modified_response == narrative
    assert review.disclaimer == STANDARD_DISCLAIMER


def test_passing_narrative_carries_no_rejection_flags():
    """Even with the missing_disclaimer advisory, hedged narratives pass."""
    # Hedged but lacks the literal word "research purposes" — that's fine.
    narrative = (
        "The RSI value suggests momentum may be cooling. MACD readings "
        "indicate possible consolidation."
    )
    review = critique(_report(narrative))

    assert review.approved is True


# ---------------------------------------------------------------------------
# Acceptance: missing disclaimer → flagged, but appended automatically
# ---------------------------------------------------------------------------


def test_missing_hedging_in_narrative_is_flagged_but_not_rejected():
    """A blunt, declarative narrative is flagged but the disclaimer is added."""
    narrative = "RSI is 55.12. MACD line is 0.5432. SMA20 is 102.34."
    review = critique(_report(narrative))

    codes = {f.code for f in review.flags}
    assert "missing_disclaimer" in codes
    # Missing-disclaimer alone is advisory — the review is still approved.
    assert review.approved is True
    # The disclaimer is appended at the model level.
    assert review.disclaimer == STANDARD_DISCLAIMER
    assert review.modified_response == narrative


def test_disclaimer_is_appended_even_when_input_narrative_is_empty():
    review = critique(_report(""))
    assert review.disclaimer == STANDARD_DISCLAIMER
    assert review.modified_response  # safe default placeholder


# ---------------------------------------------------------------------------
# Acceptance: every output includes the standard disclaimer
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "narrative",
    [
        "RSI(14) of 55.12 may indicate neutral momentum.",  # passes
        "Price target $150 by year end.",  # rejected (future price)
        "Recommendation: buy now.",  # rejected (buy/sell)
        "Guaranteed gains based on the MACD signal.",  # rejected (confidence)
        "",  # no narrative
        "Plain numeric description with no hedging at all.",  # missing hedging
    ],
)
def test_every_review_includes_standard_disclaimer(narrative: str):
    review = critique(_report(narrative))
    assert review.disclaimer == STANDARD_DISCLAIMER
    assert review.disclaimer  # non-empty


# ---------------------------------------------------------------------------
# Flag details carry the offending substring (auditability)
# ---------------------------------------------------------------------------


def test_flag_detail_records_offending_phrase():
    review = critique(_report("Our 12-month price target is $150."))
    assert any(
        f.code == "future_price_claim" and "price target" in f.detail.lower()
        for f in review.flags
    )


# ---------------------------------------------------------------------------
# Acceptance: hallucinated / unsupported numeric claims are detected
#
# The critic compares every price-like or indicator-like number in the
# narrative against TechnicalIndicators. Numbers that don't appear in the
# computed indicators are flagged as advisory (do not, on their own, reject
# the review — the design lets the critic "flag, modify, or reject", and
# rejection is reserved for the clear compliance violations).
# ---------------------------------------------------------------------------


def test_unsupported_dollar_amount_is_flagged():
    """A fabricated price not present in the indicators is flagged."""
    # latest_close in _full_indicators() is 103.21 — $999.99 is fabricated.
    review = critique(
        _report(
            "Closing price $999.99 may indicate a breakout for research purposes."
        )
    )
    codes = {f.code for f in review.flags}
    assert "unsupported_numeric_claim" in codes
    assert any(
        f.code == "unsupported_numeric_claim" and "999.99" in f.detail
        for f in review.flags
    )


def test_unsupported_indicator_value_is_flagged():
    """A decimal that doesn't match any computed indicator is flagged."""
    # rsi is 55.12, macd line is 0.5432 — 88.88 matches neither.
    review = critique(
        _report("RSI(14) of 88.88 may suggest overbought conditions.")
    )
    codes = {f.code for f in review.flags}
    assert "unsupported_numeric_claim" in codes


def test_indicator_values_quoted_correctly_do_not_trigger_flag():
    """Quoting the actual computed RSI/MACD/SMA values passes cleanly."""
    # _full_indicators(): rsi=55.12, macd.signal=0.4321, sma_20=102.34
    narrative = (
        "RSI(14) of 55.12 may indicate balanced momentum; the MACD signal "
        "of 0.4321 suggests a mild uptrend. The SMA(20) at 102.34 is "
        "informational only."
    )
    review = critique(_report(narrative))
    assert not any(
        f.code == "unsupported_numeric_claim" for f in review.flags
    )


def test_dollar_amount_matching_latest_close_passes():
    """A $-prefixed price equal to the indicators' latest_close is allowed."""
    # latest_close = 103.21
    review = critique(
        _report("Latest close $103.21 may inform research-purposes-only views.")
    )
    assert not any(
        f.code == "unsupported_numeric_claim" for f in review.flags
    )


def test_unsupported_numeric_claim_is_advisory_not_rejection():
    """An unsupported number alone (no compliance violation) does not reject."""
    # No future-price, buy/sell, or excessive-confidence phrasing — just a
    # fabricated decimal that isn't in indicators.
    review = critique(
        _report("RSI of 88.88 may indicate something noteworthy for research.")
    )
    assert review.approved is True
    codes = {f.code for f in review.flags}
    assert "unsupported_numeric_claim" in codes
    # Advisory: the original narrative is preserved, not the safe default.
    assert "88.88" in review.modified_response


def test_integer_periods_do_not_trigger_unsupported_numeric():
    """Indicator periods like RSI(14), SMA(20), MACD(12/26/9) are not flagged."""
    narrative = (
        "RSI(14), SMA(20) and MACD(12/26/9) may collectively be informative "
        "for research purposes."
    )
    review = critique(_report(narrative))
    assert not any(
        f.code == "unsupported_numeric_claim" for f in review.flags
    )


def test_year_integer_does_not_trigger_unsupported_numeric():
    """A bare four-digit year is not a price-like number."""
    review = critique(
        _report(
            "Since 2024 the RSI may have trended lower based on the data."
        )
    )
    assert not any(
        f.code == "unsupported_numeric_claim" for f in review.flags
    )


def test_unsupported_numeric_tolerates_format_rounding():
    """Narrative values within %.2f rounding tolerance of indicators are accepted.

    Indicator math typically produces high-precision values; the Analyst
    formats them with ``%.2f`` / ``%.4f``. The critic must tolerate that
    rounding — otherwise every legitimate quote would be flagged.
    """
    # Simulate the realistic case: indicator is high-precision, narrative
    # quotes the .2f-rounded form.
    indicators = TechnicalIndicators(
        rsi=55.123456,
        sample_size=60,
    )
    report = AnalysisReport(
        ticker="AAPL",
        technical_indicators=indicators,
        narrative="RSI of 55.12 may indicate balanced momentum (research).",
        confidence_level="high",
    )
    review = critique(report)
    assert not any(
        f.code == "unsupported_numeric_claim" for f in review.flags
    )


def test_unsupported_numeric_present_alongside_compliance_violation():
    """Hallucinated price WITH a future-price claim: both flags surface; rejected."""
    review = critique(_report("Our price target is $999.99 by year end."))
    codes = {f.code for f in review.flags}
    assert "future_price_claim" in codes
    assert "unsupported_numeric_claim" in codes
    # The future_price_claim is enough to trigger rejection on its own.
    assert review.approved is False


# ---------------------------------------------------------------------------
# Graph node integration
# ---------------------------------------------------------------------------


def test_risk_critic_node_attaches_review_to_state():
    report = _report(
        "RSI(14) of 55.12 may suggest balanced momentum (research purposes)."
    )
    state = {"analysis": report.model_dump(mode="json")}

    result = risk_critic_node(state)

    assert result["path"] == ["risk_critic"]
    review = RiskReview.model_validate(result["risk_review"])
    assert review.approved is True
    assert review.disclaimer == STANDARD_DISCLAIMER


def test_risk_critic_node_rejects_future_price_claims_via_state():
    report = _report("12-month price target is $150 by Q4.")
    state = {"analysis": report.model_dump(mode="json")}

    result = risk_critic_node(state)
    review = RiskReview.model_validate(result["risk_review"])

    assert review.approved is False
    assert any(f.code == "future_price_claim" for f in review.flags)


def test_risk_critic_node_handles_missing_analysis_gracefully():
    """The general_research route bypasses the Analyst — the critic must
    still emit a typed, disclaimer-bearing review."""
    result = risk_critic_node({})

    assert result["path"] == ["risk_critic"]
    review = RiskReview.model_validate(result["risk_review"])
    assert review.approved is True
    assert review.flags == []
    assert review.disclaimer == STANDARD_DISCLAIMER


def test_risk_critic_node_handles_empty_analysis_dict():
    result = risk_critic_node({"analysis": {}})

    review = RiskReview.model_validate(result["risk_review"])
    assert review.disclaimer == STANDARD_DISCLAIMER
