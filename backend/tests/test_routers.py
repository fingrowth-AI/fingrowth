"""Tests for P1-04: Health endpoint.

The analysis-stub tests that lived here originally covered the synchronous
JSON stub that has been replaced by the SSE streaming endpoint in P3-05.
Streaming/contract coverage now lives in ``test_analysis_streaming.py``;
this file only retains the health check.
"""

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
