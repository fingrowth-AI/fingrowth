"""V12-06: conversation continuity wiring around the P6-01 memory store.

A thin layer the analysis pipeline talks to, so the SSE router doesn't have to
know about session rows or embeddings:

    recall(query, user_id)   -> the user's most relevant past analyses
    remember(session_id, ...) -> persist this analysis (creating its session row)
                                 so future follow-ups can recall it

Both directions are scoped to one user (V7-04): recall filters by ``user_id``
and remember attributes the session/result/embedding chain to that same user.
Only the already-anonymized analysis content is embedded — no raw user data.
"""

from __future__ import annotations

import hashlib
import logging
import uuid
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.database import AnalysisSession
from app.services.memory import ConversationMemory, PastAnalysis

logger = logging.getLogger(__name__)


class AnalysisMemory:
    """Pipeline-facing recall/remember over :class:`ConversationMemory`."""

    def __init__(
        self,
        memory: ConversationMemory,
        session_factory: async_sessionmaker[AsyncSession],
    ) -> None:
        self._memory = memory
        self._session_factory = session_factory

    async def recall(
        self, *, query: str, user_id: uuid.UUID, top_k: int = 3
    ) -> list[PastAnalysis]:
        """The user's most relevant prior analyses for ``query`` (user-scoped)."""
        return await self._memory.find_similar(query, top_k=top_k, user_id=user_id)

    async def remember(
        self,
        *,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        query: str,
        ticker: str | None,
        analysis_type: str | None,
        portfolio_context: dict[str, Any] | None,
        result: dict[str, Any],
    ) -> None:
        """Persist this analysis so later follow-ups can recall it.

        Ensures the owning AnalysisSession exists (the result/embedding chain
        hangs off it and is attributed to ``user_id``), then indexes the result.
        """
        await self._ensure_session(
            session_id=session_id,
            user_id=user_id,
            query=query,
            ticker=ticker,
            analysis_type=analysis_type,
            portfolio_context=portfolio_context,
        )
        await self._memory.store_analysis(session_id, result, user_id=user_id)

    async def _ensure_session(
        self,
        *,
        session_id: uuid.UUID,
        user_id: uuid.UUID,
        query: str,
        ticker: str | None,
        analysis_type: str | None,
        portfolio_context: dict[str, Any] | None,
    ) -> None:
        async with self._session_factory() as session:
            async with session.begin():
                if await session.get(AnalysisSession, session_id) is not None:
                    return
                session.add(
                    AnalysisSession(
                        id=session_id,
                        user_id=user_id,
                        # Only the hash of the (already PII-free) query is stored.
                        query_hash=hashlib.sha256(query.encode("utf-8")).hexdigest(),
                        ticker=(ticker or None),
                        analysis_type=analysis_type,
                        portfolio_context=portfolio_context,
                    )
                )


def build_default_memory(
    session_factory: async_sessionmaker[AsyncSession] | None = None,
) -> AnalysisMemory:
    """Construct the production memory bound to the app's session factory.

    The embedder loads lazily (only when an analysis is actually recalled or
    stored), so building this at startup is cheap.
    """
    from app.db import get_session_factory

    factory = session_factory or get_session_factory()
    return AnalysisMemory(ConversationMemory(factory), factory)


def past_analysis_payload(item: PastAnalysis) -> dict[str, Any]:
    """Serialize a recalled analysis into the JSON-able shape the graph state
    (and the analyst) consume."""
    return {
        "session_id": str(item.session_id),
        "narrative": item.narrative,
        "confidence": item.confidence,
        "content_summary": item.content_summary,
        "similarity": round(item.similarity, 4),
        "created_at": item.created_at.isoformat(),
    }
