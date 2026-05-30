"""Tests for P2-02: Alpha Vantage market data client.

All HTTP I/O is intercepted via httpx.MockTransport. The settings API key is
patched so :class:`MissingAPIKeyError` does not fire under test.

Acceptance:
* get_daily_prices('MSFT', 30) returns 30 PriceBars
* Cached call makes zero API requests
* Rate-limit response raises RateLimitError
"""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import httpx
import pytest

import app.tools.market_data as market_data
from app.config import settings
from app.models.market import CompanyOverview, PriceBar
from app.tools.market_data import (
    DEFAULT_TTL_SECONDS,
    MissingAPIKeyError,
    RateLimitError,
    StalePriceDataError,
    _clear_cache,
    get_company_overview,
    get_daily_prices,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _api_key_and_cache(monkeypatch):
    """Every test starts with a fresh cache and a stubbed API key.

    ``_today`` is pinned just after the fixture series' newest bar (2025-01-31)
    so the V7-02 staleness check treats the canned payloads as current. Tests
    that exercise staleness override it explicitly.
    """
    monkeypatch.setattr(settings, "alpha_vantage_api_key", "test-key")
    monkeypatch.setattr(market_data, "DEFAULT_MIN_REQUEST_INTERVAL_SECONDS", 0.0)
    monkeypatch.setattr(market_data, "_today", lambda: date(2025, 2, 2))
    _clear_cache()
    yield
    _clear_cache()


def _daily_payload(num_days: int, *, start: date | None = None) -> dict:
    """Build an AV TIME_SERIES_DAILY response with ``num_days`` consecutive bars."""
    start = start or date(2025, 1, 31)
    series = {}
    for i in range(num_days):
        d = start - timedelta(days=i)
        # Slight variation per-day so tests can assert ordering.
        series[d.isoformat()] = {
            "1. open": f"{100 + i:.2f}",
            "2. high": f"{105 + i:.2f}",
            "3. low": f"{95 + i:.2f}",
            "4. close": f"{102 + i:.2f}",
            "5. volume": str(1_000_000 + i),
        }
    return {
        "Meta Data": {"2. Symbol": "MSFT"},
        "Time Series (Daily)": series,
    }


def _overview_payload() -> dict:
    return {
        "Symbol": "MSFT",
        "Name": "Microsoft Corporation",
        "Description": "Software company.",
        "Exchange": "NASDAQ",
        "Currency": "USD",
        "Country": "USA",
        "Sector": "TECHNOLOGY",
        "Industry": "Software—Infrastructure",
        "MarketCapitalization": "3000000000000",
        "PERatio": "35.5",
        "DividendYield": "0.0085",
        "EPS": "11.04",
        "Beta": "0.9",
        "52WeekHigh": "468.35",
        "52WeekLow": "362.90",
    }


def _make_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# ---------------------------------------------------------------------------
# get_daily_prices — primary acceptance criterion
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_daily_prices_msft_30_returns_30_bars():
    """Acceptance: get_daily_prices('MSFT', 30) returns 30 PriceBars."""

    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.params.get("function") == "TIME_SERIES_DAILY"
        assert req.url.params.get("symbol") == "MSFT"
        assert req.url.params.get("apikey") == "test-key"
        return httpx.Response(200, json=_daily_payload(num_days=100))

    async with _make_client(handler) as client:
        bars = await get_daily_prices("msft", 30, client=client)

    assert len(bars) == 30
    assert all(isinstance(b, PriceBar) for b in bars)
    # Bars come back newest-first.
    assert bars[0].date > bars[-1].date
    assert bars[0].ticker == "MSFT"
    # OHLCV typing
    assert isinstance(bars[0].volume, int)
    assert bars[0].open == 100.0


@pytest.mark.asyncio
async def test_get_daily_prices_uses_full_outputsize_when_more_than_100():
    """`outputsize=full` is needed when caller wants > 100 bars."""
    seen: list[str] = []

    def handler(req: httpx.Request) -> httpx.Response:
        seen.append(req.url.params.get("outputsize"))
        return httpx.Response(200, json=_daily_payload(num_days=200))

    async with _make_client(handler) as client:
        bars = await get_daily_prices("MSFT", 150, client=client)

    assert len(bars) == 150
    assert seen == ["full"]


@pytest.mark.asyncio
async def test_get_daily_prices_zero_days_rejected():
    with pytest.raises(ValueError):
        await get_daily_prices("MSFT", 0)


# ---------------------------------------------------------------------------
# Cache — acceptance criterion #2
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cache_makes_zero_repeat_api_requests():
    """Acceptance: cached call makes zero API requests."""
    calls = 0

    def handler(req: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_daily_payload(num_days=100))

    async with _make_client(handler) as client:
        await get_daily_prices("MSFT", 30, client=client)
        await get_daily_prices("MSFT", 30, client=client)
        await get_daily_prices("MSFT", 30, client=client)

    assert calls == 1


@pytest.mark.asyncio
async def test_cache_slices_different_day_counts_from_one_fetch():
    """Different ``days`` values share the same cached payload."""
    calls = 0

    def handler(req: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_daily_payload(num_days=100))

    async with _make_client(handler) as client:
        thirty = await get_daily_prices("MSFT", 30, client=client)
        seven = await get_daily_prices("MSFT", 7, client=client)

    assert len(thirty) == 30
    assert len(seven) == 7
    assert calls == 1


@pytest.mark.asyncio
async def test_cache_expires_after_ttl():
    """Setting ttl=0 effectively disables caching for the next read."""
    calls = 0

    def handler(req: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_daily_payload(num_days=30))

    async with _make_client(handler) as client:
        await get_daily_prices("MSFT", 30, ttl=0, client=client)
        # ttl=0 means the entry is already expired by the time we look.
        await get_daily_prices("MSFT", 30, ttl=0, client=client)

    assert calls == 2


# ---------------------------------------------------------------------------
# Rate limit — acceptance criterion #3
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_rate_limit_information_message_raises():
    """Acceptance: rate limit raises RateLimitError."""
    rate_limit_body = {
        "Information": (
            "Thank you for using Alpha Vantage! Our standard API rate limit is "
            "25 requests per day. Please subscribe to any of the premium plans..."
        )
    }

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=rate_limit_body)

    async with _make_client(handler) as client:
        with pytest.raises(RateLimitError):
            await get_daily_prices("MSFT", 30, client=client)


