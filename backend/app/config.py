from __future__ import annotations

from pathlib import Path

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Resolve env-file paths against this file's location so they work regardless
# of where Python is invoked from (pytest in backend/, docker-compose in repo
# root, IDE runners with arbitrary cwd).
_BACKEND_DIR = Path(__file__).resolve().parent.parent
_REPO_ROOT = _BACKEND_DIR.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        # Tuple is processed in increasing-precedence order: root .env loads
        # first, backend/.env (if present) overrides for backend-only tweaks.
        env_file=(_REPO_ROOT / ".env", _BACKEND_DIR / ".env"),
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Environment
    app_env: str = "development"

    # Database
    database_url: str = (
        "postgresql+asyncpg://postgres:postgres@localhost:5432/investmentstrategist"
    )

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # LLM providers
    openai_api_key: str = ""
    anthropic_api_key: str = ""

    # Data sources
    alpha_vantage_api_key: str = ""
    finnhub_api_key: str = ""
    sec_edgar_user_agent: str = "AIInvestmentStrategist/1.0 (research-tool)"

    # Alpaca paper trading (paper-api only — never live endpoint)
    alpaca_api_key: str = ""
    alpaca_secret_key: str = ""
    alpaca_base_url: str = "https://paper-api.alpaca.markets"

    @model_validator(mode="after")
    def _require_openai_in_production(self) -> "Settings":
        if self.app_env == "production" and not self.openai_api_key:
            raise ValueError(
                "OPENAI_API_KEY is required when APP_ENV=production"
            )
        return self


settings = Settings()
