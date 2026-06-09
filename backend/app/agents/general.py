"""General-research narrator.

The ``general_research`` route bypasses the Analyst (which narrates technical
indicators), so it used to produce no narrative at all — the iOS client then
showed "We couldn't produce an assessment". This node fills that gap: it turns
the Researcher's packet (filings + news) into a short, hedged, plain-language
summary so a general/news/overview question gets a real answer.

It is deterministic (no LLM) and authors *no advice*; like the Analyst's output
it still flows through the Risk Critic, so any advice-shaped third-party
headline it quotes is caught by the same guardrail.
"""

from __future__ import annotations

from typing import Any

from app.models.analysis import AnalysisReport, TechnicalIndicators
from app.models.research import ResearchPacket


def summarize_general_research(ticker: str, packet: ResearchPacket) -> str:
    """A hedged, advice-free summary of the research gathered for a general query."""
    subject = ticker.upper() if ticker else "this query"
    news = packet.news
    filings = packet.filings

    if not news and not filings:
        base = f"We found no recent filings or news for {subject} to summarize."
    else:
        counts: list[str] = []
        if news:
            counts.append(f"{len(news)} recent news item" + ("" if len(news) == 1 else "s"))
        if filings:
            counts.append(f"{len(filings)} filing" + ("" if len(filings) == 1 else "s"))
        base = f"Here's the recent research coverage for {subject}: " + " and ".join(counts) + "."
        headlines = [
            n.headline.strip()
            for n in news[:3]
            if getattr(n, "headline", "") and n.headline.strip()
        ]
        if headlines:
            joined = "; ".join(f"“{h}”" for h in headlines)
            base += f" Headlines reportedly in focus: {joined}."

    if packet.degraded:
        base += " Note: one or more sources were unavailable, so this view may be partial."
    base += (
        " This is a research summary for informational purposes and not advice; "
        "open the sources below for detail."
    )
    return base


def general_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: produce a general-research narrative as an AnalysisReport.

    Emitting an ``analysis`` (rather than narrating inline) means the existing
    Risk Critic node reviews this text exactly like the Analyst's, so the
    compliance guardrail and the downstream response shape are unchanged.
    """
    research = state.get("research") or {}
    ticker = state.get("ticker", "")

    if research:
        packet = ResearchPacket.model_validate(research)
        narrative = summarize_general_research(packet.ticker or ticker, packet)
        confidence = "low"
    else:
        narrative = (
            f"We found no research data for {ticker or 'this query'} to summarize. "
            "This is a research summary, not advice."
        )
        confidence = "insufficient_data"

    report = AnalysisReport(
        ticker=ticker,
        technical_indicators=TechnicalIndicators(),
        narrative=narrative,
        confidence_level=confidence,
        notes=[],
    )
    return {"path": ["general"], "analysis": report.model_dump(mode="json")}
