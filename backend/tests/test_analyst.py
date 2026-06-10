"""Tests for P3-03: Analyst agent.

Acceptance criteria (from the design doc):
  * RSI/MACD values match direct function calls on the same data
  * Narrative references the computed indicators
  * confidence_level is one of: high | medium | low | insufficient_data
"""

from __future__ import annotations

import math
from datetime import UTC, date, datetime, timedelta

import pytest

from app.agents import analyst as analyst_module
from app.agents.analyst import analyst_node, analyze, narrate
from app.models.analysis import AnalysisReport, MACDIndicator, TechnicalIndicators
from app.models.market import PriceBar
from app.models.news import NewsItem
from app.models.research import ResearchPacket, Source
from app.tools.technical import calculate_macd, calculate_rsi


@pytest.fixture(autouse=True)
def _disable_llm_by_default(monkeypatch):
    """Pin the analyst to its deterministic fallback narrator for this file.

    Some local/dev environments have OPENAI_API_KEY set in their .env, which
    would make the indicator-math tests slow and the narrative-content test
    depend on whatever the LLM chose to emit. Tests that specifically exercise
    the LLM path re-enable the key explicitly.
    """
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")


# ---------------------------------------------------------------------------
# Sample data builders
# ---------------------------------------------------------------------------


def _sine_closes(n: int, *, base: float = 100.0, amp: float = 5.0) -> list[float]:
    """A smooth oscillating series — exercises both RSI and MACD non-trivially."""
    return [base + amp * math.sin(i / 3.0) for i in range(n)]


_START = date(2024, 1, 1)


def _price_bars(closes: list[float], ticker: str = "AAPL") -> list[PriceBar]:
    """Wrap a closes list as PriceBars with monotonically increasing dates."""
    return [
        PriceBar(
            ticker=ticker,
            date=_START + timedelta(days=i),
            open=c,
            high=c + 1.0,
            low=c - 1.0,
            close=c,
            volume=1_000_000 + i,
        )
        for i, c in enumerate(closes)
    ]


def _ok_source(name: str, count: int = 0) -> Source:
    return Source(
        name=name,
        url=f"https://example/{name}",
        retrieved_at=datetime(2024, 1, 1, tzinfo=UTC),
        ok=True,
        item_count=count,
    )


def _failed_source(name: str) -> Source:
    return Source(
        name=name,
        url=f"https://example/{name}",
        retrieved_at=datetime(2024, 1, 1, tzinfo=UTC),
        ok=False,
        error="boom",
    )


def _packet(
    closes: list[float],
    *,
    ticker: str = "AAPL",
    news: list[NewsItem] | None = None,
    degraded: bool = False,
) -> ResearchPacket:
    """Build a ResearchPacket from a closes series.

    ``degraded=True`` flips the SEC source to a failed one so
    :attr:`ResearchPacket.degraded` becomes True without affecting prices.
    """
    sec = _failed_source("SEC EDGAR") if degraded else _ok_source("SEC EDGAR")
    return ResearchPacket(
        ticker=ticker,
        query="q",
        filings=[],
        price_data=_price_bars(closes, ticker=ticker),
        news=news or [],
        sources=[
            sec,
            _ok_source("Alpha Vantage", count=len(closes)),
            _ok_source("Finnhub"),
        ],
    )


# ---------------------------------------------------------------------------
# Acceptance: RSI / MACD values match direct function calls
# ---------------------------------------------------------------------------


def test_rsi_matches_direct_function_call():
    closes = _sine_closes(60)
    expected = calculate_rsi(closes)

    report = analyze(_packet(closes))

    assert report.technical_indicators.rsi is not None
    assert math.isclose(report.technical_indicators.rsi, expected, rel_tol=1e-12)


def test_macd_matches_direct_function_call():
    closes = _sine_closes(60)
    expected = calculate_macd(closes)

    report = analyze(_packet(closes))

    macd = report.technical_indicators.macd
    assert macd is not None
    assert math.isclose(macd.macd, expected.macd, rel_tol=1e-12)
    assert math.isclose(macd.signal, expected.signal, rel_tol=1e-12)
    assert math.isclose(macd.histogram, expected.histogram, rel_tol=1e-12)


def test_analyst_uses_chronologically_ordered_closes():
    """Even if PriceBars arrive out of order, the analyst sorts by date."""
    closes = _sine_closes(60)
    expected = calculate_rsi(closes)

    packet = _packet(closes)
    # Shuffle the bars (reverse order) — analyzer must still produce the same RSI.
    packet.price_data = list(reversed(packet.price_data))

    report = analyze(packet)
    assert report.technical_indicators.rsi is not None
    assert math.isclose(report.technical_indicators.rsi, expected, rel_tol=1e-12)


