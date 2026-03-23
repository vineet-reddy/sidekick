from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _bool_env(name: str, default: bool) -> bool:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def _int_env(name: str, default: int) -> int:
    raw_value = os.getenv(name)
    if raw_value is None or not raw_value.strip():
        return default
    return int(raw_value.strip())


def _float_env(name: str, default: float) -> float:
    raw_value = os.getenv(name)
    if raw_value is None or not raw_value.strip():
        return default
    return float(raw_value.strip())


@dataclass(frozen=True)
class BootstrapServiceConfig:
    github_client_id: str
    github_client_secret: str
    backend_base_url: str
    openai_api_key: str
    github_oauth_scope: str = "public_repo read:user"
    github_api_base_url: str = "https://api.github.com"
    github_web_base_url: str = "https://github.com"
    github_repo_name: str = "sidekick"
    github_repo_description: str = "Reproducible research artifacts published by Sidekick."
    github_repo_visibility: str = "public"
    github_connect_session_ttl_seconds: int = 3600
    backend_database_path: str = ".sidekick-runtime/backend.sqlite3"
    backend_artifact_root: str = ".sidekick-runtime/paper-artifacts"
    backend_kill_switch: bool = False
    backend_max_daily_spend_usd: float = 25.0
    backend_max_jobs_per_install_per_day: int = 8
    backend_max_job_runtime_seconds: int = 1800
    backend_max_concurrent_jobs_per_install: int = 1
    backend_artifact_ttl_seconds: int = 24 * 60 * 60
    openai_model: str = "gpt-5-mini"
    openai_base_url: str = "https://api.openai.com/v1"
    openai_estimated_input_cost_per_million: float = 0.25
    openai_estimated_output_cost_per_million: float = 2.0
    encryption_secret: str = "sidekick-dev-secret"

    @property
    def callback_url(self) -> str:
        return f"{self.service_base_url}/browser/github-bootstrap/callback"

    @property
    def service_base_url(self) -> str:
        return self.backend_base_url.rstrip("/")

    @property
    def database_path(self) -> Path:
        return Path(self.backend_database_path).expanduser().resolve()

    @property
    def artifact_root(self) -> Path:
        return Path(self.backend_artifact_root).expanduser().resolve()

    @classmethod
    def from_env(cls) -> "BootstrapServiceConfig":
        client_id = os.getenv("GITHUB_CLIENT_ID", "").strip()
        client_secret = os.getenv("GITHUB_CLIENT_SECRET", "").strip()
        backend_base_url = (
            os.getenv("SIDEKICK_BACKEND_BASE_URL")
            or os.getenv("GITHUB_BOOTSTRAP_REDIRECT_BASE_URL")
            or ""
        ).strip()
        openai_api_key = os.getenv("OPENAI_API_KEY", "").strip()

        if not client_id:
            raise ValueError("Missing GITHUB_CLIENT_ID")
        if not client_secret:
            raise ValueError("Missing GITHUB_CLIENT_SECRET")
        if not backend_base_url:
            raise ValueError("Missing SIDEKICK_BACKEND_BASE_URL")
        if not openai_api_key:
            raise ValueError("Missing OPENAI_API_KEY")

        return cls(
            github_client_id=client_id,
            github_client_secret=client_secret,
            backend_base_url=backend_base_url,
            openai_api_key=openai_api_key,
            github_oauth_scope=os.getenv("GITHUB_OAUTH_SCOPE", "public_repo read:user").strip() or "public_repo read:user",
            github_api_base_url=os.getenv("GITHUB_API_BASE_URL", "https://api.github.com").strip() or "https://api.github.com",
            github_web_base_url=os.getenv("GITHUB_WEB_BASE_URL", "https://github.com").strip() or "https://github.com",
            github_repo_name=os.getenv("SIDEKICK_GITHUB_REPO_NAME", "sidekick").strip() or "sidekick",
            github_repo_description=os.getenv(
                "SIDEKICK_GITHUB_REPO_DESCRIPTION",
                "Reproducible research artifacts published by Sidekick.",
            ).strip()
            or "Reproducible research artifacts published by Sidekick.",
            github_repo_visibility=(os.getenv("SIDEKICK_GITHUB_REPO_VISIBILITY", "public").strip() or "public").lower(),
            github_connect_session_ttl_seconds=_int_env("SIDEKICK_GITHUB_CONNECT_SESSION_TTL_SECONDS", 3600),
            backend_database_path=os.getenv("SIDEKICK_BACKEND_DATABASE_PATH", ".sidekick-runtime/backend.sqlite3").strip()
            or ".sidekick-runtime/backend.sqlite3",
            backend_artifact_root=os.getenv("SIDEKICK_BACKEND_ARTIFACT_ROOT", ".sidekick-runtime/paper-artifacts").strip()
            or ".sidekick-runtime/paper-artifacts",
            backend_kill_switch=_bool_env("SIDEKICK_BACKEND_KILL_SWITCH", False),
            backend_max_daily_spend_usd=_float_env("SIDEKICK_BACKEND_MAX_DAILY_SPEND_USD", 25.0),
            backend_max_jobs_per_install_per_day=_int_env("SIDEKICK_BACKEND_MAX_JOBS_PER_INSTALL_PER_DAY", 8),
            backend_max_job_runtime_seconds=_int_env("SIDEKICK_BACKEND_MAX_JOB_RUNTIME_SECONDS", 1800),
            backend_max_concurrent_jobs_per_install=_int_env("SIDEKICK_BACKEND_MAX_CONCURRENT_JOBS_PER_INSTALL", 1),
            backend_artifact_ttl_seconds=_int_env("SIDEKICK_BACKEND_ARTIFACT_TTL_SECONDS", 24 * 60 * 60),
            openai_model=os.getenv("SIDEKICK_OPENAI_MODEL", "gpt-5-mini").strip() or "gpt-5-mini",
            openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip() or "https://api.openai.com/v1",
            openai_estimated_input_cost_per_million=_float_env(
                "SIDEKICK_OPENAI_INPUT_COST_PER_MILLION",
                0.25,
            ),
            openai_estimated_output_cost_per_million=_float_env(
                "SIDEKICK_OPENAI_OUTPUT_COST_PER_MILLION",
                2.0,
            ),
            encryption_secret=os.getenv("SIDEKICK_ENCRYPTION_SECRET", "sidekick-dev-secret").strip()
            or "sidekick-dev-secret",
        )
