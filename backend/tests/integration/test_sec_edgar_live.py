"""Live integration tests against the real SEC EDGAR API.

SEC EDGAR is keyless but enforces a real User-Agent contact email. These
tests skip when ``SEC_EDGAR_USER_AGENT`` looks like the placeholder.
"""

from __future__ import annotations

import pytest

from app.models.sec import Filing, FinancialData, InsiderTrade
from app.tools.sec_edgar import (
    _clear_ticker_cache,
    get_company_filings,
    get_financial_statements,
    get_insider_trades,
    ticker_to_cik,
)
from tests.integration.conftest import needs_realistic_sec_user_agent

pytestmark = [pytest.mark.integration, needs_realistic_sec_user_agent()]


@pytest.fixture(autouse=True)
def _reset_cache():
    _clear_ticker_cache()
    yield
    _clear_ticker_cache()


@pytest.mark.asyncio
async def test_ticker_to_cik_aapl_live():
    cik = await ticker_to_cik("AAPL")
    # Apple's canonical CIK is 320193 (zero-padded to 10 digits).
    assert cik == "0000320193"


@pytest.mark.asyncio
async def test_get_company_filings_aapl_returns_ten_or_more_live():
    """Acceptance: get_company_filings('AAPL') returns 10+ filings."""
    filings = await get_company_filings("AAPL")
    assert isinstance(filings, list)
    assert len(filings) >= 10
    assert all(isinstance(f, Filing) for f in filings)
    # Apple's CIK on every record.
    assert all(f.cik == "0000320193" for f in filings)


@pytest.mark.asyncio
async def test_get_financial_statements_aapl_10k_live():
    fin = await get_financial_statements("0000320193", "10-K")
    assert isinstance(fin, FinancialData)
    assert fin.entity_name and "Apple" in fin.entity_name
    assert len(fin.facts) > 0
    assert all(f.form == "10-K" for f in fin.facts)


@pytest.mark.asyncio
async def test_get_insider_trades_aapl_live():
    trades = await get_insider_trades("AAPL")
    assert isinstance(trades, list)
    if trades:
        assert all(isinstance(t, InsiderTrade) for t in trades)
        assert trades[0].cik == "0000320193"