# ---------------------------------------------------------------------------
# Acceptance: narrative references computed indicators
# ---------------------------------------------------------------------------


def test_narrative_references_rsi_and_macd_values(monkeypatch):
    """The fallback narrative (offline default) mentions RSI/MACD by name + value.

    The LLM path is tested separately — here we pin to the deterministic
    fallback so the assertion is independent of an LLM's formatting choices.
    """
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")

    closes = _sine_closes(60)
    report = analyze(_packet(closes))

    text = report.narrative
    rsi = report.technical_indicators.rsi
    macd = report.technical_indicators.macd
    assert rsi is not None and macd is not None

    assert "RSI" in text
    assert "MACD" in text
    # Indicator values must appear in the narrative — that's the whole point.
    assert f"{rsi:.2f}" in text
    assert f"{macd.macd:.4f}" in text


def test_llm_narrator_is_called_with_indicators(monkeypatch):
    """When narrate() is monkeypatched, its return wins — i.e. the seam exists."""
    captured: dict[str, object] = {}

    def fake_narrate(
        ticker, indicators, packet,
        portfolio_profile=None, prior_analyses=None, analysis_type="technical",
    ):
        captured["ticker"] = ticker
        captured["rsi"] = indicators.rsi
        return "FAKE NARRATIVE"

    monkeypatch.setattr(analyst_module, "narrate", fake_narrate)

    closes = _sine_closes(60)
    report = analyze(_packet(closes, ticker="MSFT"))

    assert report.narrative == "FAKE NARRATIVE"
    assert captured["ticker"] == "MSFT"
    # Indicators were computed BEFORE narration, then handed to the narrator.
    assert captured["rsi"] is not None


# ---------------------------------------------------------------------------
# Acceptance: confidence_level covers all four enum values
# ---------------------------------------------------------------------------


def test_confidence_high_with_full_data_and_clean_sources():
    report = analyze(_packet(_sine_closes(60)))
    assert report.confidence_level == "high"


def test_confidence_medium_when_non_price_source_degraded():
    report = analyze(_packet(_sine_closes(60), degraded=True))
    assert report.confidence_level == "medium"
    # Indicators are still fully computed — degradation is about provenance.
    assert report.technical_indicators.rsi is not None
    assert report.technical_indicators.macd is not None


def test_confidence_low_when_macd_unavailable_but_rsi_ok():
    # 20 bars: enough for RSI(15+) but short of MACD(34+).
    report = analyze(_packet(_sine_closes(20)))
    assert report.confidence_level == "low"
    assert report.technical_indicators.rsi is not None
    assert report.technical_indicators.macd is None


def test_confidence_insufficient_data_when_no_prices():
    report = analyze(_packet([]))
    assert report.confidence_level == "insufficient_data"
    assert report.technical_indicators.rsi is None
    assert report.technical_indicators.macd is None
    assert report.technical_indicators.sample_size == 0


def test_confidence_insufficient_data_when_rsi_unavailable():
    # 10 bars: not even enough for RSI(15+).
    report = analyze(_packet(_sine_closes(10)))
    assert report.confidence_level == "insufficient_data"
    assert report.technical_indicators.rsi is None


# ---------------------------------------------------------------------------
# narrate(): fallback path is used when no LLM key is configured
# ---------------------------------------------------------------------------


def test_narrate_fallback_used_when_api_key_missing(monkeypatch):
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    indicators = TechnicalIndicators(rsi=55.5, sample_size=60)
    text = narrate("AAPL", indicators, _packet([]))
    # V10-01: the value is still quoted (anchored), now wrapped in meaning.
    assert "RSI" in text and "55.50" in text
    assert "AAPL" in text


