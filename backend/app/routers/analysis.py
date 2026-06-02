"""SSE streaming analysis endpoint (P3-05).

Replaces the P1-04 stub. The endpoint runs the compiled LangGraph pipeline
(Router → Researcher → Analyst → Risk Critic) and streams progress events
via Server-Sent Events so the iOS client can render incremental UI:

    event: progress         data: {"stage": "researching"}
    event: partial_result   data: {"stage": "research", "research": {...}}
    event: progress         data: {"stage": "analyzing"}   # skipped on general
    event: partial_result   data: {"stage": "analysis",
                                   "analysis": {"technical": {...},
                                                "confidence": "..."}}
    event: progress         data: {"stage": "reviewing"}
    event: final_result     data: <AnalysisResponse JSON>
    event: error            data: {"message": "..."}      # on pipeline failure

The graph runs via ``astream`` so per-node completions drive the progress
emission, but the agents themselves remain unchanged — they don't need to
know they're being streamed.

The ``partial_result`` events deliberately exclude the analyst's narrative:
that text has not yet passed through the Risk Critic guardrail, and the
critic may substitute a safe default in the ``final_result``. Emitting the
raw narrative early would let an iOS client render compliance-violating
text. Deterministic outputs (research data, indicators, confidence) are
safe to ship incrementally.
"""

from __future__ import annotations

import json
import logging
import uuid
from collections.abc import AsyncIterator
from typing import Any

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from app.agents.analyst import _prior_context_sentence
from app.agents.graph import agent_graph
from app.auth import CurrentUser
from app.models.risk import STANDARD_DISCLAIMER
from app.models.schemas import (
    AnalysisData,
    AnalysisQuery,
    AnalysisResponse,
    DataFreshness,
    ResearchData,
    RiskReview,
)
from app.services.analysis_memory import AnalysisMemory, past_analysis_payload

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/analysis", tags=["analysis"])

# V12-06: conversation-continuity memory. Injected (set_pipeline_memory) so it's
# off by default — tests and any deployment without pgvector/embeddings simply
# skip recall/remember. main.py wires the real one at startup. All memory calls
# are best-effort: a memory hiccup must never break the analysis stream.
_PIPELINE_MEMORY: AnalysisMemory | None = None
# How many prior analyses to surface as follow-up context.
_RECALL_TOP_K = 3
# Cosine-similarity floor for surfacing a prior analysis (V12-06 "when
# relevant"): top-K alone would inject a stale, unrelated AAPL memory into a
# later NVDA question. Only sufficiently-similar recalls inform the response.
_MIN_RECALL_SIMILARITY = 0.6


def set_pipeline_memory(memory: AnalysisMemory | None) -> None:
    """Configure (or disable, with None) the conversation-continuity memory."""
    global _PIPELINE_MEMORY
    _PIPELINE_MEMORY = memory


def get_pipeline_memory() -> AnalysisMemory | None:
    return _PIPELINE_MEMORY


async def _recall_prior(query: str, user_id: uuid.UUID) -> list[dict[str, Any]]:
    """The user's relevant prior analyses as graph-state payloads (best-effort).

    Scoped to ``user_id`` by ConversationMemory.find_similar (V7-04). Any failure
    (no memory configured, embedder/DB unavailable) degrades to no context.
    """
    memory = get_pipeline_memory()
    if memory is None:
        return []
    try:
        recalled = await memory.recall(query=query, user_id=user_id, top_k=_RECALL_TOP_K)
        # "when relevant": drop weak matches so an unrelated past analysis never
        # gets framed as context for this question.
        return [
            past_analysis_payload(item)
            for item in recalled
            if item.similarity >= _MIN_RECALL_SIMILARITY
        ]
    except Exception:
        logger.exception("conversation memory recall failed; continuing without prior context")
        return []


async def _remember(
    body: AnalysisQuery,
    session_id: uuid.UUID,
    user_id: uuid.UUID,
    response: AnalysisResponse,
    final_state: dict[str, Any],
) -> None:
    """Persist this analysis so future follow-ups can recall it (best-effort)."""
    memory = get_pipeline_memory()
    if memory is None:
        return
    try:
        result_payload = {
            "ticker": response.ticker,
            "research_data": final_state.get("research") or {},
            "technical_indicators": (final_state.get("analysis") or {}).get(
                "technical_indicators"
            )
            or {},
            "narrative": response.analysis.narrative,
            "risk_flags": final_state.get("risk_review") or {},
            "confidence": response.analysis.confidence,
        }
        await memory.remember(
            session_id=session_id,
            user_id=user_id,
            query=body.query,
            ticker=response.ticker,
            analysis_type=body.analysis_type,
            portfolio_context=(
                body.portfolio_profile.model_dump()
                if body.portfolio_profile is not None
                else None
            ),
            result=result_payload,
        )
    except Exception:
        logger.exception("conversation memory store failed; analysis result not indexed")

