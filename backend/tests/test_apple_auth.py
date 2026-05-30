"""Tests for V8-01 Apple identity-token verification.

A locally generated RSA keypair stands in for Apple's signing keys, with the
public key supplied via the injectable ``key_resolver`` so the verifier never
reaches Apple's network.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.config import settings
from app.services.apple_auth import AppleAuthError, verify_apple_identity_token


@pytest.fixture(scope="module")
def keypair():
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return private_key, private_key.public_key()


def _mint(private_key, **overrides) -> str:
    claims = {
        "iss": settings.apple_issuer,
        "aud": settings.apple_client_id,
        "sub": "000123.abcdef.0001",
        "exp": int((datetime.now(tz=UTC) + timedelta(minutes=10)).timestamp()),
        "iat": int(datetime.now(tz=UTC).timestamp()),
    }
    claims.update(overrides)
    return jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": "test"})


def test_valid_token_yields_apple_sub(keypair):
    private_key, public_key = keypair
    token = _mint(private_key, sub="000123.user.0001")

    identity = verify_apple_identity_token(token, key_resolver=lambda _t: public_key)

    assert identity.apple_sub == "000123.user.0001"


def test_relay_email_user_verifies(keypair):
    private_key, public_key = keypair
    token = _mint(
        private_key,
        email="abc123@privaterelay.appleid.com",
        email_verified="true",
        is_private_email="true",
    )

    identity = verify_apple_identity_token(token, key_resolver=lambda _t: public_key)

    assert identity.email == "abc123@privaterelay.appleid.com"
    assert identity.is_private_email is True
    assert identity.email_verified is True


def test_wrong_audience_is_rejected(keypair):
    private_key, public_key = keypair
    token = _mint(private_key, aud="com.someone.else")

    with pytest.raises(AppleAuthError):
        verify_apple_identity_token(token, key_resolver=lambda _t: public_key)


def test_wrong_issuer_is_rejected(keypair):
    private_key, public_key = keypair
    token = _mint(private_key, iss="https://evil.example.com")

    with pytest.raises(AppleAuthError):
        verify_apple_identity_token(token, key_resolver=lambda _t: public_key)


def test_bad_signature_is_rejected(keypair):
    private_key, _public_key = keypair
    # Sign with this key but verify against a *different* public key.
    other_public = rsa.generate_private_key(
        public_exponent=65537, key_size=2048
    ).public_key()
    token = _mint(private_key)

    with pytest.raises(AppleAuthError):
        verify_apple_identity_token(token, key_resolver=lambda _t: other_public)


def test_expired_token_is_rejected(keypair):
    private_key, public_key = keypair
    past = int((datetime.now(tz=UTC) - timedelta(hours=1)).timestamp())
    token = _mint(private_key, exp=past)

    with pytest.raises(AppleAuthError):
        verify_apple_identity_token(token, key_resolver=lambda _t: public_key)


def test_empty_token_is_rejected(keypair):
    _private_key, public_key = keypair
    with pytest.raises(AppleAuthError):
        verify_apple_identity_token("", key_resolver=lambda _t: public_key)


def test_key_resolver_failure_is_auth_error(keypair):
    private_key, _public_key = keypair
    token = _mint(private_key)

    def _boom(_token):
        raise RuntimeError("JWKS unreachable")

    with pytest.raises(AppleAuthError):
        verify_apple_identity_token(token, key_resolver=_boom)
