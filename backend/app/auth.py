"""Authentication contract (V7-05).

A single resolution point — :func:`get_current_user` — turns an incoming
``Authorization: Bearer`` header into the user that owns the request. Every
``/api/v1`` endpoint depends on it, so the header is accepted and tolerated
everywhere, but it is not yet verified: until Sign in with Apple lands (V8)
every request resolves to the hardcoded default user (see
:data:`app.models.database.DEFAULT_USER_ID`).

V8 fills the body of :func:`get_current_user` — verify the Apple-issued JWT,
look up or create the user row — without touching a single call site, because
the call sites already depend on it. This is the auth-shaped hole that makes
V8 a fill rather than a migration.
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.models.database import DEFAULT_USER_ID
from app.services.session_token import verify_session_token

# auto_error=False: the Bearer header is optional, so a missing or malformed
# header must not 403 — it resolves to the default user. The scheme still
# advertises bearer auth in the OpenAPI docs.
bearer_scheme = HTTPBearer(
    auto_error=False,
    description="Bearer session token from POST /auth/apple.",
)


async def get_current_user(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> uuid.UUID:
    """Resolve the requesting user's id from the Bearer session token (V8-01).

    The one place authentication is resolved. A valid session token (issued by
    POST /auth/apple) resolves to its user; anything else — no header, the
    pre-sign-in placeholder, an expired or forged token — falls back to the
    default user. The fallback is safe: an unverifiable token can never resolve
    to *another* user, only to the shared default, so it grants no escalation.
    """
    token = credentials.credentials if credentials is not None else None
    return verify_session_token(token) or DEFAULT_USER_ID


# Annotated dependency alias so endpoints read as ``current_user: CurrentUser``.
CurrentUser = Annotated[uuid.UUID, Depends(get_current_user)]


async def get_authenticated_user(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> uuid.UUID:
    """Resolve the requesting user, *requiring* a valid session token.

    Same token verification as :func:`get_current_user` — the identical bearer
    scheme and :func:`verify_session_token`, not a new auth path — but the safe
    fallback to the default user is deliberately withheld. Destructive,
    account-scoped operations (e.g. account deletion, 5.1.1(v)) must never
    silently resolve a missing, forged, or expired token to the shared default
    user and act on *their* data. A token that does not verify raises 401.
    """
    token = credentials.credentials if credentials is not None else None
    user_id = verify_session_token(token)
    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="A valid session token is required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user_id


# Annotated alias for endpoints that must reject unauthenticated requests.
AuthenticatedUser = Annotated[uuid.UUID, Depends(get_authenticated_user)]
