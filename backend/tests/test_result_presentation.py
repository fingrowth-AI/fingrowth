"""Tests for the result-screen redesign's deterministic backend fields.

The verdict (one-line takeaway) and interpretation chunks (Momentum/Trend/Range)
are derived deterministically from the indicators, are number-free (the card
carries the values), and are descriptive — never directive.
"""

from __future__ import annotations

import re

from app.agents.analyst import build_interpretation, build_verdict
from app.models.analysis import BollingerIndicator, MACDIndicator, TechnicalIndicators

# Directive language the verdict/chunks must never contain.
_ADVICE = re.compile(r"\b(buy|sell|short|hold|should|recommend|trim|exit)\b", re.IGNORECASE)
# Price-like / computed values (the card's job, not the prose): $-amounts or
# decimals with 2+ fractional digits. "20-day" / "RSI" period names are fine.
_NUMERIC = re.compile(r"\$\s*\d|(?<![\d.])\d+\.\d{2,}")


def _ind(
    *, rsi=None, hist=None, sma=None, close=None, upper=None, lower=None
) -> TechnicalIndicators:
    macd = MACDIndicator(macd=0.0, signal=0.0, histogram=hist) if hist is not None else None
    boll = (
        BollingerIndicator(upper=upper, middle=(upper + lower) / 2, lower=lower)
        if upper is not None and lower is not None
        else None
    )
    return TechnicalIndicators(
        rsi=rsi, macd=macd, sma_20=sma, bollinger=boll, latest_close=close, sample_size=60
    )


# MARK: verdict


def test_verdict_is_short_descriptive_number_free_and_safe():
    v = build_verdict("AAPL", _ind(rsi=78.0, hist=1.2))
    assert "AAPL" in v
    assert len(v.split()) <= 15, f"verdict too long: {v!r}"
    assert not _ADVICE.search(v), f"verdict is directive: {v!r}"
    assert not _NUMERIC.search(v), f"verdict quotes a value: {v!r}"
    assert "stretched" in v.lower()  # overbought read


def test_verdict_reflects_signal_states():
    assert "washed out" in build_verdict("X", _ind(rsi=20.0, hist=-1.0)).lower()
    assert "stabilizing" in build_verdict("X", _ind(rsi=20.0, hist=1.0)).lower()
    assert "rangebound" in build_verdict("X", _ind(rsi=50.0, hist=0.0)).lower()
    assert "soft" in build_verdict("X", _ind(rsi=50.0, hist=-1.0)).lower()


def test_verdict_handles_insufficient_data():
    v = build_verdict("X", _ind())  # no RSI
    assert "not enough" in v.lower()
    assert len(v.split()) <= 15


def test_all_verdict_branches_stay_short_and_safe():
    for rsi in (78.0, 20.0, 50.0, None):
        for hist in (1.0, -1.0, 0.0, None):
            v = build_verdict("AAPL", _ind(rsi=rsi, hist=hist))
            assert len(v.split()) <= 15, f"{rsi}/{hist}: {v!r}"
            assert not _ADVICE.search(v), f"{rsi}/{hist}: {v!r}"
            assert not _NUMERIC.search(v), f"{rsi}/{hist}: {v!r}"


# MARK: interpretation chunks


def test_interpretation_is_labeled_number_free_and_safe():
    sections = build_interpretation(
        _ind(rsi=78.0, hist=1.2, sma=100.0, close=110.0, upper=108.0, lower=92.0)
    )
    assert [s.label for s in sections] == ["Momentum", "Trend", "Range"]
    for s in sections:
        assert not _NUMERIC.search(s.body), f"{s.label} quotes a value: {s.body!r}"
        assert not _ADVICE.search(s.body), f"{s.label} is directive: {s.body!r}"
    range_body = next(s.body for s in sections if s.label == "Range").lower()
    assert "above its upper bollinger band" in range_body


def test_interpretation_omits_sections_without_data():
    # Only RSI present → only Momentum.
    assert [s.label for s in build_interpretation(_ind(rsi=50.0))] == ["Momentum"]
    # Nothing computable → no chunks.
    assert build_interpretation(_ind()) == []


def test_momentum_flags_signal_conflict():
    body = build_interpretation(_ind(rsi=78.0, hist=1.0))[0].body.lower()
    assert "different directions" in body  # overbought but momentum still positive
