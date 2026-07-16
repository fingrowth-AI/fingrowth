from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.middleware.disclaimer import DisclaimerMiddleware
from app.routers import analysis, auth, health, paper_trading, users
from app.services import api_quota, usage_limits
from app.tools import market_data


@asynccontextmanager
async def lifespan(app: FastAPI):
    # V8-05: wire the per-user quota counter to Redis when reachable (it falls
    # back to an in-memory counter otherwise — see app.services.api_quota).
    await api_quota.startup()
    # Request rate limits (per-user burst/daily + global daily kill switch).
    await usage_limits.startup()
    # Redis-backed market-data payload cache: survives dev reloads and worker
    # restarts so the Alpha Vantage free tier isn't re-burned on every boot.
    await market_data.startup_cache()
    # V12-06: wire conversation-continuity memory so follow-ups recall the
    # user's prior analyses. Best-effort — if construction fails the pipeline
    # simply runs without prior context.
    try:
        from app.services.analysis_memory import build_default_memory

        analysis.set_pipeline_memory(build_default_memory())
    except Exception:  # pragma: no cover - defensive startup guard
        pass
    yield
    await api_quota.shutdown()
    await usage_limits.shutdown()
    await market_data.shutdown_cache()


app = FastAPI(
    title="FinGrowth API",
    version="0.1.0",
    description=(
        "Privacy-preserving investment research backend. "
        "This is a research tool, not investment advice."
    ),
    lifespan=lifespan,
)

# Compliance gate (P6-03): guarantees every AnalysisResponse carries the
# approved disclaimer, even if the pipeline ever fails to set it.
app.add_middleware(DisclaimerMiddleware)

app.include_router(health.router)
app.include_router(auth.router, prefix="/api/v1")
app.include_router(analysis.router, prefix="/api/v1")
app.include_router(paper_trading.router, prefix="/api/v1")
app.include_router(users.router, prefix="/api/v1")
