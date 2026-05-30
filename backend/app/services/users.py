"""User lookup/creation keyed by Apple's stable subject id (V8-01)."""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.database import User


@dataclass(frozen=True)
class ResolvedUser:
    """A user resolved from an apple_sub, plus whether the row was just created."""

    user: User
    created: bool


async def get_or_create_user_by_apple_sub(
    session: AsyncSession,
    apple_sub: str,
) -> ResolvedUser:
    """Return the user for ``apple_sub``, creating the row on first sign-in.

    Uses an atomic ``INSERT ... ON CONFLICT DO NOTHING`` so two simultaneous
    first logins for the same Apple account can't both insert and 500 — one
    creates the row, the other harmlessly conflicts and resolves to the same
    row. A returning sign-in resolves to the existing row (``created=False``).
    The caller owns the transaction.
    """
    stmt = (
        pg_insert(User)
        .values(apple_sub=apple_sub)
        .on_conflict_do_nothing(index_elements=["apple_sub"])
        .returning(User.id)
    )
    inserted_id = (await session.execute(stmt)).scalar_one_or_none()

    if inserted_id is not None:
        user = (
            await session.execute(select(User).where(User.id == inserted_id))
        ).scalar_one()
        return ResolvedUser(user=user, created=True)

    # Conflict: the row already existed (or a concurrent insert just won). The
    # unique-index lock means that insert has committed by now, so it's visible.
    existing = (
        await session.execute(select(User).where(User.apple_sub == apple_sub))
    ).scalar_one()
    return ResolvedUser(user=existing, created=False)
