"""Shared fixtures + skip-helpers for live integration tests.

These tests hit real APIs. They're excluded from the default suite via
``addopts = "--ignore=tests/integration"`` in pyproject.toml. Run with::

    PYTHONPATH=. .venv/bin/pytest tests/integration/ -m integration -v
"""

from __future__ import annotations

import pytest

from app.config import settings


def needs_finnhub() -> pytest.MarkDecorator:
    return pytest.mark.skipif(
        not settings.finnhub_api_key,
        reason="FINNHUB_API_KEY not configured",
    )


def needs_alpaca() -> pytest.MarkDecorator:
    return pytest.mark.skipif(
        not (settings.alpaca_api_key and settings.alpaca_secret_key),
        reason="ALPACA_API_KEY / ALPACA_SECRET_KEY not configured",
    )


def needs_alpha_vantage() -> pytest.MarkDecorator:
    """Alpha Vantage's free tier is 25 calls/day — gate carefully."""
    return pytest.mark.skipif(
        not settings.alpha_vantage_api_key,
        reason="ALPHA_VANTAGE_API_KEY not configured",
    )


def needs_realistic_sec_user_agent() -> pytest.MarkDecorator:
    """SEC EDGAR's fair-access policy can reject placeholder user-agents."""
    ua = settings.sec_edgar_user_agent
    placeholder = "your@email.com" in ua or ua.startswith("YourApp")
    return pytest.mark.skipif(
        placeholder,
        reason=(
            "SEC_EDGAR_USER_AGENT is the placeholder; set a real "
            "'AppName/1.0 (you@example.com)' string to run live SEC tests"
        ),
    )
