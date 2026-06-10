"""Fundamentals snapshot for the fundamental-analysis route.

Holds the latest reported quarter (from SEC XBRL company facts) plus valuation
context (from the Alpha Vantage company overview). Every value is extracted
deterministically by :mod:`app.tools.fundamentals` — the LLM only narrates
these numbers, never computes them.
"""

from __future__ import annotations

from datetime import date

from pydantic import BaseModel


class FundamentalsSnapshot(BaseModel):
    """Latest-quarter results + valuation context, all deterministic."""

    # Latest reported quarter (10-Q XBRL facts).
    period_end: date | None = None
    revenue: float | None = None
    # Percent change vs. the same quarter one year earlier (e.g. 122.4 == +122.4%).
    revenue_yoy_pct: float | None = None
    net_income: float | None = None
    net_income_yoy_pct: float | None = None
    eps_diluted: float | None = None

    # Valuation context (Alpha Vantage OVERVIEW).
    pe_ratio: float | None = None
    market_cap: float | None = None
    dividend_yield: float | None = None
    week_52_high: float | None = None
    week_52_low: float | None = None

    @property
    def has_quarter(self) -> bool:
        """True when at least one latest-quarter figure was extracted."""
        return any(
            v is not None for v in (self.revenue, self.net_income, self.eps_diluted)
        )

    def allowed_numbers(self) -> list[float]:
        """Every number a narrative may legitimately quote from this snapshot.

        Large money values are admitted in their scaled display forms too
        (thousands / millions / billions / trillions, rounded to 2dp) so a
        narrative writing "$26.04 billion" for a raw 26_044_000_000 isn't
        flagged as fabricated. Percent-like fields are admitted both raw and
        ×100 (a 0.0042 dividend yield may be written "0.42%").
        """
        values: list[float] = []
        for raw in (self.revenue, self.net_income, self.market_cap):
            if raw is None:
                continue
            values.append(raw)
            for scale in (1e3, 1e6, 1e9, 1e12):
                values.append(round(raw / scale, 2))
        for raw in (
            self.eps_diluted,
            self.pe_ratio,
            self.week_52_high,
            self.week_52_low,
            self.revenue_yoy_pct,
            self.net_income_yoy_pct,
        ):
            if raw is None:
                continue
            values.extend([raw, round(raw, 2), round(raw, 1)])
        if self.dividend_yield is not None:
            values.extend(
                [
                    self.dividend_yield,
                    round(self.dividend_yield, 2),
                    round(self.dividend_yield * 100, 2),
                ]
            )
        return values
