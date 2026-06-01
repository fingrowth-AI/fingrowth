"""Per-user virtual cash and buying power (V8-03).

The shared Alpaca paper account is a single execution venue; per-user money
lives here. Each user is seeded with :data:`app.models.database.SEED_VIRTUAL_CASH`
on first access, and their *available* buying power is derived by replaying
their filled orders against that seed (``reconstruct_cash``) — never a
separately-mutated counter that could drift from the reconstructed positions.

The seed lives in our database; the spend is reconstructed from the order feed.
This is what lets one user's trades never touch another's balance: each has
their own seed row and their own client_order_id-prefixed orders (V8-02).

INTERIM (V8-03) — durability limitation:
    The design's intent is that per-user accounting "lives in your DB". Today
    only the *seed* is persisted; available cash is replayed from Alpaca's order
    feed on each read. That keeps the balance reconciled-by-construction with
    reconstructed positions, but couples correctness to the shared feed: any
    fill beyond ``paper_trading.MAX_ACCOUNT_ORDER_FETCH`` (the 5,000-order paging
    cap) or past Alpaca's order-retention window is invisible to the replay and
    would skew the balance. A durable per-user trade/cash ledger (write-through
    on fill, with the replay demoted to a periodic reconciliation check) is the
    tracked follow-up that fully satisfies the "lives in your DB" goal.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

import httpx
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.database import VirtualBalance
from app.tools.paper_trading import get_user_orders, reconstruct_cash


@dataclass(frozen=True)
class Balance:
    """A user's seed capital and current available cash."""

    starting_cash: float
    cash: float


async def get_or_create_starting_cash(
    session: AsyncSession,
    user_id: uuid.UUID | str,
) -> float:
    """Return ``user_id``'s seed capital, creating the row on first access.

    Uses an atomic ``INSERT ... ON CONFLICT DO NOTHING`` so two concurrent first
    accesses can't both insert; the column default supplies the seed amount.
    Manages its own transaction so the seed is durably committed on first
    access.
    """
    async with session.begin():
        stmt = (
            pg_insert(VirtualBalance)
            .values(user_id=user_id)
            .on_conflict_do_nothing(index_elements=["user_id"])
            .returning(VirtualBalance.starting_cash)
        )
        inserted = (await session.execute(stmt)).scalar_one_or_none()
        if inserted is not None:
            return float(inserted)

        existing = (
            await session.execute(
                select(VirtualBalance.starting_cash).where(
                    VirtualBalance.user_id == user_id
                )
            )
        ).scalar_one()
        return float(existing)


async def get_balance(
    session: AsyncSession,
    user_id: uuid.UUID | str,
    *,
    client: httpx.AsyncClient | None = None,
) -> Balance:
    """Seed capital plus available cash reconstructed from the user's fills."""
    starting = await get_or_create_starting_cash(session, user_id)
    orders = await get_user_orders(user_id, client=client)
    return Balance(starting_cash=starting, cash=reconstruct_cash(orders, starting))


async def available_buying_power(
    session: AsyncSession,
    user_id: uuid.UUID | str,
    *,
    client: httpx.AsyncClient | None = None,
) -> float:
    """The cash a user has available to open new positions (V8-03)."""
    return (await get_balance(session, user_id, client=client)).cash
