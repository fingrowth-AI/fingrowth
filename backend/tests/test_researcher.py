"""Tests for P3-02: Researcher agent.

Acceptance:
* Research on 'AAPL' returns filings + prices + news
* All sources attributed with URLs
* One data source failing does not crash the agent

The Phase 2 data tools are stubbed (monkeypatched in the researcher's
namespace) so these tests stay offline and deterministic.
"""

from __future__ import annotations

from datetime import UTC, date, datetime

from app.agents import researcher
from app.agents.researcher import gather_research, researcher_node
from app.models.market import PriceBar
from app.models.news import NewsItem
from app.models.research import ResearchPacket, Source
from app.models.sec import Filing

# ---------------------------------------------------------------------------
# Sample data
# ---------------------------------------------------------------------------


def _filings(n: int = 3) -> list[Filing]:
    return [
        Filing(
            accession_number=f"0000320193-24-{i:06d}",
            form="10-K" if i == 0 else "10-Q",
            filing_date=date(2024, 11, 1),
            report_date=date(2024, 9, 30),
            primary_document=f"aapl-{i}.htm",
            cik="0000320193",
        )
        for i in range(n)
    ]


def _prices(n: int = 5) -> list[PriceBar]:
    return [
        PriceBar(
            ticker="AAPL",
            date=date(2024, 11, 1 + i),
            open=220.0 + i,
            high=225.0 + i,
            low=219.0 + i,
            close=223.0 + i,
            volume=50_000_000 + i,
        )
        for i in range(n)
    ]


