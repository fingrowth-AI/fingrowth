from __future__ import annotations

import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import DateTime, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class AnalysisSession(Base):
    """One analysis request from the iOS client.

    Stores only the anonymized/hashed representation of the query.
    Raw user data never leaves the device.
    """

    __tablename__ = "analysis_sessions"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    # SHA-256 of the sanitized (PII-free) query for deduplication
    query_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    ticker: Mapped[str | None] = mapped_column(String(10), nullable=True)
    # "fundamental" | "technical" | "general"
    analysis_type: Mapped[str | None] = mapped_column(String(20), nullable=True)
    # Generalized portfolio profile — never raw holdings
    portfolio_context: Mapped[dict | None] = mapped_column(JSONB, nullable=True)

    results: Mapped[list[AnalysisResult]] = relationship(
        "AnalysisResult", back_populates="session", cascade="all, delete-orphan"
    )


class AnalysisResult(Base):
    """The output produced by the LangGraph agent pipeline."""

    __tablename__ = "analysis_results"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("analysis_sessions.id", ondelete="CASCADE"),
        nullable=False,
    )
    research_data: Mapped[dict] = mapped_column(
        JSONB, nullable=False, default=dict
    )
    technical_indicators: Mapped[dict] = mapped_column(
        JSONB, nullable=False, default=dict
    )
    narrative: Mapped[str] = mapped_column(Text, nullable=False, default="")
    risk_flags: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    # "high" | "medium" | "low" | "insufficient_data"
    confidence: Mapped[str] = mapped_column(
        String(20), nullable=False, default="insufficient_data"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    session: Mapped[AnalysisSession] = relationship(
        "AnalysisSession", back_populates="results"
    )
    embeddings: Mapped[list[VectorEmbedding]] = relationship(
        "VectorEmbedding", back_populates="result", cascade="all, delete-orphan"
    )


class VectorEmbedding(Base):
    """384-dim sentence-transformer embedding of an AnalysisResult."""

    __tablename__ = "vector_embeddings"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    result_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("analysis_results.id", ondelete="CASCADE"),
        nullable=False,
    )
    # sentence-transformers all-MiniLM-L6-v2 outputs 384 dims
    embedding: Mapped[list] = mapped_column(Vector(384), nullable=False)
    content_summary: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    result: Mapped[AnalysisResult] = relationship(
        "AnalysisResult", back_populates="embeddings"
    )
