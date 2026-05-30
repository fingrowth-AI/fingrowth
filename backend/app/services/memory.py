"""Conversation memory (P6-01).

Stores each analysis result as a sentence-transformer embedding in pgvector so
future queries can recall semantically similar past analyses (cosine similarity).

Privacy note: only the already-anonymized analysis content is embedded — the same
PII-free text the cloud pipeline produced. No raw user data is involved here.

Public surface (matches the design doc):
    ConversationMemory.store_analysis(session_id, result) -> embedding_id
    ConversationMemory.find_similar(query, top_k=5)        -> list[PastAnalysis]
    ConversationMemory.prune_old(older_than_days=90)       -> int   (entries removed)
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol, runtime_checkable

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.database import (
    DEFAULT_USER_ID,
    AnalysisResult,
    AnalysisSession,
    VectorEmbedding,
)

# all-MiniLM-L6-v2 emits 384-dim vectors — must match VectorEmbedding.embedding.
EMBEDDING_DIM = 384
DEFAULT_MODEL = "all-MiniLM-L6-v2"
# How much of the embedded text to keep for display/debugging alongside the vector.
_CONTENT_SUMMARY_MAX = 2000


@runtime_checkable
class Embedder(Protocol):
    """Maps text to a fixed-size unit vector. Injectable so tests can run
    offline without downloading the ~90MB sentence-transformer weights."""

    def encode(self, text: str) -> list[float]: ...


class SentenceTransformerEmbedder:
    """Production embedder: lazy-loads all-MiniLM-L6-v2 and L2-normalizes its
    output so pgvector cosine distance behaves as 1 - cosine_similarity.

    The model is cached on the class, so repeated instantiation never reloads
    the weights (loading is the expensive, one-time cost)."""

    _model: Any = None

    def __init__(self, model_name: str = DEFAULT_MODEL) -> None:
        self.model_name = model_name

    def _ensure_model(self) -> Any:
        if SentenceTransformerEmbedder._model is None:
            # Imported lazily so the module (and the app) load without the heavy
            # dependency present until an embedding is actually needed.
            from sentence_transformers import SentenceTransformer

            SentenceTransformerEmbedder._model = SentenceTransformer(self.model_name)
        return SentenceTransformerEmbedder._model

    def encode(self, text: str) -> list[float]:
        model = self._ensure_model()
        vec = model.encode(text, normalize_embeddings=True)
        return [float(x) for x in vec]


@dataclass(frozen=True)
class PastAnalysis:
    """A recalled analysis plus how similar it is to the query (0..1)."""

    session_id: uuid.UUID
    result_id: uuid.UUID
    narrative: str
    confidence: str
    content_summary: str
    similarity: float
    created_at: datetime


class ConversationMemory:
    """Vector-backed recall over past analyses.

    Bound to an async session factory so each call runs in its own transaction;
    the embedder is injectable for offline tests.
    """

    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        embedder: Embedder | None = None,
    ) -> None:
        self._session_factory = session_factory
        self.embedder = embedder or SentenceTransformerEmbedder()

    async def store_analysis(
        self,
        session_id: uuid.UUID,
        result: Mapping[str, Any] | AnalysisResult,
        *,
        content: str | None = None,
        user_id: uuid.UUID | None = None,
    ) -> uuid.UUID:
        """Persist `result` for `session_id` and index it for recall.

        Creates the AnalysisResult row (linked to an existing AnalysisSession),
        embeds `content` (defaults to the result narrative — the text future
        queries are matched against), and stores the vector.

        Ownership (V7-04) is inherited from the owning AnalysisSession, which is
        the single source of truth: the result and embedding are attributed to
        the same user as the session, so a row chain can never end up split
        across users. If `user_id` is supplied it is treated as an assertion and
        must match the session's owner — a mismatch raises rather than silently
        writing an incoherent chain. Returns the new embedding id.
        """
        text_content = (content if content is not None else self._content_for(result)).strip()
        if not text_content:
            text_content = "(empty analysis)"
        # Embedding (and the one-time model load) is blocking CPU work — run it
        # off the event loop so FastAPI request handling isn't stalled.
        vector = await asyncio.to_thread(self._encode, text_content)

        async with self._session_factory() as session:
            async with session.begin():
                owner = await self._resolve_owner(session, session_id, user_id)

                result_row = self._as_result_row(session_id, result)
                result_row.user_id = owner
                session.add(result_row)
                await session.flush()  # assign result_row.id

                embedding = VectorEmbedding(
                    result_id=result_row.id,
                    user_id=owner,
                    embedding=vector,
                    content_summary=text_content[:_CONTENT_SUMMARY_MAX],
                )
                session.add(embedding)
                await session.flush()
                return embedding.id

    @staticmethod
    async def _resolve_owner(
        session: AsyncSession,
        session_id: uuid.UUID,
        claimed_user_id: uuid.UUID | None,
    ) -> uuid.UUID:
        """Return the AnalysisSession's owner, enforcing it as the authority.

        Raises ``ValueError`` if the session is missing, or if a caller-supplied
        ``user_id`` contradicts the session's owner (an ownership-mismatch guard
        that keeps the session/result/embedding chain coherent).
        """
        session_row = await session.get(AnalysisSession, session_id)
        if session_row is None:
            raise ValueError(f"AnalysisSession {session_id} does not exist")
        owner = session_row.user_id
        if claimed_user_id is not None and claimed_user_id != owner:
            raise ValueError(
                f"user_id {claimed_user_id} does not own session {session_id} "
                f"(owned by {owner})"
            )
        return owner

    async def find_similar(
        self,
        query: str,
        top_k: int = 5,
        *,
        user_id: uuid.UUID = DEFAULT_USER_ID,
    ) -> list[PastAnalysis]:
        """Return up to `top_k` past analyses most similar to `query`, ordered
        by descending cosine similarity (most relevant first).

        Recall is scoped to `user_id` (V7-04) so one user never sees another's
        analyses; until V8 this is the default user.
        """
        if top_k <= 0:
            return []
        query_vector = await asyncio.to_thread(self._encode, query)

        # pgvector cosine distance (<=>) == 1 - cosine_similarity for unit
        # vectors; order ascending so the closest match comes first.
        distance = VectorEmbedding.embedding.cosine_distance(query_vector).label("distance")
        stmt = (
            select(AnalysisResult, VectorEmbedding.content_summary, distance)
            .join(AnalysisResult, VectorEmbedding.result_id == AnalysisResult.id)
            .where(AnalysisResult.user_id == user_id)
            .order_by(distance)
            .limit(top_k)
        )

        async with self._session_factory() as session:
            rows = (await session.execute(stmt)).all()

        return [
            PastAnalysis(
                session_id=result.session_id,
                result_id=result.id,
                narrative=result.narrative,
                confidence=result.confidence,
                content_summary=content_summary,
                similarity=1.0 - float(distance_value),
                created_at=result.created_at,
            )
            for result, content_summary, distance_value in rows
        ]

    async def prune_old(self, older_than_days: int = 90) -> int:
        """Prune memory entries (vector embeddings) older than `older_than_days`,
        returning the number removed.

        Scope is deliberately narrow: this removes only the recall index
        (VectorEmbedding rows), not the AnalysisSession/AnalysisResult records,
        which back other features (e.g. audit/history) and own their own
        lifecycle. A pruned analysis simply stops being recalled — its result is
        left untouched.
        """
        cutoff = datetime.now(UTC) - timedelta(days=older_than_days)
        async with self._session_factory() as session:
            async with session.begin():
                outcome = await session.execute(
                    delete(VectorEmbedding).where(VectorEmbedding.created_at < cutoff)
                )
        return outcome.rowcount or 0

    # -- internals ---------------------------------------------------------

    def _encode(self, text: str) -> list[float]:
        vector = self.embedder.encode(text)
        if len(vector) != EMBEDDING_DIM:
            raise ValueError(
                f"Embedder produced {len(vector)} dims, expected {EMBEDDING_DIM} "
                f"(must match VectorEmbedding.embedding)."
            )
        return vector

    @staticmethod
    def _content_for(result: Mapping[str, Any] | AnalysisResult) -> str:
        """Build the text to embed from an analysis result. The narrative is the
        primary signal; the ticker (if present) sharpens recall."""
        if isinstance(result, AnalysisResult):
            return result.narrative or ""
        narrative = str(result.get("narrative", "") or "")
        ticker = str(result.get("ticker", "") or "")
        return f"{ticker} {narrative}".strip() if ticker else narrative

    @staticmethod
    def _as_result_row(
        session_id: uuid.UUID, result: Mapping[str, Any] | AnalysisResult
    ) -> AnalysisResult:
        """Coerce the caller's result into an AnalysisResult row for `session_id`.
        Accepts an already-built ORM object or a plain mapping of fields."""
        if isinstance(result, AnalysisResult):
            result.session_id = session_id
            return result
        return AnalysisResult(
            session_id=session_id,
            research_data=dict(result.get("research_data") or {}),
            technical_indicators=dict(result.get("technical_indicators") or {}),
            narrative=str(result.get("narrative", "") or ""),
            risk_flags=dict(result.get("risk_flags") or {}),
            confidence=str(result.get("confidence", "insufficient_data") or "insufficient_data"),
        )
