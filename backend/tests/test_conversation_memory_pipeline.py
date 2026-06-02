"""Tests for V12-06: Conversation continuity via existing memory.

Acceptance criteria:
  * A follow-up retrieves the user's relevant prior analyses.
  * Retrieval is scoped to the requesting user only.
  * Prior context visibly informs the new response when relevant.

The analyst unit tests run offline (deterministic fallback). The pipeline-wiring
test injects a fake memory so it exercises recall/inject/remember end-to-end
without needing pgvector or the embedding model.
"""

from __future__ import annotations

import json
import math
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.agents import analyst as analyst_module
from app.agents.analyst import _prior_context_sentence, analyze
from app.main import app
from app.models.database import DEFAULT_USER_ID
from app.models.research import ResearchPacket
from app.routers import analysis as analysis_router
from app.services.memory import PastAnalysis

BASE = "http://test"
ENDPOINT = "/api/v1/analysis/query"


# ---------------------------------------------------------------------------
# Analyst unit: prior context visibly informs the narrative (AC3)
# ---------------------------------------------------------------------------


def _prior(summary: str, similarity: float = 0.83) -> dict[str, Any]:
    return {
        "session_id": str(uuid.uuid4()),
        "narrative": summary,
        "confidence": "high",
        "content_summary": summary,
        "similarity": similarity,
        "created_at": datetime.now(UTC).isoformat(),
    }


def test_prior_context_sentence_renders_recalled_analyses():
    sentence = _prior_context_sentence([_prior("AAPL looked stretched last week")])
    assert sentence is not None
    assert "Prior context" in sentence
    assert "AAPL looked stretched last week" in sentence
    assert "% similar" in sentence


def test_prior_context_sentence_empty_is_none():
    assert _prior_context_sentence(None) is None
    assert _prior_context_sentence([]) is None
    assert _prior_context_sentence([{"content_summary": "   "}]) is None


def _packet(n: int = 60) -> ResearchPacket:
    start = date(2024, 1, 1)
    bars = []
    for i in range(n):
        close = 100.0 + 5.0 * math.sin(i / 3.0)
        bars.append(
            {
                "ticker": "AAPL",
                "date": (start + timedelta(days=i)).isoformat(),
                "open": close,
                "high": close + 1.0,
                "low": close - 1.0,
                "close": close,
                "volume": 1_000_000 + i,
            }
        )
    return ResearchPacket.model_validate(
        {
            "query": "AAPL",
            "ticker": "AAPL",
            "price_data": bars,
            "filings": [],
            "news": [],
            "sources": [],
        }
    )


def test_analyze_folds_prior_context_into_narrative(monkeypatch):
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    report = analyze(
        _packet(),
        prior_analyses=[_prior("AAPL looked stretched last week")],
    )
    assert "Prior context" in report.narrative
    assert "AAPL looked stretched last week" in report.narrative


def test_analyze_without_prior_has_no_prior_context(monkeypatch):
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    report = analyze(_packet(), prior_analyses=None)
    assert "Prior context" not in report.narrative


# ---------------------------------------------------------------------------
# Pipeline wiring: recall (user-scoped) → inform → remember
# ---------------------------------------------------------------------------


class FakeMemory:
    """Duck-typed AnalysisMemory recording recall/remember without a DB."""

    def __init__(self, prior: list[PastAnalysis]) -> None:
        self.prior = prior
        self.recall_calls: list[tuple[str, uuid.UUID]] = []
        self.remember_calls: list[dict[str, Any]] = []

    async def recall(self, *, query: str, user_id: uuid.UUID, top_k: int = 3):
        self.recall_calls.append((query, user_id))
        return self.prior

    async def remember(self, *, session_id, user_id, ticker, **kwargs):
        self.remember_calls.append(
            {"session_id": session_id, "user_id": user_id, "ticker": ticker}
        )


@pytest.fixture(autouse=True)
def _stub_researcher_and_llm(monkeypatch):
    from app.models.market import PriceBar

    async def _empty(*args, **kwargs):
        return []

    async def _prices(*args, **kwargs):
        return list(_packet().price_data)

    monkeypatch.setattr("app.agents.researcher.get_company_filings", _empty)
    monkeypatch.setattr("app.agents.researcher.get_daily_prices", _prices)
    monkeypatch.setattr("app.agents.researcher.get_company_news", _empty)
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")
    _ = PriceBar  # imported for parity with the streaming test's shape


