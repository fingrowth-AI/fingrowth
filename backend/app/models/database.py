from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pgvector.sqlalchemy import Vector
from sqlalchemy import DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

# V7-04: the system is single-user today but the schema is multi-user-ready.
# Every per-user row carries a user_id; until Sign in with Apple lands (V8),
# everything is attributed to this fixed default user. A stable, well-known
# UUID lets the migration seed the row and the app reference it without a
# lookup. V8 fills user_id with the real authenticated user — a fill, not a
# migration.
DEFAULT_USER_ID = uuid.UUID("00000000-0000-0000-0000-000000000001")

# V8-03: every user starts with this much tracked virtual cash. Kept in lockstep
# with the 0003 migration's server_default and with
# app.tools.paper_trading.SEED_EQUITY (the equity-curve seed) — they are the
# same starting capital viewed two ways (cash on hand vs. account equity).
SEED_VIRTUAL_CASH = Decimal("100000.00")


class Base(DeclarativeBase):
    pass


class User(Base):
    """An application user.

    ``apple_sub`` is the stable subject identifier from Sign in with Apple. It
    is nullable for now (the default user has none) and is populated in V8 when
    real authentication is wired up.
    """

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    apple_sub: Mapped[str | None] = mapped_column(
        String(255), unique=True, nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class AnalysisSession(Base):
    """One analysis request from the iOS client.

    Stores only the anonymized/hashed representation of the query.
    Raw user data never leaves the device.
    """

    __tablename__ = "analysis_sessions"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        default=DEFAULT_USER_ID,
        server_default=str(DEFAULT_USER_ID),
        index=True,
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
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        default=DEFAULT_USER_ID,
        server_default=str(DEFAULT_USER_ID),
        index=True,
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
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        default=DEFAULT_USER_ID,
        server_default=str(DEFAULT_USER_ID),
        index=True,
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


class VirtualBalance(Base):
    """Per-user virtual cash, the heart of V8-03.

    The shared Alpaca paper account holds one $100K buying-power pool that every
    user would otherwise drain in common. Instead, per-user accounting lives
    here: each user gets their own row seeded at :data:`SEED_VIRTUAL_CASH`, and
    Alpaca is demoted to a pure execution venue. ``starting_cash`` is the seed
    capital; *available* cash is derived by replaying the user's filled orders
    against it (see ``app.tools.paper_trading.reconstruct_cash``), so it always
    reconciles with their reconstructed positions rather than drifting from a
    separately-mutated counter.
    """

    __tablename__ = "virtual_balances"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    starting_cash: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False, server_default="100000.00"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
