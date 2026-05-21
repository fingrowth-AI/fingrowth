"""Paper trading client (P2-05).

Wraps Alpaca's REST API at the paper-trading endpoint. Hard safety rule:
every call validates that ``settings.alpaca_base_url`` references the
``paper-api.alpaca.markets`` domain — if it doesn't, we raise
:class:`LiveEndpointError` *before* sending any request.

This module is intentionally minimal. It exposes only the three primitives
the design doc enumerates (place order, list positions, list orders). Bracket
orders, OCO/OTO, and trailing-stop variants are left to a follow-up.
"""

from __future__ import annotations

from urllib.parse import urlparse

import httpx

from app.config import settings
from app.models.trading import Order, Position

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PAPER_DOMAIN = "paper-api.alpaca.markets"
DEFAULT_TIMEOUT = httpx.Timeout(15.0, connect=10.0)
ALLOWED_SIDES = frozenset({"buy", "sell"})


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class PaperTradingError(Exception):
    """Base error for the paper trading client."""


class LiveEndpointError(PaperTradingError):
    """Refused to call a non-paper Alpaca endpoint.

    This is a safety guard, not a transport error: it fires before any
    network I/O if ``ALPACA_BASE_URL`` does not reference the paper domain.
    """


class MissingCredentialsError(PaperTradingError):
    """``ALPACA_API_KEY`` / ``ALPACA_SECRET_KEY`` are not configured."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _require_paper_endpoint() -> str:
    """Return the trimmed Alpaca base URL after asserting it's paper-only.

    Alpaca's docs are inconsistent about whether ``/v2`` belongs in the base
    URL or the path; we accept either by stripping a trailing ``/v2`` so our
    callers can always append ``/v2/<resource>``.

    The paper-only guard parses the URL and requires the host to be *exactly*
    the paper domain. A substring check would accept a hostile look-alike such
    as ``paper-api.alpaca.markets.evil.com`` or ``paper-api.alpaca.markets``
    embedded in a path/userinfo segment.
    """
    base = (settings.alpaca_base_url or "").rstrip("/")
    parsed = urlparse(base)
    if parsed.scheme not in ("http", "https") or parsed.hostname != PAPER_DOMAIN:
        raise LiveEndpointError(
            f"refusing to call non-paper endpoint: {base!r}; "
            f"ALPACA_BASE_URL host must be exactly {PAPER_DOMAIN}"
        )
    if base.endswith("/v2"):
        base = base[: -len("/v2")]
    return base


def _auth_headers() -> dict[str, str]:
    if not settings.alpaca_api_key or not settings.alpaca_secret_key:
        raise MissingCredentialsError(
            "ALPACA_API_KEY / ALPACA_SECRET_KEY are not configured"
        )
    return {
        "APCA-API-KEY-ID": settings.alpaca_api_key,
        "APCA-API-SECRET-KEY": settings.alpaca_secret_key,
        "Accept": "application/json",
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def place_paper_order(
    ticker: str,
    qty: float,
    side: str,
    *,
    order_type: str = "market",
    time_in_force: str = "day",
    client: httpx.AsyncClient | None = None,
) -> Order:
    """Place a paper order. Always paper — live endpoint will raise."""
    if side not in ALLOWED_SIDES:
        raise ValueError(f"side must be one of {sorted(ALLOWED_SIDES)}, got {side!r}")
    if qty <= 0:
        raise ValueError("qty must be > 0")
    base = _require_paper_endpoint()

    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        body = {
            "symbol": ticker.upper(),
            "qty": str(qty),
            "side": side,
            "type": order_type,
            "time_in_force": time_in_force,
        }
        resp = await client.post(
            f"{base}/v2/orders",
            json=body,
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        return Order.model_validate(resp.json())
    finally:
        if own_client:
            await client.aclose()


async def get_positions(
    *,
    client: httpx.AsyncClient | None = None,
) -> list[Position]:
    """Return the current paper positions list (empty when none held)."""
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        resp = await client.get(f"{base}/v2/positions", headers=_auth_headers())
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, list):
            return []
        return [Position.model_validate(p) for p in data]
    finally:
        if own_client:
            await client.aclose()


async def get_order_history(
    limit: int = 50,
    *,
    status: str = "all",
    client: httpx.AsyncClient | None = None,
) -> list[Order]:
    """Return the most recent ``limit`` orders.

    ``status`` follows Alpaca's filter (``open`` / ``closed`` / ``all``).
    """
    if limit <= 0:
        raise ValueError("limit must be > 0")
    base = _require_paper_endpoint()
    own_client = client is None
    client = client or httpx.AsyncClient(timeout=DEFAULT_TIMEOUT)
    try:
        params = {"limit": str(limit), "status": status}
        resp = await client.get(
            f"{base}/v2/orders",
            params=params,
            headers=_auth_headers(),
        )
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, list):
            return []
        return [Order.model_validate(o) for o in data]
    finally:
        if own_client:
            await client.aclose()
