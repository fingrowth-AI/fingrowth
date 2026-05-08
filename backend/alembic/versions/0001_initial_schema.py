"""initial_schema

Revision ID: 0001
Revises:
Create Date: 2026-04-15 00:46:10.992640

"""

from typing import Sequence, Union

import sqlalchemy as sa
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects.postgresql import JSONB, UUID

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0001"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Enable pgvector extension (idempotent)
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        "analysis_sessions",
        sa.Column(
            "id",
            UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("query_hash", sa.String(64), nullable=False),
        sa.Column("ticker", sa.String(10), nullable=True),
        sa.Column("analysis_type", sa.String(20), nullable=True),
        sa.Column("portfolio_context", JSONB, nullable=True),
    )

    op.create_table(
        "analysis_results",
        sa.Column(
            "id",
            UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "session_id",
            UUID(as_uuid=True),
            sa.ForeignKey("analysis_sessions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("research_data", JSONB, nullable=False),
        sa.Column("technical_indicators", JSONB, nullable=False),
        sa.Column("narrative", sa.Text, nullable=False),
        sa.Column("risk_flags", JSONB, nullable=False),
        sa.Column("confidence", sa.String(20), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )

    op.create_table(
        "vector_embeddings",
        sa.Column(
            "id",
            UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "result_id",
            UUID(as_uuid=True),
            sa.ForeignKey("analysis_results.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("embedding", Vector(384), nullable=False),
        sa.Column("content_summary", sa.Text, nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_table("vector_embeddings")
    op.drop_table("analysis_results")
    op.drop_table("analysis_sessions")
    op.execute("DROP EXTENSION IF EXISTS vector")
