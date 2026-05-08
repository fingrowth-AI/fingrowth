"""SEC EDGAR data client (P2-01).

Free tier — no API key. The SEC fair-access policy requires:
  * a descriptive User-Agent header with a contact email
  * ≤ 10 requests/sec across all clients

This module exposes async functions for company filings, XBRL financial
statements, and insider/institutional filings. All HTTP I/O routes through a
single token-bucket limiter so concurrent callers stay within the SEC budget.
"""

from __future__ import annotations

import asyncio
import time
from datetime import date
from typing import Any

import httpx

from app.config import settings
from app.models.sec import (
    Filing,
    FinancialData,
    FinancialFact,
    InsiderTrade,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EDGAR_BASE = "https://data.sec.gov"
WWW_BASE = "https://www.sec.gov"
TICKER_INDEX_URL = f"{WWW_BASE}/files/company_tickers.json"

DEFAULT_TIMEOUT = httpx.Timeout(20.0, connect=10.0)
RATE_LIMIT_PER_SECOND = 10


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class SECEdgarError(Exception):
    """Base error for SEC EDGAR client failures."""


class CIKNotFoundError(SECEdgarError):
    """Ticker has no SEC mapping or the CIK URL returned 404."""


class RateLimitError(SECEdgarError):
    """SEC EDGAR responded with HTTP 429."""


# ---------------------------------------------------------------------------
# Rate limiter (token bucket: 10 tokens/sec, max burst = 10)
# ---------------------------------------------------------------------------


class _TokenBucket:
    """Simple async token bucket. Refill rate = `rate` tokens/sec."""

    def __init__(self, rate: int) -> None:
        self._rate = float(rate)
        self._tokens = float(rate)
        self._last = time.monotonic()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        async with self._lock:
            now = time.monotonic()
            elapsed = now - self._last
            self._tokens = min(self._rate, self._tokens + elapsed * self._rate)
            self._last = now
            if self._tokens < 1.0:
                wait = (1.0 - self._tokens) / self._rate
                await asyncio.sleep(wait)
                self._tokens = 0.0
            else:
                self._tokens -= 1.0

    def reset(self) -> None:
        """Reset to a full bucket. Test helper."""
        self._tokens = self._rate
        self._last = time.monotonic()


_bucket = _TokenBucket(RATE_LIMIT_PER_SECOND)
_ticker_cik_cache: dict[str, str] | None = None
_cache_lock = asyncio.Lock()


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _headers() -> dict[str, str]:
    return {
        "User-Agent": settings.sec_edgar_user_agent,
        "Accept": "application/json",
    }


async def _request_json(client: httpx.AsyncClient, url: str) -> Any:
    await _bucket.acquire()
    resp = await client.get(url, headers=_headers())
    if resp.status_code == 404:
        raise CIKNotFoundError(f"Not found: {url}")
    if resp.status_code == 429:
        raise RateLimitError("SEC rate limit hit (HTTP 429)")
    resp.raise_for_status()
    return resp.json()


def _normalize_cik(cik: str | int) -> str:
    """Return the SEC's canonical 10-digit zero-padded CIK string."""
    return str(cik).lstrip("0").zfill(10)


# ---------------------------------------------------------------------------
# Ticker → CIK
# ---------------------------------------------------------------------------


async def _load_ticker_index(client: httpx.AsyncClient) -> dict[str, str]:
    """Fetch + cache the SEC's full ticker→CIK mapping.

    The ticker index is a JSON object keyed by row index where each value has
    ``{cik_str, ticker, title}``. We collapse it to a flat ``UPPER → padded CIK``.
    """
    global _ticker_cik_cache
    async with _cache_lock:
        if _ticker_cik_cache is not None:
            return _ticker_cik_cache
        data = await _request_json(client, TICKER_INDEX_URL)
        mapping: dict[str, str] = {}
        for row in data.values():
            ticker = str(row.get("ticker", "")).upper()
            if not ticker:
                continue
            mapping[ticker] = _normalize_cik(row["cik_str"])
        _ticker_cik_cache = mapping
        return mapping


async def ticker_to_cik(
    ticker: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> str:
    """Resolve a ticker symbol to a 10-digit zero-padded CIK string."""
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        index = await _load_ticker_index(client)
        cik = index.get(ticker.upper())
        if not cik:
            raise CIKNotFoundError(f"Ticker {ticker!r} not found in SEC ticker index")
        return cik
    finally:
        if own_client:
            await client.aclose()


def _clear_ticker_cache() -> None:
    """Reset the in-memory ticker→CIK cache. Test helper."""
    global _ticker_cik_cache
    _ticker_cik_cache = None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def get_company_filings(
    ticker: str,
    *,
    forms: tuple[str, ...] | None = None,
    limit: int | None = None,
    client: httpx.AsyncClient | None = None,
) -> list[Filing]:
    """Return SEC filings for a ticker.

    Args:
        ticker: Equity ticker symbol (case-insensitive).
        forms: Optional whitelist of form types (e.g. ``("10-K", "10-Q")``).
        limit: Optional cap on the number of filings returned.
        client: Optional shared httpx.AsyncClient. One is created per call if omitted.
    """
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        cik = await ticker_to_cik(ticker, client=client)
        url = f"{EDGAR_BASE}/submissions/CIK{cik}.json"
        data = await _request_json(client, url)
        recent = data.get("filings", {}).get("recent", {})
        accession = recent.get("accessionNumber", [])
        forms_arr = recent.get("form", [])
        filing_dates = recent.get("filingDate", [])
        report_dates = recent.get("reportDate", [])
        primary_docs = recent.get("primaryDocument", [])

        filings: list[Filing] = []
        for i, acc in enumerate(accession):
            form = forms_arr[i] if i < len(forms_arr) else ""
            if forms and form not in forms:
                continue
            try:
                fdate = date.fromisoformat(filing_dates[i])
            except (IndexError, ValueError):
                continue
            rdate: date | None = None
            if i < len(report_dates) and report_dates[i]:
                try:
                    rdate = date.fromisoformat(report_dates[i])
                except ValueError:
                    rdate = None
            filings.append(
                Filing(
                    accession_number=acc,
                    form=form,
                    filing_date=fdate,
                    report_date=rdate,
                    primary_document=primary_docs[i] if i < len(primary_docs) else None,
                    cik=cik,
                )
            )
            if limit and len(filings) >= limit:
                break
        return filings
    finally:
        if own_client:
            await client.aclose()


async def get_financial_statements(
    cik: str | int,
    form_type: str = "10-K",
    *,
    client: httpx.AsyncClient | None = None,
) -> FinancialData:
    """Return XBRL company facts filtered to a single periodic-report form.

    Uses the ``/api/xbrl/companyfacts/CIK{cik}.json`` endpoint, then narrows to
    facts whose source form matches ``form_type``.
    """
    if form_type not in {"10-K", "10-Q"}:
        raise ValueError(
            f"Unsupported form_type: {form_type!r}; expected '10-K' or '10-Q'"
        )
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    cik_str = _normalize_cik(cik)
    try:
        url = f"{EDGAR_BASE}/api/xbrl/companyfacts/CIK{cik_str}.json"
        data = await _request_json(client, url)
        entity_name = data.get("entityName")
        facts_payload = data.get("facts", {}).get("us-gaap", {})

        facts: list[FinancialFact] = []
        for concept, payload in facts_payload.items():
            label = payload.get("label")
            for unit, items in payload.get("units", {}).items():
                for item in items:
                    if item.get("form") != form_type:
                        continue
                    try:
                        period_end = date.fromisoformat(item["end"])
                    except (KeyError, ValueError):
                        continue
                    period_start: date | None = None
                    if "start" in item:
                        try:
                            period_start = date.fromisoformat(item["start"])
                        except ValueError:
                            period_start = None
                    facts.append(
                        FinancialFact(
                            concept=f"us-gaap:{concept}",
                            label=label,
                            unit=unit,
                            value=float(item["val"]),
                            period_start=period_start,
                            period_end=period_end,
                            form=item["form"],
                            accession_number=item.get("accn"),
                        )
                    )
        return FinancialData(
            cik=cik_str,
            entity_name=entity_name,
            form_type=form_type,
            facts=facts,
        )
    finally:
        if own_client:
            await client.aclose()


async def get_insider_trades(
    ticker: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> list[InsiderTrade]:
    """Return Form 4 insider-transaction filings for a ticker."""
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        filings = await get_company_filings(ticker, forms=("4",), client=client)
        return [
            InsiderTrade(
                accession_number=f.accession_number,
                filing_date=f.filing_date,
                cik=f.cik,
                primary_document=f.primary_document,
            )
            for f in filings
        ]
    finally:
        if own_client:
            await client.aclose()


async def get_institutional_holdings(
    ticker: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> list[Filing]:
    """Return 13F-HR filings for a ticker (institutional holdings)."""
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        return await get_company_filings(
            ticker, forms=("13F-HR", "13F-HR/A"), client=client
        )
    finally:
        if own_client:
            await client.aclose()
