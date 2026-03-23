from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .config import BootstrapServiceConfig
from .crypto import decrypt_text, encrypt_text
from .database import JobClaim, SidekickDatabase, iso_now, utc_now
from .github_client import GitHubClient, GitHubClientError
from .openai_client import OpenAIClient


def _json_dumps(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, sort_keys=True).encode("utf-8")


def _slugify(value: str) -> str:
    normalized = value.strip().lower()
    normalized = re.sub(r"[^a-z0-9]+", "-", normalized)
    normalized = re.sub(r"-+", "-", normalized).strip("-")
    return normalized or "paper"


def _extract_json_object(raw_text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    for index, character in enumerate(raw_text):
        if character != "{":
            continue
        try:
            payload, _ = decoder.raw_decode(raw_text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            return payload
    raise ValueError("Model output did not contain a JSON object.")


def _sha256_texts(texts: list[str]) -> str:
    digest = hashlib.sha256()
    for text in texts:
        digest.update(text.encode("utf-8"))
    return digest.hexdigest()


def _read_json_file(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json_file(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


@dataclass(frozen=True)
class JobContext:
    job: dict[str, Any]
    install_session: dict[str, Any]
    github_connection: dict[str, Any]
    request_payload: dict[str, Any]


class JobProcessor(threading.Thread):
    def __init__(
        self,
        *,
        config: BootstrapServiceConfig,
        database: SidekickDatabase,
        github_client: GitHubClient,
        openai_client: OpenAIClient,
    ):
        super().__init__(daemon=True)
        self._config = config
        self._database = database
        self._github_client = github_client
        self._openai_client = openai_client
        self._stop_event = threading.Event()

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self._database.purge_expired_github_connect_sessions()
                self._cleanup_expired_artifacts()

                if self._config.backend_kill_switch:
                    time.sleep(2)
                    continue

                spend_window_start = (utc_now() - timedelta(days=1)).isoformat()
                if self._database.sum_daily_cost_usd(spend_window_start) >= self._config.backend_max_daily_spend_usd:
                    time.sleep(5)
                    continue

                claim = self._database.claim_next_queued_job(
                    self._config.backend_max_concurrent_jobs_per_install
                )
                if claim is None:
                    time.sleep(2)
                    continue

                self._run_claimed_job(claim)
            except Exception as error:  # pragma: no cover - last-resort worker protection
                print(f"[sidekick-backend] worker loop error: {error}")
                time.sleep(2)

    def _run_claimed_job(self, claim: JobClaim) -> None:
        job = self._database.get_paper_job(claim.job_id)
        if job is None:
            return

        install_session = self._database.get_install_session_by_id(claim.install_session_id)
        if install_session is None:
            install_session = {
                "id": claim.install_session_id,
            }

        github_connection = self._database.get_github_connection_for_install(claim.install_session_id)
        if github_connection is None:
            self._database.update_paper_job(
                claim.job_id,
                status="failed",
                stage="plan",
                progress_message="GitHub must be connected before Sidekick can generate this paper.",
                error_message="Missing GitHub connection.",
                completed=True,
            )
            return

        request_payload = json.loads(job["request_payload_json"])
        context = JobContext(
            job=job,
            install_session=install_session,
            github_connection=github_connection,
            request_payload=request_payload,
        )

        try:
            plan = self._generate_plan(context)
            bundle = self._generate_bundle(context, plan)
            publication = self._publish_bundle(context, bundle)
            self._persist_artifacts(context.job["id"], bundle, publication)
            self._database.update_paper_job(
                context.job["id"],
                status="completed",
                stage="write",
                progress_message="Paper bundle published to GitHub and ready for download.",
                repo_commit_sha=publication["commit_sha"],
                repo_path=publication["repo_path"],
                completed=True,
            )
        except Exception as error:
            self._database.update_paper_job(
                context.job["id"],
                status="failed",
                stage=str((self._database.get_paper_job(context.job["id"]) or context.job).get("stage") or "plan"),
                progress_message=str(error),
                error_message=str(error),
                completed=True,
            )

    def _generate_plan(self, context: JobContext) -> dict[str, Any]:
        self._database.update_paper_job(
            context.job["id"],
            status="running",
            stage="plan",
            progress_message="Planning the paper from clustered notes.",
        )
        instructions = """
You are planning a scientific paper from short research notes.
Return strict JSON only with this exact shape:
{
  "question": "string",
  "hypotheses": ["string"],
  "dataset_needs": [
    {
      "dataset_id": "string or null",
      "role": "primary or supporting",
      "variables": ["string"],
      "rationale": "string"
    }
  ],
  "candidate_methods": ["string"],
  "planned_figures": [
    {
      "identifier": "figure_1",
      "title": "string",
      "purpose": "string"
    }
  ],
  "risks": ["string"],
  "execution_notes": "string"
}
Keep the plan concise, empirical, and honest. Use public data and reproducibility-friendly methods.
"""
        notes = context.request_payload["notes"]
        input_text = json.dumps(
            {
                "title": context.request_payload["title"],
                "theme": context.request_payload["theme"],
                "dataset_hints": context.request_payload.get("dataset_ids", []),
                "notes": notes,
            },
            sort_keys=True,
        )
        response = self._openai_client.generate_json(
            instructions=instructions,
            input_text=input_text,
            use_code_interpreter=False,
            timeout_seconds=min(300, self._config.backend_max_job_runtime_seconds),
        )
        self._database.update_paper_job(
            context.job["id"],
            openai_response_id=response.response_id,
            progress_message="Plan complete. Inspecting reachable data.",
        )
        self._database.record_paper_job_metrics(
            job_id=context.job["id"],
            model=self._config.openai_model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            estimated_cost_usd=self._estimate_cost(response.usage.input_tokens, response.usage.output_tokens),
        )
        return _extract_json_object(response.output_text)

    def _generate_bundle(self, context: JobContext, plan: dict[str, Any]) -> dict[str, Any]:
        self._database.update_paper_job(
            context.job["id"],
            stage="inspect",
            progress_message="Inspecting public data and preparing the analysis workspace.",
        )
        self._database.update_paper_job(
            context.job["id"],
            stage="analyze",
            progress_message="Running the empirical analysis on OpenAI-hosted compute.",
        )
        instructions = """
You are a scientifically conservative research assistant running in Code Interpreter.
Use real public data, generate real analysis code, and write a reproducible paper bundle.
Return strict JSON only with this exact shape:
{
  "title": "string",
  "markdown": "string",
  "latex": "string",
  "analysis_files": [
    {
      "path": "analysis.py",
      "content": "string"
    }
  ],
  "figures": [
    {
      "filename": "figure_1.png",
      "caption": "string",
      "mime_type": "image/png",
      "base64_data": "..."
    }
  ],
  "manifest": {
    "entrypoint": "analysis.py",
    "python_version": "3.11",
    "run_command": "python analysis.py",
    "notes_hash": "string",
    "model": "string",
    "dataset_sources": ["string"]
  },
  "provenance": {
    "used_dataset_ids": ["string"],
    "accessed_domains": ["string"],
    "left_trusted_set": false,
    "external_sources": ["string"],
    "notes": "string"
  },
  "inspection": {
    "dataset_manifest": {
      "primary_dataset_ids": ["string"],
      "data_sources": ["string"],
      "sample_description": "string",
      "row_count": 0,
      "selected_variables": ["string"],
      "quality_notes": ["string"]
    },
    "access_notes": "string",
    "quality_checks": ["string"],
    "analysis_checklist": ["string"]
  },
  "analysis": {
    "dataset_manifest": {
      "primary_dataset_ids": ["string"],
      "data_sources": ["string"],
      "sample_description": "string",
      "row_count": 0,
      "selected_variables": ["string"],
      "quality_notes": ["string"]
    },
    "narrative_summary": "string",
    "findings": [
      {
        "claim": "string",
        "estimate": "string",
        "uncertainty": "string",
        "evidence": "string",
        "supports_hypothesis": true
      }
    ],
    "tables": [
      {
        "identifier": "table_1",
        "title": "string",
        "columns": ["string"],
        "rows": [["string"]],
        "notes": "string"
      }
    ],
    "figures": [
      {
        "filename": "figure_1.png",
        "caption": "string",
        "mime_type": "image/png",
        "base64_data": "..."
      }
    ],
    "limitations": ["string"],
    "provenance": {
      "used_dataset_ids": ["string"],
      "accessed_domains": ["string"],
      "left_trusted_set": false,
      "external_sources": ["string"],
      "notes": "string"
    }
  },
  "verification": {
    "decision": "proceed or revise_analysis or blocked",
    "summary": "string",
    "supported_claims": ["string"],
    "weak_or_unsupported_claims": ["string"],
    "figure_sanity_checks": [
      {
        "filename": "figure_1.png",
        "status": "ok or warning or missing",
        "issue": "string"
      }
    ],
    "model_warnings": ["string"],
    "sample_warnings": ["string"],
    "required_revisions": ["string"]
  },
  "draft": {
    "title": "string",
    "markdown": "string"
  }
}
Requirements:
- Use Code Interpreter to inspect data, run the analysis, and generate any figures.
- The paper must be a real empirical paper with citations and enough detail to reproduce the analysis.
- `analysis_files` must include at minimum `analysis.py`, `requirements.txt`, and `Makefile`.
- Keep repository paths out of the paper text; cite sources in the paper body itself.
- `verification.decision` must be `proceed` only if the evidence in the bundle supports a real paper.
- Use conservative claims and document limitations.
"""
        notes = context.request_payload["notes"]
        notes_hash = _sha256_texts([note["content"] for note in notes])
        input_text = json.dumps(
            {
                "title": context.request_payload["title"],
                "theme": context.request_payload["theme"],
                "dataset_hints": context.request_payload.get("dataset_ids", []),
                "plan": plan,
                "notes_hash": notes_hash,
                "notes": notes,
            },
            sort_keys=True,
        )
        response = self._openai_client.generate_json(
            instructions=instructions,
            input_text=input_text,
            use_code_interpreter=True,
            timeout_seconds=self._config.backend_max_job_runtime_seconds,
        )
        self._database.update_paper_job(
            context.job["id"],
            stage="verify",
            progress_message="Verifying evidence and drafting the final manuscript.",
            openai_response_id=response.response_id,
        )
        self._database.record_paper_job_metrics(
            job_id=context.job["id"],
            model=self._config.openai_model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            estimated_cost_usd=self._estimate_cost(response.usage.input_tokens, response.usage.output_tokens),
        )
        bundle = _extract_json_object(response.output_text)
        bundle["plan"] = plan
        bundle.setdefault("draft", {"title": bundle.get("title", ""), "markdown": bundle.get("markdown", "")})
        bundle.setdefault(
            "manifest",
            {
                "entrypoint": "analysis.py",
                "python_version": "3.11",
                "run_command": "python analysis.py",
                "notes_hash": notes_hash,
                "model": self._config.openai_model,
                "dataset_sources": [],
            },
        )
        return bundle

    def _publish_bundle(self, context: JobContext, bundle: dict[str, Any]) -> dict[str, Any]:
        self._database.update_paper_job(
            context.job["id"],
            stage="write",
            progress_message="Publishing LaTeX and reproducibility code to the user GitHub repository.",
        )
        access_token = decrypt_text(
            context.github_connection["access_token_encrypted"],
            self._config.encryption_secret,
        )
        owner = context.github_connection["repo_owner"]
        repo_name = context.github_connection["repo_name"]
        title = str(bundle.get("title") or context.request_payload["title"]).strip() or context.request_payload["title"]
        slug = _slugify(title)
        date_prefix = datetime.now(tz=UTC).strftime("%Y-%m-%d")
        directory = f"papers/{date_prefix}-{slug}-{context.job['id'][:6]}"
        commit_message = f"Add paper: {title}"

        root_readme = f"""# Sidekick Research

This repository stores reproducible paper bundles published by Sidekick.
"""
        self._github_client.commit_text_file(
            access_token,
            owner=owner,
            repo_name=repo_name,
            path="README.md",
            content=root_readme,
            message=commit_message,
        )

        bundle_readme = f"""# {title}

Generated by Sidekick.

- Paper markdown: `paper.md`
- Paper LaTeX: `paper.tex`
- Reproducibility entrypoint: `{bundle['manifest'].get('entrypoint', 'analysis.py')}`
- Run command: `{bundle['manifest'].get('run_command', 'python analysis.py')}`
"""
        latest_commit_sha = ""
        latest_commit = self._github_client.commit_text_file(
            access_token,
            owner=owner,
            repo_name=repo_name,
            path=f"{directory}/README.md",
            content=bundle_readme,
            message=commit_message,
        )
        latest_commit_sha = latest_commit.sha

        text_files = {
            f"{directory}/paper.md": str(bundle.get("markdown") or ""),
            f"{directory}/paper.tex": str(bundle.get("latex") or ""),
            f"{directory}/manifest.json": json.dumps(bundle.get("manifest") or {}, indent=2, sort_keys=True),
            f"{directory}/plan.json": json.dumps(bundle.get("plan") or {}, indent=2, sort_keys=True),
            f"{directory}/inspection.json": json.dumps(bundle.get("inspection") or {}, indent=2, sort_keys=True),
            f"{directory}/analysis.json": json.dumps(bundle.get("analysis") or {}, indent=2, sort_keys=True),
            f"{directory}/verification.json": json.dumps(bundle.get("verification") or {}, indent=2, sort_keys=True),
            f"{directory}/provenance.json": json.dumps(bundle.get("provenance") or {}, indent=2, sort_keys=True),
        }
        for file_path, content in text_files.items():
            latest_commit_sha = self._github_client.commit_text_file(
                access_token,
                owner=owner,
                repo_name=repo_name,
                path=file_path,
                content=content,
                message=commit_message,
            ).sha

        for file_entry in bundle.get("analysis_files", []) or []:
            path = str(file_entry.get("path") or "").strip()
            if not path:
                continue
            content = str(file_entry.get("content") or "")
            latest_commit_sha = self._github_client.commit_text_file(
                access_token,
                owner=owner,
                repo_name=repo_name,
                path=f"{directory}/{path}",
                content=content,
                message=commit_message,
            ).sha

        for figure in bundle.get("figures", []) or []:
            filename = str(figure.get("filename") or "").strip()
            raw = str(figure.get("base64_data") or "").encode("utf-8")
            if not filename or not raw:
                continue
            latest_commit_sha = self._github_client.commit_binary_file(
                access_token,
                owner=owner,
                repo_name=repo_name,
                path=f"{directory}/figures/{filename}",
                raw_bytes=base64.b64decode(raw),
                message=commit_message,
            ).sha

        return {
            "repo_url": context.github_connection["repo_url"],
            "commit_sha": latest_commit_sha,
            "repo_path": directory,
            "published_at": iso_now(),
        }

    def _persist_artifacts(
        self,
        job_id: str,
        bundle: dict[str, Any],
        publication: dict[str, Any],
    ) -> None:
        job_directory = self._config.artifact_root / job_id
        _write_json_file(job_directory / "bundle.json", {"bundle": bundle, "publication": publication})

    def _cleanup_expired_artifacts(self) -> None:
        root = self._config.artifact_root
        if not root.exists():
            return
        deadline = time.time() - self._config.backend_artifact_ttl_seconds
        for child in root.iterdir():
            try:
                if child.stat().st_mtime >= deadline:
                    continue
            except FileNotFoundError:
                continue
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)

    def _estimate_cost(self, input_tokens: int, output_tokens: int) -> float:
        return (
            (input_tokens / 1_000_000) * self._config.openai_estimated_input_cost_per_million
            + (output_tokens / 1_000_000) * self._config.openai_estimated_output_cost_per_million
        )


class BootstrapServiceHTTPServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        request_handler_class: type[BaseHTTPRequestHandler],
        *,
        config: BootstrapServiceConfig,
        database: SidekickDatabase,
        github_client: GitHubClient,
        openai_client: OpenAIClient,
    ):
        super().__init__(server_address, request_handler_class)
        self.config = config
        self.database = database
        self.github_client = github_client
        self.openai_client = openai_client
        self.job_processor = JobProcessor(
            config=config,
            database=database,
            github_client=github_client,
            openai_client=openai_client,
        )
        self.job_processor.start()


class BootstrapServiceHandler(BaseHTTPRequestHandler):
    server: BootstrapServiceHTTPServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self._send_json(HTTPStatus.OK, {"ok": True})
            return

        if parsed.path.startswith("/api/github/connect/sessions/"):
            install_session = self._require_install_session()
            if install_session is None:
                return
            session_id = parsed.path.rsplit("/", 1)[-1]
            session = self.server.database.get_github_connect_session(session_id)
            if session is None or session["install_session_id"] != install_session["id"]:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_session"})
                return
            self._send_json(HTTPStatus.OK, self._github_connect_session_payload(session))
            return

        if parsed.path.startswith("/api/papers/") and parsed.path.endswith("/artifacts"):
            install_session = self._require_install_session()
            if install_session is None:
                return
            job_id = parsed.path.split("/")[3]
            job = self.server.database.get_paper_job(job_id)
            if job is None or job["install_session_id"] != install_session["id"]:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_job"})
                return
            job_directory = self.server.config.artifact_root / job_id / "bundle.json"
            if not job_directory.exists():
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "artifacts_unavailable"})
                return
            payload = _read_json_file(job_directory)
            self._send_json(HTTPStatus.OK, payload)
            return

        if parsed.path.startswith("/api/papers/"):
            install_session = self._require_install_session()
            if install_session is None:
                return
            job_id = parsed.path.rsplit("/", 1)[-1]
            job = self.server.database.get_paper_job(job_id)
            if job is None or job["install_session_id"] != install_session["id"]:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_job"})
                return
            self._send_json(HTTPStatus.OK, self._paper_job_payload(job))
            return

        if parsed.path == "/github/connect/start":
            query = parse_qs(parsed.query)
            session_id = (query.get("session_id") or [""])[0].strip()
            session = self.server.database.get_github_connect_session(session_id)
            if session is None:
                self._send_text(HTTPStatus.NOT_FOUND, "Unknown GitHub connect session.")
                return

            self.server.database.update_github_connect_session(
                session_id,
                status="redirected_to_github",
            )
            self._redirect(self.server.github_client.build_user_authorization_url(session["state"]))
            return

        if parsed.path in {"/oauth/github/callback", "/browser/github-connect/callback"}:
            self._handle_github_callback(parsed)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)

        if parsed.path == "/api/device/session":
            payload = self._read_json_body()
            device_id = str(payload.get("device_id") or "").strip()
            if not device_id:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing_device_id"})
                return

            session = self.server.database.ensure_install_session(device_id)
            connection = self.server.database.get_github_connection_for_install(session["id"])
            self._send_json(
                HTTPStatus.CREATED,
                {
                    "install_session_id": session["id"],
                    "session_token": session["session_token"],
                    "created_at": session["created_at"],
                    "last_seen_at": session["last_seen_at"],
                    "github_connection": self._github_connection_payload(connection),
                },
            )
            return

        if parsed.path == "/api/github/connect/start":
            install_session = self._require_install_session()
            if install_session is None:
                return
            session = self.server.database.create_github_connect_session(
                install_session["id"],
                self.server.config.github_connect_session_ttl_seconds,
            )
            if self.server.config.github_access_token:
                try:
                    user = self.server.github_client.fetch_authenticated_user(self.server.config.github_access_token)
                    repo = self.server.github_client.ensure_sidekick_repository(
                        self.server.config.github_access_token,
                        owner=user.login,
                    )
                    self.server.database.upsert_github_connection(
                        install_session_id=install_session["id"],
                        github_login=user.login,
                        repo_owner=user.login,
                        repo_name=repo.name,
                        repo_full_name=repo.full_name,
                        repo_url=repo.html_url or f"https://github.com/{repo.full_name}",
                        access_token_encrypted=encrypt_text(
                            self.server.config.github_access_token,
                            self.server.config.encryption_secret,
                        ),
                        visibility=repo.visibility,
                    )
                    session = self.server.database.update_github_connect_session(
                        session["id"],
                        status="completed",
                        error_message=None,
                    ) or session
                except GitHubClientError as error:
                    session = self.server.database.update_github_connect_session(
                        session["id"],
                        status="failed",
                        error_message=str(error),
                    ) or session
            self._send_json(HTTPStatus.CREATED, self._github_connect_session_payload(session))
            return

        if parsed.path == "/api/notes/assess":
            install_session = self._require_install_session()
            if install_session is None:
                return
            payload = self._read_json_body()
            notes = payload.get("notes")
            if not isinstance(notes, list) or not notes:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing_notes"})
                return
            clusters = self._assess_notes(notes)
            self._send_json(HTTPStatus.OK, {"clusters": clusters})
            return

        if parsed.path == "/api/papers":
            install_session = self._require_install_session()
            if install_session is None:
                return
            if self.server.config.backend_kill_switch:
                self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "kill_switch_enabled"})
                return

            connection = self.server.database.get_github_connection_for_install(install_session["id"])
            if connection is None:
                self._send_json(
                    HTTPStatus.CONFLICT,
                    {"error": "github_required", "message": "GitHub must be connected before Sidekick can generate a paper."},
                )
                return

            since = (utc_now() - timedelta(days=1)).isoformat()
            recent_jobs = self.server.database.count_recent_jobs_for_install(install_session["id"], since)
            if recent_jobs >= self.server.config.backend_max_jobs_per_install_per_day:
                self._send_json(
                    HTTPStatus.TOO_MANY_REQUESTS,
                    {"error": "install_daily_limit_reached"},
                )
                return

            payload = self._read_json_body()
            title = str(payload.get("title") or "").strip()
            theme = str(payload.get("theme") or "").strip()
            notes = payload.get("notes")
            if not title or not theme or not isinstance(notes, list) or not notes:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing_paper_fields"})
                return

            request_payload = {
                "title": title,
                "theme": theme,
                "notes": notes,
                "dataset_ids": payload.get("dataset_ids") or [],
                "dataset_hints": payload.get("dataset_hints") or [],
                "allowed_domains": payload.get("allowed_domains") or [],
            }
            job = self.server.database.create_paper_job(
                install_session_id=install_session["id"],
                github_connection_id=connection["id"],
                paper_title=title,
                request_payload=request_payload,
            )
            self._send_json(HTTPStatus.CREATED, {"job_id": job["id"]})
            return

        if parsed.path.startswith("/api/papers/") and parsed.path.endswith("/cancel"):
            install_session = self._require_install_session()
            if install_session is None:
                return
            job_id = parsed.path.split("/")[3]
            job = self.server.database.get_paper_job(job_id)
            if job is None or job["install_session_id"] != install_session["id"]:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_job"})
                return
            updated = self.server.database.update_paper_job(
                job_id,
                status="failed",
                progress_message="Paper job cancelled by request.",
                error_message="Cancelled by request.",
                completed=True,
            )
            self._send_json(HTTPStatus.OK, self._paper_job_payload(updated))
            return

        if parsed.path.startswith("/api/papers/") and parsed.path.endswith("/publish"):
            install_session = self._require_install_session()
            if install_session is None:
                return
            job_id = parsed.path.split("/")[3]
            job = self.server.database.get_paper_job(job_id)
            if job is None or job["install_session_id"] != install_session["id"]:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_job"})
                return
            artifact_file = self.server.config.artifact_root / job_id / "bundle.json"
            if not artifact_file.exists():
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "artifacts_unavailable"})
                return
            payload = _read_json_file(artifact_file)
            self._send_json(HTTPStatus.OK, payload.get("publication") or {})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _assess_notes(self, notes: list[dict[str, Any]]) -> list[dict[str, Any]]:
        note_groups: dict[str, list[dict[str, Any]]] = {}
        for note in notes:
            content = str(note.get("content") or "").strip()
            note_id = str(note.get("id") or "").strip()
            if not content or not note_id:
                continue
            tokens = re.findall(r"[a-zA-Z]{4,}", content.lower())
            bucket = tokens[0] if tokens else "general"
            note_groups.setdefault(bucket, []).append(note)

        clusters: list[dict[str, Any]] = []
        for grouped_notes in note_groups.values():
            title = str(grouped_notes[0].get("title") or grouped_notes[0].get("content") or "").strip()
            title = title[:80] if title else "Research paper"
            clusters.append(
                {
                    "noteIDs": [str(note["id"]) for note in grouped_notes],
                    "theme": title,
                    "suggestedTitle": title,
                    "dataset_ids": [],
                    "readiness_mode": "trusted_ready",
                    "is_ready": True,
                }
            )
        return clusters

    def _handle_github_callback(self, parsed_url: Any) -> None:
        query = parse_qs(parsed_url.query)
        state = (query.get("state") or [""])[0].strip()
        code = (query.get("code") or [""])[0].strip()
        oauth_error = (query.get("error") or [""])[0].strip()
        error_description = (query.get("error_description") or [""])[0].strip()

        session = self.server.database.get_github_connect_session_for_state(state)
        if session is None:
            self._send_text(HTTPStatus.BAD_REQUEST, "Unknown or expired GitHub OAuth state.")
            return

        if oauth_error:
            message = error_description or oauth_error
            self.server.database.update_github_connect_session(
                session["id"],
                status="failed",
                error_message=message,
            )
            self._send_text(HTTPStatus.BAD_REQUEST, message)
            return

        if not code:
            self.server.database.update_github_connect_session(
                session["id"],
                status="failed",
                error_message="GitHub did not return an OAuth code.",
            )
            self._send_text(HTTPStatus.BAD_REQUEST, "GitHub did not return an OAuth code.")
            return

        try:
            access_token = self.server.github_client.exchange_code_for_user_token(code)
            user = self.server.github_client.fetch_authenticated_user(access_token)
            repo = self.server.github_client.ensure_sidekick_repository(
                access_token,
                owner=user.login,
            )
            self.server.database.upsert_github_connection(
                install_session_id=session["install_session_id"],
                github_login=user.login,
                repo_owner=user.login,
                repo_name=repo.name,
                repo_full_name=repo.full_name,
                repo_url=repo.html_url or f"https://github.com/{repo.full_name}",
                access_token_encrypted=encrypt_text(
                    access_token,
                    self.server.config.encryption_secret,
                ),
                visibility=repo.visibility,
            )
            self.server.database.update_github_connect_session(
                session["id"],
                status="completed",
                error_message=None,
            )
            self._send_text(HTTPStatus.OK, "GitHub connected. You can return to Sidekick.")
        except GitHubClientError as error:
            self.server.database.update_github_connect_session(
                session["id"],
                status="failed",
                error_message=str(error),
            )
            self._send_text(HTTPStatus.BAD_GATEWAY, str(error))

    def _require_install_session(self) -> dict[str, Any] | None:
        auth_header = self.headers.get("Authorization", "")
        token = ""
        if auth_header.lower().startswith("bearer "):
            token = auth_header[7:].strip()
        if not token:
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "missing_session_token"})
            return None

        install_session = self.server.database.get_install_session_by_token(token)
        if install_session is None:
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid_session_token"})
            return None
        return install_session

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

    def _paper_job_payload(self, job: dict[str, Any] | None) -> dict[str, Any]:
        if job is None:
            return {"error": "unknown_job"}

        metrics = self.server.database.get_metrics_for_job(job["id"]) or {}
        return {
            "job_id": job["id"],
            "status": job["status"],
            "stage": job["stage"],
            "progress_message": job.get("progress_message"),
            "error_message": job.get("error_message"),
            "openai_response_id": job.get("openai_response_id"),
            "repo_commit_sha": job.get("repo_commit_sha"),
            "repo_path": job.get("repo_path"),
            "created_at": job.get("created_at"),
            "updated_at": job.get("updated_at"),
            "completed_at": job.get("completed_at"),
            "metrics": {
                "model": metrics.get("model"),
                "input_tokens": metrics.get("input_tokens", 0),
                "output_tokens": metrics.get("output_tokens", 0),
                "estimated_cost_usd": metrics.get("estimated_cost_usd", 0),
            },
        }

    def _github_connection_payload(self, connection: dict[str, Any] | None) -> dict[str, Any] | None:
        if connection is None:
            return None
        return {
            "id": connection["id"],
            "github_login": connection["github_login"],
            "repo_owner": connection["repo_owner"],
            "repo_name": connection["repo_name"],
            "repo_full_name": connection["repo_full_name"],
            "repo_url": connection["repo_url"],
            "visibility": connection["visibility"],
            "created_at": connection["created_at"],
            "updated_at": connection["updated_at"],
        }

    def _github_connect_session_payload(self, session: dict[str, Any]) -> dict[str, Any]:
        connection = self.server.database.get_github_connection_for_install(session["install_session_id"])
        return {
            "session_id": session["id"],
            "status": session["status"],
            "error_message": session["error_message"],
            "created_at": session["created_at"],
            "updated_at": session["updated_at"],
            "expires_at": session["expires_at"],
            "browser_url": f"{self.server.config.service_base_url}/github/connect/start?session_id={session['id']}",
            "connection": self._github_connection_payload(connection),
        }

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = _json_dumps(payload)
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
    database: SidekickDatabase | None = None,
    github_client: GitHubClient | None = None,
    openai_client: OpenAIClient | None = None,
) -> BootstrapServiceHTTPServer:
    resolved_config = config or BootstrapServiceConfig.from_env()
    resolved_database = database or SidekickDatabase(resolved_config)
    resolved_github_client = github_client or GitHubClient(resolved_config)
    resolved_openai_client = openai_client or OpenAIClient(resolved_config)
    resolved_config.artifact_root.mkdir(parents=True, exist_ok=True)
    return BootstrapServiceHTTPServer(
        (host, port),
        BootstrapServiceHandler,
        config=resolved_config,
        database=resolved_database,
        github_client=resolved_github_client,
        openai_client=resolved_openai_client,
    )


def main() -> None:
    config = BootstrapServiceConfig.from_env()
    host = os.getenv("HOST", "0.0.0.0").strip() or "0.0.0.0"
    port = int((os.getenv("PORT", "8787").strip() or "8787"))
    server = create_server(host, port, config=config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.job_processor.stop()
        server.server_close()


if __name__ == "__main__":
    main()