def test_narrate_falls_back_when_llm_raises(monkeypatch):
    """An LLM exception must not propagate — fallback narrative is used instead."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "sk-test")

    # Make ChatOpenAI import succeed via a stand-in that raises on invoke().
    class _BoomLLM:
        def __init__(self, *a, **kw):
            pass

        def invoke(self, _messages):
            raise RuntimeError("network is down")

    import langchain_openai

    monkeypatch.setattr(langchain_openai, "ChatOpenAI", _BoomLLM)

    indicators = TechnicalIndicators(rsi=42.0, sample_size=60)
    text = narrate("AAPL", indicators, _packet([]))
    # Fell back to the deterministic template — value still anchored.
    assert "RSI" in text and "42.00" in text


def test_narrate_falls_back_when_llm_omits_indicators(monkeypatch):
    """An LLM response that ignores the computed indicators is rejected.

    The acceptance contract is "narrative references computed indicators";
    if the LLM produces text that names neither RSI nor MACD nor mentions
    their values, the analyst must substitute the deterministic template
    so the contract holds end-to-end.
    """
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "sk-test")

    class _IgnoresIndicatorsLLM:
        def __init__(self, *a, **kw):
            pass

        def invoke(self, _messages):
            class _Result:
                content = (
                    "The market may be exhibiting interesting patterns "
                    "that suggest further research is warranted."
                )

            return _Result()

    import langchain_openai

    monkeypatch.setattr(langchain_openai, "ChatOpenAI", _IgnoresIndicatorsLLM)

    closes = _sine_closes(60)
    report = analyze(_packet(closes))

    # The fallback emits these specific tokens; their presence proves the
    # post-validator rejected the LLM output and used the template instead.
    rsi = report.technical_indicators.rsi
    assert rsi is not None
    assert "RSI" in report.narrative and f"{rsi:.2f}" in report.narrative


def test_narrate_falls_back_when_llm_omits_value(monkeypatch):
    """Naming RSI without quoting any value close to the computed one fails."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "sk-test")

    class _NamesOnlyLLM:
        def __init__(self, *a, **kw):
            pass

        def invoke(self, _messages):
            class _Result:
                content = (
                    "RSI and MACD may both be informative here; further "
                    "research is suggested."
                )

            return _Result()

    import langchain_openai

    monkeypatch.setattr(langchain_openai, "ChatOpenAI", _NamesOnlyLLM)

    closes = _sine_closes(60)
    report = analyze(_packet(closes))
    rsi = report.technical_indicators.rsi
    assert rsi is not None
    # Fell back: deterministic template emits the formatted value.
    assert f"{rsi:.2f}" in report.narrative


def test_narrate_accepts_compliant_llm_response(monkeypatch):
    """A response that names + quotes each computed indicator survives validation.

    For a 60-bar series all four indicators (RSI, MACD, SMA, Bollinger) are
    computed, so the canned narrative must reference each of them or the
    post-validator routes through the deterministic fallback.
    """
    from app.tools.technical import calculate_bollinger, calculate_sma

    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "sk-test")

    closes = _sine_closes(60)
    # Compute what the analyst will see so the fake LLM can echo accurate values.
    expected_rsi = calculate_rsi(closes)
    expected_macd = calculate_macd(closes)
    expected_sma = calculate_sma(closes)
    expected_boll = calculate_bollinger(closes)

    canned_narrative = (
        f"RSI(14) of {expected_rsi:.2f} may suggest neutral momentum; the "
        f"MACD line at {expected_macd.macd:.4f} could indicate a mild "
        f"uptrend. SMA(20) sits near {expected_sma:.2f} and the Bollinger "
        f"midline is around {expected_boll.middle:.2f} for research purposes."
    )

    class _CompliantLLM:
        def __init__(self, *a, **kw):
            pass

        def invoke(self, _messages):
            class _Result:
                content = canned_narrative

            return _Result()

    import langchain_openai

    monkeypatch.setattr(langchain_openai, "ChatOpenAI", _CompliantLLM)

    report = analyze(_packet(closes))
    # The LLM output was preserved verbatim — no fallback substitution.
    assert report.narrative == canned_narrative


