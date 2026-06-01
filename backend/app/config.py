from __future__ import annotations

from pathlib import Path

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Committed development default for the session-signing secret. Referenced by
# both the field default and the production validator so a deploy can never
# silently sign tokens with this publicly known value.
DEV_SESSION_SECRET = "dev-insecure-session-secret-change-me"
_MIN_SESSION_SECRET_LEN = 32

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
        "postgresql+asyncpg://postgres:postgres@localhost:5432/fingrowth"
    )

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # LLM provider
    openai_api_key: str = ""

    # Data sources
    alpha_vantage_api_key: str = ""
    finnhub_api_key: str = ""
    sec_edgar_user_agent: str = "FinGrowth/1.0 (research-tool)"

    # Per-user daily Alpha Vantage allocation (V8-05). The free tier is 25
    # calls/day on one shared key; this caps how many *uncached* calls a single
    # user may trigger per UTC day so one user can't starve the rest. Only real
    # upstream calls count — cache hits (incl. the shared SPY benchmark) are
    # free. Tune down as the user base grows, or raise it with a paid tier; a
    # value <= 0 disables the quota entirely.
    alpha_vantage_daily_quota_per_user: int = 25

    # Reject daily price data whose most-recent bar is older than this many
    # calendar days (V7-02). Sized to absorb weekends plus a long holiday
    # weekend so a normal market gap is tolerated, but genuinely stale data is
    # refused rather than presented as the current close.
    max_price_staleness_days: int = 5

    # Alpaca paper trading (paper-api only — never live endpoint)
    alpaca_api_key: str = ""
    alpaca_secret_key: str = ""
    alpaca_base_url: str = "https://paper-api.alpaca.markets"

    # Sign in with Apple (V8-01).
    # ``apple_client_id`` is the audience the Apple identity token must carry —
    # the app's bundle id. ``apple_issuer`` / ``apple_keys_url`` point at Apple.
    apple_client_id: str = "com.fingrowth.FinGrowth"
    apple_issuer: str = "https://appleid.apple.com"
    apple_keys_url: str = "https://appleid.apple.com/auth/keys"
    # Secret used to sign our own session tokens (HS256). MUST be overridden in
    # production — the validator below refuses to start with the dev default.
    session_jwt_secret: str = DEV_SESSION_SECRET
    session_issuer: str = "fingrowth"
    session_token_ttl_seconds: int = 60 * 60 * 24 * 30  # 30 days

    @model_validator(mode="after")
    def _require_production_secrets(self) -> "Settings":
        if self.app_env != "production":
            return self
        if not self.openai_api_key:
            raise ValueError("OPENAI_API_KEY is required when APP_ENV=production")
        # Session tokens are HS256-signed: a default/empty/weak secret lets
        # anyone forge a token for any user_id, so refuse to boot with one.
        if (
            self.session_jwt_secret in ("", DEV_SESSION_SECRET)
            or len(self.session_jwt_secret) < _MIN_SESSION_SECRET_LEN
        ):
            raise ValueError(
                "SESSION_JWT_SECRET must be set to a strong, non-default value "
                f"(>= {_MIN_SESSION_SECRET_LEN} chars) when APP_ENV=production"
            )
        return self


settings = Settings()