# Internal route names emitted by the Router node, mapped to the next progress
# stage. Kept here (not imported from agents.graph) so the SSE contract is
# explicit at the API boundary — adding a new internal route does not silently
# change the wire-level event sequence.
_ROUTES_WITH_ANALYST = {"fundamental_analysis", "technical_analysis"}
_WIRE_FILING_LIMIT = 10
_WIRE_NEWS_LIMIT = 25


def _sse_event(event: str, data: dict[str, Any]) -> str:
    """Format one SSE frame. Trailing blank line is part of the protocol."""
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


def _wire_research_payload(research_dict: dict[str, Any]) -> dict[str, Any]:
    """Bound research lists before putting them on the SSE wire.

    The researcher may gather hundreds of news items. The analyst still sees
    the full packet in graph state, but iOS does not need every raw article in
    a single streaming frame. Keeping the public payload bounded avoids very
    large one-line SSE ``data:`` fields, which are fragile on mobile clients.
    """
    return {
        "filings": (research_dict.get("filings") or [])[:_WIRE_FILING_LIMIT],
        "news": (research_dict.get("news") or [])[:_WIRE_NEWS_LIMIT],
    }


def _partial_research_payload(final_state: dict[str, Any]) -> dict[str, Any]:
    """Project the researcher's output for an incremental SSE frame.

    Mirrors the shape of ``AnalysisResponse.research`` so the iOS client can
    merge the partial into the same field of its draft response when the
    final event eventually arrives.
    """
    research_dict = final_state.get("research") or {}
    return {
        "stage": "research",
        "research": _wire_research_payload(research_dict),
    }


def _partial_analysis_payload(final_state: dict[str, Any]) -> dict[str, Any]:
    """Project the analyst's deterministic outputs for an incremental SSE frame.

    The narrative is intentionally withheld until the Risk Critic has run —
    see the module docstring. Technical indicators and confidence are
    deterministic functions of the price data and are safe to ship before
    review.
    """
    analysis_dict = final_state.get("analysis") or {}
    return {
        "stage": "analysis",
        "analysis": {
            "technical": analysis_dict.get("technical_indicators") or {},
            "confidence": analysis_dict.get(
                "confidence_level", "insufficient_data"
            ),
        },
    }


def _data_freshness(research_dict: dict[str, Any]) -> DataFreshness:
    """Derive 'as of' timestamps for the price and news data (V7-03).

    Computed from the full research packet (before wire-trimming) so it sees
    every bar and source. ``price_as_of`` is the newest bar's trading day;
    fetch timestamps come from the source provenance, where the price source's
    ``retrieved_at`` is already cache-aware (set to the original fetch time by
    the researcher).
    """
    price_data = research_dict.get("price_data") or []
    sources = research_dict.get("sources") or []

    # Bar dates are ISO "YYYY-MM-DD" strings in the dump; lexical max == latest.
    bar_dates = [b.get("date") for b in price_data if b.get("date")]
    price_as_of = max(bar_dates) if bar_dates else None

    def _fetch_time(source_name: str) -> Any | None:
        for source in sources:
            if source.get("name") == source_name and source.get("ok"):
                return source.get("retrieved_at")
        return None

    return DataFreshness(
        price_as_of=price_as_of,
        price_fetched_at=_fetch_time("Alpha Vantage"),
        news_as_of=_fetch_time("Finnhub"),
    )


def _build_response(
    session_id: uuid.UUID,
    ticker: str,
    final_state: dict[str, Any],
) -> AnalysisResponse:
    """Project the accumulated graph state onto the public AnalysisResponse.

    The graph's internal state carries full Pydantic dumps of ResearchPacket
    and AnalysisReport; the wire model only exposes the trimmed-down fields
    defined in section 7.2 of the design doc. We reshape rather than expose
    the internal shape directly.
    """
    research_dict = final_state.get("research") or {}
    analysis_dict = final_state.get("analysis") or {}
    risk_dict = final_state.get("risk_review") or {}

    research = ResearchData(
        **_wire_research_payload(research_dict),
        freshness=_data_freshness(research_dict),
    )

    indicators = analysis_dict.get("technical_indicators") or {}

    risk_review = (
        RiskReview.model_validate(risk_dict)
        if risk_dict
        else RiskReview(disclaimer=STANDARD_DISCLAIMER)
    )

    # The Risk Critic is the authority on what narrative is safe to display:
    # on rejection it substitutes a safe default, on approval it mirrors the
    # analyst's text. Prefer it whenever a review was produced so the wire
    # response cannot leak a rejected narrative. The general_research route
    # bypasses the analyst and leaves modified_response empty — fall through
    # to the (also-empty) analyst value in that case.
    analyst_narrative = analysis_dict.get("narrative", "")
    if not risk_review.approved or risk_review.modified_response:
        narrative_text = risk_review.modified_response
    else:
        narrative_text = analyst_narrative

    analysis = AnalysisData(
        technical=indicators,
        narrative=narrative_text,
        confidence=analysis_dict.get("confidence_level", "insufficient_data"),
    )

    return AnalysisResponse(
        session_id=session_id,
        ticker=ticker,
        research=research,
        analysis=analysis,
        risk_review=risk_review,
        disclaimer=risk_review.disclaimer or STANDARD_DISCLAIMER,
    )


