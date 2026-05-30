"""Tests for P1-03: Database Models + Migrations.

Integration tests require a PostgreSQL instance with pgvector.
They are automatically skipped when the database is unreachable.
"""

from __future__ import annotations

import uuid

import numpy as np
import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.config import settings
from app.models.database import (
    DEFAULT_USER_ID,
    AnalysisResult,
    AnalysisSession,
    Base,
    User,
    VectorEmbedding,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_engine():
    return create_async_engine(settings.database_url, echo=False)


async def _db_reachable() -> bool:
    try:
        engine = _make_engine()
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Unit tests — no DB required
# ---------------------------------------------------------------------------


def test_model_tablenames():
    assert AnalysisSession.__tablename__ == "analysis_sessions"
    assert AnalysisResult.__tablename__ == "analysis_results"
    assert VectorEmbedding.__tablename__ == "vector_embeddings"
    assert User.__tablename__ == "users"


def test_users_table_columns():
    """V7-04: users has id, apple_sub (nullable), created_at."""
    cols = {c.name: c for c in User.__table__.columns}
    assert {"id", "apple_sub", "created_at"} <= set(cols)
    assert cols["apple_sub"].nullable is True


def test_model_columns():
    session_cols = {c.name for c in AnalysisSession.__table__.columns}
    expected_session = {
        "id", "user_id", "created_at", "query_hash", "ticker",
        "analysis_type", "portfolio_context",
    }
    assert expected_session <= session_cols

    result_cols = {c.name for c in AnalysisResult.__table__.columns}
    expected_result = {
        "id", "user_id", "session_id", "research_data", "technical_indicators",
        "narrative", "risk_flags", "confidence",
    }
    assert expected_result <= result_cols

    emb_cols = {c.name for c in VectorEmbedding.__table__.columns}
    assert {"id", "user_id", "result_id", "embedding", "content_summary"} <= emb_cols


def test_user_id_present_on_every_per_user_table():
    """V7-04: every per-user table carries a user_id FK to users."""
    for model in (AnalysisSession, AnalysisResult, VectorEmbedding):
        user_fks = {
            fk.target_fullname
            for col in model.__table__.columns
            if col.name == "user_id"
            for fk in col.foreign_keys
        }
        assert any("users.id" in fk for fk in user_fks), (
            f"{model.__tablename__}.user_id must reference users.id"
        )


def test_default_user_id_is_stable():
    assert str(DEFAULT_USER_ID) == "00000000-0000-0000-0000-000000000001"


def test_foreign_keys():
    result_fks = {fk.target_fullname for fk in AnalysisResult.__table__.foreign_keys}
    assert any("analysis_sessions" in fk for fk in result_fks)

    emb_fks = {fk.target_fullname for fk in VectorEmbedding.__table__.foreign_keys}
    assert any("analysis_results" in fk for fk in emb_fks)


# ---------------------------------------------------------------------------
# Integration tests — require live PostgreSQL with pgvector
# ---------------------------------------------------------------------------

pytestmark_integration = pytest.mark.skipif(
    True,  # evaluated per-test via fixture skip logic
    reason="No database available",
)


@pytest_asyncio.fixture
async def db_session():
    """Provide a transactional async session; rolls back after each test."""
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping integration test")

    engine = _make_engine()

    # Rebuild the schema from the current models so it always matches (V7-04
    # added user_id columns; create_all alone won't alter pre-existing tables).
    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
        # Seed the default user so user_id foreign keys resolve (V7-04).
        await conn.execute(
            text(
                "INSERT INTO users (id, apple_sub) VALUES (:id, NULL) "
                "ON CONFLICT (id) DO NOTHING"
            ),
            {"id": str(DEFAULT_USER_ID)},
        )

    session_factory = async_sessionmaker(engine, expire_on_commit=False)

    async with session_factory() as session:
        async with session.begin():
            yield session
            await session.rollback()

    await engine.dispose()


@pytest.mark.asyncio
async def test_insert_and_query_vector_embedding(db_session: AsyncSession):
    """Acceptance criterion: can insert and query a vector embedding."""
    # Insert a session
    session_row = AnalysisSession(
        id=uuid.uuid4(),
        query_hash="a" * 64,
        ticker="AAPL",
        analysis_type="technical",
    )
    db_session.add(session_row)
    await db_session.flush()

    # Insert a result linked to the session
    result_row = AnalysisResult(
        id=uuid.uuid4(),
        session_id=session_row.id,
        research_data={},
        technical_indicators={"rsi": 55.0},
        narrative="Test narrative",
        risk_flags={},
        confidence="medium",
    )
    db_session.add(result_row)
    await db_session.flush()

    # Insert a vector embedding (384 dims, random values)
    rng = np.random.default_rng(42)
    vec = rng.standard_normal(384).astype(np.float32).tolist()

    emb_row = VectorEmbedding(
        id=uuid.uuid4(),
        result_id=result_row.id,
        embedding=vec,
        content_summary="AAPL technical analysis",
    )
    db_session.add(emb_row)
    await db_session.flush()

    # Query it back via cosine distance (<=>)
    rows = await db_session.execute(
        text(
            "SELECT id, content_summary, embedding <=> :vec AS distance "
            "FROM vector_embeddings "
            "ORDER BY distance "
            "LIMIT 1"
        ),
        {"vec": str(vec)},
    )
    result = rows.fetchone()
    assert result is not None
    assert result.content_summary == "AAPL technical analysis"
    # Same vector against itself → distance ≈ 0
    assert float(result.distance) < 1e-4


@pytest.mark.asyncio
async def test_cascade_delete(db_session: AsyncSession):
    """Deleting a session cascades to results and embeddings."""
    session_row = AnalysisSession(
        id=uuid.uuid4(),
        query_hash="b" * 64,
        ticker="MSFT",
        analysis_type="fundamental",
    )
    db_session.add(session_row)
    await db_session.flush()

    result_row = AnalysisResult(
        id=uuid.uuid4(),
        session_id=session_row.id,
        research_data={},
        technical_indicators={},
        narrative="",
        risk_flags={},
        confidence="low",
    )
    db_session.add(result_row)
    await db_session.flush()

    rng = np.random.default_rng(0)
    vec = rng.standard_normal(384).astype(np.float32).tolist()
    emb_row = VectorEmbedding(
        id=uuid.uuid4(),
        result_id=result_row.id,
        embedding=vec,
        content_summary="cascade test",
    )
    db_session.add(emb_row)
    await db_session.flush()

    # Delete session; cascade should remove result and embedding
    await db_session.delete(session_row)
    await db_session.flush()

    rows = await db_session.execute(
        text("SELECT COUNT(*) FROM vector_embeddings WHERE result_id = :rid"),
        {"rid": str(result_row.id)},
    )
    assert rows.scalar() == 0
