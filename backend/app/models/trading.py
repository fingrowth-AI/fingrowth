"""Domain models for paper trading (P2-05).

Shapes returned by Alpaca's /v2/orders and /v2/positions endpoints. Numeric
fields arrive as strings on the wire; Pydantic's lax-mode coercion handles
the conversion. ``model_config = extra='ignore'`` so unrelated Alpaca fields
(asset_id, exchange, replaced_by, etc.) don't break parsing.
"""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class Order(BaseModel):
    """A paper order — submitted, accepted, filled, or canceled."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str
    client_order_id: str | None = None
    symbol: str
    qty: float
    side: str  # "buy" | "sell"
    order_type: str = Field(default="market", validation_alias="type")
    time_in_force: str = "day"
    status: str  # "accepted" | "filled" | "canceled" | ...
    submitted_at: datetime | None = None
    filled_qty: float = 0.0
    filled_avg_price: float | None = None


class Position(BaseModel):
    """A held paper-trading position."""

    model_config = ConfigDict(extra="ignore")

    symbol: str
    qty: float
    side: str  # "long" | "short"
    avg_entry_price: float
    market_value: float | None = None
    cost_basis: float | None = None
    unrealized_pl: float | None = None


class PortfolioHistoryPoint(BaseModel):
    """One equity sample on the account's value-over-time curve."""

    date: str  # ISO yyyy-mm-dd, derived from Alpaca's unix timestamp
    equity: float


class PortfolioHistory(BaseModel):
    """Account equity over time, powering the Performance tracker (P4-04).

    Alpaca returns parallel ``timestamp`` / ``equity`` arrays plus a
    ``base_value`` (account equity at the start of the window). We flatten that
    into ``points`` and keep ``base_value`` so the client can express each
    point as a cumulative return without depending on locally-captured
    snapshots — closed-position outcomes are already realised into equity.
    """

    base_value: float
    points: list[PortfolioHistoryPoint]