def _news(n: int = 4) -> list[NewsItem]:
    return [
        NewsItem(
            headline=f"Apple story #{i}",
            summary=f"Summary #{i}",
            source="Reuters",
            sentiment_score=0.3,
            datetime=datetime(2024, 11, 1, 12, 0, tzinfo=UTC),
            url=f"https://news.example/{i}",
            related="AAPL",
        )
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Tool stubs
# ---------------------------------------------------------------------------


def _stub_tools(monkeypatch, *, filings=None, prices=None, news=None):
    """Patch the three data tools in the researcher's namespace.

    A list value is returned as-is; an Exception value is raised — that drives
    the graceful-degradation tests.
    """

    def _make(value):
        async def _tool(*args, **kwargs):
            if isinstance(value, BaseException):
                raise value
            return value

        return _tool

    monkeypatch.setattr(researcher, "get_company_filings", _make(filings or []))
    monkeypatch.setattr(researcher, "get_daily_prices", _make(prices or []))
    monkeypatch.setattr(researcher, "get_company_news", _make(news or []))


# ---------------------------------------------------------------------------
# Acceptance: research returns filings + prices + news
# ---------------------------------------------------------------------------


async def test_research_aapl_returns_filings_prices_news(monkeypatch):
    """Acceptance: research on 'AAPL' returns filings + prices + news."""
    _stub_tools(monkeypatch, filings=_filings(3), prices=_prices(5), news=_news(4))

    packet = await gather_research("Is Apple healthy?", "AAPL")

    assert isinstance(packet, ResearchPacket)
    assert packet.ticker == "AAPL"
    assert packet.query == "Is Apple healthy?"
    assert len(packet.filings) == 3
    assert len(packet.price_data) == 5
    assert len(packet.news) == 4
    assert not packet.degraded


async def test_ticker_is_normalized_to_uppercase(monkeypatch):
    _stub_tools(monkeypatch, filings=_filings(1))
    packet = await gather_research("q", "  aapl ")
    assert packet.ticker == "AAPL"


# ---------------------------------------------------------------------------
# Acceptance: all sources attributed with URLs
# ---------------------------------------------------------------------------


async def test_all_sources_attributed_with_urls(monkeypatch):
    """Acceptance: every source carries a name, URL and timestamp."""
    _stub_tools(monkeypatch, filings=_filings(2), prices=_prices(3), news=_news(2))

    packet = await gather_research("q", "AAPL")

    names = {s.name for s in packet.sources}
    assert names == {"SEC EDGAR", "Alpha Vantage", "Finnhub"}
    for src in packet.sources:
        assert isinstance(src, Source)
        assert src.url.startswith("https://")
        assert "AAPL" in src.url
        assert isinstance(src.retrieved_at, datetime)


async def test_source_item_counts_match_data(monkeypatch):
    _stub_tools(monkeypatch, filings=_filings(2), prices=_prices(3), news=_news(4))
    packet = await gather_research("q", "AAPL")
    counts = {s.name: s.item_count for s in packet.sources}
    assert counts == {"SEC EDGAR": 2, "Alpha Vantage": 3, "Finnhub": 4}


async def test_news_items_carry_provenance(monkeypatch):
    """Each news data point has its own source URL and timestamp."""
    _stub_tools(monkeypatch, news=_news(3))
    packet = await gather_research("q", "AAPL")
    for item in packet.news:
        assert item.url and item.url.startswith("https://")
        assert isinstance(item.datetime, datetime)


# ---------------------------------------------------------------------------
# V7-03: price source reports the original (cache-aware) fetch time
# ---------------------------------------------------------------------------


async def test_price_source_reports_original_fetch_time(monkeypatch):
    """The Alpha Vantage source's retrieved_at is the cached original fetch
    time, not the gather/serve time — so cached prices don't look fresh-now."""
    _stub_tools(monkeypatch, prices=_prices(3))
    original = datetime(2025, 5, 28, 20, 15, tzinfo=UTC)
    monkeypatch.setattr(researcher, "daily_prices_fetched_at", lambda _t: original)

    packet = await gather_research("q", "AAPL")

    av = next(s for s in packet.sources if s.name == "Alpha Vantage")
    assert av.retrieved_at == original


async def test_price_source_falls_back_to_gather_time_when_uncached(monkeypatch):
    """With nothing cached, the price source still carries a real timestamp."""
    _stub_tools(monkeypatch, prices=_prices(3))
    monkeypatch.setattr(researcher, "daily_prices_fetched_at", lambda _t: None)

    packet = await gather_research("q", "AAPL")

    av = next(s for s in packet.sources if s.name == "Alpha Vantage")
    assert isinstance(av.retrieved_at, datetime)


# ---------------------------------------------------------------------------
# Acceptance: one data source failing does not crash the agent
# ---------------------------------------------------------------------------


async def test_one_source_failure_does_not_crash(monkeypatch):
    """Acceptance: SEC fails, but prices + news still come back."""
    _stub_tools(
        monkeypatch,
        filings=RuntimeError("SEC EDGAR is down"),
        prices=_prices(5),
        news=_news(3),
    )

    packet = await gather_research("q", "AAPL")

    assert packet.filings == []  # failed source degrades to empty
    assert len(packet.price_data) == 5
    assert len(packet.news) == 3
    assert packet.degraded

    sec = next(s for s in packet.sources if s.name == "SEC EDGAR")
    assert sec.ok is False
    assert "SEC EDGAR is down" in sec.error
    # The healthy sources are untouched.
    assert all(s.ok for s in packet.sources if s.name != "SEC EDGAR")


async def test_all_sources_failing_still_returns_packet(monkeypatch):
    """Even a total outage yields a (degraded, empty) packet, not a crash."""
    _stub_tools(
        monkeypatch,
        filings=RuntimeError("sec down"),
        prices=RuntimeError("av down"),
        news=RuntimeError("finnhub down"),
    )

    packet = await gather_research("q", "AAPL")

    assert packet.filings == []
    assert packet.price_data == []
    assert packet.news == []
    assert packet.degraded
    assert all(s.ok is False and s.error for s in packet.sources)
    # URLs are still attributed even for failed sources.
    assert all(s.url.startswith("https://") for s in packet.sources)


# ---------------------------------------------------------------------------
# Graph node integration
# ---------------------------------------------------------------------------


def test_researcher_node_attaches_research_to_state(monkeypatch):
    """The graph node returns a JSON-serializable research dict + path entry."""
    _stub_tools(monkeypatch, filings=_filings(2), prices=_prices(3), news=_news(1))

    result = researcher_node({"query": "Is Apple healthy?", "ticker": "AAPL"})

    assert result["path"] == ["researcher"]
    research = result["research"]
    assert isinstance(research, dict)
    assert len(research["filings"]) == 2
    assert len(research["price_data"]) == 3
    assert len(research["news"]) == 1
    assert len(research["sources"]) == 3
    # model_dump(mode="json") => dates/datetimes are strings, network-safe.
    assert isinstance(research["sources"][0]["retrieved_at"], str)
    assert isinstance(research["filings"][0]["filing_date"], str)


def test_researcher_node_survives_source_failure(monkeypatch):
    """A failing tool inside the graph node degrades gracefully, no exception."""
    _stub_tools(
        monkeypatch,
        filings=RuntimeError("sec down"),
        prices=_prices(2),
        news=_news(2),
    )

    result = researcher_node({"query": "q", "ticker": "AAPL"})

    research = result["research"]
    assert research["filings"] == []
    assert len(research["price_data"]) == 2
    sec = next(s for s in research["sources"] if s["name"] == "SEC EDGAR")
    assert sec["ok"] is False


# ---------------------------------------------------------------------------
# V8-05: per-user quota threading + graceful exhaustion
# ---------------------------------------------------------------------------


async def test_quota_exhaustion_degrades_price_source(monkeypatch):
    """A quota-exhausted price fetch surfaces as a failed source with a clear
    message — the pipeline keeps running on the other sources, no crash."""
    from app.tools.market_data import QuotaExceededError

    _stub_tools(
        monkeypatch,
        filings=_filings(2),
        prices=QuotaExceededError("Daily market-data limit reached; resets tomorrow."),
        news=_news(3),
    )

    packet = await gather_research("q", "AAPL", user_id="user-1")

    assert packet.price_data == []
    assert packet.degraded
    av = next(s for s in packet.sources if s.name == "Alpha Vantage")
    assert av.ok is False
    assert "limit reached" in av.error.lower()
    # The other sources are unaffected.
    assert len(packet.filings) == 2
    assert len(packet.news) == 3


def test_researcher_node_threads_user_id_from_state(monkeypatch):
    """The graph node passes state['user_id'] into the metered price fetch."""
    captured: dict = {}

    async def fake_gather(query, ticker, *, user_id=None, client=None):
        captured["user_id"] = user_id
        return ResearchPacket(
            ticker=ticker, query=query, filings=[], price_data=[], news=[], sources=[]
        )

    monkeypatch.setattr(researcher, "gather_research", fake_gather)

    researcher_node({"query": "q", "ticker": "AAPL", "user_id": "user-42"})

    assert captured["user_id"] == "user-42"
