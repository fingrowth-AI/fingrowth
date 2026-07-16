"""Tests for account deletion — DELETE /api/v1/users/me (5.1.1(v)).

App Store Review Guideline 5.1.1(v) requires in-app account deletion. These
tests cover the endpoint contract: an authenticated delete removes the user and
every row referencing them (via ON DELETE CASCADE), a missing/invalid token is
rejected with 401, and a deleted user's session token no longer grants account
access.

Needs a live PostgreSQL (real rows are written and cascade-deleted); skipped
otherwise, matching the other DB-backed router tests.
"""

from __future__ import annotations

import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, func, select, text

from app.db import dispose_engine, get_session_factory
from app.main import app
from app.models.database import (
    AnalysisResult,
    AnalysisSession,
    User,
    VectorEmbedding,
    VirtualBalance,
)
from app.services.session_token import issue_session_token

BASE = "http://test"


@pytest.fixture(autouse=True)
async def _fresh_engine():
    """A cached async engine is bound to one event loop; pytest-asyncio gives
    each test its own loop, so reset the global engine around every test."""
    await dispose_engine()
    yield
    await dispose_engine()


async def _db_reachable() -> bool:
    try:
        async with get_session_factory()() as session:
            await session.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


@pytest.fixture
async def client():
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping users router integration test")
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


@pytest.fixture
async def seeded_user():
    """Create a user with one row in every per-user table; tear it down after.

    Yields the user's id. Cleanup deletes the user row (cascading to any
    remaining dependent rows), so it is a harmless no-op once a test has already
    deleted the account.
    """
    user_id = uuid.uuid4()
    session_id = uuid.uuid4()
    result_id = uuid.uuid4()

    async with get_session_factory()() as session:
        async with session.begin():
            # Flush in FK dependency order so each row's parent already exists.
            session.add(User(id=user_id, apple_sub=f"del.{uuid.uuid4()}"))
            await session.flush()
            session.add(
                AnalysisSession(
                    id=session_id,
                    user_id=user_id,
                    query_hash="0" * 64,
                    ticker="AAPL",
                    analysis_type="technical",
                )
            )
            session.add(VirtualBalance(user_id=user_id))
            await session.flush()
            session.add(
                AnalysisResult(
                    id=result_id,
                    session_id=session_id,
                    user_id=user_id,
                    narrative="test",
                )
            )
            await session.flush()
            session.add(
                VectorEmbedding(
                    result_id=result_id,
                    user_id=user_id,
                    embedding=[0.0] * 384,
                    content_summary="test",
                )
            )

    yield user_id

    async with get_session_factory()() as session:
        async with session.begin():
            await session.execute(delete(User).where(User.id == user_id))


async def _count_for_user(user_id: uuid.UUID) -> dict[str, int]:
    """Row counts across every per-user table for ``user_id``."""
    async with get_session_factory()() as session:
        counts: dict[str, int] = {}
        for label, model in (
            ("users", User),
            ("analysis_sessions", AnalysisSession),
            ("analysis_results", AnalysisResult),
            ("vector_embeddings", VectorEmbedding),
            ("virtual_balances", VirtualBalance),
        ):
            col = model.id if label == "users" else model.user_id
            counts[label] = (
                await session.execute(
                    select(func.count()).where(col == user_id)
                )
            ).scalar_one()
    return counts


@pytest.mark.asyncio
async def test_delete_removes_user_and_all_dependent_rows(client, seeded_user):
    """A successful delete returns 204 and removes the user plus every row that
    references them (cascade across all four per-user tables)."""
    before = await _count_for_user(seeded_user)
    assert before == {
        "users": 1,
        "analysis_sessions": 1,
        "analysis_results": 1,
        "vector_embeddings": 1,
        "virtual_balances": 1,
    }

    token = issue_session_token(seeded_user)
    resp = await client.delete(
        "/api/v1/users/me", headers={"Authorization": f"Bearer {token}"}
    )

    assert resp.status_code == 204
    assert resp.content == b""

    after = await _count_for_user(seeded_user)
    assert after == {
        "users": 0,
        "analysis_sessions": 0,
        "analysis_results": 0,
        "vector_embeddings": 0,
        "virtual_balances": 0,
    }


@pytest.mark.asyncio
async def test_delete_without_token_returns_401(client, seeded_user):
    """A missing Bearer token is rejected — it must never fall back to the
    shared default user and delete their data."""
    resp = await client.delete("/api/v1/users/me")

    assert resp.status_code == 401
    # The account is untouched.
    assert (await _count_for_user(seeded_user))["users"] == 1


@pytest.mark.asyncio
async def test_delete_with_invalid_token_returns_401(client, seeded_user):
    """A forged/garbage Bearer token is rejected without touching any account."""
    resp = await client.delete(
        "/api/v1/users/me", headers={"Authorization": "Bearer not-a-real-token"}
    )

    assert resp.status_code == 401
    assert (await _count_for_user(seeded_user))["users"] == 1


@pytest.mark.asyncio
async def test_deleted_users_token_no_longer_works(client, seeded_user):
    """After deletion the same (still cryptographically valid) session token no
    longer grants account access: a second delete finds no account (404)."""
    token = issue_session_token(seeded_user)
    headers = {"Authorization": f"Bearer {token}"}

    first = await client.delete("/api/v1/users/me", headers=headers)
    assert first.status_code == 204

    # The token still verifies (stateless JWT), but the account it points to is
    # gone — the endpoint reports the account no longer exists.
    second = await client.delete("/api/v1/users/me", headers=headers)
    assert second.status_code == 404
