"""per-user virtual cash balances (V8-03)

Adds a ``virtual_balances`` table holding each user's starting virtual cash,
seeded at $100K. This is the per-user accounting that replaces the shared
Alpaca account's single buying-power pool: orders are validated against the
owning user's balance before submission, and the shared account becomes a pure
execution venue. The default user's row is seeded so single-user flows keep
working until real users sign in (V8-01).

Revision ID: 0003
Revises: 0002
Create Date: 2026-06-01

"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0003"
down_revision: Union[str, Sequence[str], None] = "0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Keep in lockstep with app.models.database.DEFAULT_USER_ID / SEED_VIRTUAL_CASH.
DEFAULT_USER_ID = "00000000-0000-0000-0000-000000000001"
SEED_VIRTUAL_CASH = "100000.00"


def upgrade() -> None:
    op.create_table(
        "virtual_balances",
        sa.Column("user_id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "starting_cash",
            sa.Numeric(18, 2),
            nullable=False,
            server_default=SEED_VIRTUAL_CASH,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
    )
    op.create_foreign_key(
        "fk_virtual_balances_user_id_users",
        "virtual_balances",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # Seed the default user so the single-user flow has a tracked balance before
    # any real sign-in. The id is cast explicitly — Postgres won't implicitly
    # coerce a string literal into a uuid column. starting_cash takes the column
    # default.
    op.execute(
        f"INSERT INTO virtual_balances (user_id) VALUES ('{DEFAULT_USER_ID}'::uuid)"
    )


def downgrade() -> None:
    op.drop_table("virtual_balances")
