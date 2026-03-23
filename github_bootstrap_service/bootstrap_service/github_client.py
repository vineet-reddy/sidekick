from __future__ import annotations

import base64
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
    visibility: str


@dataclass(frozen=True)
class GitHubCommitResult:
    sha: str
    html_url: str | None


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
        description: str,
    ) -> GitHubRepository:
        payload = self._request_json(
            method="POST",
            url=f"{self._config.github_api_base_url.rstrip('/')}/user/repos",
            access_token=access_token,
            body={
                "name": repo_name,
                "private": private,
                "auto_init": True,
                "description": description,
            },
        )
        return self._decode_repository(payload)

    def ensure_sidekick_repository(
        self,
        access_token: str,
        *,
        owner: str,
    ) -> GitHubRepository:
        repo_name = self._config.github_repo_name
        desired_private = self._config.github_repo_visibility != "public"
        existing = self.find_repository(access_token, owner=owner, repo_name=repo_name)
        if existing is None:
            return self.create_repository(
                access_token,
                repo_name=repo_name,
                private=desired_private,
                description=self._config.github_repo_description,
            )

        if desired_private is False and existing.visibility != "public":
            payload = self._request_json(
                method="PATCH",
                url=f"{self._config.github_api_base_url.rstrip('/')}/repos/{owner}/{repo_name}",
                access_token=access_token,
                body={"private": False},
            )
            return self._decode_repository(payload)

        return existing

    def commit_text_file(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
        path: str,
        content: str,
        message: str,
    ) -> GitHubCommitResult:
        return self._commit_file(
            access_token,
            owner=owner,
            repo_name=repo_name,
            path=path,
            raw_bytes=content.encode("utf-8"),
            message=message,
        )

    def commit_binary_file(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
        path: str,
        raw_bytes: bytes,
        message: str,
    ) -> GitHubCommitResult:
        return self._commit_file(
            access_token,
            owner=owner,
            repo_name=repo_name,
            path=path,
            raw_bytes=raw_bytes,
            message=message,
        )

    def _commit_file(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
        path: str,
        raw_bytes: bytes,
        message: str,
    ) -> GitHubCommitResult:
        existing_sha = self._existing_content_sha(
            access_token,
            owner=owner,
            repo_name=repo_name,
            path=path,
        )
        body: dict[str, Any] = {
            "message": message,
            "content": base64.b64encode(raw_bytes).decode("ascii"),
        }
        if existing_sha:
            body["sha"] = existing_sha

        payload = self._request_json(
            method="PUT",
            url=f"{self._config.github_api_base_url.rstrip('/')}/repos/{owner}/{repo_name}/contents/{path}",
            access_token=access_token,
            body=body,
        )
        commit = payload.get("commit")
        if not isinstance(commit, dict):
            raise GitHubClientError("GitHub did not return a commit payload.")
        sha = (commit.get("sha") or "").strip()
        html_url = (commit.get("html_url") or "").strip() or None
        if not sha:
            raise GitHubClientError("GitHub did not return a commit sha.")
        return GitHubCommitResult(sha=sha, html_url=html_url)

    def _existing_content_sha(
        self,
        access_token: str,
        *,
        owner: str,
        repo_name: str,
        path: str,
    ) -> str | None:
        try:
            payload = self._request_json(
                method="GET",
                url=f"{self._config.github_api_base_url.rstrip('/')}/repos/{owner}/{repo_name}/contents/{path}",
                access_token=access_token,
            )
        except GitHubClientError as error:
            if "HTTP 404" in str(error):
                return None
            raise
        sha = payload.get("sha")
        return str(sha).strip() if isinstance(sha, str) and sha.strip() else None

    def _decode_repository(self, payload: dict[str, Any]) -> GitHubRepository:
        repository_id = payload.get("id")
        name = (payload.get("name") or "").strip()
        full_name = (payload.get("full_name") or "").strip()
        default_branch = (payload.get("default_branch") or "main").strip() or "main"
        visibility = (payload.get("visibility") or "").strip().lower()
        private = payload.get("private")
        if not visibility:
            visibility = "private" if private else "public"
        if not isinstance(repository_id, int) or not name or not full_name:
            raise GitHubClientError("GitHub returned an incomplete repository payload.")
        return GitHubRepository(
            repository_id=repository_id,
            name=name,
            full_name=full_name,
            html_url=(payload.get("html_url") or "").strip() or None,
            default_branch=default_branch,
            visibility=visibility,
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
            "X-GitHub-Api-Version": "2022-11-28",
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
