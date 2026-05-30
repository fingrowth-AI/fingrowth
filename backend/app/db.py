"""Async database engine, session factory, and FastAPI dependency.

Centralizes the SQLAlchemy async engine so routers don't each spin up their own
(health.py predates this and still does an ad-hoc connect for its liveness
check). The engine is created lazily on first use and reused process-wide.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.config import settings

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def get_engine() -> AsyncEngine:
    """Return the process-wide async engine, creating it on first use."""
    global _engine
    if _engine is None:
        _engine = create_async_engine(settings.database_url, pool_pre_ping=True)
    return _engine


def get_session_factory() -> async_sessionmaker[AsyncSession]:
    """Return the process-wide async session factory."""
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(get_engine(), expire_on_commit=False)
    return _session_factory


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency yielding a request-scoped async session."""
    async with get_session_factory()() as session:
        yield session


async def dispose_engine() -> None:
    """Dispose the process-wide engine and reset the factory.

    Used at app shutdown and for test isolation — a cached async engine is bound
    to the event loop it was created on, so per-test loops need a fresh one.
    """
    global _engine, _session_factory
    if _engine is not None:
        await _engine.dispose()
    _engine = None
    _session_factory = None