@pytest.fixture
def fake_memory():
    prior = [
        PastAnalysis(
            session_id=uuid.uuid4(),
            result_id=uuid.uuid4(),
            narrative="AAPL looked stretched last week",
            confidence="high",
            content_summary="AAPL looked stretched last week",
            similarity=0.81,
            created_at=datetime.now(UTC),
        )
    ]
    mem = FakeMemory(prior)
    analysis_router.set_pipeline_memory(mem)
    yield mem
    analysis_router.set_pipeline_memory(None)


def _parse_sse(text: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        event_name = data_payload = None
        for line in block.splitlines():
            if line.startswith("event:"):
                event_name = line[len("event:"):].strip()
            elif line.startswith("data:"):
                data_payload = line[len("data:"):].strip()
        if event_name and data_payload:
            events.append({"event": event_name, "data": json.loads(data_payload)})
    return events


async def _final_event(payload: dict[str, Any]) -> dict[str, Any]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as client:
        async with client.stream("POST", ENDPOINT, json=payload) as resp:
            body = ""
            async for chunk in resp.aiter_text():
                body += chunk
    events = _parse_sse(body)
    return next(e for e in events if e["event"] == "final_result")


@pytest.mark.asyncio
async def test_followup_recalls_scoped_to_user_and_informs_response(fake_memory):
    final = await _final_event(
        {"query": "How does AAPL look now?", "ticker": "AAPL", "analysis_type": "technical"}
    )

    # AC1: a follow-up retrieved the user's prior analyses.
    assert len(fake_memory.recall_calls) == 1
    recalled_query, recalled_user = fake_memory.recall_calls[0]
    assert recalled_query == "How does AAPL look now?"
    # AC2: retrieval scoped to the requesting user (default user until V8).
    assert recalled_user == DEFAULT_USER_ID

    # AC3: prior context visibly informs the new response.
    narrative = final["data"]["analysis"]["narrative"]
    assert "Prior context" in narrative
    assert "AAPL looked stretched last week" in narrative


@pytest.mark.asyncio
async def test_general_route_followup_still_shows_prior_context(fake_memory):
    # The general route skips the Analyst, but a general follow-up must still
    # surface recalled prior context in the final narrative.
    final = await _final_event(
        {"query": "What's going on with the market?", "ticker": "AAPL", "analysis_type": "general"}
    )
    narrative = final["data"]["analysis"]["narrative"]
    assert "Prior context" in narrative
    assert "AAPL looked stretched last week" in narrative


@pytest.mark.asyncio
async def test_irrelevant_prior_below_threshold_is_not_injected():
    # Two recalls: one related (high similarity), one stale/unrelated (low).
    # Only the related one should reach the narrative ("when relevant").
    prior = [
        PastAnalysis(
            session_id=uuid.uuid4(), result_id=uuid.uuid4(),
            narrative="NVDA momentum was strong", confidence="high",
            content_summary="NVDA momentum was strong", similarity=0.78,
            created_at=datetime.now(UTC),
        ),
        PastAnalysis(
            session_id=uuid.uuid4(), result_id=uuid.uuid4(),
            narrative="an unrelated old AAPL note", confidence="low",
            content_summary="an unrelated old AAPL note", similarity=0.20,
            created_at=datetime.now(UTC),
        ),
    ]
    mem = FakeMemory(prior)
    analysis_router.set_pipeline_memory(mem)
    try:
        final = await _final_event(
            {"query": "How is NVDA?", "ticker": "NVDA", "analysis_type": "technical"}
        )
    finally:
        analysis_router.set_pipeline_memory(None)
    narrative = final["data"]["analysis"]["narrative"]
    assert "NVDA momentum was strong" in narrative  # relevant: surfaced
    assert "unrelated old AAPL note" not in narrative  # below threshold: dropped


@pytest.mark.asyncio
async def test_analysis_is_remembered_for_future_recall(fake_memory):
    final = await _final_event(
        {"query": "AAPL momentum?", "ticker": "AAPL", "analysis_type": "technical"}
    )
    session_id = uuid.UUID(final["data"]["session_id"])

    assert len(fake_memory.remember_calls) == 1
    call = fake_memory.remember_calls[0]
    assert call["session_id"] == session_id
    assert call["user_id"] == DEFAULT_USER_ID  # attributed to the requesting user
    assert call["ticker"] == "AAPL"