@pytest.mark.asyncio
async def test_rate_limit_note_message_raises():
    """The legacy ``Note`` rate-limit envelope is also recognized."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "Note": (
                    "Thank you for using Alpha Vantage! Our standard API call "
                    "frequency is 5 calls per minute and 500 calls per day."
                )
            },
        )

    async with _make_client(handler) as client:
        with pytest.raises(RateLimitError):
            await get_daily_prices("MSFT", 30, client=client)


@pytest.mark.asyncio
async def test_cache_misses_are_paced_to_avoid_burst_throttle(monkeypatch):
    """Distinct live requests are serialized with a minimum start interval."""
    now = 100.0
    sleeps: list[float] = []
    calls = 0

    def fake_monotonic() -> float:
        return now

    async def fake_sleep(delay: float) -> None:
        nonlocal now
        sleeps.append(delay)
        now += delay

    def handler(req: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        payload = {**_overview_payload(), "Symbol": req.url.params["symbol"]}
        return httpx.Response(200, json=payload)

    monkeypatch.setattr(market_data, "DEFAULT_MIN_REQUEST_INTERVAL_SECONDS", 1.1)
    monkeypatch.setattr(market_data, "_monotonic", fake_monotonic)
    monkeypatch.setattr(market_data, "_rate_limit_sleep", fake_sleep)
    _clear_cache()

    async with _make_client(handler) as client:
        await get_company_overview("MSFT", client=client)
        await get_company_overview("AAPL", client=client)

    assert calls == 2
    assert len(sleeps) == 1
    assert sleeps[0] == pytest.approx(1.1)


# ---------------------------------------------------------------------------
# Staleness — V7-02
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_stale_price_data_is_rejected(monkeypatch):
    """A newest bar older than the threshold raises rather than returning a
    price that no longer reflects the market."""

    def handler(req: httpx.Request) -> httpx.Response:
        # Newest bar is 2025-01-31.
        return httpx.Response(200, json=_daily_payload(num_days=100))

    # Two weeks later, with the default 5-day threshold, the data is stale.
    monkeypatch.setattr(market_data, "_today", lambda: date(2025, 2, 14))

    async with _make_client(handler) as client:
        with pytest.raises(StalePriceDataError):
            await get_daily_prices("MSFT", 30, client=client)


@pytest.mark.asyncio
async def test_fresh_price_data_within_threshold_passes(monkeypatch):
    """A newest bar inside the threshold (e.g. a long weekend gap) is served."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_daily_payload(num_days=100))

    # 4 days after the newest bar — under the default 5-day threshold.
    monkeypatch.setattr(market_data, "_today", lambda: date(2025, 2, 4))

    async with _make_client(handler) as client:
        bars = await get_daily_prices("MSFT", 30, client=client)

    assert len(bars) == 30