def _stub_llm(monkeypatch, content: str) -> None:
    """Point ChatOpenAI at a canned response and enable the LLM path."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "sk-test")

    class _StubLLM:
        def __init__(self, *a, **kw):
            pass

        def invoke(self, _messages):
            class _Result:
                pass

            r = _Result()
            r.content = content
            return r

    import langchain_openai

    monkeypatch.setattr(langchain_openai, "ChatOpenAI", _StubLLM)


def test_narrate_rejects_llm_response_with_fabricated_number(monkeypatch):
    """V10-01 AC4 on the live path: correct indicator values but an EXTRA
    fabricated price must not reach the user — route to the clean fallback."""
    from app.tools.technical import calculate_bollinger, calculate_sma

    closes = _sine_closes(60)
    rsi = calculate_rsi(closes)
    macd = calculate_macd(closes)
    sma = calculate_sma(closes)
    boll = calculate_bollinger(closes)

    fabricated = (
        f"RSI(14) at {rsi:.2f} looks neutral; MACD line {macd.macd:.4f} is mild. "
        f"SMA(20) {sma:.2f} and the Bollinger midline {boll.middle:.2f} frame it. "
        "A reasonable support sits at $1234.56."  # not a computed value
    )
    _stub_llm(monkeypatch, fabricated)

    report = analyze(_packet(closes))
    # Fell back: the fabricated figure never reaches the narrative.
    assert "1234.56" not in report.narrative
    assert report.narrative != fabricated
    # The deterministic fallback still anchors the real values.
    assert f"{rsi:.2f}" in report.narrative


def test_narrate_rejects_unanchored_sma_or_bollinger_claim(monkeypatch):
    """V10-01 AC3 on the live path: naming SMA/Bollinger without quoting their
    computed values is unanchored → rejected → fallback."""
    closes = _sine_closes(60)
    rsi = calculate_rsi(closes)
    macd = calculate_macd(closes)

    unanchored = (
        f"RSI(14) at {rsi:.2f} is neutral and the MACD line {macd.macd:.4f} is "
        "mild. Watch the SMA and the Bollinger bands for confirmation."  # no values
    )
    _stub_llm(monkeypatch, unanchored)

    report = analyze(_packet(closes))
    assert report.narrative != unanchored  # rejected for missing SMA/Bollinger values


# ---------------------------------------------------------------------------
# V10-01: the narrative interprets, it doesn't just restate
# ---------------------------------------------------------------------------


def test_narrative_explains_meaning_of_each_signal(monkeypatch):
    """AC1: meaning, not just value — overbought RSI + momentum-bearing MACD."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    indicators = TechnicalIndicators(
        rsi=78.50,
        macd=MACDIndicator(macd=2.0, signal=1.0, histogram=1.0),
        sample_size=60,
    )
    text = narrate("AAPL", indicators, _packet([])).lower()
    assert "overbought" in text          # what the RSI value *means*
    assert "momentum" in text            # what the MACD reading *means*


def test_narrative_notes_conflict_between_signals(monkeypatch):
    """AC2: RSI overbought (bearish lean) but MACD positive (bullish) → conflict."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    indicators = TechnicalIndicators(
        rsi=78.50,
        macd=MACDIndicator(macd=2.0, signal=1.0, histogram=1.0),
        sample_size=60,
    )
    text = narrate("AAPL", indicators, _packet([]))
    assert "78.50" in text               # anchored to the computed value
    assert "conflict" in text.lower()


def test_narrative_notes_agreement_when_signals_align(monkeypatch):
    """The mirror of conflict: oversold RSI + negative MACD both lean bearish... no,
    oversold leans bullish; pair it with a positive MACD so both agree."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    indicators = TechnicalIndicators(
        rsi=22.00,  # oversold → bullish lean
        macd=MACDIndicator(macd=2.0, signal=1.0, histogram=1.0),  # positive → bullish
        sample_size=60,
    )
    text = narrate("AAPL", indicators, _packet([]))
    assert "oversold" in text.lower()
    assert "agree" in text.lower()


def test_narrative_anchors_every_value_to_computed_output(monkeypatch):
    """AC3/AC4: each computed indicator value appears verbatim, so every claim is
    verifiable and the narrative can't state a figure that differs from the math."""
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    closes = _sine_closes(60)
    report = analyze(_packet(closes))
    ind = report.technical_indicators
    text = report.narrative

    assert ind.rsi is not None and ind.macd is not None
    assert f"{ind.rsi:.2f}" in text
    assert f"{ind.macd.macd:.4f}" in text
    assert ind.sma_20 is not None and f"{ind.sma_20:.2f}" in text
    assert ind.bollinger is not None
    assert (
        f"{ind.bollinger.upper:.2f}" in text or f"{ind.bollinger.lower:.2f}" in text
    )
    # Interprets rather than merely restating — a meaning word is present.
    assert any(
        w in text.lower()
        for w in ("overbought", "oversold", "neutral", "momentum", "uptrend", "downtrend")
    )


# ---------------------------------------------------------------------------
# Graph node integration
# ---------------------------------------------------------------------------


