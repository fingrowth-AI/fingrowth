"""Live integration tests against the real Alpaca paper-trading API."""

from __future__ import annotations

import pytest

from app.config import settings
from app.models.trading import Order, Position
from app.tools.paper_trading import (
    PAPER_DOMAIN,
    get_order_history,
    get_positions,
)
from tests.integration.conftest import needs_alpaca

pytestmark = [pytest.mark.integration, needs_alpaca()]


def test_alpaca_base_url_is_paper():
    """Sanity: configured base URL must reference paper-api hostname."""
    assert PAPER_DOMAIN in settings.alpaca_base_url, (
        f"ALPACA_BASE_URL must reference {PAPER_DOMAIN}, got "
        f"{settings.alpaca_base_url!r}"
    )


@pytest.mark.asyncio
async def test_get_positions_returns_list_live():
    """Whether the paper account holds positions or not, this should not raise."""
    positions = await get_positions()
    assert isinstance(positions, list)
    for p in positions:
        assert isinstance(p, Position)


@pytest.mark.asyncio
async def test_get_order_history_returns_list_live():
    orders = await get_order_history(limit=10)
    assert isinstance(orders, list)
    assert len(orders) <= 10
    for o in orders:
        assert isinstance(o, Order)
        assert o.symbol
        assert o.status


# -------------------------------------------------------------------------
# Mutating: actually places a paper order against your account.
# Opt-in only — set FINGROWTH_RUN_ORDER_TEST=1 to enable.
# -------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_place_paper_order_aapl_buy_one_live(monkeypatch):
    """Place a real paper order for 1 share of AAPL.

    Skipped unless ``FINGROWTH_RUN_ORDER_TEST=1`` is set, because it mutates
    the paper account's order history. Acceptance criterion was: the returned
    Order's status is ``accepted`` (or ``new`` / ``pending_new`` while routing).
    """
    import os

    if os.environ.get("FINGROWTH_RUN_ORDER_TEST") != "1":
        pytest.skip("opt-in only; set FINGROWTH_RUN_ORDER_TEST=1 to enable")

    from app.tools.paper_trading import place_paper_order

    order = await place_paper_order("AAPL", 1, "buy")
    assert isinstance(order, Order)
    # Alpaca returns 'accepted', 'new', or 'pending_new' for fresh orders;
    # 'filled' is possible during market hours.
    assert order.status in {"accepted", "new", "pending_new", "filled"}
    assert order.symbol == "AAPL"
    assert order.side == "buy"
    assert order.qty == 1.0
