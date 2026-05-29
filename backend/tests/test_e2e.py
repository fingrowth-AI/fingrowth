"""P6-02: End-to-End Integration Test.

Exercises the full cloud pipeline the iOS client drives:

    (on-device privacy gate) -> POST /analysis/query -> Router -> Researcher
    -> Analyst -> Risk Critic -> SSE -> client merges final_result

The privacy gate and the Privacy Audit Log live on-device (Swift), so they're
represented here by ``SimulatedIOSClient``: it holds the raw (PII-bearing)
query, records an audit entry, and transmits ONLY the sanitized rewrite + a
generalized profile — exactly what the real client puts on the wire. The agent
tools and the analyst LLM are stubbed at the I/O edges so the run is offline,
deterministic, and fast.

Acceptance criteria:
  * Completes in under 30 seconds
  * Response includes research, indicators, risk review, disclaimer
  * No PII in backend logs (grep verification) — also checked on the wire + DB
  * Audit log entry created for every cloud call
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import time
import uuid
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.agents import analyst as analyst_module
from app.config import settings
from app.main import app
from app.models.database import AnalysisResult, AnalysisSession, Base, VectorEmbedding
from app.models.news import NewsItem
from app.models.risk import STANDARD_DISCLAIMER
from app.models.sec import Filing
from app.services.memory import EMBEDDING_DIM, ConversationMemory

BASE = "http://test"
ENDPOINT = "/api/v1/analysis/query"

# --- Simulated on-device privacy gate -------------------------------------
# The raw query carries PII; the on-device QueryRewriter produces the sanitized
# text — the ONLY thing that may reach the cloud. The PII tokens must never
# appear downstream (wire, logs, or DB).
RAW_QUERY = (
    "Should I sell my 500 shares of AAPL bought at $142.50 in my "
    "Fidelity account 12345678? — Jane Doe"
)
SANITIZED_QUERY = (
    "Is a concentrated AAPL position with an undisclosed cost basis worth holding?"
)
PII_TOKENS = ["500 shares", "142.50", "Fidelity", "12345678", "Jane Doe"]
# Generalized portfolio profile (from on-device DifferentialPrivacy) — bucketed,
# never raw holdings.
GENERALIZED_PROFILE = {
    "sector_weights": {"technology": 0.8},
    "largest_position": "concentrated",
    "diversification": "low",
    "risk_orientation": "growth",
}


# ---------------------------------------------------------------------------
# Stub the pipeline's I/O edges so the test is offline + deterministic.
# ---------------------------------------------------------------------------


def _price_bars(n: int) -> list[Any]:
    from app.models.market import PriceBar

    start = date(2024, 1, 1)
    bars = []
    for i in range(n):
        close = 100.0 + 5.0 * math.sin(i / 3.0)
        bars.append(
            PriceBar.model_validate(
                {
                    "ticker": "AAPL",
                    "date": (start + timedelta(days=i)).isoformat(),
                    "open": close,
                    "high": close + 1.0,
                    "low": close - 1.0,
                    "close": close,
                    "volume": 1_000_000 + i,
                }
            )
        )
    return bars


@pytest.fixture(autouse=True)
def _stub_pipeline_edges(monkeypatch):
    """Real graph, stubbed at the network edges. Research is deliberately
    populated (one filing + one news item) so 'includes research' is meaningful;
    none of the stub content contains PII."""

    async def _filings(*args, **kwargs):
        return [
            Filing(
                accession_number="0000320193-24-000010",
                form="10-Q",
                filing_date=date(2024, 1, 15),
                cik="0000320193",
            )
        ]

    async def _news(*args, **kwargs):
        return [
            NewsItem(
                headline="AAPL reports quarterly results in line with estimates",
                summary="Revenue steady; services segment grew.",
                source="TestWire",
                sentiment_score=0.2,
                datetime=datetime(2024, 1, 16, tzinfo=UTC),
                related="AAPL",
            )
        ]

    async def _prices(*args, **kwargs):
        return _price_bars(60)

    monkeypatch.setattr("app.agents.researcher.get_company_filings", _filings)
    monkeypatch.setattr("app.agents.researcher.get_company_news", _news)
    monkeypatch.setattr("app.agents.researcher.get_daily_prices", _prices)
    # Disable the LLM so the deterministic fallback narrator runs (offline).
    monkeypatch.setattr(analyst_module.settings, "openai_api_key", "")


@pytest.fixture
async def http_client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


# ---------------------------------------------------------------------------
# SSE parsing + iOS-client harness
# ---------------------------------------------------------------------------


def _parse_sse(body: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for block in body.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        name = data = None
        for line in block.splitlines():
            if line.startswith("event:"):
                name = line[len("event:") :].strip()
            elif line.startswith("data:"):
                data = line[len("data:") :].strip()
        if name and data is not None:
            events.append({"event": name, "data": json.loads(data)})
    return events


@dataclass
class AuditEntry:
    """Mirror of the on-device PrivacyAuditLog row: keeps the original locally
    for user inspection, records the rewritten text actually transmitted."""

    original: str
    rewritten: str
    profile: dict | None
    ticker: str
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))


class SimulatedIOSClient:
    """Stands in for the iOS app: privacy gate + audit log + SSE consumption."""

    def __init__(self, http: AsyncClient) -> None:
        self._http = http
        self.audit_log: list[AuditEntry] = []
        self.cloud_calls = 0
        self.sent_payloads: list[dict[str, Any]] = []

    async def analyze(
        self,
        *,
        original: str,
        rewritten: str,
        ticker: str,
        analysis_type: str,
        profile: dict | None = None,
    ) -> tuple[dict[str, Any] | None, list[dict[str, Any]], str]:
        # 1. Record the audit entry BEFORE transmission — the device's invariant
        #    is that no cloud call leaves without a corresponding audit row.
        self.audit_log.append(
            AuditEntry(original=original, rewritten=rewritten, profile=profile, ticker=ticker)
        )
        # 2. Transmit ONLY the sanitized rewrite + generalized profile.
        payload: dict[str, Any] = {
            "query": rewritten,
            "ticker": ticker,
            "analysis_type": analysis_type,
        }
        if profile is not None:
            payload["portfolio_profile"] = profile
        self.sent_payloads.append(payload)
        self.cloud_calls += 1

        body = ""
        async with self._http.stream("POST", ENDPOINT, json=payload) as resp:
            async for chunk in resp.aiter_text():
                body += chunk
        events = _parse_sse(body)
        final = next((e["data"] for e in events if e["event"] == "final_result"), None)
        return final, events, body


# ---------------------------------------------------------------------------
# Acceptance: full pipeline response is complete
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_e2e_full_pipeline_returns_complete_response(http_client: AsyncClient):
    harness = SimulatedIOSClient(http_client)
    final, events, _raw = await harness.analyze(
        original=RAW_QUERY,
        rewritten=SANITIZED_QUERY,
        ticker="AAPL",
        analysis_type="technical",
        profile=GENERALIZED_PROFILE,
    )

    assert final is not None, "pipeline produced no final_result"
    # research — populated filings/news
    assert "research" in final
    assert final["research"]["filings"] or final["research"]["news"]
    # indicators — non-empty technical dict
    assert final["analysis"]["technical"], "expected technical indicators"
    assert "rsi" in {k.lower() for k in final["analysis"]["technical"]}
    # risk review
    assert "risk_review" in final and "approved" in final["risk_review"]
    # disclaimer — non-empty, canonical
    assert final["disclaimer"]
    assert final["disclaimer"] == STANDARD_DISCLAIMER
    # full SSE shape: progress + partial + terminal final_result
    names = [e["event"] for e in events]
    assert "progress" in names
    assert "partial_result" in names
    assert names[-1] == "final_result"


# ---------------------------------------------------------------------------
# Acceptance: completes in under 30 seconds
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_e2e_completes_under_30_seconds(http_client: AsyncClient):
    harness = SimulatedIOSClient(http_client)
    start = time.perf_counter()
    final, _events, _raw = await harness.analyze(
        original=RAW_QUERY,
        rewritten=SANITIZED_QUERY,
        ticker="AAPL",
        analysis_type="technical",
        profile=GENERALIZED_PROFILE,
    )
    elapsed = time.perf_counter() - start
    assert final is not None
    assert elapsed < 30.0, f"pipeline took {elapsed:.1f}s (budget 30s)"


# ---------------------------------------------------------------------------
# Acceptance: no PII on the wire or in backend logs (grep verification)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_e2e_no_pii_in_wire_or_logs(http_client: AsyncClient, caplog):
    caplog.set_level(logging.DEBUG)
    harness = SimulatedIOSClient(http_client)
    final, _events, raw = await harness.analyze(
        original=RAW_QUERY,
        rewritten=SANITIZED_QUERY,
        ticker="AAPL",
        analysis_type="technical",
        profile=GENERALIZED_PROFILE,
    )
    assert final is not None

    # Everything the backend saw (payload), emitted (SSE), or logged.
    haystack = "\n".join(
        [json.dumps(p) for p in harness.sent_payloads] + [raw, caplog.text]
    )
    for token in PII_TOKENS:
        assert token not in haystack, f"PII leaked downstream: {token!r}"


# ---------------------------------------------------------------------------
# Acceptance: an audit entry exists for every cloud call
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_e2e_audit_entry_for_every_cloud_call(http_client: AsyncClient):
    harness = SimulatedIOSClient(http_client)
    calls = 3
    for _ in range(calls):
        final, _e, _r = await harness.analyze(
            original=RAW_QUERY,
            rewritten=SANITIZED_QUERY,
            ticker="AAPL",
            analysis_type="technical",
            profile=GENERALIZED_PROFILE,
        )
        assert final is not None

    # Exactly one audit entry per cloud call — the device invariant.
    assert harness.cloud_calls == calls
    assert len(harness.audit_log) == calls

    for entry in harness.audit_log:
        # The rewritten text that was sent carries no PII...
        assert entry.rewritten == SANITIZED_QUERY
        for token in PII_TOKENS:
            assert token not in entry.rewritten
        # ...while the original is retained only locally for user inspection.
        assert entry.original == RAW_QUERY


# ---------------------------------------------------------------------------
# Acceptance: no PII in any database record (live PostgreSQL; skipped if down)
# ---------------------------------------------------------------------------


class _FakeEmbedder:
    """Offline deterministic embedder so the persistence step needs no model."""

    def encode(self, text: str) -> list[float]:
        vec = [0.0] * EMBEDDING_DIM
        for token in text.lower().split():
            vec[int(hashlib.sha1(token.encode()).hexdigest(), 16) % EMBEDDING_DIM] += 1.0
        norm = math.sqrt(sum(v * v for v in vec)) or 1.0
        return [v / norm for v in vec]


async def _db_reachable() -> bool:
    try:
        engine = create_async_engine(settings.database_url)
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
        return True
    except Exception:
        return False


@pytest.mark.asyncio
async def test_e2e_no_pii_in_database_records(http_client: AsyncClient):
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping DB record PII check")

    engine = create_async_engine(settings.database_url)
    truncate = "TRUNCATE vector_embeddings, analysis_results, analysis_sessions CASCADE"
    async with engine.begin() as conn:
        await conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(text(truncate))
    sf = async_sessionmaker(engine, expire_on_commit=False)

    try:
        # Run the pipeline.
        harness = SimulatedIOSClient(http_client)
        final, _e, _r = await harness.analyze(
            original=RAW_QUERY,
            rewritten=SANITIZED_QUERY,
            ticker="AAPL",
            analysis_type="technical",
            profile=GENERALIZED_PROFILE,
        )
        assert final is not None

        # Persist as the device would: the session stores a HASH of the original
        # query (never the text) + the generalized profile; memory stores the
        # PII-free result + sanitized content.
        session_id = uuid.uuid4()
        query_hash = hashlib.sha256(RAW_QUERY.encode()).hexdigest()
        async with sf() as session:
            async with session.begin():
                session.add(
                    AnalysisSession(
                        id=session_id,
                        query_hash=query_hash,
                        ticker="AAPL",
                        analysis_type="technical",
                        portfolio_context=GENERALIZED_PROFILE,
                    )
                )

        memory = ConversationMemory(sf, embedder=_FakeEmbedder())
        await memory.store_analysis(
            session_id,
            {
                "narrative": final["analysis"]["narrative"],
                "technical_indicators": final["analysis"]["technical"],
                "research_data": final["research"],
                "risk_flags": {},
                "confidence": final["analysis"]["confidence"],
            },
            content=SANITIZED_QUERY,
        )

        # Grep every persisted text/JSON column across all three tables.
        async with sf() as session:
            sessions = (await session.execute(select(AnalysisSession))).scalars().all()
            results = (await session.execute(select(AnalysisResult))).scalars().all()
            embeddings = (await session.execute(select(VectorEmbedding))).scalars().all()

        dumped = json.dumps(
            {
                "sessions": [
                    {
                        "query_hash": s.query_hash,
                        "ticker": s.ticker,
                        "analysis_type": s.analysis_type,
                        "portfolio_context": s.portfolio_context,
                    }
                    for s in sessions
                ],
                "results": [
                    {
                        "narrative": r.narrative,
                        "technical_indicators": r.technical_indicators,
                        "research_data": r.research_data,
                        "risk_flags": r.risk_flags,
                        "confidence": r.confidence,
                    }
                    for r in results
                ],
                "embeddings": [{"content_summary": e.content_summary} for e in embeddings],
            },
            default=str,
        )

        for token in PII_TOKENS:
            assert token not in dumped, f"PII persisted in a DB record: {token!r}"
        # The session keeps a hash, not the raw query.
        assert query_hash in dumped
        assert RAW_QUERY not in dumped
    finally:
        async with engine.begin() as conn:
            await conn.execute(text(truncate))
        await engine.dispose()