def test_analyst_node_attaches_analysis_to_state():
    closes = _sine_closes(60)
    packet = _packet(closes)

    result = analyst_node(
        {
            "ticker": "AAPL",
            "research": packet.model_dump(mode="json"),
        }
    )

    assert result["path"] == ["analyst"]
    analysis = result["analysis"]
    assert isinstance(analysis, dict)
    # Round-trip into the typed model to confirm the dict is well-formed.
    report = AnalysisReport.model_validate(analysis)
    assert report.ticker == "AAPL"
    assert report.confidence_level == "high"
    assert report.technical_indicators.rsi is not None
    assert "RSI" in report.narrative


def test_analyst_node_handles_missing_research_gracefully():
    """If the researcher contributed nothing, emit a typed insufficient-data report."""
    result = analyst_node({"ticker": "AAPL", "research": {}})

    assert result["path"] == ["analyst"]
    report = AnalysisReport.model_validate(result["analysis"])
    assert report.confidence_level == "insufficient_data"
    assert report.technical_indicators.sample_size == 0
    assert report.notes  # explanatory note attached


# ---------------------------------------------------------------------------
# Fundamental route: the report leads with the earnings answer
# ---------------------------------------------------------------------------


def _fundamentals():
    from app.models.fundamentals import FundamentalsSnapshot

    return FundamentalsSnapshot(
        period_end=date(2025, 4, 27),
        revenue=26_044_000_000,
        revenue_yoy_pct=43.7,
        net_income=18_775_000_000,
        net_income_yoy_pct=26.2,
        eps_diluted=0.76,
        pe_ratio=55.5,
        market_cap=3_210_000_000_000,
    )


def _fundamental_packet(closes: list[float], *, ticker: str = "NVDA") -> ResearchPacket:
    packet = _packet(closes, ticker=ticker)
    return packet.model_copy(update={
        "query": "How were NVDA's latest earnings?",
        "fundamentals": _fundamentals(),
    })


def test_fundamental_route_leads_with_earnings_answer():
    """The narrative answers the earnings question first; technicals follow."""
    report = analyze(_fundamental_packet(_sine_closes(60)), analysis_type="fundamental")

    narrative = report.narrative
    # Leads with the reported quarter, not the technical template.
    assert narrative.index("quarter ended") < narrative.index("Technical read")
    assert "$26.04 billion" in narrative
    assert "up 43.7% year over year" in narrative
    assert "$18.77 billion" in narrative
    assert "diluted EPS of $0.76" in narrative


def test_fundamental_verdict_reflects_the_quarter_not_momentum():
    report = analyze(_fundamental_packet(_sine_closes(60)), analysis_type="fundamental")
    assert "quarter" in report.verdict.lower()
    assert "revenue grew" in report.verdict.lower()
    assert len(report.verdict.split()) <= 15
    # Number-free: the narrative carries the figures.
    assert not any(ch.isdigit() for ch in report.verdict)


def test_fundamental_interpretation_has_earnings_and_valuation_chunks():
    report = analyze(_fundamental_packet(_sine_closes(60)), analysis_type="fundamental")
    labels = [s.label for s in report.interpretation]
    assert labels[0] == "Earnings"
    assert "Valuation" in labels
    assert "Momentum" in labels  # supporting context, after the answer
    assert "Trend" not in labels and "Range" not in labels


def test_fundamental_route_degrades_when_fundamentals_missing():
    """No fundamentals fetched → say so, then fall back to general context."""
    packet = _packet(_sine_closes(60), ticker="NVDA")
    report = analyze(packet, analysis_type="fundamental")
    assert "couldn't retrieve" in report.narrative.lower()
    assert "unavailable" in report.verdict.lower()


def test_fundamental_report_carries_fundamentals_for_the_critic():
    report = analyze(_fundamental_packet(_sine_closes(60)), analysis_type="fundamental")
    assert report.fundamentals is not None
    assert report.fundamentals.revenue == pytest.approx(26_044_000_000)


def test_technical_route_behavior_is_unchanged():
    report = analyze(_packet(_sine_closes(60)))
    assert report.narrative.startswith("Technical read for AAPL")
    assert report.fundamentals is None
    labels = [s.label for s in report.interpretation]
    assert "Momentum" in labels and "Earnings" not in labels


def test_fundamental_fallback_passes_risk_critic():
    """The earnings fallback's figures are recognized as legitimate (advisory-clean)."""
    from app.agents.risk_critic import critique

    report = analyze(_fundamental_packet(_sine_closes(60)), analysis_type="fundamental")
    review = critique(report)
    assert review.approved is True
    assert not any(f.code == "unsupported_numeric_claim" for f in review.flags)
