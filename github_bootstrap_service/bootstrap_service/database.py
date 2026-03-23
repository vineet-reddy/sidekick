from __future__ import annotations

import json
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Iterator

from .config import BootstrapServiceConfig


def utc_now() -> datetime:
    return datetime.now(tz=UTC)


def iso_now() -> str:
    return utc_now().isoformat()


@dataclass(frozen=True)
class JobClaim:
    job_id: str
    install_session_id: str


class SidekickDatabase:
    def __init__(self, config: BootstrapServiceConfig):
        self._config = config
        self._lock = threading.RLock()
        self._path = config.database_path
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self._path, check_same_thread=False)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            yield connection
            connection.commit()
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS install_sessions (
                    id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL UNIQUE,
                    session_token TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS github_connect_sessions (
                    id TEXT PRIMARY KEY,
                    install_session_id TEXT NOT NULL,
                    state TEXT NOT NULL UNIQUE,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    FOREIGN KEY (install_session_id) REFERENCES install_sessions(id)
                );

                CREATE TABLE IF NOT EXISTS github_connections (
                    id TEXT PRIMARY KEY,
                    install_session_id TEXT NOT NULL UNIQUE,
                    github_login TEXT NOT NULL,
                    repo_owner TEXT NOT NULL,
                    repo_name TEXT NOT NULL,
                    repo_full_name TEXT NOT NULL,
                    repo_url TEXT NOT NULL,
                    access_token_encrypted TEXT NOT NULL,
                    visibility TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY (install_session_id) REFERENCES install_sessions(id)
                );

                CREATE TABLE IF NOT EXISTS paper_jobs (
                    id TEXT PRIMARY KEY,
                    install_session_id TEXT NOT NULL,
                    github_connection_id TEXT,
                    paper_title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    progress_message TEXT,
                    error_message TEXT,
                    openai_response_id TEXT,
                    repo_commit_sha TEXT,
                    repo_path TEXT,
                    request_payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    completed_at TEXT,
                    started_at TEXT,
                    FOREIGN KEY (install_session_id) REFERENCES install_sessions(id),
                    FOREIGN KEY (github_connection_id) REFERENCES github_connections(id)
                );

                CREATE TABLE IF NOT EXISTS paper_job_metrics (
                    id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL UNIQUE,
                    model TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    estimated_cost_usd REAL NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (job_id) REFERENCES paper_jobs(id)
                );
                """
            )

    def ensure_install_session(self, device_id: str) -> dict[str, Any]:
        now = iso_now()
        with self._lock, self._connection() as connection:
            existing = connection.execute(
                """
                SELECT * FROM install_sessions
                WHERE device_id = ?
                """,
                (device_id,),
            ).fetchone()

            if existing is not None:
                connection.execute(
                    """
                    UPDATE install_sessions
                    SET last_seen_at = ?
                    WHERE id = ?
                    """,
                    (now, existing["id"]),
                )
                refreshed = connection.execute(
                    "SELECT * FROM install_sessions WHERE id = ?",
                    (existing["id"],),
                ).fetchone()
                return dict(refreshed)

            session_id = secrets.token_urlsafe(18)
            session_token = secrets.token_urlsafe(32)
            connection.execute(
                """
                INSERT INTO install_sessions (
                    id,
                    device_id,
                    session_token,
                    created_at,
                    last_seen_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, device_id, session_token, now, now),
            )
            created = connection.execute(
                "SELECT * FROM install_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            return dict(created)

    def get_install_session_by_token(self, session_token: str) -> dict[str, Any] | None:
        now = iso_now()
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT * FROM install_sessions
                WHERE session_token = ?
                """,
                (session_token,),
            ).fetchone()
            if row is None:
                return None
            connection.execute(
                "UPDATE install_sessions SET last_seen_at = ? WHERE id = ?",
                (now, row["id"]),
            )
            refreshed = connection.execute(
                "SELECT * FROM install_sessions WHERE id = ?",
                (row["id"],),
            ).fetchone()
            return dict(refreshed)

    def get_install_session_by_id(self, install_session_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT * FROM install_sessions
                WHERE id = ?
                """,
                (install_session_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def create_github_connect_session(self, install_session_id: str, ttl_seconds: int) -> dict[str, Any]:
        now = utc_now()
        payload = {
            "id": secrets.token_urlsafe(18),
            "install_session_id": install_session_id,
            "state": secrets.token_urlsafe(24),
            "status": "created",
            "error_message": None,
            "created_at": now.isoformat(),
            "updated_at": now.isoformat(),
            "expires_at": (now + timedelta(seconds=ttl_seconds)).isoformat(),
        }
        with self._lock, self._connection() as connection:
            connection.execute(
                """
                INSERT INTO github_connect_sessions (
                    id,
                    install_session_id,
                    state,
                    status,
                    error_message,
                    created_at,
                    updated_at,
                    expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                tuple(payload.values()),
            )
        return payload

    def ensure_github_connect_session(
        self,
        *,
        session_id: str,
        install_session_id: str,
        state: str,
        expires_at: str,
        status: str = "created",
        error_message: str | None = None,
    ) -> dict[str, Any]:
        now = iso_now()
        with self._lock, self._connection() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO github_connect_sessions (
                    id,
                    install_session_id,
                    state,
                    status,
                    error_message,
                    created_at,
                    updated_at,
                    expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    session_id,
                    install_session_id,
                    state,
                    status,
                    error_message,
                    now,
                    now,
                    expires_at,
                ),
            )
            row = connection.execute(
                "SELECT * FROM github_connect_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            return dict(row) if row is not None else {}

    def get_github_connect_session(self, session_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM github_connect_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def get_github_connect_session_for_state(self, state: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM github_connect_sessions WHERE state = ?",
                (state,),
            ).fetchone()
            return dict(row) if row is not None else None

    def update_github_connect_session(
        self,
        session_id: str,
        *,
        status: str,
        error_message: str | None = None,
    ) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            connection.execute(
                """
                UPDATE github_connect_sessions
                SET status = ?, error_message = ?, updated_at = ?
                WHERE id = ?
                """,
                (status, error_message, iso_now(), session_id),
            )
            row = connection.execute(
                "SELECT * FROM github_connect_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def upsert_github_connection(
        self,
        *,
        install_session_id: str,
        github_login: str,
        repo_owner: str,
        repo_name: str,
        repo_full_name: str,
        repo_url: str,
        access_token_encrypted: str,
        visibility: str,
    ) -> dict[str, Any]:
        now = iso_now()
        connection_id = secrets.token_urlsafe(18)
        with self._lock, self._connection() as connection:
            existing = connection.execute(
                """
                SELECT id FROM github_connections
                WHERE install_session_id = ?
                """,
                (install_session_id,),
            ).fetchone()

            if existing is None:
                connection.execute(
                    """
                    INSERT INTO github_connections (
                        id,
                        install_session_id,
                        github_login,
                        repo_owner,
                        repo_name,
                        repo_full_name,
                        repo_url,
                        access_token_encrypted,
                        visibility,
                        created_at,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        connection_id,
                        install_session_id,
                        github_login,
                        repo_owner,
                        repo_name,
                        repo_full_name,
                        repo_url,
                        access_token_encrypted,
                        visibility,
                        now,
                        now,
                    ),
                )
                row_id = connection_id
            else:
                connection.execute(
                    """
                    UPDATE github_connections
                    SET github_login = ?,
                        repo_owner = ?,
                        repo_name = ?,
                        repo_full_name = ?,
                        repo_url = ?,
                        access_token_encrypted = ?,
                        visibility = ?,
                        updated_at = ?
                    WHERE install_session_id = ?
                    """,
                    (
                        github_login,
                        repo_owner,
                        repo_name,
                        repo_full_name,
                        repo_url,
                        access_token_encrypted,
                        visibility,
                        now,
                        install_session_id,
                    ),
                )
                row_id = str(existing["id"])

            row = connection.execute(
                "SELECT * FROM github_connections WHERE id = ?",
                (row_id,),
            ).fetchone()
            return dict(row)

    def get_github_connection_for_install(self, install_session_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT * FROM github_connections
                WHERE install_session_id = ?
                """,
                (install_session_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def create_paper_job(
        self,
        *,
        install_session_id: str,
        github_connection_id: str,
        paper_title: str,
        request_payload: dict[str, Any],
    ) -> dict[str, Any]:
        now = iso_now()
        job_id = secrets.token_urlsafe(18)
        with self._lock, self._connection() as connection:
            connection.execute(
                """
                INSERT INTO paper_jobs (
                    id,
                    install_session_id,
                    github_connection_id,
                    paper_title,
                    status,
                    stage,
                    progress_message,
                    error_message,
                    openai_response_id,
                    repo_commit_sha,
                    repo_path,
                    request_payload_json,
                    created_at,
                    updated_at,
                    completed_at,
                    started_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    install_session_id,
                    github_connection_id,
                    paper_title,
                    "queued",
                    "plan",
                    "Queued for Sidekick-hosted analysis.",
                    None,
                    None,
                    None,
                    None,
                    json.dumps(request_payload, sort_keys=True),
                    now,
                    now,
                    None,
                    None,
                ),
            )
            row = connection.execute(
                "SELECT * FROM paper_jobs WHERE id = ?",
                (job_id,),
            ).fetchone()
            return dict(row)

    def get_paper_job(self, job_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM paper_jobs WHERE id = ?",
                (job_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def get_paper_jobs_for_install(self, install_session_id: str) -> list[dict[str, Any]]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                """
                SELECT * FROM paper_jobs
                WHERE install_session_id = ?
                ORDER BY created_at DESC
                """,
                (install_session_id,),
            ).fetchall()
            return [dict(row) for row in rows]

    def count_recent_jobs_for_install(self, install_session_id: str, since_iso: str) -> int:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT COUNT(*) AS count
                FROM paper_jobs
                WHERE install_session_id = ?
                  AND created_at >= ?
                """,
                (install_session_id, since_iso),
            ).fetchone()
            return int(row["count"] if row is not None else 0)

    def count_running_jobs_for_install(self, install_session_id: str) -> int:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT COUNT(*) AS count
                FROM paper_jobs
                WHERE install_session_id = ?
                  AND status = 'running'
                """,
                (install_session_id,),
            ).fetchone()
            return int(row["count"] if row is not None else 0)

    def claim_next_queued_job(self, max_concurrent_jobs_per_install: int) -> JobClaim | None:
        with self._lock, self._connection() as connection:
            queued_jobs = connection.execute(
                """
                SELECT id, install_session_id
                FROM paper_jobs
                WHERE status = 'queued'
                ORDER BY created_at ASC
                """
            ).fetchall()

            for row in queued_jobs:
                running = connection.execute(
                    """
                    SELECT COUNT(*) AS count
                    FROM paper_jobs
                    WHERE install_session_id = ?
                      AND status = 'running'
                    """,
                    (row["install_session_id"],),
                ).fetchone()
                if int(running["count"]) >= max_concurrent_jobs_per_install:
                    continue

                connection.execute(
                    """
                    UPDATE paper_jobs
                    SET status = 'running',
                        updated_at = ?,
                        started_at = COALESCE(started_at, ?),
                        progress_message = ?
                    WHERE id = ?
                    """,
                    (
                        iso_now(),
                        iso_now(),
                        "Planning research run.",
                        row["id"],
                    ),
                )
                return JobClaim(
                    job_id=str(row["id"]),
                    install_session_id=str(row["install_session_id"]),
                )

            return None

    def update_paper_job(
        self,
        job_id: str,
        *,
        status: str | None = None,
        stage: str | None = None,
        progress_message: str | None = None,
        error_message: str | None = None,
        openai_response_id: str | None = None,
        repo_commit_sha: str | None = None,
        repo_path: str | None = None,
        completed: bool = False,
    ) -> dict[str, Any] | None:
        assignments: list[str] = ["updated_at = ?"]
        parameters: list[Any] = [iso_now()]

        if status is not None:
            assignments.append("status = ?")
            parameters.append(status)
        if stage is not None:
            assignments.append("stage = ?")
            parameters.append(stage)
        if progress_message is not None:
            assignments.append("progress_message = ?")
            parameters.append(progress_message)
        if error_message is not None:
            assignments.append("error_message = ?")
            parameters.append(error_message)
        if openai_response_id is not None:
            assignments.append("openai_response_id = ?")
            parameters.append(openai_response_id)
        if repo_commit_sha is not None:
            assignments.append("repo_commit_sha = ?")
            parameters.append(repo_commit_sha)
        if repo_path is not None:
            assignments.append("repo_path = ?")
            parameters.append(repo_path)
        if completed:
            assignments.append("completed_at = ?")
            parameters.append(iso_now())

        parameters.append(job_id)

        with self._lock, self._connection() as connection:
            connection.execute(
                f"""
                UPDATE paper_jobs
                SET {", ".join(assignments)}
                WHERE id = ?
                """,
                tuple(parameters),
            )
            row = connection.execute(
                "SELECT * FROM paper_jobs WHERE id = ?",
                (job_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def record_paper_job_metrics(
        self,
        *,
        job_id: str,
        model: str,
        input_tokens: int,
        output_tokens: int,
        estimated_cost_usd: float,
    ) -> None:
        now = iso_now()
        with self._lock, self._connection() as connection:
            existing = connection.execute(
                """
                SELECT input_tokens, output_tokens, estimated_cost_usd
                FROM paper_job_metrics
                WHERE job_id = ?
                """,
                (job_id,),
            ).fetchone()
            total_input_tokens = input_tokens
            total_output_tokens = output_tokens
            total_estimated_cost = estimated_cost_usd
            if existing is not None:
                total_input_tokens += int(existing["input_tokens"])
                total_output_tokens += int(existing["output_tokens"])
                total_estimated_cost += float(existing["estimated_cost_usd"])

            connection.execute(
                """
                INSERT INTO paper_job_metrics (
                    id,
                    job_id,
                    model,
                    input_tokens,
                    output_tokens,
                    estimated_cost_usd,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id) DO UPDATE SET
                    model = excluded.model,
                    input_tokens = excluded.input_tokens,
                    output_tokens = excluded.output_tokens,
                    estimated_cost_usd = excluded.estimated_cost_usd,
                    created_at = excluded.created_at
                """,
                (
                    secrets.token_urlsafe(12),
                    job_id,
                    model,
                    total_input_tokens,
                    total_output_tokens,
                    total_estimated_cost,
                    now,
                ),
            )

    def sum_daily_cost_usd(self, since_iso: str) -> float:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                """
                SELECT COALESCE(SUM(estimated_cost_usd), 0) AS total
                FROM paper_job_metrics
                WHERE created_at >= ?
                """,
                (since_iso,),
            ).fetchone()
            return float(row["total"] if row is not None else 0)

    def get_metrics_for_job(self, job_id: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM paper_job_metrics WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def purge_expired_github_connect_sessions(self) -> None:
        now = iso_now()
        with self._lock, self._connection() as connection:
            connection.execute(
                """
                DELETE FROM github_connect_sessions
                WHERE expires_at <= ?
                """,
                (now,),
            )
