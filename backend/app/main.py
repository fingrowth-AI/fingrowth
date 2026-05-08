from fastapi import FastAPI

from app.routers import analysis, health

app = FastAPI(
    title="AI Investment Strategist API",
    version="0.1.0",
    description=(
        "Privacy-preserving investment research backend. "
        "This is a research tool, not investment advice."
    ),
)

app.include_router(health.router)
app.include_router(analysis.router, prefix="/api/v1")
