"""Live end-to-end integration test for P3-05: SSE analysis pipeline.

Hits POST /api/v1/analysis/query against the **real** Phase-2 data tools
(SEC EDGAR + Alpha Vantage + Finnhub) and, if an OpenAI key is configured,
the real LLM narrator inside the Analyst.

Quota note
----------
Alpha Vantage's free tier is 25 calls/day. Each test here costs *one* live
price fetch; we keep the test count low and reuse the same ticker so the
researcher's in-memory price cache absorbs subsequent runs within the same
process.

Skipped automatically when any of the three required research APIs is not
configured — the suite stays green on machines without keys.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app
from app.models.risk import STANDARD_DISCLAIMER
from app.models.schemas import AnalysisResponse
from tests.integration.conftest import (
    needs_alpha_vantage,
    needs_finnhub,
    needs_realistic_sec_user_agent,
)

# Every test in this file talks to all three research APIs through the graph.
# Compose the three skip-guards so the file is skipped wholesale when any one
# of the keys is missing — partial runs would muddy the diagnostic signal.
pytestmark = [
    pytest.mark.integration,
    needs_finnhub(),
    needs_alpha_vantage(),
    needs_realistic_sec_user_agent(),
]

BASE = "http://test"
ENDPOINT = "/api/v1/analysis/query"
# A high-coverage, liquid ticker. Re-used across tests so the researcher's
# price cache amortises the Alpha Vantage quota cost across the file.
LIVE_TICKER = "AAPL"


def _parse_sse(text: str) -> list[dict[str, Any]]:
    """Same minimal SSE parser as the offline streaming tests."""
    events: list[dict[str, Any]] = []
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        name: str | None = None
        payload: str | None = None
        for line in block.splitlines():
            if line.startswith("event:"):
                name = line[len("event:") :].strip()
            elif line.startswith("data:"):
                payload = line[len("data:") :].strip()
        if name and payload is not None:
            events.append({"event": name, "data": json.loads(payload)})
    return events


async def _stream(
    payload: dict[str, Any],
) -> tuple[int, str, list[dict[str, Any]]]:
    # 60s ceiling: the design budget for the live pipeline is 2-10s, but SEC
    # EDGAR's fair-access throttle can occasionally double that. 60s gives
    # comfortable headroom without letting a hang masquerade as a slow API.
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url=BASE, timeout=60.0) as c:
        async with c.stream("POST", ENDPOINT, json=payload) as resp:
            body = ""
            async for chunk in resp.aiter_text():
                body += chunk
            return resp.status_code, resp.headers.get("content-type", ""), _parse_sse(body)


# ---------------------------------------------------------------------------
# Technical route — full pipeline, every progress stage
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_live_technical_route_emits_full_progress_and_final_result():
    """End-to-end: real APIs → real graph → SSE stream → typed final result."""
    status, content_type, events = await _stream(
        {
            "query": f"Technical snapshot for {LIVE_TICKER}",
            "ticker": LIVE_TICKER,
            "analysis_type": "technical",
        }
    )

    assert status == 200
    assert "text/event-stream" in content_type

    # Acceptance: progress events in the right order.
    progress = [e["data"]["stage"] for e in events if e["event"] == "progress"]
    assert progress == ["researching", "analyzing", "reviewing"]

    # Acceptance: a single, schema-valid final_result terminates the stream.
    finals = [e for e in events if e["event"] == "final_result"]
    assert len(finals) == 1
    assert events[-1]["event"] == "final_result"

    response = AnalysisResponse.model_validate(finals[0]["data"])
    assert response.ticker == LIVE_TICKER
    assert response.disclaimer == STANDARD_DISCLAIMER

    # The Analyst should have produced real indicators from real prices.
    technical = finals[0]["data"]["analysis"]["technical"]
    assert technical.get("sample_size", 0) > 30  # enough bars for RSI + MACD
    assert technical.get("rsi") is not None
    # RSI is bounded by definition — a useful sanity check on real data.
    assert 0.0 <= float(technical["rsi"]) <= 100.0
    assert technical.get("macd") is not None

    # And a non-trivial narrative referencing those numbers.
    narrative = response.analysis.narrative
    assert len(narrative) > 40
    # Fallback path always names "RSI" verbatim; LLM path is overwhelmingly
    # likely to as well. If the LLM ever drops the name we'd want to know.
    assert "RSI" in narrative


# ---------------------------------------------------------------------------
# General route — analyst is skipped end-to-end
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_live_general_route_skips_analyzing_progress_stage():
    """General research bypasses the Analyst over the wire as well as in unit tests."""
    status, _ct, events = await _stream(
        {
            "query": f"What's the general outlook for {LIVE_TICKER}?",
            "ticker": LIVE_TICKER,
            "analysis_type": "general",
        }
    )
    assert status == 200
    progress = [e["data"]["stage"] for e in events if e["event"] == "progress"]
    assert progress == ["researching", "reviewing"]
    assert "analyzing" not in progress
    # Final result still emitted — general route returns an empty analysis +
    # disclaimer-bearing risk review.
    final = next(e for e in events if e["event"] == "final_result")
    AnalysisResponse.model_validate(final["data"])


# ---------------------------------------------------------------------------
# Unknown ticker resilience — graceful degradation, not error frame
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_live_unknown_ticker_degrades_rather_than_erroring():
    """Researcher's ``return_exceptions=True`` contract must hold over the wire.

    A ticker no API recognises should still produce a typed final_result with
    confidence ``insufficient_data`` — never an ``event: error`` frame.
    """
    status, _ct, events = await _stream(
        {
            "query": "Analyze ZZZZZ",
            "ticker": "ZZZZZ",
            "analysis_type": "technical",
        }
    )
    assert status == 200
    # Acceptance: degrade, don't crash.
    assert not any(e["event"] == "error" for e in events)
    final = next(e for e in events if e["event"] == "final_result")
    response = AnalysisResponse.model_validate(final["data"])
    assert response.ticker == "ZZZZZ"
    assert response.analysis.confidence == "insufficient_data"
    # Disclaimer is still attached on the degraded path.
    assert response.disclaimer == STANDARD_DISCLAIMER
