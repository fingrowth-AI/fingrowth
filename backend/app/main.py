from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.middleware.disclaimer import DisclaimerMiddleware
from app.routers import analysis, auth, health, paper_trading
from app.services import api_quota


@asynccontextmanager
async def lifespan(app: FastAPI):
    # V8-05: wire the per-user quota counter to Redis when reachable (it falls
    # back to an in-memory counter otherwise — see app.services.api_quota).
    await api_quota.startup()
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
