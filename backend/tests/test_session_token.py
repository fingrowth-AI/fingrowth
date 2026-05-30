"""Tests for V8-01 session tokens (issue/verify our own HS256 JWT)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest

from app.config import settings
from app.services.session_token import issue_session_token, verify_session_token


def test_issue_then_verify_round_trips():
    user_id = uuid.uuid4()
    token = issue_session_token(user_id)
    assert verify_session_token(token) == user_id


def test_missing_or_garbage_token_returns_none():
    assert verify_session_token(None) is None
    assert verify_session_token("") is None
    assert verify_session_token("not-a-jwt") is None


def test_expired_token_returns_none():
    user_id = uuid.uuid4()
    long_ago = datetime.now(tz=UTC) - timedelta(days=400)
    token = issue_session_token(user_id, now=long_ago)
    assert verify_session_token(token) is None


def test_token_signed_with_wrong_secret_returns_none():
    user_id = uuid.uuid4()
    forged = jwt.encode(
        {
            "sub": str(user_id),
            "iss": settings.session_issuer,
            "iat": int(datetime.now(tz=UTC).timestamp()),
            "exp": int((datetime.now(tz=UTC) + timedelta(days=1)).timestamp()),
        },
        "the-wrong-secret",
        algorithm="HS256",
    )
    assert verify_session_token(forged) is None


def test_token_with_wrong_issuer_returns_none(monkeypatch):
    user_id = uuid.uuid4()
    token = jwt.encode(
        {
            "sub": str(user_id),
            "iss": "somebody-else",
            "iat": int(datetime.now(tz=UTC).timestamp()),
            "exp": int((datetime.now(tz=UTC) + timedelta(days=1)).timestamp()),
        },
        settings.session_jwt_secret,
        algorithm="HS256",
    )
    assert verify_session_token(token) is None


@pytest.mark.parametrize("ttl", [60, 3600, 86400])
def test_ttl_is_honored(monkeypatch, ttl):
    monkeypatch.setattr(settings, "session_token_ttl_seconds", ttl)
    user_id = uuid.uuid4()
    now = datetime.now(tz=UTC)
    token = issue_session_token(user_id, now=now)
    payload = jwt.decode(
        token, settings.session_jwt_secret, algorithms=["HS256"],
        issuer=settings.session_issuer,
    )
    assert payload["exp"] - payload["iat"] == ttl
