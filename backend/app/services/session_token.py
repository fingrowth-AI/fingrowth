"""Session tokens (V8-01).

After a user proves their identity via Sign in with Apple, the backend issues
its *own* short-ish-lived bearer token — an HS256 JWT carrying the user id —
which the client sends on every subsequent request. This keeps Apple out of the
hot path: we verify Apple's token once, then trust our own signed token.

Verification is deliberately total (never raises): an absent, malformed, or
expired token resolves to ``None`` so :func:`app.auth.get_current_user` can fall
back to the default user rather than 500-ing the request.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import jwt

from app.config import settings

_ALGORITHM = "HS256"


def issue_session_token(
    user_id: uuid.UUID,
    *,
    now: datetime | None = None,
) -> str:
    """Sign a session token attributing subsequent requests to ``user_id``."""
    issued_at = now or datetime.now(tz=UTC)
    expires_at = issued_at + timedelta(seconds=settings.session_token_ttl_seconds)
    payload = {
        "sub": str(user_id),
        "iss": settings.session_issuer,
        "iat": int(issued_at.timestamp()),
        "exp": int(expires_at.timestamp()),
    }
    return jwt.encode(payload, settings.session_jwt_secret, algorithm=_ALGORITHM)


def verify_session_token(token: str | None) -> uuid.UUID | None:
    """Return the token's user id, or ``None`` if it is missing/invalid/expired.

    Total by design — callers treat ``None`` as "not authenticated" and fall
    back to the default user rather than rejecting the request.
    """
    if not token:
        return None
    try:
        payload = jwt.decode(
            token,
            settings.session_jwt_secret,
            algorithms=[_ALGORITHM],
            issuer=settings.session_issuer,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.InvalidTokenError:
        return None
    try:
        return uuid.UUID(str(payload["sub"]))
    except (KeyError, ValueError):
        return None