@pytest.mark.asyncio
async def test_staleness_threshold_is_configurable(monkeypatch):
    """The threshold honors the explicit override and Settings default."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_daily_payload(num_days=100))

    monkeypatch.setattr(market_data, "_today", lambda: date(2025, 2, 14))

    async with _make_client(handler) as client:
        # A wider explicit threshold accepts the same 14-day-old data.
        bars = await get_daily_prices(
            "MSFT", 30, max_staleness_days=30, client=client
        )
        assert len(bars) == 30

        # Settings drives the default path.
        _clear_cache()
        monkeypatch.setattr(settings, "max_price_staleness_days", 30)
        bars2 = await get_daily_prices("MSFT", 30, client=client)
        assert len(bars2) == 30


@pytest.mark.asyncio
async def test_non_positive_threshold_disables_staleness_check(monkeypatch):
    """A non-positive threshold opts out of rejection entirely."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_daily_payload(num_days=100))

    monkeypatch.setattr(market_data, "_today", lambda: date(2030, 1, 1))

    async with _make_client(handler) as client:
        bars = await get_daily_prices(
            "MSFT", 30, max_staleness_days=0, client=client
        )

    assert len(bars) == 30


@pytest.mark.asyncio
async def test_cache_hit_preserves_original_fetch_time(monkeypatch):
    """V7-03: a cache hit reports the original fetch time, not the serve time."""
    first_fetch = datetime(2025, 2, 2, 10, 0, tzinfo=UTC)
    later_serve = datetime(2025, 2, 2, 10, 45, tzinfo=UTC)
    stamps = iter([first_fetch, later_serve])
    monkeypatch.setattr(market_data, "_now_wall", lambda: next(stamps))

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=_daily_payload(num_days=100))

    async with _make_client(handler) as client:
        await get_daily_prices("MSFT", 30, client=client)  # miss → stamps first_fetch
        after_miss = market_data.daily_prices_fetched_at("MSFT")
        await get_daily_prices("MSFT", 30, client=client)  # hit → no restamp
        after_hit = market_data.daily_prices_fetched_at("MSFT")

    assert after_miss == first_fetch
    # The original fetch time survives the cache hit; the later serve time is
    # never surfaced.
    assert after_hit == first_fetch


def test_daily_prices_fetched_at_none_when_uncached():
    """No cache entry → no fetch time (the gather path falls back to now)."""
    _clear_cache()
    assert market_data.daily_prices_fetched_at("NOPE") is None


@pytest.mark.asyncio
async def test_no_fabricated_data_when_api_key_missing(monkeypatch):
    """Production must never substitute a fixture: a missing key fails loudly
    instead of returning sample bars."""
    monkeypatch.setattr(settings, "alpha_vantage_api_key", "")

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be hit when key is missing")

    async with _make_client(handler) as client:
        with pytest.raises(MissingAPIKeyError):
            await get_daily_prices("AAPL", 90, client=client)


# ---------------------------------------------------------------------------
# get_company_overview
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_company_overview_parses_payload():
    def handler(req: httpx.Request) -> httpx.Response:
        assert req.url.params.get("function") == "OVERVIEW"
        return httpx.Response(200, json=_overview_payload())

    async with _make_client(handler) as client:
        overview = await get_company_overview("MSFT", client=client)

    assert isinstance(overview, CompanyOverview)
    assert overview.symbol == "MSFT"
    assert overview.sector == "TECHNOLOGY"
    assert overview.market_cap == 3_000_000_000_000.0
    assert overview.pe_ratio == 35.5
    assert overview.eps == 11.04


@pytest.mark.asyncio
async def test_get_company_overview_handles_unknown_symbol():
    """AV returns ``{}`` for unknown tickers; we surface that as ``None``."""

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={})

    async with _make_client(handler) as client:
        result = await get_company_overview("ZZZZ", client=client)

    assert result is None


@pytest.mark.asyncio
async def test_overview_coerces_missing_numeric_fields():
    """AV reports unknown numeric fields as the strings 'None' or '-'."""
    payload = {**_overview_payload(), "PERatio": "None", "Beta": "-", "EPS": ""}

    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=payload)

    async with _make_client(handler) as client:
        overview = await get_company_overview("MSFT", client=client)

    assert overview is not None
    assert overview.pe_ratio is None
    assert overview.beta is None
    assert overview.eps is None
    # Unaffected fields still parse.
    assert overview.market_cap == 3_000_000_000_000.0


@pytest.mark.asyncio
async def test_overview_cached():
    calls = 0

    def handler(req: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_overview_payload())

    async with _make_client(handler) as client:
        await get_company_overview("MSFT", client=client)
        await get_company_overview("MSFT", client=client)

    assert calls == 1


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_api_key_raises(monkeypatch):
    monkeypatch.setattr(settings, "alpha_vantage_api_key", "")

    def handler(req: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("network must not be hit when key is missing")

    async with _make_client(handler) as client:
        with pytest.raises(MissingAPIKeyError):
            await get_daily_prices("MSFT", 30, client=client)


def test_default_ttl_is_one_hour():
    """Sanity: the default TTL is 1 hour as described in the design doc."""
    assert DEFAULT_TTL_SECONDS == 3600
