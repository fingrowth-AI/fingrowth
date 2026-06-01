"""Tests for V8-03 per-user virtual cash (app.services.virtual_balance).

The cash *math* is unit-tested in test_paper_trading.py (reconstruct_cash); here
we cover the DB-backed seed: first-access creation at $100K, idempotency, and
per-user isolation. The order feed is patched so these tests need only Postgres,
not Alpaca.

Needs a live PostgreSQL (the upsert writes a real row); skipped otherwise.
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import delete, text

from app.db import dispose_engine, get_session_factory
from app.models.database import SEED_VIRTUAL_CASH, User, VirtualBalance
from app.models.trading import Order
from app.services import virtual_balance as vb

SEED = float(SEED_VIRTUAL_CASH)


@pytest.fixture(autouse=True)
async def _fresh_engine():
    """Each pytest-asyncio test gets its own loop; reset the cached engine."""
    await dispose_engine()
    yield
    await dispose_engine()


async def _db_reachable() -> bool:
    try:
        async with get_session_factory()() as session:
            await session.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


@pytest.fixture
async def db_guard():
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping virtual-balance DB test")


@pytest.fixture
async def make_user():
    """Create real user rows and tear them down (cascades to virtual_balances)."""
    created: list[uuid.UUID] = []

    async def _make() -> uuid.UUID:
        user = User(apple_sub=f"vb.{uuid.uuid4()}")
        async with get_session_factory()() as session:
            async with session.begin():
                session.add(user)
            uid = user.id
        created.append(uid)
        return uid

    yield _make

    async with get_session_factory()() as session:
        async with session.begin():
            for uid in created:
                await session.execute(delete(User).where(User.id == uid))


def _filled_buy(user_id, *, symbol: str, qty: float, price: float) -> Order:
    return Order.model_validate(
        {
            "id": uuid.uuid4().hex,
            "client_order_id": f"{user_id}_{uuid.uuid4().hex}",
            "submitted_at": "2024-01-15T15:30:00Z",
            "symbol": symbol,
            "qty": str(qty),
            "filled_qty": str(qty),
            "filled_avg_price": str(price),
            "type": "market",
            "side": "buy",
            "time_in_force": "day",
            "status": "filled",
        }
    )


@pytest.mark.asyncio
async def test_new_user_seeded_at_100k(db_guard, make_user):
    """Acceptance: each new user starts with a tracked $100K virtual balance."""
    uid = await make_user()
    async with get_session_factory()() as session:
        starting = await vb.get_or_create_starting_cash(session, uid)
    assert starting == pytest.approx(SEED)
    assert SEED == pytest.approx(100_000.0)


@pytest.mark.asyncio
async def test_seed_is_idempotent(db_guard, make_user):
    """Repeated access returns the same seed and never double-creates."""
    uid = await make_user()
    async with get_session_factory()() as session:
        first = await vb.get_or_create_starting_cash(session, uid)
    async with get_session_factory()() as session:
        second = await vb.get_or_create_starting_cash(session, uid)
        rows = (
            await session.execute(
                VirtualBalance.__table__.select().where(
                    VirtualBalance.user_id == uid
                )
            )
        ).all()
    assert first == second == pytest.approx(SEED)
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_get_balance_subtracts_user_fills(db_guard, make_user, monkeypatch):
    """Available cash = seed minus the user's own filled buys."""
    uid = await make_user()

    async def fake_orders(user_id, *, status="all", client=None):
        assert user_id == uid
        return [_filled_buy(uid, symbol="AAPL", qty=10, price=100)]

    monkeypatch.setattr(vb, "get_user_orders", fake_orders)

    async with get_session_factory()() as session:
        bal = await vb.get_balance(session, uid)

    assert bal.starting_cash == pytest.approx(SEED)
    assert bal.cash == pytest.approx(SEED - 1000.0)


@pytest.mark.asyncio
async def test_one_users_trades_never_reduce_anothers_balance(
    db_guard, make_user, monkeypatch
):
    """Acceptance: one user's trades never reduce another user's balance."""
    spender = await make_user()
    bystander = await make_user()

    async def fake_orders(user_id, *, status="all", client=None):
        # Only the spender has fills; the bystander has none.
        if user_id == spender:
            return [_filled_buy(spender, symbol="AAPL", qty=50, price=100)]
        return []

    monkeypatch.setattr(vb, "get_user_orders", fake_orders)

    async with get_session_factory()() as session:
        spender_bal = await vb.get_balance(session, spender)
    async with get_session_factory()() as session:
        bystander_bal = await vb.get_balance(session, bystander)

    assert spender_bal.cash == pytest.approx(SEED - 5000.0)
    assert bystander_bal.cash == pytest.approx(SEED)  # untouched
