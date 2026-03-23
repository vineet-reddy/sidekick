from __future__ import annotations

import os
from dataclasses import dataclass


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


@dataclass(frozen=True)
class BootstrapServiceConfig:
    github_client_id: str
    github_client_secret: str
    github_bootstrap_redirect_base_url: str
    github_oauth_scope: str = "repo read:user"
    github_api_base_url: str = "https://api.github.com"
    github_web_base_url: str = "https://github.com"
    github_bootstrap_workspace_repo_name: str = "sidekick-workspace"
    github_bootstrap_workspace_repo_private: bool = True
    github_bootstrap_template_owner: str | None = None
    github_bootstrap_template_repo: str | None = None
    github_bootstrap_protect_default_branch: bool = True
    github_bootstrap_require_pull_request_reviews: bool = True
    github_bootstrap_required_approving_review_count: int = 1
    github_bootstrap_require_linear_history: bool = True
    github_bootstrap_enforce_admins: bool = True
    github_bootstrap_allow_force_pushes: bool = False
    github_bootstrap_allow_deletions: bool = False
    github_bootstrap_connector_slug: str = "chatgpt-codex-connector"
    github_bootstrap_session_ttl_seconds: int = 3600

    @property
    def callback_url(self) -> str:
        base = self.github_bootstrap_redirect_base_url.rstrip("/")
        return f"{base}/browser/github-bootstrap/callback"

    @property
    def service_base_url(self) -> str:
        return self.github_bootstrap_redirect_base_url.rstrip("/")

    @classmethod
    def from_env(cls) -> "BootstrapServiceConfig":
        client_id = os.getenv("GITHUB_CLIENT_ID", "").strip()
        client_secret = os.getenv("GITHUB_CLIENT_SECRET", "").strip()
        redirect_base_url = os.getenv("GITHUB_BOOTSTRAP_REDIRECT_BASE_URL", "").strip()

        if not client_id:
            raise ValueError("Missing GITHUB_CLIENT_ID")
        if not client_secret:
            raise ValueError("Missing GITHUB_CLIENT_SECRET")
        if not redirect_base_url:
            raise ValueError("Missing GITHUB_BOOTSTRAP_REDIRECT_BASE_URL")

        return cls(
            github_client_id=client_id,
            github_client_secret=client_secret,
            github_bootstrap_redirect_base_url=redirect_base_url,
            github_oauth_scope=os.getenv("GITHUB_OAUTH_SCOPE", "repo read:user").strip() or "repo read:user",
            github_api_base_url=os.getenv("GITHUB_API_BASE_URL", "https://api.github.com").strip() or "https://api.github.com",
            github_web_base_url=os.getenv("GITHUB_WEB_BASE_URL", "https://github.com").strip() or "https://github.com",
            github_bootstrap_workspace_repo_name=os.getenv("GITHUB_BOOTSTRAP_WORKSPACE_REPO_NAME", "sidekick-workspace").strip() or "sidekick-workspace",
            github_bootstrap_workspace_repo_private=_bool_env("GITHUB_BOOTSTRAP_WORKSPACE_REPO_PRIVATE", True),
            github_bootstrap_template_owner=(os.getenv("GITHUB_BOOTSTRAP_TEMPLATE_OWNER") or "").strip() or None,
            github_bootstrap_template_repo=(os.getenv("GITHUB_BOOTSTRAP_TEMPLATE_REPO") or "").strip() or None,
            github_bootstrap_protect_default_branch=_bool_env("GITHUB_BOOTSTRAP_PROTECT_DEFAULT_BRANCH", True),
            github_bootstrap_require_pull_request_reviews=_bool_env("GITHUB_BOOTSTRAP_REQUIRE_PULL_REQUEST_REVIEWS", True),
            github_bootstrap_required_approving_review_count=_int_env("GITHUB_BOOTSTRAP_REQUIRED_APPROVING_REVIEW_COUNT", 1),
            github_bootstrap_require_linear_history=_bool_env("GITHUB_BOOTSTRAP_REQUIRE_LINEAR_HISTORY", True),
            github_bootstrap_enforce_admins=_bool_env("GITHUB_BOOTSTRAP_ENFORCE_ADMINS", True),
            github_bootstrap_allow_force_pushes=_bool_env("GITHUB_BOOTSTRAP_ALLOW_FORCE_PUSHES", False),
            github_bootstrap_allow_deletions=_bool_env("GITHUB_BOOTSTRAP_ALLOW_DELETIONS", False),
            github_bootstrap_connector_slug=os.getenv("GITHUB_BOOTSTRAP_CONNECTOR_SLUG", "chatgpt-codex-connector").strip() or "chatgpt-codex-connector",
            github_bootstrap_session_ttl_seconds=_int_env("GITHUB_BOOTSTRAP_SESSION_TTL_SECONDS", 3600),
        )
