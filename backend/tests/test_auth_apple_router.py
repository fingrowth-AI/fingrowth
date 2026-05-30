"""Tests for V8-01 POST /api/v1/auth/apple.

Apple-token verification is exercised in test_apple_auth.py; here we patch the
verifier (as the router imported it) and focus on the endpoint contract:
first-sign-in creation, returning-sign-in resolution, rejection, relay users,
and that the issued session token is accepted on subsequent calls.

Needs a live PostgreSQL (the upsert writes a real row); skipped otherwise.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.security import HTTPAuthorizationCredentials
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, text

from app.auth import get_current_user
from app.db import dispose_engine, get_session_factory
from app.main import app
from app.models.database import User
from app.routers import auth as auth_module
from app.services.apple_auth import AppleAuthError, AppleIdentity

BASE = "http://test"


@pytest.fixture(autouse=True)
async def _fresh_engine():
    """A cached async engine is bound to one event loop; pytest-asyncio gives
    each test its own loop, so reset the global engine around every test."""
    await dispose_engine()
    yield
    await dispose_engine()


async def _db_reachable() -> bool:
    try:
        async with get_session_factory()() as session:
            await session.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


@pytest.fixture
async def client():
    if not await _db_reachable():
        pytest.skip("PostgreSQL not reachable — skipping auth router integration test")
    async with AsyncClient(transport=ASGITransport(app=app), base_url=BASE) as c:
        yield c


@pytest.fixture
async def cleanup_subs():
    """Delete any users created for the apple_subs a test registers."""
    subs: list[str] = []
    yield subs
    async with get_session_factory()() as session:
        async with session.begin():
            for sub in subs:
                await session.execute(delete(User).where(User.apple_sub == sub))


def _patch_verifier(monkeypatch, identity: AppleIdentity):
    monkeypatch.setattr(
        auth_module, "verify_apple_identity_token", lambda *a, **k: identity
    )


@pytest.mark.asyncio
async def test_first_sign_in_creates_user(monkeypatch, client, cleanup_subs):
    sub = f"first.{uuid.uuid4()}"
    cleanup_subs.append(sub)
    _patch_verifier(monkeypatch, AppleIdentity(apple_sub=sub))

    resp = await client.post("/api/v1/auth/apple", json={"identity_token": "x"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["created"] is True
    assert body["session_token"]
    # The new user id is a real UUID.
    uuid.UUID(body["user_id"])


@pytest.mark.asyncio
async def test_returning_sign_in_resolves_same_user(monkeypatch, client, cleanup_subs):
    sub = f"return.{uuid.uuid4()}"
    cleanup_subs.append(sub)
    _patch_verifier(monkeypatch, AppleIdentity(apple_sub=sub))

    first = (await client.post("/api/v1/auth/apple", json={"identity_token": "x"})).json()
    second = (await client.post("/api/v1/auth/apple", json={"identity_token": "x"})).json()

    assert first["created"] is True
    assert second["created"] is False
    assert first["user_id"] == second["user_id"]


@pytest.mark.asyncio
async def test_invalid_token_returns_401(monkeypatch, client):
    def _raise(*_a, **_k):
        raise AppleAuthError("bad audience")

    monkeypatch.setattr(auth_module, "verify_apple_identity_token", _raise)

    resp = await client.post("/api/v1/auth/apple", json={"identity_token": "bad"})

    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_relay_email_user_signs_in(monkeypatch, client, cleanup_subs):
    sub = f"relay.{uuid.uuid4()}"
    cleanup_subs.append(sub)
    _patch_verifier(
        monkeypatch,
        AppleIdentity(
            apple_sub=sub,
            email="abc@privaterelay.appleid.com",
            is_private_email=True,
            email_verified=True,
        ),
    )

    resp = await client.post("/api/v1/auth/apple", json={"identity_token": "x"})

    assert resp.status_code == 200
    assert resp.json()["created"] is True


@pytest.mark.asyncio
async def test_issued_token_is_accepted_on_subsequent_calls(
    monkeypatch, client, cleanup_subs
):
    sub = f"accept.{uuid.uuid4()}"
    cleanup_subs.append(sub)
    _patch_verifier(monkeypatch, AppleIdentity(apple_sub=sub))

    body = (await client.post("/api/v1/auth/apple", json={"identity_token": "x"})).json()
    token = body["session_token"]

    # get_current_user resolves the same user from the issued session token.
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)
    resolved = await get_current_user(creds)
    assert str(resolved) == body["user_id"]
