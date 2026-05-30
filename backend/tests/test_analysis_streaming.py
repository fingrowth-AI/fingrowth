"""Tests for P3-05: SSE streaming analysis endpoint.

Acceptance criteria (from section 5.3 of the design doc):
  * curl receives streamed events over 2-10 seconds
  * Progress events: researching, analyzing, reviewing
  * Final event matches AnalysisResponse schema
  * portfolio_profile influences analysis narrative when present
"""

from __future__ import annotations

import json
import math
from datetime import date, timedelta
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.agents import analyst as analyst_module
from app.main import app
from app.models.risk import STANDARD_DISCLAIMER

BASE = "http://test"
ENDPOINT = "/api/v1/analysis/query"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


def _price_payload(n: int) -> list[dict[str, Any]]:
    """Build n PriceBar-shaped dicts that calculate_rsi/macd can consume.

    The researcher tools return list[PriceBar]; we build the same shape so
    the analyst can compute every indicator (RSI/MACD/SMA/Bollinger).
    """
    start = date(2024, 1, 1)
    bars: list[dict[str, Any]] = []
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
    return bars


@pytest.fixture(autouse=True)
def _stub_researcher_and_llm(monkeypatch):
    """Run end-to-end against the real graph, but stubbed at the I/O edges.

    - Researcher's three data tools return deterministic content so the test
      runs offline and the analyst has enough bars to compute every indicator.
    - The analyst's LLM is disabled so its fallback narrator drives the text
      — that path is deterministic, so narrative-content assertions are stable.
    """
    from app.models.market import PriceBar

    async def _empty_filings(*args, **kwargs):
        return []

    async def _empty_news(*args, **kwargs):
        return []

    async def _prices(*args, **kwargs):
        return [PriceBar.model_validate(b) for b in _price_payload(60)]

    monkeypatch.setattr("app.agents.researcher.get_company_filings", _empty_filings)
    monkeypatch.setattr("app.agents.researcher.get_daily_prices", _prices)
    monkeypatch.setattr("app.agents.researcher.get_company_news", _empty_news)
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")


# ---------------------------------------------------------------------------
# SSE parsing helper
# ---------------------------------------------------------------------------


def _parse_sse(text: str) -> list[dict[str, Any]]:
    """Parse an SSE stream into [{event, data}] pairs.

    The endpoint emits one JSON object per ``data:`` line and a blank line
    between frames, which is the simplest dialect of the SSE protocol.
    """
    events: list[dict[str, Any]] = []
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        event_name: str | None = None
        data_payload: str | None = None
        for line in block.splitlines():
            if line.startswith("event:"):
                event_name = line[len("event:") :].strip()
            elif line.startswith("data:"):
                data_payload = line[len("data:") :].strip()
        if event_name is None or data_payload is None:
            continue
        events.append({"event": event_name, "data": json.loads(data_payload)})
    return events


async def _collect_events(
    client: AsyncClient, payload: dict[str, Any]
) -> tuple[int, str, list[dict[str, Any]]]:
    """POST to the SSE endpoint and return (status, content_type, events)."""
    async with client.stream("POST", ENDPOINT, json=payload) as resp:
        body = ""
        async for chunk in resp.aiter_text():
            body += chunk
        return resp.status_code, resp.headers.get("content-type", ""), _parse_sse(body)


# ---------------------------------------------------------------------------
# Transport: content-type, framing
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_content_type_is_text_event_stream(client: AsyncClient):
    """Response advertises the SSE media type so clients dispatch correctly."""
    async with client.stream(
        "POST",
        ENDPOINT,
        json={"query": "q", "ticker": "AAPL", "analysis_type": "general"},
    ) as resp:
        assert resp.status_code == 200
        assert "text/event-stream" in resp.headers.get("content-type", "")
        # Drain so the ASGI generator finishes cleanly.
        async for _ in resp.aiter_text():
            pass


# ---------------------------------------------------------------------------
# Acceptance: Progress events in the right order for each route
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("analysis_type", ["fundamental", "technical"])
async def test_progress_sequence_when_analyst_runs(
    client: AsyncClient, analysis_type: str
):
    """Routes that exercise the analyst emit researching → analyzing → reviewing."""
    _status, _ct, events = await _collect_events(
        client,
        {"query": "q", "ticker": "AAPL", "analysis_type": analysis_type},
    )
    progress = [e["data"]["stage"] for e in events if e["event"] == "progress"]
    assert progress == ["researching", "analyzing", "reviewing"]


@pytest.mark.asyncio
async def test_progress_sequence_for_general_route_skips_analyzing(
    client: AsyncClient,
):
    """The general route bypasses the analyst, so 'analyzing' must not appear."""
    _status, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "general"}
    )
    progress = [e["data"]["stage"] for e in events if e["event"] == "progress"]
    assert progress == ["researching", "reviewing"]
    assert "analyzing" not in progress


