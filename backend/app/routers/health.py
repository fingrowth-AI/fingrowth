from __future__ import annotations

from fastapi import APIRouter
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import settings
from app.models.schemas import HealthResponse

router = APIRouter(tags=["health"])


async def _check_db() -> str:
    try:
        engine = create_async_engine(settings.database_url, pool_pre_ping=True)
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        await engine.dispose()
        return "connected"
    except Exception:
        return "disconnected"


@router.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """Return service liveness + DB connectivity status."""
    db_status = await _check_db()
    return HealthResponse(
        status="ok",
        db=db_status,
        redis="unknown",  # Redis check added in a later phase
    )
