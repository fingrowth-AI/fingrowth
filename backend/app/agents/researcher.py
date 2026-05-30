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

from app.models.research import ResearchPacket, Source
from app.tools.market_data import (
    ALPHA_VANTAGE_BASE,
    daily_prices_fetched_at,
    get_daily_prices,
)
from app.tools.news_sentiment import FINNHUB_BASE, get_company_news
from app.tools.sec_edgar import WWW_BASE, get_company_filings

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


async def gather_research(
    query: str,
    ticker: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> ResearchPacket:
    """Gather filings, prices and news for ``ticker`` into a ResearchPacket.

    The three data tools are fetched concurrently. ``return_exceptions=True``
    means one failing source never aborts the others — failures surface as
    ``ok=False`` entries in :attr:`ResearchPacket.sources`.
    """
    symbol = ticker.strip().upper()

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=_TIMEOUT)
    try:
        filings_res, prices_res, news_res = await asyncio.gather(
            get_company_filings(
                symbol, forms=_FILING_FORMS, limit=_FILING_LIMIT, client=client
            ),
            get_daily_prices(symbol, days=_PRICE_DAYS, client=client),
            get_company_news(symbol, days_back=_NEWS_DAYS_BACK, client=client),
            return_exceptions=True,
        )
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

    return ResearchPacket(
        ticker=symbol,
        query=query,
        filings=filings,
        price_data=prices,
        news=news,
        sources=[sec_source, av_source, fh_source],
    )


def researcher_node(state: dict[str, Any]) -> dict[str, Any]:
    """Graph node: gather research and attach a ResearchPacket to the state.

    Kept synchronous so the graph compiles for both ``invoke`` and ``ainvoke``;
    the async data fetches run inside a fresh event loop here. LangGraph runs
    sync nodes off the main thread under ``ainvoke``, so the nested loop is
    safe in either invocation mode.
    """
    query = state.get("query", "")
    ticker = state.get("ticker", "")
    packet = asyncio.run(gather_research(query, ticker))
    return {"path": ["researcher"], "research": packet.model_dump(mode="json")}
