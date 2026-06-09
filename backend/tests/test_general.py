"""Tests for the general-research narrator.

The general_research route bypasses the Analyst, so without this it produced an
empty narrative (the iOS client then showed "We couldn't produce an
assessment"). The narrator turns the Researcher's packet into a short, hedged,
advice-free summary so general/news/overview questions get a real answer.
"""

from __future__ import annotations

from datetime import UTC, datetime

from app.agents.general import general_node, summarize_general_research
from app.agents.risk_critic import critique
from app.models.analysis import AnalysisReport
from app.models.research import ResearchPacket


def _packet(*, news=None, filings=None, sources=None) -> ResearchPacket:
    return ResearchPacket.model_validate(
        {
            "ticker": "AAPL",
            "query": "what's happening with AAPL",
            "news": news or [],
            "filings": filings or [],
            "price_data": [],
            "sources": sources or [],
        }
    )


def _news(headline: str, score: float = 0.0) -> dict:
    return {
        "headline": headline,
        "sentiment_score": score,
        "datetime": datetime(2024, 1, 1, tzinfo=UTC).isoformat(),
    }


def test_summary_includes_counts_and_headlines():
    packet = _packet(
        news=[_news("Apple unveils new product line"), _news("Apple reports quarterly results")]
    )
    text = summarize_general_research("AAPL", packet)
    assert "AAPL" in text
    assert "2 recent news items" in text
    assert "Apple unveils new product line" in text
    # Hedged + framed as research, not advice.
    assert "not advice" in text.lower()


def test_summary_handles_no_research_gracefully():
    text = summarize_general_research("AAPL", _packet())
    assert "no recent filings or news" in text.lower()
    assert "not advice" in text.lower()


def test_summary_is_singular_for_one_item():
    packet = _packet(news=[_news("Only one story")], filings=[])
    text = summarize_general_research("AAPL", packet)
    assert "1 recent news item" in text
    assert "1 recent news items" not in text


def test_general_node_emits_nonempty_reviewed_narrative():
    # The node produces an AnalysisReport; the Risk Critic must approve a clean
    # summary, so the final narrative is non-empty (no more "We couldn't produce").
    packet = _packet(news=[_news("Apple announces buyback")])
    state = {"research": packet.model_dump(mode="json"), "ticker": "AAPL"}
    result = general_node(state)

    report = AnalysisReport.model_validate(result["analysis"])
    assert report.narrative.strip()
    assert report.confidence_level == "low"

    review = critique(report)
    assert review.approved, f"clean summary should pass the critic; flags={review.flags}"
    assert review.modified_response.strip()  # non-empty narrative reaches the client


def test_general_node_without_research_still_narrates():
    result = general_node({"research": {}, "ticker": "AAPL"})
    report = AnalysisReport.model_validate(result["analysis"])
    assert "AAPL" in report.narrative
    assert report.confidence_level == "insufficient_data"
