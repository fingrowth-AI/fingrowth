"""Tests for P6-01: Conversation Memory.

Acceptance criteria:
  * Identical query returns similarity > 0.9
  * Results ordered by relevance
  * Entries pruned after 90 days

Unit tests run offline with an injected deterministic embedder. The pgvector
path needs a live PostgreSQL+pgvector and is skipped when unreachable (same
convention as test_database.py).
"""

from __future__ import annotations

import hashlib
import math
import uuid
from datetime import UTC, datetime, timedelta

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.config import settings
from app.models.database import AnalysisResult, AnalysisSession, Base, VectorEmbedding
from app.services.memory import EMBEDDING_DIM, ConversationMemory


class FakeEmbedder:
    """Deterministic, offline bag-of-words hashing embedder. Identical text →
    identical unit vector (cosine 1.0); shared tokens → higher cosine. Same
    384-dim space as the real model so the pgvector column accepts it."""

    def __init__(self, dim: int = EMBEDDING_DIM) -> None:
        self.dim = dim

    def encode(self, text: str) -> list[float]:
        vec = [0.0] * self.dim
        for token in text.lower().split():
            bucket = int(hashlib.sha1(token.encode()).hexdigest(), 16) % self.dim
            vec[bucket] += 1.0
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        return [v / norm for v in vec]


# ---------------------------------------------------------------------------
# Unit tests — no DB
# ---------------------------------------------------------------------------


def test_fake_embedder_dim_and_determinism():
    e = FakeEmbedder()
    v1 = e.encode("apple stock outlook")
    v2 = e.encode("apple stock outlook")
    assert len(v1) == EMBEDDING_DIM
    assert v1 == v2  # deterministic
    # unit norm
    assert math.isclose(math.sqrt(sum(x * x for x in v1)), 1.0, abs_tol=1e-6)
    # identical text → cosine similarity 1.0
    assert math.isclose(sum(a * b for a, b in zip(v1, v2)), 1.0, abs_tol=1e-6)
    # different text → less similar
    v3 = e.encode("microsoft azure revenue")
    assert sum(a * b for a, b in zip(v1, v3)) < 0.99


def test_content_for_builds_text():
    assert ConversationMemory._content_for({"narrative": "foo", "ticker": "AAPL"}) == "AAPL foo"
    assert ConversationMemory._content_for({"narrative": "foo"}) == "foo"
    assert ConversationMemory._content_for({}) == ""


def test_encode_rejects_wrong_dimension():
    class BadEmbedder:
        def encode(self, text: str) -> list[float]:
            return [0.1] * 10  # not 384

    memory = ConversationMemory(session_factory=None, embedder=BadEmbedder())  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="expected 384"):
        memory._encode("anything")


@pytest.mark.asyncio
async def test_find_similar_zero_top_k_short_circuits():
    # top_k <= 0 returns [] without touching the DB or embedder.
    memory = ConversationMemory(session_factory=None, embedder=FakeEmbedder())  # type: ignore[arg-type]
    assert await memory.find_similar("anything", top_k=0) == []


# ---------------------------------------------------------------------------
# Integration tests — live PostgreSQL + pgvector
# ---------------------------------------------------------------------------


async def _db_reachable() -> bool:
    try:
        engine = create_async_engine(settings.database_url)
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
        return True
    except Exception:
        return False


_TRUNCATE = "TRUNCATE vector_embeddings, analysis_results, analysis_sessions CASCADE"


@pytest_asyncio.fixture
async def memory_env():
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping conversation-memory integration test")

    engine = create_async_engine(settings.database_url)
    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(text(_TRUNCATE))

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    memory = ConversationMemory(session_factory, embedder=FakeEmbedder())
    try:
        yield memory, session_factory
    finally:
        async with engine.begin() as conn:
            await conn.execute(text(_TRUNCATE))
        await engine.dispose()


async def _new_session(session_factory, ticker: str = "AAPL", created_at: datetime | None = None):
    sid = uuid.uuid4()
    async with session_factory() as session:
        async with session.begin():
            row = AnalysisSession(
                id=sid,
                query_hash="0" * 64,
                ticker=ticker,
                analysis_type="general",
            )
            if created_at is not None:
                row.created_at = created_at
            session.add(row)
    return sid


@pytest.mark.asyncio
async def test_identical_query_similarity_above_threshold(memory_env):
    memory, sf = memory_env
    sid = await _new_session(sf)
    content = "Apple shows strong technical momentum with rising RSI and volume"

    emb_id = await memory.store_analysis(
        sid, {"narrative": content, "confidence": "high"}, content=content
    )
    assert isinstance(emb_id, uuid.UUID)

    results = await memory.find_similar(content, top_k=5)
    assert results, "expected to recall the stored analysis"
    # Acceptance: identical query → similarity > 0.9 (deterministic embedder → ~1.0)
    assert results[0].similarity > 0.9
    assert results[0].session_id == sid
    assert results[0].confidence == "high"


@pytest.mark.asyncio
async def test_results_ordered_by_relevance(memory_env):
    memory, sf = memory_env
    apple = "apple iphone services revenue growth accelerating"
    msft = "microsoft azure cloud enterprise contracts expanding"

    sid_a = await _new_session(sf, "AAPL")
    sid_m = await _new_session(sf, "MSFT")
    await memory.store_analysis(sid_a, {"narrative": apple}, content=apple)
    await memory.store_analysis(sid_m, {"narrative": msft}, content=msft)

    results = await memory.find_similar(apple, top_k=2)
    assert len(results) == 2
    # Ordered by descending similarity, and the matching analysis ranks first.
    assert results[0].similarity >= results[1].similarity
    assert results[0].session_id == sid_a
    assert results[0].similarity > 0.9  # exact match
    assert results[0].similarity > results[1].similarity  # apple beats msft


@pytest.mark.asyncio
async def test_prune_old_removes_entries_past_90_days(memory_env):
    memory, sf = memory_env

    # Recent entry via the service (embedding created_at defaults to now).
    sid_recent = await _new_session(sf, "NEW")
    await memory.store_analysis(
        sid_recent, {"narrative": "recent analysis"}, content="recent analysis"
    )

    # Old entry: insert the embedding directly with a 100-day-old created_at,
    # since pruning is by the memory entry's age.
    sid_old = await _new_session(sf, "OLD")
    old_ts = datetime.now(UTC) - timedelta(days=100)
    async with sf() as session:
        async with session.begin():
            result = AnalysisResult(
                session_id=sid_old, narrative="stale analysis", confidence="low"
            )
            session.add(result)
            await session.flush()
            session.add(
                VectorEmbedding(
                    result_id=result.id,
                    embedding=FakeEmbedder().encode("stale analysis"),
                    content_summary="stale analysis",
                    created_at=old_ts,
                )
            )

    removed = await memory.prune_old(older_than_days=90)
    assert removed == 1  # only the 100-day-old embedding entry

    # The old entry is no longer recalled; the recent one still is. The old
    # AnalysisResult/Session are intentionally left intact (not recalled, since
    # find_similar inner-joins through embeddings).
    survivors = {r.session_id for r in await memory.find_similar("analysis", top_k=10)}
    assert sid_old not in survivors
    assert sid_recent in survivors
