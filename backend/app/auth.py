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

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.models.database import DEFAULT_USER_ID

# auto_error=False: the Bearer header is optional today, so a missing or
# malformed header must not 403 — it simply resolves to the default user. The
# scheme still advertises bearer auth in the OpenAPI docs.
bearer_scheme = HTTPBearer(
    auto_error=False,
    description="Bearer session token. Tolerated but not yet verified (V8).",
)


async def get_current_user(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None, Depends(bearer_scheme)
    ] = None,
) -> uuid.UUID:
    """Resolve the requesting user's id.

    The one place authentication is resolved. For now any Bearer token (or none)
    is tolerated and ignored, and the default user id is returned; V8 verifies
    the token here and maps it to a real user row.
    """
    # ``credentials`` is intentionally unused for now — accepted and tolerated.
    # V8 verifies credentials.credentials (the JWT) and resolves the user.
    del credentials
    return DEFAULT_USER_ID


# Annotated dependency alias so endpoints read as ``current_user: CurrentUser``.
CurrentUser = Annotated[uuid.UUID, Depends(get_current_user)]
