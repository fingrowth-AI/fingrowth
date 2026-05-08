"""Tests for P1-02: Configuration Management."""
import pytest
from pydantic import ValidationError


def test_import_settings():
    """from app.config import settings must work."""
    from app.config import settings  # noqa: F401

    assert settings is not None


def test_default_database_url():
    from app.config import Settings

    s = Settings()
    assert "postgresql+asyncpg" in s.database_url


def test_default_redis_url():
    from app.config import Settings

    s = Settings()
    assert s.redis_url.startswith("redis://")


def test_alpaca_base_url_is_paper():
    from app.config import Settings

    s = Settings()
    assert "paper-api.alpaca.markets" in s.alpaca_base_url


def test_production_requires_openai_key(monkeypatch):
    """Missing OPENAI_API_KEY in production must raise ValidationError."""
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    from app.config import Settings

    with pytest.raises((ValidationError, ValueError)):
        Settings(app_env="production", openai_api_key="")


def test_production_with_openai_key_ok(monkeypatch):
    """Production mode is valid when OPENAI_API_KEY is set."""
    from app.config import Settings

    s = Settings(app_env="production", openai_api_key="sk-test-key")
    assert s.app_env == "production"
    assert s.openai_api_key == "sk-test-key"


def test_development_does_not_require_openai_key():
    """Development mode must not raise even without OPENAI_API_KEY."""
    from app.config import Settings

    s = Settings(app_env="development", openai_api_key="")
    assert s.app_env == "development"
