from fastapi import FastAPI

from app.middleware.disclaimer import DisclaimerMiddleware
from app.routers import analysis, auth, health, paper_trading

app = FastAPI(
    title="FinGrowth API",
    version="0.1.0",
    description=(
        "Privacy-preserving investment research backend. "
        "This is a research tool, not investment advice."
    ),
)

# Compliance gate (P6-03): guarantees every AnalysisResponse carries the
# approved disclaimer, even if the pipeline ever fails to set it.
app.add_middleware(DisclaimerMiddleware)

app.include_router(health.router)
app.include_router(auth.router, prefix="/api/v1")
app.include_router(analysis.router, prefix="/api/v1")
app.include_router(paper_trading.router, prefix="/api/v1")
