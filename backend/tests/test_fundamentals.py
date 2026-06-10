"""Tests for the deterministic fundamentals extraction (earnings answers).

The extractor distills SEC XBRL company facts + the Alpha Vantage overview
into the FundamentalsSnapshot the fundamental route leads with. Pure
functions — no I/O.
"""

from __future__ import annotations

from datetime import date

import pytest

from app.models.fundamentals import FundamentalsSnapshot
from app.models.market import CompanyOverview
from app.models.sec import FinancialData, FinancialFact
from app.tools.fundamentals import extract_fundamentals, format_compact_usd


def _fact(
    concept: str,
    value: float,
    end: date,
    *,
    days: int = 91,
    unit: str = "USD",
) -> FinancialFact:
    return FinancialFact(
        concept=concept,
        label=None,
        unit=unit,
        value=value,
        period_start=date.fromordinal(end.toordinal() - days),
        period_end=end,
        form="10-Q",
        accession_number=None,
    )


def _financials(*facts: FinancialFact) -> FinancialData:
    return FinancialData(
        cik="0000000000", entity_name="Test Co", form_type="10-Q", facts=list(facts)
    )


def _overview(**overrides) -> CompanyOverview:
    payload = {"Symbol": "NVDA", "PERatio": "55.5", "MarketCapitalization": "3210000000000"}
    payload.update(overrides)
    return CompanyOverview.model_validate(payload)


REV = "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"
NI = "us-gaap:NetIncomeLoss"
EPS = "us-gaap:EarningsPerShareDiluted"


def test_extracts_latest_quarter_with_yoy():
    financials = _financials(
        _fact(REV, 18_120_000_000, date(2024, 4, 28)),
        _fact(REV, 26_044_000_000, date(2025, 4, 27)),
        _fact(NI, 14_881_000_000, date(2024, 4, 28)),
        _fact(NI, 18_775_000_000, date(2025, 4, 27)),
        _fact(EPS, 0.60, date(2024, 4, 28), unit="USD/shares"),
        _fact(EPS, 0.76, date(2025, 4, 27), unit="USD/shares"),
    )
    snap = extract_fundamentals(financials, _overview())

    assert snap is not None
    assert snap.period_end == date(2025, 4, 27)
    assert snap.revenue == pytest.approx(26_044_000_000)
    assert snap.revenue_yoy_pct == pytest.approx(43.7, abs=0.1)
    assert snap.net_income == pytest.approx(18_775_000_000)
    assert snap.net_income_yoy_pct == pytest.approx(26.2, abs=0.1)
    assert snap.eps_diluted == pytest.approx(0.76)
    assert snap.pe_ratio == pytest.approx(55.5)
    assert snap.market_cap == pytest.approx(3.21e12)


def test_ignores_year_to_date_durations():
    """10-Q facts include 9-month YTD periods; only true quarters count."""
    financials = _financials(
        _fact(REV, 26_000_000_000, date(2025, 4, 27)),
        _fact(REV, 80_000_000_000, date(2025, 4, 27), days=270),  # YTD — ignore
    )
    snap = extract_fundamentals(financials, None)
    assert snap is not None
    assert snap.revenue == pytest.approx(26_000_000_000)


def test_yoy_absent_when_no_prior_year_quarter():
    financials = _financials(_fact(REV, 26_000_000_000, date(2025, 4, 27)))
    snap = extract_fundamentals(financials, None)
    assert snap is not None
    assert snap.revenue_yoy_pct is None


def test_overview_only_still_yields_snapshot():
    snap = extract_fundamentals(None, _overview())
    assert snap is not None
    assert not snap.has_quarter
    assert snap.pe_ratio == pytest.approx(55.5)


def test_nothing_yields_none():
    assert extract_fundamentals(None, None) is None
    # Empty facts + empty overview fields → nothing worth a snapshot.
    empty_overview = CompanyOverview.model_validate({"Symbol": "ZZZ"})
    assert extract_fundamentals(_financials(), empty_overview) is None


def test_falls_back_to_alternate_revenue_concept():
    financials = _financials(_fact("us-gaap:Revenues", 5_000_000_000, date(2025, 3, 31)))
    snap = extract_fundamentals(financials, None)
    assert snap is not None
    assert snap.revenue == pytest.approx(5_000_000_000)


def test_negative_prior_net_income_yoy_uses_abs_denominator():
    financials = _financials(
        _fact(NI, -1_000_000_000, date(2024, 3, 31)),
        _fact(NI, 500_000_000, date(2025, 3, 30)),
    )
    snap = extract_fundamentals(financials, None)
    assert snap is not None
    assert snap.net_income_yoy_pct == pytest.approx(150.0)


# ---------------------------------------------------------------------------
# allowed_numbers / formatting — the contract that keeps numeric guards happy
# ---------------------------------------------------------------------------


def test_format_compact_usd_magnitudes():
    assert format_compact_usd(26_044_000_000) == "$26.04 billion"
    assert format_compact_usd(3_210_000_000_000) == "$3.21 trillion"
    assert format_compact_usd(309_400_000) == "$309.40 million"
    assert format_compact_usd(-1_500_000_000) == "-$1.50 billion"
    assert format_compact_usd(42.5) == "$42.50"


def test_allowed_numbers_include_scaled_display_forms():
    snap = FundamentalsSnapshot(
        revenue=26_044_000_000,
        market_cap=3_210_000_000_000,
        eps_diluted=0.76,
        dividend_yield=0.0042,
    )
    allowed = snap.allowed_numbers()
    # "$26.04 billion" / "$3.21 trillion" / "$0.76" / "0.42%"
    assert any(v == pytest.approx(26.04) for v in allowed)
    assert any(v == pytest.approx(3.21) for v in allowed)
    assert any(v == pytest.approx(0.76) for v in allowed)
    assert any(v == pytest.approx(0.42) for v in allowed)
