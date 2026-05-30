"""Sign in with Apple identity-token verification (V8-01).

Apple issues the client an RS256-signed identity token (a JWT). The backend
verifies it before trusting any claim:

  * signature — against Apple's published public keys (JWKS), matched by ``kid``
  * ``iss``   — must be ``https://appleid.apple.com``
  * ``aud``   — must be our app's client id (bundle id); a token minted for a
                different app is rejected
  * ``exp``   — not expired

On success the stable subject identifier (``sub`` → ``apple_sub``) and the
optional relay/real email are returned. The signing-key lookup is injectable so
tests can verify a locally minted token without reaching Apple's network.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import jwt

from app.config import settings

# A key resolver turns the raw token into the key its header's ``kid`` selects.
# Default uses Apple's JWKS; tests inject a resolver returning a known key.
KeyResolver = Callable[[str], Any]

_ALGORITHMS = ["RS256"]


class AppleAuthError(Exception):
    """The Apple identity token failed verification."""


@dataclass(frozen=True)
class AppleIdentity:
    """The trusted claims extracted from a verified Apple identity token."""

    apple_sub: str
    email: str | None = None
    email_verified: bool = False
    is_private_email: bool = False


def _apple_jwks_resolver(token: str) -> Any:
    """Resolve the signing key from Apple's JWKS for this token's ``kid``."""
    client = jwt.PyJWKClient(settings.apple_keys_url)
    return client.get_signing_key_from_jwt(token).key


def _coerce_bool(value: Any) -> bool:
    # Apple sends these flags as the JSON strings "true"/"false" (or bools).
    if isinstance(value, bool):
        return value
    return str(value).lower() == "true"


def verify_apple_identity_token(
    token: str,
    *,
    key_resolver: KeyResolver | None = None,
    audience: str | None = None,
) -> AppleIdentity:
    """Verify ``token`` and return its trusted claims.

    Raises :class:`AppleAuthError` for any failure — bad signature, wrong
    audience, wrong issuer, expiry, or a missing subject.
    """
    if not token:
        raise AppleAuthError("missing identity token")

    resolver = key_resolver or _apple_jwks_resolver
    expected_audience = audience or settings.apple_client_id

    try:
        key = resolver(token)
    except Exception as exc:  # noqa: BLE00 — any resolver failure is an auth failure
        raise AppleAuthError(f"could not resolve signing key: {exc}") from exc

    try:
        claims: dict[str, Any] = jwt.decode(
            token,
            key,
            algorithms=_ALGORITHMS,
            audience=expected_audience,
            issuer=settings.apple_issuer,
            options={"require": ["exp", "iss", "sub", "aud"]},
        )
    except jwt.InvalidTokenError as exc:
        raise AppleAuthError(f"invalid Apple identity token: {exc}") from exc

    apple_sub = str(claims.get("sub") or "")
    if not apple_sub:
        raise AppleAuthError("Apple identity token has no subject")

    email = claims.get("email")
    return AppleIdentity(
        apple_sub=apple_sub,
        email=str(email) if email else None,
        email_verified=_coerce_bool(claims.get("email_verified")),
        is_private_email=_coerce_bool(claims.get("is_private_email")),
    )
