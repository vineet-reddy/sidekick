from __future__ import annotations

import secrets
import threading
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any


def utc_now() -> datetime:
    return datetime.now(tz=UTC)


@dataclass
class WorkspaceRecord:
    github_login: str
    github_account_id: int
    repository_id: int
    repository_name: str
    repository_full_name: str
    repository_html_url: str | None
    default_branch: str
    connector_install_url: str
    connector_repair_url: str
    bootstrap_session_id: str
    install_launch_time: datetime
    provisioned_at: datetime

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["install_launch_time"] = self.install_launch_time.isoformat()
        payload["provisioned_at"] = self.provisioned_at.isoformat()
        return payload


@dataclass
class BootstrapSession:
    session_id: str
    state: str
    created_at: datetime
    updated_at: datetime
    expires_at: datetime
    status: str = "created"
    chatgpt_email: str | None = None
    error_message: str | None = None
    workspace: WorkspaceRecord | None = None
    oauth_access_token: str | None = None

    def to_public_dict(self, service_base_url: str) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "session_id": self.session_id,
            "status": self.status,
            "chatgpt_email": self.chatgpt_email,
            "error_message": self.error_message,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "expires_at": self.expires_at.isoformat(),
            "start_url": f"{service_base_url}/bootstrap/start?session_id={self.session_id}",
            "status_url": f"{service_base_url}/api/bootstrap/sessions/{self.session_id}",
        }
        if self.workspace is not None:
            payload["workspace"] = self.workspace.to_dict()
        return payload


class BootstrapSessionStore:
    def __init__(self, ttl_seconds: int = 3600):
        self._ttl = timedelta(seconds=ttl_seconds)
        self._lock = threading.Lock()
        self._sessions: dict[str, BootstrapSession] = {}
        self._sessions_by_state: dict[str, str] = {}

    def create_session(self, chatgpt_email: str | None = None) -> BootstrapSession:
        now = utc_now()
        session = BootstrapSession(
            session_id=secrets.token_urlsafe(18),
            state=secrets.token_urlsafe(24),
            created_at=now,
            updated_at=now,
            expires_at=now + self._ttl,
            chatgpt_email=chatgpt_email,
        )
        with self._lock:
            self._purge_locked(now)
            self._sessions[session.session_id] = session
            self._sessions_by_state[session.state] = session.session_id
        return session

    def get_session(self, session_id: str) -> BootstrapSession | None:
        now = utc_now()
        with self._lock:
            self._purge_locked(now)
            return self._sessions.get(session_id)

    def get_session_for_state(self, state: str) -> BootstrapSession | None:
        now = utc_now()
        with self._lock:
            self._purge_locked(now)
            session_id = self._sessions_by_state.get(state)
            if session_id is None:
                return None
            return self._sessions.get(session_id)

    def update_status(
        self,
        session_id: str,
        *,
        status: str,
        error_message: str | None = None,
        oauth_access_token: str | None = None,
        workspace: WorkspaceRecord | None = None,
    ) -> BootstrapSession | None:
        now = utc_now()
        with self._lock:
            self._purge_locked(now)
            session = self._sessions.get(session_id)
            if session is None:
                return None

            session.status = status
            session.updated_at = now
            session.error_message = error_message
            if oauth_access_token is not None:
                session.oauth_access_token = oauth_access_token
            if workspace is not None:
                session.workspace = workspace
            return session

    def _purge_locked(self, now: datetime) -> None:
        expired_ids = [
            session_id
            for session_id, session in self._sessions.items()
            if session.expires_at <= now
        ]
        for session_id in expired_ids:
            session = self._sessions.pop(session_id, None)
            if session is not None:
                self._sessions_by_state.pop(session.state, None)