# ---------------------------------------------------------------------------
# Acceptance: Final event matches AnalysisResponse schema
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_final_result_event_emitted_once_and_matches_schema(
    client: AsyncClient,
):
    """Exactly one final_result frame, validating against AnalysisResponse."""
    from app.models.schemas import AnalysisResponse

    _status, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    finals = [e for e in events if e["event"] == "final_result"]
    assert len(finals) == 1
    # Pydantic validates the wire payload against the documented schema.
    AnalysisResponse.model_validate(finals[0]["data"])


@pytest.mark.asyncio
async def test_final_result_contains_all_required_fields(client: AsyncClient):
    """Section 7.2 mandates session_id, ticker, research, analysis, risk_review,
    disclaimer."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    data = final["data"]
    for key in (
        "session_id",
        "ticker",
        "research",
        "analysis",
        "risk_review",
        "disclaimer",
    ):
        assert key in data, f"final_result missing {key!r}"
    assert data["ticker"] == "AAPL"
    assert data["disclaimer"] == STANDARD_DISCLAIMER


@pytest.mark.asyncio
async def test_final_result_carries_data_freshness(client: AsyncClient):
    """V7-03: the result exposes 'as of' timestamps for price and news data,
    with price_as_of equal to the newest price bar's trading day."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    freshness = final["data"]["research"]["freshness"]

    expected_as_of = max(b["date"] for b in _price_payload(60))
    assert freshness["price_as_of"] == expected_as_of
    # Fetch timestamps are populated (ISO strings); news source is healthy here.
    assert freshness["price_fetched_at"] is not None
    assert freshness["news_as_of"] is not None


def test_wire_research_payload_is_bounded_for_mobile_sse():
    """Large research packets should not become huge one-line SSE frames."""
    from app.routers.analysis import _wire_research_payload

    research = {
        "filings": [{"form": "10-Q", "i": i} for i in range(20)],
        "news": [{"headline": f"item {i}"} for i in range(100)],
    }

    payload = _wire_research_payload(research)

    assert len(payload["filings"]) == 10
    assert len(payload["news"]) == 25


@pytest.mark.asyncio
async def test_final_result_event_is_last_event(client: AsyncClient):
    """No frames may follow the terminal final_result event."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    assert events[-1]["event"] == "final_result"


@pytest.mark.asyncio
async def test_session_id_round_trips_when_provided(client: AsyncClient):
    """A caller-supplied session_id must come back unchanged in final_result."""
    import uuid

    sid = str(uuid.uuid4())
    _s, _ct, events = await _collect_events(
        client,
        {
            "query": "q",
            "ticker": "AAPL",
            "analysis_type": "general",
            "session_id": sid,
        },
    )
    final = next(e for e in events if e["event"] == "final_result")
    assert final["data"]["session_id"] == sid


@pytest.mark.asyncio
async def test_session_id_is_generated_when_omitted(client: AsyncClient):
    """Omitted session_id → server generates a valid UUID."""
    import uuid

    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "general"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    # Round-trip parse confirms it's a syntactically valid UUID.
    uuid.UUID(final["data"]["session_id"])


# ---------------------------------------------------------------------------
# Acceptance: portfolio_profile influences the narrative
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_portfolio_profile_influences_narrative(client: AsyncClient):
    """With LLM disabled, the deterministic fallback appends the profile sentence
    so the influence is observable end-to-end without depending on a live model."""
    _s, _ct, events = await _collect_events(
        client,
        {
            "query": "q",
            "ticker": "AAPL",
            "analysis_type": "technical",
            "portfolio_profile": {
                "sector_weights": {"technology": 0.8},
                "largest_position": "concentrated",
                "diversification": "low",
                "risk_orientation": "growth",
            },
        },
    )
    final = next(e for e in events if e["event"] == "final_result")
    narrative = final["data"]["analysis"]["narrative"]
    # The deterministic fallback emits a "Portfolio context:" clause when a
    # profile is provided; its presence proves the field reached the analyst.
    assert "Portfolio context" in narrative
    assert "growth" in narrative


@pytest.mark.asyncio
async def test_omitted_portfolio_profile_produces_no_context_clause(
    client: AsyncClient,
):
    """Mirror test: without a profile, the context sentence must not appear."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    narrative = final["data"]["analysis"]["narrative"]
    assert "Portfolio context" not in narrative


# ---------------------------------------------------------------------------
# Error path: pipeline failure surfaces as an SSE 'error' event
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_pipeline_exception_is_emitted_as_error_event(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
):
    """A crash inside the graph must not 500 — it surfaces as event: error."""

    async def _boom(*args, **kwargs):
        raise RuntimeError("simulated graph failure")
        yield  # pragma: no cover — make this an async generator

    monkeypatch.setattr("app.routers.analysis.agent_graph.astream", _boom)

    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "general"}
    )
    error_events = [e for e in events if e["event"] == "error"]
    assert len(error_events) == 1
    assert "simulated graph failure" in error_events[0]["data"]["message"]
    # And no final_result should be emitted on a failed run.
    assert not any(e["event"] == "final_result" for e in events)


