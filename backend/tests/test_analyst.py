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
from app.models.analysis import AnalysisReport, TechnicalIndicators
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

    def fake_narrate(ticker, indicators, packet):
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
    assert "RSI(14) is 55.50" in text
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
    # Fell back to the deterministic template.
    assert "RSI(14) is 42.00" in text


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
