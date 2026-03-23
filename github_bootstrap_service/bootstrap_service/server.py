from __future__ import annotations

import json
import os
from dataclasses import asdict
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from .config import BootstrapServiceConfig
from .github_client import GitHubClient, GitHubClientError
from .store import BootstrapSessionStore, WorkspaceRecord, utc_now


class BootstrapServiceHTTPServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        request_handler_class: type[BaseHTTPRequestHandler],
        *,
        config: BootstrapServiceConfig,
        session_store: BootstrapSessionStore,
        github_client: GitHubClient,
    ):
        super().__init__(server_address, request_handler_class)
        self.config = config
        self.session_store = session_store
        self.github_client = github_client


class BootstrapServiceHandler(BaseHTTPRequestHandler):
    server: BootstrapServiceHTTPServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._send_json(HTTPStatus.OK, {"ok": True})
            return

        if parsed.path.startswith("/api/bootstrap/sessions/"):
            session_id = parsed.path.rsplit("/", 1)[-1]
            session = self.server.session_store.get_session(session_id)
            if session is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_session"})
                return
            self._send_json(HTTPStatus.OK, session.to_public_dict(self.server.config.service_base_url))
            return

        if parsed.path == "/bootstrap/start":
            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0].strip()
            session = self.server.session_store.get_session(session_id)
            if session is None:
                self._send_text(HTTPStatus.NOT_FOUND, "Unknown bootstrap session.")
                return

            self.server.session_store.update_status(session_id, status="redirected_to_github")
            self._redirect(self.server.github_client.build_user_authorization_url(session.state))
            return

        if parsed.path in {"/oauth/github/callback", "/browser/github-bootstrap/callback"}:
            self._handle_github_callback(parsed)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/api/bootstrap/sessions":
            payload = self._read_json_body()
            chatgpt_email = str(payload.get("chatgpt_email") or "").strip() or None
            session = self.server.session_store.create_session(chatgpt_email=chatgpt_email)
            self._send_json(HTTPStatus.CREATED, session.to_public_dict(self.server.config.service_base_url))
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _handle_github_callback(self, parsed_url: Any) -> None:
        query = parse_qs(parsed_url.query)
        state = (query.get("state") or [""])[0].strip()
        code = (query.get("code") or [""])[0].strip()
        oauth_error = (query.get("error") or [""])[0].strip()
        error_description = (query.get("error_description") or [""])[0].strip()

        session = self.server.session_store.get_session_for_state(state)
        if session is None:
            self._send_text(HTTPStatus.BAD_REQUEST, "Unknown or expired GitHub OAuth state.")
            return

        if oauth_error:
            message = error_description or oauth_error
            self.server.session_store.update_status(
                session.session_id,
                status="failed",
                error_message=message,
            )
            self._send_text(HTTPStatus.BAD_REQUEST, message)
            return

        if not code:
            self.server.session_store.update_status(
                session.session_id,
                status="failed",
                error_message="GitHub did not return an OAuth code.",
            )
            self._send_text(HTTPStatus.BAD_REQUEST, "GitHub did not return an OAuth code.")
            return

        try:
            access_token = self.server.github_client.exchange_code_for_user_token(code)
            user = self.server.github_client.fetch_authenticated_user(access_token)
            repo = self.server.github_client.ensure_workspace_repository(
                access_token,
                owner=user.login,
            )
            self.server.github_client.protect_default_branch(
                access_token,
                owner=user.login,
                repo_name=repo.name,
                branch_name=repo.default_branch,
            )
            connector_install_url = self.server.github_client.build_connector_install_url(
                github_account_id=user.account_id,
                repository_id=repo.repository_id,
            )
            connector_repair_url = self.server.github_client.build_connector_repair_url(
                github_account_id=user.account_id,
                repository_id=repo.repository_id,
            )
            timestamp = utc_now()
            workspace = WorkspaceRecord(
                github_login=user.login,
                github_account_id=user.account_id,
                repository_id=repo.repository_id,
                repository_name=repo.name,
                repository_full_name=repo.full_name,
                repository_html_url=repo.html_url,
                default_branch=repo.default_branch,
                connector_install_url=connector_install_url,
                connector_repair_url=connector_repair_url,
                bootstrap_session_id=session.session_id,
                install_launch_time=timestamp,
                provisioned_at=timestamp,
            )
            self.server.session_store.update_status(
                session.session_id,
                status="connector_install_launched",
                oauth_access_token=access_token,
                workspace=workspace,
            )
            self._redirect(connector_install_url)
        except GitHubClientError as error:
            self.server.session_store.update_status(
                session.session_id,
                status="failed",
                error_message=str(error),
            )
            self._send_text(HTTPStatus.BAD_GATEWAY, str(error))

    def _read_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length") or "0")
        if content_length <= 0:
            return {}
        raw_body = self.rfile.read(content_length)
        if not raw_body:
            return {}
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError:
            return {}
        if not isinstance(payload, dict):
            return {}
        return payload

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, status: HTTPStatus, text: str) -> None:
        body = text.encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location: str) -> None:
        self.send_response(HTTPStatus.FOUND.value)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()


def create_server(
    host: str,
    port: int,
    *,
    config: BootstrapServiceConfig | None = None,
    session_store: BootstrapSessionStore | None = None,
    github_client: GitHubClient | None = None,
) -> BootstrapServiceHTTPServer:
    resolved_config = config or BootstrapServiceConfig.from_env()
    resolved_store = session_store or BootstrapSessionStore(
        ttl_seconds=resolved_config.github_bootstrap_session_ttl_seconds
    )
    resolved_client = github_client or GitHubClient(resolved_config)
    return BootstrapServiceHTTPServer(
        (host, port),
        BootstrapServiceHandler,
        config=resolved_config,
        session_store=resolved_store,
        github_client=resolved_client,
    )


def main() -> None:
    config = BootstrapServiceConfig.from_env()
    host = os.getenv("HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int((os.getenv("PORT", "8787").strip() or "8787"))
    server = create_server(host, port, config=config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
