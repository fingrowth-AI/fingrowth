"""Sign in with Apple endpoint (V8-01).

The client performs Sign in with Apple on-device and posts the resulting Apple
identity token here. The backend verifies it, looks up or creates the user keyed
by the stable ``apple_sub``, and returns its own session token for subsequent
requests. No username/password is ever involved.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.services.apple_auth import AppleAuthError, verify_apple_identity_token
from app.services.session_token import issue_session_token
from app.services.users import get_or_create_user_by_apple_sub

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


class AppleSignInRequest(BaseModel):
    """Body for POST /auth/apple — the Apple-issued identity token (a JWT)."""

    identity_token: str = Field(..., min_length=1)


class AppleSignInResponse(BaseModel):
    """Session credentials the client uses on subsequent requests."""

    session_token: str
    user_id: str
    # True only on the very first sign-in for this Apple account.
    created: bool


@router.post("/apple", response_model=AppleSignInResponse)
async def sign_in_with_apple(
    body: AppleSignInRequest,
    session: AsyncSession = Depends(get_session),
) -> AppleSignInResponse:
    """Verify an Apple identity token and return a backend session token.

    Hidden-email relay accounts are first-class: verification keys off the
    stable ``sub``, not the email, so relay users sign in like anyone else.
    """
    try:
        identity = verify_apple_identity_token(body.identity_token)
    except AppleAuthError as exc:
        # Wrong signature, audience, issuer, or expiry all land here.
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    async with session.begin():
        resolved = await get_or_create_user_by_apple_sub(session, identity.apple_sub)

    token = issue_session_token(resolved.user.id)
    return AppleSignInResponse(
        session_token=token,
        user_id=str(resolved.user.id),
        created=resolved.created,
    )
