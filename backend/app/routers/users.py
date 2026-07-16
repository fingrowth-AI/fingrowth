"""Account management endpoints.

Currently one endpoint: ``DELETE /users/me``, which permanently and irreversibly
deletes the authenticated user's account together with every row that references
it. App Store Review Guideline 5.1.1(v) requires apps that support account
creation (Sign in with Apple, here) to offer in-app account deletion.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import AuthenticatedUser
from app.db import get_session
from app.models.database import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/users", tags=["users"])


@router.delete(
    "/me",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        401: {"description": "Missing or invalid session token."},
        404: {"description": "The account no longer exists."},
    },
)
async def delete_current_user(
    current_user: AuthenticatedUser,
    session: AsyncSession = Depends(get_session),
) -> Response:
    """Permanently delete the authenticated user and all of their data.

    Deleting the ``users`` row is sufficient: every per-user foreign key is
    declared ``ON DELETE CASCADE`` (migrations 0002 and 0003), so the database
    removes the dependent rows in ``analysis_sessions``, ``analysis_results``,
    ``vector_embeddings`` and ``virtual_balances`` atomically as part of the same
    transaction. There is no partial-delete state to leave behind.

    Returns ``204 No Content`` on success and ``404`` if the account is already
    gone — a still-cryptographically-valid session token for a deleted account
    no longer grants access to it.

    TODO(prod): Apple requires apps that use Sign in with Apple to also revoke
    the user's Apple token on account deletion via Apple's token-revocation
    endpoint (POST https://appleid.apple.com/auth/revoke) using the stored
    refresh token. We persist only the stable ``apple_sub`` today, not a refresh
    token, so there is nothing to revoke yet; wire this call in once refresh
    tokens are stored.
    """
    async with session.begin():
        result = await session.execute(
            delete(User).where(User.id == current_user)
        )

    if result.rowcount == 0:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Account not found.",
        )

    logger.info("Deleted user account %s and all dependent data.", current_user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
