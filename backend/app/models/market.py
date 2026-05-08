"""Domain models for market data (P2-02).

Shapes returned by tools/market_data.py from Alpha Vantage. Numeric fields are
coerced from AV's stringly-typed JSON; missing values surface as ``None``.
"""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Alpha Vantage uses these sentinel strings for "missing" instead of nulls.
_AV_MISSING = {None, "", "None", "-"}


def _coerce_float(v: object) -> float | None:
    if v in _AV_MISSING:
        return None
    try:
        return float(v)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


class PriceBar(BaseModel):
    """OHLCV bar for a single trading day."""

    ticker: str
    date: date
    open: float
    high: float
    low: float
    close: float
    volume: int


class CompanyOverview(BaseModel):
    """Subset of Alpha Vantage's OVERVIEW endpoint we actually use downstream."""

    model_config = ConfigDict(populate_by_name=True)

    symbol: str = Field(validation_alias="Symbol")
    name: str | None = Field(default=None, validation_alias="Name")
    description: str | None = Field(default=None, validation_alias="Description")
    exchange: str | None = Field(default=None, validation_alias="Exchange")
    currency: str | None = Field(default=None, validation_alias="Currency")
    country: str | None = Field(default=None, validation_alias="Country")
    sector: str | None = Field(default=None, validation_alias="Sector")
    industry: str | None = Field(default=None, validation_alias="Industry")
    market_cap: float | None = Field(default=None, validation_alias="MarketCapitalization")
    pe_ratio: float | None = Field(default=None, validation_alias="PERatio")
    dividend_yield: float | None = Field(default=None, validation_alias="DividendYield")
    eps: float | None = Field(default=None, validation_alias="EPS")
    beta: float | None = Field(default=None, validation_alias="Beta")
    week_52_high: float | None = Field(default=None, validation_alias="52WeekHigh")
    week_52_low: float | None = Field(default=None, validation_alias="52WeekLow")

    @field_validator(
        "market_cap",
        "pe_ratio",
        "dividend_yield",
        "eps",
        "beta",
        "week_52_high",
        "week_52_low",
        mode="before",
    )
    @classmethod
    def _coerce_optional_float(cls, v: object) -> float | None:
        return _coerce_float(v)
