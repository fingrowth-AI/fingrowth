"""Researcher agent (P3-02).

Receives a sanitized query and ticker, then gathers research from the Phase 2
data tools:

  * SEC EDGAR     — recent 10-K / 10-Q filings
  * Alpha Vantage — daily price history
  * Finnhub       — company news with sentiment

The three fetches run concurrently. Each is isolated: a failure in one source
is recorded as a failed :class:`Source` and the others still return, so a
single outage never crashes the agent (graceful degradation).
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Any

import httpx

from app.models.fundamentals import FundamentalsSnapshot
from app.models.research import ResearchPacket, Source
from app.models.sec import FinancialData
from app.tools.fundamentals import extract_fundamentals
from app.tools.market_data import (
    ALPHA_VANTAGE_BASE,
    daily_prices_fetched_at,
    get_company_overview,
    get_daily_prices,
)
from app.tools.news_sentiment import FINNHUB_BASE, get_company_news
from app.tools.sec_edgar import (
    WWW_BASE,
    get_company_filings,
    get_financial_statements,
    ticker_to_cik,
)

# Periodic reports drive fundamental research; ignore 8-Ks, proxies, etc.
_FILING_FORMS = ("10-K", "10-Q")
_FILING_LIMIT = 10
_PRICE_DAYS = 90
_NEWS_DAYS_BACK = 7

# A generous timeout for the shared client — three APIs, one round of calls.
_TIMEOUT = httpx.Timeout(20.0, connect=10.0)


def _now() -> datetime:
    """Indirection so tests can pin the retrieval timestamp."""
    return datetime.now(tz=UTC)


# ---------------------------------------------------------------------------
# Canonical provenance URLs
#
# These describe *where the data was requested from* in human-navigable form.
# They are intentionally independent of the data tools' internal request URLs
# (API keys, pagination params) so nothing secret is ever attributed.
# ---------------------------------------------------------------------------


def _sec_url(ticker: str) -> str:
    return (
        f"{WWW_BASE}/cgi-bin/browse-edgar?action=getcompany"
        f"&ticker={ticker}&type=10-K&dateb=&owner=include&count=40"
    )


def _price_url(ticker: str) -> str:
    return f"{ALPHA_VANTAGE_BASE}?function=TIME_SERIES_DAILY&symbol={ticker}"


def _news_url(ticker: str) -> str:
    return f"{FINNHUB_BASE}/company-news?symbol={ticker}"


def _xbrl_url(ticker: str) -> str:
    return (
        f"{WWW_BASE}/cgi-bin/browse-edgar?action=getcompany"
        f"&ticker={ticker}&type=10-Q&dateb=&owner=include&count=10"
    )


def _overview_url(ticker: str) -> str:
    return f"{ALPHA_VANTAGE_BASE}?function=OVERVIEW&symbol={ticker}"


def _resolve(
    result: list[Any] | BaseException,
    *,
    name: str,
    url: str,
    retrieved_at: datetime,
) -> tuple[list[Any], Source]:
    """Turn a gathered fetch result into ``(data, Source)``.

    A raised exception becomes an empty data list plus a failed ``Source`` —
    this is the graceful-degradation seam.
    """
    if isinstance(result, BaseException):
        return [], Source(
            name=name,
            url=url,
            retrieved_at=retrieved_at,
            ok=False,
            error=f"{type(result).__name__}: {result}",
        )
    data = result or []
    return data, Source(
        name=name,
        url=url,
        retrieved_at=retrieved_at,
        ok=True,
        item_count=len(data),
    )


async def _fetch_quarterly_financials(
    symbol: str, *, client: httpx.AsyncClient
) -> FinancialData:
    """Latest 10-Q XBRL facts for ``symbol`` (resolves the CIK first)."""
    cik = await ticker_to_cik(symbol, client=client)
    return await get_financial_statements(cik, "10-Q", client=client)


async def gather_research(
    query: str,
    ticker: str,
    *,
    user_id: object | None = None,
    include_fundamentals: bool = False,
    client: httpx.AsyncClient | None = None,
) -> ResearchPacket:
    """Gather filings, prices and news for ``ticker`` into a ResearchPacket.

    The data tools are fetched concurrently. ``return_exceptions=True``
    means one failing source never aborts the others — failures surface as
    ``ok=False`` entries in :attr:`ResearchPacket.sources`. That seam is also
    how a V8-05 quota exhaustion degrades: the price source comes back
    ``ok=False`` with a clear message rather than crashing the pipeline.

    ``include_fundamentals`` (the fundamental-analysis route) additionally
    fetches the latest 10-Q XBRL facts and the company overview, distilled
    deterministically into :attr:`ResearchPacket.fundamentals` so an earnings
    question can be answered with earnings data. Same degradation contract:
    either source failing yields a partial (or absent) snapshot, never a crash.

    ``user_id`` bills the (uncached) Alpha Vantage fetches against that
    user's daily allocation (V8-05). SEC EDGAR and Finnhub are separate keys and
    are not metered here.
    """
    symbol = ticker.strip().upper()

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=_TIMEOUT)
    try:
        tasks = [
            get_company_filings(
                symbol, forms=_FILING_FORMS, limit=_FILING_LIMIT, client=client
            ),
            get_daily_prices(symbol, days=_PRICE_DAYS, user_id=user_id, client=client),
            get_company_news(symbol, days_back=_NEWS_DAYS_BACK, client=client),
        ]
        if include_fundamentals:
            tasks.append(_fetch_quarterly_financials(symbol, client=client))
            tasks.append(get_company_overview(symbol, user_id=user_id, client=client))
        results = await asyncio.gather(*tasks, return_exceptions=True)
        filings_res, prices_res, news_res = results[:3]
        financials_res = results[3] if include_fundamentals else None
        overview_res = results[4] if include_fundamentals else None
    finally:
        if own_client:
            await client.aclose()

    retrieved_at = _now()
    filings, sec_source = _resolve(
        filings_res, name="SEC EDGAR", url=_sec_url(symbol), retrieved_at=retrieved_at
    )
    prices, av_source = _resolve(
        prices_res, name="Alpha Vantage", url=_price_url(symbol), retrieved_at=retrieved_at
    )
    # Price data is cached (P2-02). Report when it was *originally* fetched so a
    # cache hit doesn't masquerade as fresh-as-of-now (V7-03). Falls back to the
    # gather timestamp when nothing is cached (e.g. stubbed tools under test).
    if av_source.ok:
        fetched_at = daily_prices_fetched_at(symbol)
        if fetched_at is not None:
            av_source = av_source.model_copy(update={"retrieved_at": fetched_at})
    news, fh_source = _resolve(
        news_res, name="Finnhub", url=_news_url(symbol), retrieved_at=retrieved_at
    )

    sources = [sec_source, av_source, fh_source]
    fundamentals: FundamentalsSnapshot | None = None
    if include_fundamentals:
        financials, xbrl_source = _resolve_one(
            financials_res,
            name="SEC EDGAR XBRL",
            url=_xbrl_url(symbol),
            retrieved_at=retrieved_at,
        )
        overview, overview_source = _resolve_one(
            overview_res,
            name="Alpha Vantage Overview",
            url=_overview_url(symbol),
            retrieved_at=retrieved_at,
        )
        sources.extend([xbrl_source, overview_source])
        fundamentals = extract_fundamentals(financials, overview)

    return ResearchPacket(
        ticker=symbol,
        query=query,
        filings=filings,
        price_data=prices,
        news=news,
        fundamentals=fundamentals,
        sources=sources,
    )


def _resolve_one(
    result: Any,
    *,
    name: str,
    url: str,
    retrieved_at: datetime,
) -> tuple[Any, Source]:
    """Like :func:`_resolve` but for single-object fetches (not lists).

    A raised exception (or an explicit ``None`` payload, e.g. an unknown ticker
    on the overview endpoint) becomes ``ok=False``.
    """
    if isinstance(result, BaseException):
        return None, Source(
            name=name,
            url=url,
            retrieved_at=retrieved_at,
            ok=False,
            error=f"{type(result).__name__}: {result}",
        )
    if result is None:
        return None, Source(
            name=name,
            url=url,
            retrieved_at=retrieved_at,
            ok=False,
            error="no data returned",
        )
    return result, Source(name=name, url=url, retrieved_at=retrieved_at, ok=True)


def researcher_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: gather research and attach a ResearchPacket to the state.

    Kept synchronous so the graph compiles for both ``invoke`` and ``ainvoke``;
    the async data fetches run inside a fresh event loop here. LangGraph runs
    sync nodes off the main thread under ``ainvoke``, so the nested loop is
    safe in either invocation mode.
    """
    query = state.get("query", "")
    ticker = state.get("ticker", "")
    # user_id is carried in the graph state (set by the analysis router) so the
    # uncached price fetch is metered against the requesting user (V8-05).
    user_id = state.get("user_id")
    # The fundamental route additionally needs earnings/valuation data — that's
    # what makes "how were earnings" answerable with earnings figures.
    include_fundamentals = state.get("route") == "fundamental_analysis"
    packet = asyncio.run(
        gather_research(
            query, ticker, user_id=user_id, include_fundamentals=include_fundamentals
        )
    )
    return {"path": ["researcher"], "research": packet.model_dump(mode="json")}
