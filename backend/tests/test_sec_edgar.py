"""Tests for P2-01: SEC EDGAR client.

All HTTP I/O is intercepted via httpx.MockTransport — no live calls to
data.sec.gov. The full set of acceptance criteria is exercised here:

* get_company_filings('AAPL') returns ≥10 filings
* Rate-limiter respects the SEC 10 req/sec budget
* 404 on an unknown CIK raises CIKNotFoundError
* User-Agent header is populated from settings
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from app.config import settings
from app.tools.sec_edgar import (
    CIKNotFoundError,
    _bucket,
    _clear_ticker_cache,
    get_company_filings,
    get_financial_statements,
    get_insider_trades,
    get_institutional_holdings,
    ticker_to_cik,
)

# ---------------------------------------------------------------------------
# Fixtures + helpers
# ---------------------------------------------------------------------------


AAPL_CIK = "0000320193"


def _ticker_index_payload() -> dict:
    return {
        "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
        "1": {"cik_str": 789019, "ticker": "MSFT", "title": "Microsoft Corp"},
    }


def _submissions_payload(num_filings: int = 12, ticker_cik: str = AAPL_CIK) -> dict:
    """Build a /submissions/CIK{cik}.json-shaped payload with mixed form types."""
    forms = ["10-K", "10-Q", "10-Q", "10-Q", "8-K", "4", "4", "13F-HR",
             "10-K", "10-Q", "10-Q", "8-K", "4", "13F-HR/A"][:num_filings]
    accession = [f"0000320193-25-{i:06d}" for i in range(num_filings)]
    filing_dates = [f"2025-{(i % 12) + 1:02d}-15" for i in range(num_filings)]
    report_dates = [f"2025-{(i % 12) + 1:02d}-01" for i in range(num_filings)]
    primary = [f"doc-{i}.htm" for i in range(num_filings)]
    return {
        "cik": ticker_cik,
        "name": "Apple Inc.",
        "filings": {
            "recent": {
                "accessionNumber": accession,
                "form": forms,
                "filingDate": filing_dates,
                "reportDate": report_dates,
                "primaryDocument": primary,
            }
        },
    }


def _companyfacts_payload(cik: str = AAPL_CIK) -> dict:
    return {
        "cik": int(cik),
        "entityName": "Apple Inc.",
        "facts": {
            "us-gaap": {
                "Revenues": {
                    "label": "Revenues",
                    "units": {
                        "USD": [
                            {
                                "start": "2023-10-01",
                                "end": "2024-09-30",
                                "val": 391035000000,
                                "form": "10-K",
                                "accn": "0000320193-24-000123",
                            },
                            {
                                "start": "2024-07-01",
                                "end": "2024-09-30",
                                "val": 94930000000,
                                "form": "10-Q",
                                "accn": "0000320193-24-000098",
                            },
                        ]
                    },
                },
                "NetIncomeLoss": {
                    "label": "Net Income (Loss)",
                    "units": {
                        "USD": [
                            {
                                "start": "2023-10-01",
                                "end": "2024-09-30",
                                "val": 93736000000,
                                "form": "10-K",
                                "accn": "0000320193-24-000123",
                            }
                        ]
                    },
                },
            }
        },
    }


def _make_mock_client(handler) -> httpx.AsyncClient:
    """Build an AsyncClient backed by httpx.MockTransport."""
    transport = httpx.MockTransport(handler)
    return httpx.AsyncClient(transport=transport)


@pytest.fixture(autouse=True)
def _reset_module_state():
    """Each test starts with a fresh cache + full token bucket."""
    _clear_ticker_cache()
    _bucket.reset()
    yield
    _clear_ticker_cache()
    _bucket.reset()


# ---------------------------------------------------------------------------
# Ticker → CIK
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_ticker_to_cik_resolves_known_ticker():
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(200, json=_ticker_index_payload())

    async with _make_mock_client(handler) as client:
        cik = await ticker_to_cik("aapl", client=client)

    assert cik == AAPL_CIK
    # Sanity: hit the SEC ticker index URL with our User-Agent
    assert captured[0].url.host == "www.sec.gov"
    assert captured[0].url.path == "/files/company_tickers.json"
    assert captured[0].headers.get("user-agent") == settings.sec_edgar_user_agent


@pytest.mark.asyncio
async def test_ticker_to_cik_unknown_raises():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_ticker_index_payload())

    async with _make_mock_client(handler) as client:
        with pytest.raises(CIKNotFoundError):
            await ticker_to_cik("ZZZZ", client=client)


@pytest.mark.asyncio
async def test_ticker_index_is_cached():
    """Second resolution should not hit the network again."""
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_ticker_index_payload())

    async with _make_mock_client(handler) as client:
        await ticker_to_cik("AAPL", client=client)
        await ticker_to_cik("MSFT", client=client)

    assert calls == 1, "ticker index must be cached after first fetch"


# ---------------------------------------------------------------------------
# get_company_filings — primary acceptance criterion
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_company_filings_returns_ten_or_more_for_aapl():
    """Acceptance: get_company_filings('AAPL') returns 10+ filings."""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        if request.url.path == f"/submissions/CIK{AAPL_CIK}.json":
            return httpx.Response(200, json=_submissions_payload(num_filings=12))
        return httpx.Response(404)

    async with _make_mock_client(handler) as client:
        filings = await get_company_filings("AAPL", client=client)

    assert len(filings) >= 10
    first = filings[0]
    assert first.cik == AAPL_CIK
    assert first.form == "10-K"
    assert first.accession_number.startswith("0000320193")
    # All filings carry parsed dates
    assert all(f.filing_date is not None for f in filings)


@pytest.mark.asyncio
async def test_get_company_filings_filters_by_form():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        return httpx.Response(200, json=_submissions_payload(num_filings=14))

    async with _make_mock_client(handler) as client:
        only_10k = await get_company_filings("AAPL", forms=("10-K",), client=client)

    assert len(only_10k) >= 1
    assert all(f.form == "10-K" for f in only_10k)


@pytest.mark.asyncio
async def test_get_company_filings_respects_limit():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        return httpx.Response(200, json=_submissions_payload(num_filings=14))

    async with _make_mock_client(handler) as client:
        filings = await get_company_filings("AAPL", limit=5, client=client)

    assert len(filings) == 5


@pytest.mark.asyncio
async def test_get_company_filings_404_raises_cik_not_found():
    """Acceptance: handles 404 for invalid CIK."""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        # /submissions/... returns 404 (CIK exists in index but SEC has no doc for it)
        return httpx.Response(404, text="Not Found")

    async with _make_mock_client(handler) as client:
        with pytest.raises(CIKNotFoundError):
            await get_company_filings("AAPL", client=client)


# ---------------------------------------------------------------------------
# get_financial_statements
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_financial_statements_parses_10k_facts():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == f"/api/xbrl/companyfacts/CIK{AAPL_CIK}.json":
            return httpx.Response(200, json=_companyfacts_payload())
        return httpx.Response(404)

    async with _make_mock_client(handler) as client:
        fin = await get_financial_statements(AAPL_CIK, "10-K", client=client)

    assert fin.entity_name == "Apple Inc."
    assert fin.form_type == "10-K"
    assert fin.cik == AAPL_CIK
    assert len(fin.facts) == 2  # both Revenues 10-K and NetIncomeLoss 10-K
    revenues = [f for f in fin.facts if f.concept == "us-gaap:Revenues"]
    assert revenues and revenues[0].value == 391035000000.0
    assert revenues[0].unit == "USD"
    assert revenues[0].form == "10-K"


@pytest.mark.asyncio
async def test_get_financial_statements_filters_to_10q():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_companyfacts_payload())

    async with _make_mock_client(handler) as client:
        fin = await get_financial_statements(AAPL_CIK, "10-Q", client=client)

    # Only the single 10-Q Revenues row in the fixture
    assert len(fin.facts) == 1
    assert fin.facts[0].form == "10-Q"


@pytest.mark.asyncio
async def test_get_financial_statements_rejects_unknown_form():
    with pytest.raises(ValueError):
        await get_financial_statements(AAPL_CIK, "8-K")


@pytest.mark.asyncio
async def test_get_financial_statements_normalizes_short_cik():
    """Passing an int or a short string should resolve to the 10-digit URL."""
    captured: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request.url.path)
        return httpx.Response(200, json=_companyfacts_payload())

    async with _make_mock_client(handler) as client:
        await get_financial_statements(320193, "10-K", client=client)

    assert captured == [f"/api/xbrl/companyfacts/CIK{AAPL_CIK}.json"]


# ---------------------------------------------------------------------------
# get_insider_trades / get_institutional_holdings
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_insider_trades_filters_form_4():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        return httpx.Response(200, json=_submissions_payload(num_filings=14))

    async with _make_mock_client(handler) as client:
        trades = await get_insider_trades("AAPL", client=client)

    assert len(trades) >= 1
    # All entries should be Form 4 by construction; the InsiderTrade struct
    # carries metadata sourced from those filings.
    assert all(t.cik == AAPL_CIK for t in trades)
    assert all(t.accession_number.startswith("0000320193") for t in trades)


@pytest.mark.asyncio
async def test_get_institutional_holdings_filters_13f():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        return httpx.Response(200, json=_submissions_payload(num_filings=14))

    async with _make_mock_client(handler) as client:
        holdings = await get_institutional_holdings("AAPL", client=client)

    assert len(holdings) >= 1
    assert all(f.form in {"13F-HR", "13F-HR/A"} for f in holdings)


# ---------------------------------------------------------------------------
# Rate limiter
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_rate_limiter_throttles_above_budget():
    """11 sequential acquisitions on a 10/sec bucket must take ≥ 0.1 s.

    The 11th acquire blocks until at least one token has refilled (1/10 s).
    We allow generous slack so the test is not flaky on slow runners.
    """
    _bucket.reset()
    loop = asyncio.get_event_loop()
    start = loop.time()
    for _ in range(11):
        await _bucket.acquire()
    elapsed = loop.time() - start
    # Refill rate is 10/s → one extra token costs ~0.1s. Allow ±50% slack downward.
    assert elapsed >= 0.05, f"limiter let 11 calls through in {elapsed:.3f}s"


@pytest.mark.asyncio
async def test_user_agent_header_present_on_every_request():
    """SEC fair-access requires the UA header on every call."""
    seen_uas: set[str] = set()

    def handler(request: httpx.Request) -> httpx.Response:
        seen_uas.add(request.headers.get("user-agent", ""))
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        if request.url.path == f"/submissions/CIK{AAPL_CIK}.json":
            return httpx.Response(200, json=_submissions_payload())
        return httpx.Response(404)

    async with _make_mock_client(handler) as client:
        await get_company_filings("AAPL", client=client)

    assert seen_uas == {settings.sec_edgar_user_agent}


# ---------------------------------------------------------------------------
# Smoke: payload shapes round-trip cleanly to/from JSON via Pydantic
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_filing_serializes_to_json():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/files/company_tickers.json":
            return httpx.Response(200, json=_ticker_index_payload())
        return httpx.Response(200, json=_submissions_payload(num_filings=3))

    async with _make_mock_client(handler) as client:
        filings = await get_company_filings("AAPL", client=client)

    # Pydantic serialization should be loss-tolerant enough for SSE transport.
    json.loads(filings[0].model_dump_json())
