"""users table and per-user user_id columns (V7-04)

Adds a ``users`` table and a ``user_id`` foreign key to every per-user table
(analysis_sessions, analysis_results, vector_embeddings). A single hardcoded
default user is seeded and used to backfill existing rows; real authentication
(V8) fills user_id with the authenticated user. The user_id columns carry a
server_default of the default user id so the system keeps working single-user
until then.

Revision ID: 0002
Revises: 0001
Create Date: 2026-05-30

"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0002"
down_revision: Union[str, Sequence[str], None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Keep in lockstep with app.models.database.DEFAULT_USER_ID.
DEFAULT_USER_ID = "00000000-0000-0000-0000-000000000001"

# Tables that gain a user_id column. Kept in dependency order so the columns are
# added before anything references them.
_PER_USER_TABLES = ("analysis_sessions", "analysis_results", "vector_embeddings")


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column(
            "id",
            UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column("apple_sub", sa.String(255), nullable=True, unique=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )

    # Seed the default user so the user_id foreign keys (and the backfill below)
    # are immediately satisfiable. The id is cast explicitly — Postgres won't
    # implicitly coerce a string literal into a uuid column.
    op.execute(
        f"INSERT INTO users (id, apple_sub) VALUES ('{DEFAULT_USER_ID}'::uuid, NULL)"
    )

    # The server_default backfills every existing row to the default user and
    # keeps single-user inserts working until V8 sets user_id explicitly.
    for table in _PER_USER_TABLES:
        op.add_column(
            table,
            sa.Column(
                "user_id",
                UUID(as_uuid=True),
                nullable=False,
                server_default=DEFAULT_USER_ID,
            ),
        )
        op.create_foreign_key(
            f"fk_{table}_user_id_users",
            table,
            "users",
            ["user_id"],
            ["id"],
            ondelete="CASCADE",
        )
        op.create_index(f"ix_{table}_user_id", table, ["user_id"])


def downgrade() -> None:
    for table in reversed(_PER_USER_TABLES):
        op.drop_index(f"ix_{table}_user_id", table_name=table)
        op.drop_constraint(f"fk_{table}_user_id_users", table, type_="foreignkey")
        op.drop_column(table, "user_id")
    op.drop_table("users")
