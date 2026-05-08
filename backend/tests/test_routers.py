"""Tests for P1-04: Health + Router Stubs."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app

BASE = "http://test"


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health_returns_status_ok(client: AsyncClient):
    """GET /health must return {status: ok, db: ...}."""
    resp = await client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert "db" in body


@pytest.mark.asyncio
async def test_health_db_field_present(client: AsyncClient):
    """db field is present regardless of whether PostgreSQL is running."""
    resp = await client.get("/health")
    body = resp.json()
    assert body["db"] in ("connected", "disconnected")


# ---------------------------------------------------------------------------
# Analysis stub
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_analysis_query_returns_mock_response(client: AsyncClient):
    """POST /api/v1/analysis/query returns a valid AnalysisResponse."""
    payload = {
        "query": "Analyze AAPL earnings trends",
        "ticker": "AAPL",
        "analysis_type": "fundamental",
    }
    resp = await client.post("/api/v1/analysis/query", json=payload)
    assert resp.status_code == 200
    body = resp.json()

    assert "session_id" in body
    assert body["ticker"] == "AAPL"
    assert "research" in body
    assert "analysis" in body
    assert "risk_review" in body
    assert "disclaimer" in body
    assert len(body["disclaimer"]) > 0


@pytest.mark.asyncio
async def test_analysis_query_optional_fields(client: AsyncClient):
    """session_id and portfolio_profile are optional."""
    import uuid

    payload = {
        "query": "What is the RSI for MSFT?",
        "ticker": "MSFT",
        "analysis_type": "technical",
        "session_id": str(uuid.uuid4()),
        "portfolio_profile": {
            "sector_weights": {"technology": 0.8},
            "risk_orientation": "growth",
        },
    }
    resp = await client.post("/api/v1/analysis/query", json=payload)
    assert resp.status_code == 200
    assert resp.json()["ticker"] == "MSFT"


@pytest.mark.asyncio
async def test_analysis_query_invalid_body_returns_422(client: AsyncClient):
    """Missing required fields → 422 Unprocessable Entity."""
    resp = await client.post("/api/v1/analysis/query", json={})
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_analysis_query_invalid_analysis_type_returns_422(client: AsyncClient):
    """analysis_type must be fundamental | technical | general."""
    payload = {
        "query": "...",
        "ticker": "AAPL",
        "analysis_type": "buy_signal",  # invalid
    }
    resp = await client.post("/api/v1/analysis/query", json=payload)
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_analysis_response_disclaimer_non_empty(client: AsyncClient):
    """Every AnalysisResponse must include a non-empty disclaimer."""
    payload = {
        "query": "General market overview",
        "ticker": "SPY",
        "analysis_type": "general",
    }
    resp = await client.post("/api/v1/analysis/query", json=payload)
    assert resp.status_code == 200
    assert resp.json()["disclaimer"] != ""