# ---------------------------------------------------------------------------
# Validation: malformed requests fail before the stream opens
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_required_fields_returns_422(client: AsyncClient):
    """Pydantic body validation runs before SSE starts; bad input → 422."""
    resp = await client.post(ENDPOINT, json={})
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_invalid_analysis_type_returns_422(client: AsyncClient):
    """analysis_type is constrained to fundamental | technical | general."""
    resp = await client.post(
        ENDPOINT,
        json={"query": "q", "ticker": "AAPL", "analysis_type": "buy_signal"},
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Acceptance: partial_result events are emitted (P3-05 outputs section)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("analysis_type", ["fundamental", "technical"])
async def test_partial_result_emitted_for_research_and_analysis_stages(
    client: AsyncClient, analysis_type: str
):
    """Analyst routes emit one partial_result for research and one for analysis."""
    _s, _ct, events = await _collect_events(
        client,
        {"query": "q", "ticker": "AAPL", "analysis_type": analysis_type},
    )
    partials = [e for e in events if e["event"] == "partial_result"]
    stages = [p["data"]["stage"] for p in partials]
    assert stages == ["research", "analysis"]


@pytest.mark.asyncio
async def test_partial_result_for_general_route_only_research(
    client: AsyncClient,
):
    """The general route bypasses the analyst, so only the research partial fires."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "general"}
    )
    partials = [e for e in events if e["event"] == "partial_result"]
    stages = [p["data"]["stage"] for p in partials]
    assert stages == ["research"]


@pytest.mark.asyncio
async def test_analysis_partial_result_excludes_unreviewed_narrative(
    client: AsyncClient,
):
    """Narrative ships only in final_result — never in the analysis partial.

    The Risk Critic is the guardrail; leaking the raw analyst text in a
    partial would defeat its purpose.
    """
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    analysis_partial = next(
        e for e in events
        if e["event"] == "partial_result" and e["data"]["stage"] == "analysis"
    )
    assert "narrative" not in analysis_partial["data"]["analysis"]
    # Deterministic indicators are safe to ship early.
    assert "technical" in analysis_partial["data"]["analysis"]
    assert "confidence" in analysis_partial["data"]["analysis"]


@pytest.mark.asyncio
async def test_partial_result_arrives_before_final_result(client: AsyncClient):
    """Partials must precede final_result so the iOS client can render early."""
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    types = [e["event"] for e in events]
    last_partial = max(i for i, t in enumerate(types) if t == "partial_result")
    final_idx = types.index("final_result")
    assert last_partial < final_idx


# ---------------------------------------------------------------------------
# Acceptance: rejected narrative is replaced by risk_review.modified_response
# in the final_result (Risk Critic is authoritative for displayed narrative).
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_rejected_narrative_replaced_by_safe_default_in_final_result(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
):
    """A narrative the Risk Critic rejects must NOT leak via final_result.

    The wire-level analysis.narrative is sourced from the critic's
    modified_response, so rejected text is substituted with the safe
    default rather than passed through unchanged.
    """

    def _violating_narrate(ticker, indicators, packet, portfolio_profile=None):
        # Triggers buy_sell_recommendation + future_price_claim flags, which
        # are both rejection codes.
        return (
            "Recommendation: buy now. Our 12-month price target is $250 "
            "and the stock will reach $300 by year end."
        )

    monkeypatch.setattr(
        "app.agents.analyst.narrate", _violating_narrate
    )

    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    narrative = final["data"]["analysis"]["narrative"]
    review = final["data"]["risk_review"]

    assert review["approved"] is False
    # The displayed narrative is the safe default, not the violating text.
    assert "cannot share this analysis" in narrative.lower()
    assert "buy now" not in narrative
    assert "$250" not in narrative
    # And it matches the critic's modified_response verbatim — single source
    # of truth for what is safe to show.
    assert narrative == review["modified_response"]


@pytest.mark.asyncio
async def test_approved_narrative_passes_through_to_final_result(
    client: AsyncClient,
):
    """When the critic approves, the analyst's narrative survives unchanged.

    Sanity check that the modified_response substitution doesn't accidentally
    erase legitimate narratives.
    """
    _s, _ct, events = await _collect_events(
        client, {"query": "q", "ticker": "AAPL", "analysis_type": "technical"}
    )
    final = next(e for e in events if e["event"] == "final_result")
    narrative = final["data"]["analysis"]["narrative"]
    review = final["data"]["risk_review"]

    assert review["approved"] is True
    # The deterministic fallback narrative survives.
    assert "RSI" in narrative
    assert narrative == review["modified_response"]
