from __future__ import annotations

import uuid

from fastapi import APIRouter

from app.models.schemas import (
    AnalysisData,
    AnalysisQuery,
    AnalysisResponse,
    ResearchData,
    RiskFlag,
    RiskReview,
)

router = APIRouter(prefix="/analysis", tags=["analysis"])


@router.post("/query", response_model=AnalysisResponse)
async def query_analysis(body: AnalysisQuery) -> AnalysisResponse:
    """Stub endpoint — returns a mock AnalysisResponse.

    The real implementation (P3-05) streams SSE events from the LangGraph
    agent pipeline.  This stub satisfies P1-04 acceptance criteria so that
    iOS integration can begin before the AI layer is wired up.
    """
    session_id = body.session_id or uuid.uuid4()

    return AnalysisResponse(
        session_id=session_id,
        ticker=body.ticker.upper(),
        research=ResearchData(filings=[], news=[]),
        analysis=AnalysisData(
            technical={},
            narrative=(
                f"[STUB] Analysis for {body.ticker.upper()} "
                f"({body.analysis_type}) is not yet implemented."
            ),
            confidence="insufficient_data",
        ),
        risk_review=RiskReview(
            approved=True,
            flags=[RiskFlag(code="missing_disclaimer", detail="stub_response")],
            modified_response=(
                f"[STUB] Analysis for {body.ticker.upper()} "
                f"({body.analysis_type}) is not yet implemented."
            ),
        ),
    )
