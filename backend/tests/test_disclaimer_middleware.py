"""Tests for P6-03: Disclaimer + Compliance Middleware.

Acceptance criteria:
  * Every AnalysisResponse has a non-empty disclaimer
  * Disclaimer matches the approved template
  * Removing the middleware causes a test failure

The last criterion is demonstrated directly: the same scenario (an endpoint that
emits an empty disclaimer) is run against the real app (middleware present →
disclaimer enforced) and a bare app (no middleware → empty disclaimer leaks). If
the middleware were removed from the real app, ``test_middleware_injects_*``
would fail exactly like the bare-app contrast test.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.main import app as real_app
from app.models.risk import STANDARD_DISCLAIMER
from app.routers import analysis as analysis_module

BASE = "http://test"
ENDPOINT = "/api/v1/analysis/query"
QUERY = {"query": "q", "ticker": "AAPL", "analysis_type": "general"}


@pytest.fixture(autouse=True)
def _stub_graph(monkeypatch):
    """No-op the agent graph so these tests are offline and fast — the
    middleware only cares about the final_result frame, not research content."""

    async def _empty_astream(_initial_state):
        return
        yield  # pragma: no cover — makes this an async generator

    monkeypatch.setattr(analysis_module.agent_graph, "astream", _empty_astream)


def _parse_sse(body: str) -> list[dict[str, Any]]:
    events = []
    for block in body.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        name = data = None
        for line in block.splitlines():
            if line.startswith("event:"):
                name = line[len("event:") :].strip()
            elif line.startswith("data:"):
                data = line[len("data:") :].strip()
        if name and data is not None:
            events.append({"event": name, "data": json.loads(data)})
    return events


async def _final_result(client: AsyncClient) -> dict[str, Any]:
    body = ""
    async with client.stream("POST", ENDPOINT, json=QUERY) as resp:
        async for chunk in resp.aiter_text():
            body += chunk
    events = _parse_sse(body)
    return next(e["data"] for e in events if e["event"] == "final_result")


def _force_empty_disclaimer(monkeypatch):
    """Make the endpoint emit a final_result with an empty disclaimer, so only
    the middleware can restore compliance."""

    def _build_empty(session_id, ticker, final_state):
        from app.models.schemas import AnalysisResponse

        return AnalysisResponse(session_id=session_id, ticker=ticker, disclaimer="")

    monkeypatch.setattr(analysis_module, "_build_response", _build_empty)


# ---------------------------------------------------------------------------
# Acceptance: every AnalysisResponse has a non-empty, approved disclaimer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_final_result_has_nonempty_approved_disclaimer():
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        final = await _final_result(client)
    assert final["disclaimer"], "disclaimer must be non-empty"
    assert final["disclaimer"] == STANDARD_DISCLAIMER


# ---------------------------------------------------------------------------
# Acceptance: middleware injects the disclaimer when the endpoint omits it
# (this is the test that fails if the middleware is removed)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_middleware_injects_disclaimer_when_endpoint_emits_empty(monkeypatch):
    _force_empty_disclaimer(monkeypatch)
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        final = await _final_result(client)
    # Endpoint emitted "", but the middleware restored the approved template.
    assert final["disclaimer"] == STANDARD_DISCLAIMER


@pytest.mark.asyncio
async def test_without_middleware_empty_disclaimer_leaks(monkeypatch):
    """Contrast test proving the middleware is load-bearing: the same scenario
    against an app WITHOUT DisclaimerMiddleware lets the empty disclaimer through."""
    _force_empty_disclaimer(monkeypatch)
    bare = FastAPI()
    bare.include_router(analysis_module.router, prefix="/api/v1")
    async with AsyncClient(transport=ASGITransport(app=bare), base_url=BASE) as client:
        final = await _final_result(client)
    # No middleware → the empty disclaimer is NOT repaired.
    assert final["disclaimer"] == ""


# ---------------------------------------------------------------------------
# Middleware must not disturb the rest of the stream or non-SSE responses
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_middleware_preserves_other_frames_and_ordering():
    """Progress frames pass through and final_result stays terminal."""
    body = ""
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        async with client.stream("POST", ENDPOINT, json=QUERY) as resp:
            assert "text/event-stream" in resp.headers.get("content-type", "")
            async for chunk in resp.aiter_text():
                body += chunk
    events = _parse_sse(body)
    names = [e["event"] for e in events]
    assert "progress" in names
    assert names[-1] == "final_result"
    # The progress frame is untouched by the rewriter.
    assert events[0] == {"event": "progress", "data": {"stage": "researching"}}


@pytest.mark.asyncio
async def test_middleware_passthrough_for_non_sse_endpoint():
    """A non-event-stream response (health) is forwarded untouched."""
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        resp = await client.get("/health")
    assert resp.status_code == 200
    # JSON body intact and parseable — middleware didn't mangle it.
    assert "status" in resp.json()


@pytest.mark.asyncio
async def test_middleware_enforces_template_over_nonmatching_disclaimer(monkeypatch):
    """A non-empty but non-approved disclaimer is replaced with the template."""

    def _build_wrong(session_id, ticker, final_state):
        from app.models.schemas import AnalysisResponse

        return AnalysisResponse(
            session_id=session_id, ticker=ticker, disclaimer="do whatever you want"
        )

    monkeypatch.setattr(analysis_module, "_build_response", _build_wrong)
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        final = await _final_result(client)
    assert final["disclaimer"] == STANDARD_DISCLAIMER


@pytest.mark.asyncio
async def test_session_id_still_round_trips_through_middleware():
    """Rewriting the frame must not corrupt other fields."""
    sid = str(uuid.uuid4())
    body = ""
    payload = {**QUERY, "session_id": sid}
    async with AsyncClient(transport=ASGITransport(app=real_app), base_url=BASE) as client:
        async with client.stream("POST", ENDPOINT, json=payload) as resp:
            async for chunk in resp.aiter_text():
                body += chunk
    final = next(e["data"] for e in _parse_sse(body) if e["event"] == "final_result")
    assert final["session_id"] == sid
    assert final["disclaimer"] == STANDARD_DISCLAIMER
