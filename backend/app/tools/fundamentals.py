"""Deterministic fundamentals extraction (the earnings answer's number source).

Distills SEC XBRL company facts (:func:`app.tools.sec_edgar.get_financial_statements`)
and the Alpha Vantage company overview into a small
:class:`~app.models.fundamentals.FundamentalsSnapshot`: the latest reported
quarter's revenue / net income / diluted EPS with year-over-year change, plus
valuation context. Pure functions over already-fetched data — no I/O, no LLM.
"""

from __future__ import annotations

from datetime import date

from app.models.fundamentals import FundamentalsSnapshot
from app.models.market import CompanyOverview
from app.models.sec import FinancialData, FinancialFact

# XBRL concept aliases per figure. Issuers vary: NVDA reports revenue as
# RevenueFromContractWithCustomerExcludingAssessedTax, older filers as Revenues.
_REVENUE_CONCEPTS = (
    "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax",
    "us-gaap:Revenues",
    "us-gaap:SalesRevenueNet",
)
_NET_INCOME_CONCEPTS = ("us-gaap:NetIncomeLoss",)
_EPS_CONCEPTS = (
    "us-gaap:EarningsPerShareDiluted",
    "us-gaap:EarningsPerShareBasic",
)

# A "quarterly" duration. 10-Q facts also carry year-to-date durations (≈180 /
# 270 days); this window keeps only true single-quarter periods.
_QUARTER_MIN_DAYS = 75
_QUARTER_MAX_DAYS = 100

# The prior-year comparison quarter ends roughly one year before the latest
# one; fiscal-calendar drift means "roughly", hence the window.
_YOY_MIN_DAYS = 336
_YOY_MAX_DAYS = 396


def _quarterly_series(data: FinancialData, concepts: tuple[str, ...]) -> dict[date, float]:
    """period_end -> value for single-quarter facts, preferring later filings.

    Comparative prior-year figures are restated in every subsequent 10-Q;
    iterating in fact order and overwriting per period_end keeps the most
    recently filed value for each period.
    """
    series: dict[date, float] = {}
    for concept in concepts:
        facts = [f for f in data.facts if f.concept == concept]
        if not facts:
            continue
        for fact in facts:
            if _is_quarterly(fact):
                series[fact.period_end] = fact.value
        if series:
            break  # first concept alias with data wins; don't mix definitions
    return series


def _is_quarterly(fact: FinancialFact) -> bool:
    if fact.period_start is None:
        return False
    duration = (fact.period_end - fact.period_start).days
    return _QUARTER_MIN_DAYS <= duration <= _QUARTER_MAX_DAYS


def _latest_with_yoy(series: dict[date, float]) -> tuple[float | None, float | None, date | None]:
    """(latest value, % change vs the same quarter last year, latest period end)."""
    if not series:
        return None, None, None
    latest_end = max(series)
    latest = series[latest_end]
    prior_ends = [
        end
        for end in series
        if _YOY_MIN_DAYS <= (latest_end - end).days <= _YOY_MAX_DAYS
    ]
    yoy: float | None = None
    if prior_ends:
        prior = series[max(prior_ends)]
        if prior:
            yoy = round((latest - prior) / abs(prior) * 100.0, 1)
    return latest, yoy, latest_end


def extract_fundamentals(
    financials: FinancialData | None,
    overview: CompanyOverview | None,
) -> FundamentalsSnapshot | None:
    """Build the snapshot from whatever sources succeeded; None when neither did."""
    if financials is None and overview is None:
        return None

    snapshot = FundamentalsSnapshot()

    if financials is not None:
        revenue, revenue_yoy, revenue_end = _latest_with_yoy(
            _quarterly_series(financials, _REVENUE_CONCEPTS)
        )
        income, income_yoy, income_end = _latest_with_yoy(
            _quarterly_series(financials, _NET_INCOME_CONCEPTS)
        )
        eps, _eps_yoy, eps_end = _latest_with_yoy(
            _quarterly_series(financials, _EPS_CONCEPTS)
        )
        snapshot.revenue = revenue
        snapshot.revenue_yoy_pct = revenue_yoy
        snapshot.net_income = income
        snapshot.net_income_yoy_pct = income_yoy
        snapshot.eps_diluted = eps
        ends = [e for e in (revenue_end, income_end, eps_end) if e is not None]
        snapshot.period_end = max(ends) if ends else None

    if overview is not None:
        snapshot.pe_ratio = overview.pe_ratio
        snapshot.market_cap = overview.market_cap
        snapshot.dividend_yield = overview.dividend_yield
        snapshot.week_52_high = overview.week_52_high
        snapshot.week_52_low = overview.week_52_low

    # Both sources present but empty (e.g. an unknown ticker's empty facts).
    if not snapshot.has_quarter and snapshot.pe_ratio is None and snapshot.market_cap is None:
        return None
    return snapshot


def format_compact_usd(value: float) -> str:
    """Canonical money formatting for narratives: "$26.04 billion".

    The scaled magnitudes this emits are exactly the ones
    :meth:`FundamentalsSnapshot.allowed_numbers` admits, so a narrative built
    with this formatter always passes the numeric guards.
    """
    magnitude = abs(value)
    sign = "-" if value < 0 else ""
    for scale, label in ((1e12, "trillion"), (1e9, "billion"), (1e6, "million"), (1e3, "thousand")):
        if magnitude >= scale:
            return f"{sign}${round(magnitude / scale, 2):.2f} {label}"
    return f"{sign}${magnitude:.2f}"
