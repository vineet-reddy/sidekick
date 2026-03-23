from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .config import BootstrapServiceConfig


class GitHubClientError(RuntimeError):
    pass


@dataclass(frozen=True)
class GitHubUser:
    login: str
    account_id: int


@dataclass(frozen=True)
class GitHubRepository:
    repository_id: int
    name: str
    full_name: str
    html_url: str | None
    default_branch: str


class GitHubClient:
    def __init__(self, config: BootstrapServiceConfig):
        self._config = config

    def build_user_authorization_url(self, state: str) -> str:
        query = urlencode(
            {
                "client_id": self._config.github_client_id,
                "redirect_uri": self._config.callback_url,
                "scope": self._config.github_oauth_scope,
                "state": state,
            }
        )
        return f"{self._config.github_web_base_url.rstrip('/')}/login/oauth/authorize?{query}"

    def exchange_code_for_user_token(self, code: str) -> str:
        payload = self._request_json(
            method="POST",
            url=f"{self._config.github_web_base_url.rstrip('/')}/login/oauth/access_token",
            body={
                "client_id": self._config.github_client_id,
                "client_secret": self._config.github_client_secret,
                "code": code,
                "redirect_uri": self._config.callback_url,
            },
            headers={"Accept": "application/json"},
        )
        token = (payload.get("access_token") or "").strip()
        if not token:
            raise GitHubClientError("GitHub did not return an access token.")
        return token

    def fetch_authenticated_user(self, access_token: str) -> GitHubUser:
        payload = self._request_json(
            method="GET",
            url=f"{self._config.github_api_base_url.rstrip('/')}/user",
            access_token=access_token,
        )
        login = (payload.get("login") or "").strip()
        account_id = payload.get("id")
        if not login or not isinstance(account_id, int):
            raise GitHubClientError("GitHub returned an incomplete user profile.")
        return GitHubUser(login=login, account_id=account_id)

    def find_repository(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
    ) -> GitHubRepository | None:
        try:
            payload = self._request_json(
                method="GET",
                url=f"{self._config.github_api_base_url.rstrip('/')}/repos/{owner}/{repo_name}",
                access_token=access_token,
            )
        except GitHubClientError as error:
            if "HTTP 404" in str(error):
                return None
            raise
        return self._decode_repository(payload)

    def create_repository(
        self,
        access_token: str,
        *,
        repo_name: str,
        private: bool,
        description: str | None = None,
    ) -> GitHubRepository:
        payload = self._request_json(
            method="POST",
            url=f"{self._config.github_api_base_url.rstrip('/')}/user/repos",
            access_token=access_token,
            body={
                "name": repo_name,
                "private": private,
                "auto_init": True,
                "description": description or "Sidekick Codex workspace",
            },
        )
        return self._decode_repository(payload)

    def create_repo_from_template(
        self,
        access_token: str,
        *,
        template_owner: str,
        template_repo: str,
        repo_name: str,
        private: bool,
        description: str | None = None,
    ) -> GitHubRepository:
        payload = self._request_json(
            method="POST",
            url=(
                f"{self._config.github_api_base_url.rstrip('/')}/repos/"
                f"{template_owner}/{template_repo}/generate"
            ),
            access_token=access_token,
            body={
                "name": repo_name,
                "private": private,
                "include_all_branches": False,
                "description": description or "Sidekick Codex workspace",
            },
        )
        return self._decode_repository(payload)

    def ensure_workspace_repository(
        self,
        access_token: str,
        *,
        owner: str,
    ) -> GitHubRepository:
        existing = self.find_repository(
            access_token,
            owner=owner,
            repo_name=self._config.github_bootstrap_workspace_repo_name,
        )
        if existing is not None:
            return existing

        if self._config.github_bootstrap_template_owner and self._config.github_bootstrap_template_repo:
            return self.create_repo_from_template(
                access_token,
                template_owner=self._config.github_bootstrap_template_owner,
                template_repo=self._config.github_bootstrap_template_repo,
                repo_name=self._config.github_bootstrap_workspace_repo_name,
                private=self._config.github_bootstrap_workspace_repo_private,
            )

        return self.create_repository(
            access_token,
            repo_name=self._config.github_bootstrap_workspace_repo_name,
            private=self._config.github_bootstrap_workspace_repo_private,
        )

    def protect_default_branch(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
        branch_name: str,
    ) -> None:
        if not self._config.github_bootstrap_protect_default_branch:
            return

        self._request_json(
            method="PUT",
            url=(
                f"{self._config.github_api_base_url.rstrip('/')}/repos/"
                f"{owner}/{repo_name}/branches/{branch_name}/protection"
            ),
            access_token=access_token,
            body={
                "required_status_checks": None,
                "enforce_admins": self._config.github_bootstrap_enforce_admins,
                "required_pull_request_reviews": (
                    {
                        "dismiss_stale_reviews": False,
                        "require_code_owner_reviews": False,
                        "required_approving_review_count": self._config.github_bootstrap_required_approving_review_count,
                    }
                    if self._config.github_bootstrap_require_pull_request_reviews
                    else None
                ),
                "restrictions": None,
                "required_linear_history": self._config.github_bootstrap_require_linear_history,
                "allow_force_pushes": self._config.github_bootstrap_allow_force_pushes,
                "allow_deletions": self._config.github_bootstrap_allow_deletions,
                "block_creations": False,
                "required_conversation_resolution": False,
                "lock_branch": False,
            },
        )

    def build_connector_install_url(
        self,
        *,
        github_account_id: int,
        repository_id: int,
    ) -> str:
        query = urlencode(
            [
                ("suggested_target_id", str(github_account_id)),
                ("repository_ids[]", str(repository_id)),
            ]
        )
        return (
            f"{self._config.github_web_base_url.rstrip('/')}/apps/"
            f"{self._config.github_bootstrap_connector_slug}/installations/new/permissions?{query}"
        )

    def build_connector_repair_url(
        self,
        *,
        github_account_id: int,
        repository_id: int,
    ) -> str:
        return self.build_connector_install_url(
            github_account_id=github_account_id,
            repository_id=repository_id,
        )

    def _decode_repository(self, payload: dict[str, Any]) -> GitHubRepository:
        repository_id = payload.get("id")
        name = (payload.get("name") or "").strip()
        full_name = (payload.get("full_name") or "").strip()
        default_branch = (payload.get("default_branch") or "main").strip() or "main"
        if not isinstance(repository_id, int) or not name or not full_name:
            raise GitHubClientError("GitHub returned an incomplete repository payload.")
        return GitHubRepository(
            repository_id=repository_id,
            name=name,
            full_name=full_name,
            html_url=(payload.get("html_url") or "").strip() or None,
            default_branch=default_branch,
        )

    def _request_json(
        self,
        *,
        method: str,
        url: str,
        access_token: str | None = None,
        body: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        request_headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            **(headers or {}),
        }
        if access_token:
            request_headers["Authorization"] = f"Bearer {access_token}"

        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"

        request = Request(url=url, data=data, headers=request_headers, method=method)

        try:
            with urlopen(request, timeout=30) as response:
                payload = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise GitHubClientError(f"GitHub request failed with HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise GitHubClientError(f"GitHub request failed: {error.reason}") from error

        if not payload:
            return {}

        try:
            decoded = json.loads(payload.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise GitHubClientError("GitHub returned invalid JSON.") from error

        if not isinstance(decoded, dict):
            raise GitHubClientError("GitHub returned an unexpected JSON payload.")

        return decoded