async def _run_pipeline(
    body: AnalysisQuery,
    session_id: uuid.UUID,
    user_id: uuid.UUID,
) -> AsyncIterator[str]:
    """Drive the LangGraph pipeline and yield SSE frames as it progresses.

    ``astream`` yields ``{node_name: state_diff}`` after each node finishes.
    We accumulate diffs into ``final_state`` and use the node name to choose
    the next progress event. The first ``researching`` frame is emitted before
    invoking the graph so the iOS client sees activity immediately rather than
    only after the first network round-trip into the data tools.

    ``user_id`` (resolved by :func:`get_current_user`) is carried in the graph
    state so per-user persistence (V8/V12-06) can attribute work to its owner.
    """
    ticker = body.ticker.upper()
    # V12-06: recall the user's relevant prior analyses *before* the graph runs
    # so the Analyst can fold them into the narrative. Scoped to this user;
    # best-effort, so an empty/unavailable memory just means no prior context.
    prior_analyses = await _recall_prior(body.query, user_id)
    initial_state: dict[str, Any] = {
        "query": body.query,
        "ticker": ticker,
        "analysis_type": body.analysis_type,
        "portfolio_profile": (
            body.portfolio_profile.model_dump()
            if body.portfolio_profile is not None
            else None
        ),
        "prior_analyses": prior_analyses,
        "session_id": str(session_id),
        "user_id": str(user_id),
    }

    try:
        yield _sse_event("progress", {"stage": "researching"})

        final_state: dict[str, Any] = {}
        async for update in agent_graph.astream(initial_state):
            # ``update`` is keyed by the node that just completed.
            for node_name, diff in update.items():
                if not isinstance(diff, dict):
                    continue
                # Merge the diff into our local copy. ``path`` is the only
                # field with a reducer (add); we skip it because we don't
                # rely on it for the response.
                for key, value in diff.items():
                    if key == "path":
                        continue
                    final_state[key] = value

                if node_name == "researcher":
                    yield _sse_event(
                        "partial_result", _partial_research_payload(final_state)
                    )
                    route = final_state.get("route", "")
                    next_stage = (
                        "analyzing"
                        if route in _ROUTES_WITH_ANALYST
                        else "reviewing"
                    )
                    yield _sse_event("progress", {"stage": next_stage})
                elif node_name == "analyst":
                    yield _sse_event(
                        "partial_result", _partial_analysis_payload(final_state)
                    )
                    yield _sse_event("progress", {"stage": "reviewing"})

        response = _build_response(session_id, ticker, final_state)
        # V12-06: index this analysis so future follow-ups can recall it. Stored
        # before the prior-context line is appended, so memory keeps the base
        # narrative rather than re-embedding recalled context.
        await _remember(body, session_id, user_id, response, final_state)
        # The Analyst renders prior context itself; the general route skips the
        # Analyst, so surface the recalled context here instead — otherwise a
        # general follow-up would recall memory but never show it.
        if final_state.get("route") not in _ROUTES_WITH_ANALYST and prior_analyses:
            sentence = _prior_context_sentence(prior_analyses)
            if sentence:
                base = response.analysis.narrative
                response.analysis.narrative = f"{base} {sentence}".strip() if base else sentence
        yield _sse_event("final_result", response.model_dump(mode="json"))
    except Exception as exc:
        logger.exception("analysis pipeline failed")
        yield _sse_event("error", {"message": f"{type(exc).__name__}: {exc}"})


@router.post("/query")
async def query_analysis(
    body: AnalysisQuery,
    current_user: CurrentUser,
) -> StreamingResponse:
    """Stream the multi-agent pipeline's progress and final result as SSE.

    A ``StreamingResponse`` is returned (rather than ``AnalysisResponse``) so
    intermediate progress events can be emitted as the graph runs. The final
    ``final_result`` event carries an AnalysisResponse-shaped payload, matching
    the schema documented in section 7.2 of the design doc.

    Accepts an ``Authorization: Bearer`` header resolved to ``current_user`` by
    :func:`get_current_user` (the default user until V8).
    """
    session_id = body.session_id or uuid.uuid4()
    return StreamingResponse(
        _run_pipeline(body, session_id, current_user),
        media_type="text/event-stream",
        headers={
            # Disable proxy buffering so events are flushed promptly even
            # behind reverse proxies (nginx in particular).
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
