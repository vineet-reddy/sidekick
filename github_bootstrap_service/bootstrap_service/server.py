from __future__ import annotations

import base64
import hashlib
import hmac
import json
import mimetypes
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
from .manuscript import (
    build_manuscript_manifest,
    compile_pdf,
    format_reference_from_source,
    normalize_manuscript_sections,
    render_latex,
    results_to_markdown,
)
from .openai_client import OpenAIClient, OpenAIContainerFile
from .pipeline_engine import PaperPipelineEngine, PipelineExecutionError


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


def _normalize_text_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def _read_json_file(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json_file(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_texts(texts: list[str]) -> str:
    digest = hashlib.sha256()
    for text in texts:
        digest.update(text.encode("utf-8"))
    return digest.hexdigest()


def _is_http_url(value: str) -> bool:
    lowered = value.strip().lower()
    return lowered.startswith("https://") or lowered.startswith("http://")


def _sanitize_relative_path(value: str, *, fallback: str) -> str:
    candidate = value.strip().replace("\\", "/")
    candidate = re.sub(r"^\./+", "", candidate)
    candidate = candidate.lstrip("/")
    parts = []
    for part in candidate.split("/"):
        cleaned = part.strip()
        if not cleaned or cleaned in {".", ".."}:
            continue
        parts.append(cleaned)
    sanitized = "/".join(parts)
    return sanitized or fallback


def _guess_mime_type(path: str, fallback: str = "application/octet-stream") -> str:
    guessed, _ = mimetypes.guess_type(path)
    return guessed or fallback


def _artifact_path_value(artifact: dict[str, Any]) -> str:
    for key in ("path", "file_path", "filename", "relative_path"):
        value = str(artifact.get(key) or "").strip()
        if value:
            return value
    return ""


def _artifact_source_ids(artifact: dict[str, Any]) -> list[str]:
    return _normalize_text_list(artifact.get("source_ids") or artifact.get("sources"))


def _path_candidates(value: str) -> set[str]:
    raw = value.strip()
    if not raw:
        return set()
    sanitized = _sanitize_relative_path(raw, fallback="")
    basename = Path(sanitized or raw).name
    candidates = {candidate for candidate in {raw, sanitized, basename} if candidate}
    return candidates


def _find_banned_phrases(text: str) -> list[str]:
    lowered = text.lower()
    patterns = {
        "synthetic data": r"\bsynthetic\s+(?:data|dataset|results?|analysis)\b",
        "simulated data": r"\bsimulated\s+(?:data|dataset|results?|analysis)\b",
        "mock data": r"\bmock\s+(?:data|dataset|results?)\b",
        "placeholder": r"\bplaceholder\s+(?:data|dataset|results?|figure|table|text)\b",
        "demo mode": r"\bdemo(?:\s+mode)?\b",
        "draft language": r"\bthis draft\b|\(draft\)",
        "proof claim": r"\b(?:prove|proves|proven|definitive(?:ly)?|conclusive(?:ly)?)\b",
    }
    return [label for label, pattern in patterns.items() if re.search(pattern, lowered)]


def _source_has_reproducible_receipt(source: dict[str, Any]) -> bool:
    accession_id = str(source.get("accession_id") or "").strip()
    download_url = str(source.get("download_url") or "").strip()
    api_query = source.get("api_query")
    api_endpoint = str(source.get("api_endpoint") or "").strip()
    return bool(
        accession_id
        or _is_http_url(download_url)
        or api_endpoint
        or (isinstance(api_query, dict) and bool(api_query))
        or (isinstance(api_query, str) and api_query.strip())
    )


def _source_external_urls(source: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    for key in ("download_url", "landing_page_url", "api_endpoint"):
        value = str(source.get(key) or "").strip()
        if _is_http_url(value):
            urls.append(value)
    return urls


def _domain_from_url(url: str) -> str:
    try:
        parsed = urlparse(url)
    except ValueError:
        return ""
    return parsed.netloc.strip().lower()


def _normalize_source(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    return {
        "source_id": str(entry.get("source_id") or f"source_{index + 1}").strip() or f"source_{index + 1}",
        "label": str(entry.get("label") or entry.get("title") or f"Source {index + 1}").strip() or f"Source {index + 1}",
        "landing_page_url": str(entry.get("landing_page_url") or entry.get("url") or "").strip(),
        "download_url": str(entry.get("download_url") or entry.get("direct_download_url") or "").strip(),
        "accession_id": str(entry.get("accession_id") or entry.get("dataset_id") or "").strip(),
        "api_endpoint": str(entry.get("api_endpoint") or "").strip(),
        "api_query": entry.get("api_query"),
        "notes": str(entry.get("notes") or entry.get("retrieval_note") or "").strip(),
    }


def _normalize_artifact(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    declared_path = _artifact_path_value(entry)
    return {
        "artifact_id": str(entry.get("artifact_id") or f"artifact_{index + 1}").strip() or f"artifact_{index + 1}",
        "path": declared_path,
        "kind": str(entry.get("kind") or entry.get("artifact_type") or "artifact").strip() or "artifact",
        "mime_type": str(entry.get("mime_type") or "").strip(),
        "description": str(entry.get("description") or entry.get("caption") or "").strip(),
        "source_ids": _artifact_source_ids(entry),
    }


def _normalize_result(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    return {
        "result_id": str(entry.get("result_id") or entry.get("id") or f"result_{index + 1}").strip() or f"result_{index + 1}",
        "text": str(entry.get("text") or entry.get("result") or "").strip(),
        "artifact_ids": _normalize_text_list(entry.get("artifact_ids") or entry.get("artifacts")),
    }


def _normalize_ledger(raw_ledger: dict[str, Any], *, title_fallback: str) -> dict[str, Any]:
    sources = [_normalize_source(entry, index) for index, entry in enumerate(raw_ledger.get("sources") or [])]
    artifacts = [_normalize_artifact(entry, index) for index, entry in enumerate(raw_ledger.get("artifacts") or [])]
    results = [_normalize_result(entry, index) for index, entry in enumerate(raw_ledger.get("results") or [])]
    return {
        "title": str(raw_ledger.get("title") or title_fallback).strip() or title_fallback,
        "research_question": str(raw_ledger.get("research_question") or raw_ledger.get("question") or "").strip(),
        "methods": str(raw_ledger.get("methods") or "").strip(),
        "limitations": _normalize_text_list(raw_ledger.get("limitations")),
        "sources": sources,
        "artifacts": artifacts,
        "results": results,
    }


@dataclass(frozen=True)
class DownloadedArtifactFile:
    artifact_id: str | None
    container_id: str
    file_id: str
    filename: str
    relative_path: str
    metadata_path: str
    mime_type: str
    sha256: str


def _build_validation_error_message(validation: dict[str, Any]) -> str:
    lines = [str(validation.get("summary") or "Validation blocked the run.").strip() or "Validation blocked the run."]

    dropped_results = validation.get("dropped_results") or []
    if isinstance(dropped_results, list):
        for entry in dropped_results[:3]:
            if not isinstance(entry, dict):
                continue
            result_id = str(entry.get("result_id") or "result").strip() or "result"
            reasons = [str(reason).strip() for reason in entry.get("reasons") or [] if str(reason).strip()]
            if reasons:
                lines.append(f"{result_id}: {'; '.join(reasons)}")

    if len(lines) == 1:
        issues = [str(issue).strip() for issue in validation.get("validation_issues") or [] if str(issue).strip()]
        lines.extend(issues[:3])

    return "\n".join(lines)


def _build_task_provenance(ledger: dict[str, Any]) -> dict[str, Any]:
    used_dataset_ids = sorted(
        {
            str(source.get("accession_id") or "").strip()
            for source in ledger.get("sources", [])
            if isinstance(source, dict) and str(source.get("accession_id") or "").strip()
        }
    )
    external_sources = []
    accessed_domains = set()
    for source in ledger.get("sources", []):
        if not isinstance(source, dict):
            continue
        for url in _source_external_urls(source):
            external_sources.append(url)
            domain = _domain_from_url(url)
            if domain:
                accessed_domains.add(domain)

    return {
        "used_dataset_ids": used_dataset_ids,
        "accessed_domains": sorted(accessed_domains),
        "left_trusted_set": False,
        "external_sources": external_sources,
        "notes": str(
            ledger.get("research_question")
            or ledger.get("methods")
            or "Validated from the research workspace record."
        ).strip()
        or "Validated from the research workspace record.",
    }


def _build_verification_payload(validation: dict[str, Any], figures: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "decision": "proceed" if validation.get("manuscript_kind") == "paper" else "blocked",
        "summary": str(validation.get("summary") or "").strip(),
        "supported_claims": [str(result.get("text") or "").strip() for result in validation.get("approved_results", [])],
        "weak_or_unsupported_claims": [
            f"{entry.get('result_id')}: {'; '.join(entry.get('reasons') or [])}".strip(": ")
            for entry in validation.get("dropped_results", [])
            if str(entry.get("result_id") or "").strip()
        ],
        "figure_sanity_checks": [
            {"filename": str(figure.get("filename") or ""), "status": "ok", "issue": ""}
            for figure in figures
            if str(figure.get("filename") or "").strip()
        ],
        "model_warnings": [],
        "sample_warnings": _normalize_text_list(validation.get("validation_issues")),
        "required_revisions": [] if validation.get("manuscript_kind") == "paper" else _normalize_text_list(validation.get("memo_reasons")),
    }


@dataclass(frozen=True)
class JobContext:
    job: dict[str, Any]
    install_session: dict[str, Any]
    github_connection: dict[str, Any]
    request_payload: dict[str, Any]


JobExecutionError = PipelineExecutionError


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
        self._engine = PaperPipelineEngine(
            config=config,
            openai_client=openai_client,
            status_callback=self._record_pipeline_status,
            metrics_callback=self._record_response_metrics,
        )
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

                claim = self._database.claim_next_queued_job(self._config.backend_max_concurrent_jobs_per_install)
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

        install_session = self._database.get_install_session_by_id(claim.install_session_id) or {"id": claim.install_session_id}
        github_connection = self._database.get_github_connection_for_install(claim.install_session_id)
        if github_connection is None:
            self._database.update_paper_job(
                claim.job_id,
                status="failed",
                stage="inspect",
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
            ledger = self._run_research_workspace(context)
            validation = self._validate_ledger(context.job["id"], ledger)
            bundle = self._write_bundle(context, ledger, validation)
            publication = self._publish_bundle(context, bundle)
            self._persist_artifacts(context.job["id"], bundle, publication)
            manuscript_kind = str(bundle.get("manuscript_kind") or "paper").strip() or "paper"
            self._database.update_paper_job(
                context.job["id"],
                status="completed",
                stage="write",
                progress_message=(
                    "Paper bundle published to GitHub and ready for download."
                    if manuscript_kind == "paper"
                    else "Research memo bundle published to GitHub and ready for download."
                ),
                repo_commit_sha=publication["commit_sha"],
                repo_path=publication["repo_path"],
                completed=True,
            )
        except Exception as error:
            stage = getattr(error, "stage", None)
            self._database.update_paper_job(
                context.job["id"],
                status="failed",
                stage=str(stage or (self._database.get_paper_job(context.job["id"]) or context.job).get("stage") or "inspect"),
                progress_message=str(error),
                error_message=str(error),
                completed=True,
            )

    def _record_response_metrics(self, *, job_id: str, model: str, input_tokens: int, output_tokens: int) -> None:
        self._database.record_paper_job_metrics(
            job_id=job_id,
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            estimated_cost_usd=self._estimate_cost(input_tokens, output_tokens),
        )

    def _record_pipeline_status(
        self,
        job_id: str,
        *,
        stage: str,
        progress_message: str,
        status: str | None = None,
        openai_response_id: str | None = None,
    ) -> None:
        self._database.update_paper_job(
            job_id,
            stage=stage,
            status=status,
            progress_message=progress_message,
            openai_response_id=openai_response_id,
        )

    def _run_research_workspace(self, context: JobContext) -> dict[str, Any]:
        return self._engine.run_research_workspace(run_id=context.job["id"], request_payload=context.request_payload)

    def _materialize_workspace_files(
        self,
        job_id: str,
        ledger: dict[str, Any],
        *,
        container_ids: list[str],
    ) -> list[DownloadedArtifactFile]:
        return self._engine.materialize_workspace_files(run_id=job_id, ledger=ledger, container_ids=container_ids)

    def _apply_downloaded_files_to_ledger(self, ledger: dict[str, Any], downloaded_files: list[DownloadedArtifactFile]) -> None:
        self._engine.apply_downloaded_files_to_ledger(ledger, downloaded_files)

    def _validate_ledger(self, job_id: str, ledger: dict[str, Any]) -> dict[str, Any]:
        return self._engine.validate_ledger(run_id=job_id, ledger=ledger)

    def _write_bundle(self, context: JobContext, ledger: dict[str, Any], validation: dict[str, Any]) -> dict[str, Any]:
        return self._engine.write_bundle(
            run_id=context.job["id"],
            request_payload=context.request_payload,
            ledger=ledger,
            validation=validation,
        )

    def _bundle_figures_from_ledger(self, job_id: str, ledger: dict[str, Any]) -> list[dict[str, Any]]:
        return self._engine.bundle_figures_from_ledger(run_id=job_id, ledger=ledger)

    def _publish_bundle(self, context: JobContext, bundle: dict[str, Any]) -> dict[str, Any]:
        self._database.update_paper_job(
            context.job["id"],
            stage="write",
            progress_message="Publishing the canonical manuscript bundle to GitHub.",
        )
        access_token = decrypt_text(context.github_connection["access_token_encrypted"], self._config.encryption_secret)
        owner = context.github_connection["repo_owner"]
        repo_name = context.github_connection["repo_name"]
        title = str(bundle.get("title") or context.request_payload["title"]).strip() or context.request_payload["title"]
        manuscript_kind = str(bundle.get("manuscript_kind") or "paper").strip() or "paper"
        slug = _slugify(title)
        date_prefix = datetime.now(tz=UTC).strftime("%Y-%m-%d")
        collection_name = "memos" if manuscript_kind == "memo" else "papers"
        base_filename = "memo" if manuscript_kind == "memo" else "paper"
        directory = f"{collection_name}/{date_prefix}-{slug}-{context.job['id'][:6]}"
        commit_message = f"Add {manuscript_kind}: {title}"

        root_readme = """# Sidekick Research

This repository stores reproducible paper and memo bundles published by Sidekick.
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

- Canonical manuscript source: `{base_filename}.tex`
- Compiled manuscript PDF: `{base_filename}.pdf`
- Bibliography: `references.bib`
- Figure assets: `figures/`
- Table assets: `tables/`
- Validation lockfile: `validation.json`
- Research workspace record: `ledger.json`
- Reproducibility artifacts: `artifacts/`
"""
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
            f"{directory}/{base_filename}.tex": str(bundle.get("latex") or ""),
            f"{directory}/references.bib": str(bundle.get("references_bib") or ""),
            f"{directory}/ledger.json": json.dumps(bundle.get("ledger") or {}, indent=2, sort_keys=True),
            f"{directory}/validation.json": json.dumps(bundle.get("validation") or {}, indent=2, sort_keys=True),
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

        job_directory = self._job_directory(context.job["id"])
        manifest = bundle.get("artifact_manifest") or {}
        for key in ("figures", "tables"):
            for entry in manifest.get(key) or []:
                if not isinstance(entry, dict):
                    continue
                relative_path = _sanitize_relative_path(str(entry.get("path") or "").strip(), fallback=f"{key}/file.bin")
                local_path = job_directory / relative_path
                if not local_path.exists() or not local_path.is_file():
                    continue
                latest_commit_sha = self._github_client.commit_binary_file(
                    access_token,
                    owner=owner,
                    repo_name=repo_name,
                    path=f"{directory}/{relative_path}",
                    raw_bytes=local_path.read_bytes(),
                    message=commit_message,
                ).sha

        pdf_payload = bundle.get("pdf") or {}
        pdf_filename = str(pdf_payload.get("filename") or f"{base_filename}.pdf").strip() or f"{base_filename}.pdf"
        pdf_path = job_directory / pdf_filename
        if pdf_path.exists() and pdf_path.is_file():
            latest_commit_sha = self._github_client.commit_binary_file(
                access_token,
                owner=owner,
                repo_name=repo_name,
                path=f"{directory}/{base_filename}.pdf",
                raw_bytes=pdf_path.read_bytes(),
                message=commit_message,
            ).sha
        elif str(pdf_payload.get("error") or "").strip():
            latest_commit_sha = self._github_client.commit_text_file(
                access_token,
                owner=owner,
                repo_name=repo_name,
                path=f"{directory}/pdf_compile_error.log",
                content=str(pdf_payload.get("error") or "") + "\n\n" + str(pdf_payload.get("log") or ""),
                message=commit_message,
            ).sha

        for artifact_file in bundle.get("artifact_files", []) or []:
            if not isinstance(artifact_file, dict):
                continue
            relative_path = _sanitize_relative_path(
                str(artifact_file.get("path") or "").strip(),
                fallback="artifacts/file.bin",
            )
            local_path = job_directory / relative_path
            if not local_path.exists() or not local_path.is_file():
                continue
            repo_path = f"{directory}/{relative_path}"
            raw_bytes = local_path.read_bytes()
            try:
                content = raw_bytes.decode("utf-8")
            except UnicodeDecodeError:
                latest_commit_sha = self._github_client.commit_binary_file(
                    access_token,
                    owner=owner,
                    repo_name=repo_name,
                    path=repo_path,
                    raw_bytes=raw_bytes,
                    message=commit_message,
                ).sha
            else:
                latest_commit_sha = self._github_client.commit_text_file(
                    access_token,
                    owner=owner,
                    repo_name=repo_name,
                    path=repo_path,
                    content=content,
                    message=commit_message,
                ).sha

        return {
            "repo_url": context.github_connection["repo_url"],
            "commit_sha": latest_commit_sha,
            "repo_path": directory,
            "manuscript_kind": manuscript_kind,
            "published_at": iso_now(),
        }

    def _persist_artifacts(self, job_id: str, bundle: dict[str, Any], publication: dict[str, Any]) -> None:
        _write_json_file(self._job_directory(job_id) / "bundle.json", {"bundle": bundle, "publication": publication})

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

    def _job_directory(self, job_id: str) -> Path:
        directory = self._config.artifact_root / job_id
        directory.mkdir(parents=True, exist_ok=True)
        return directory

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
            artifact_file = self.server.config.artifact_root / job_id / "bundle.json"
            if not artifact_file.exists():
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "artifacts_unavailable"})
                return
            payload = _read_json_file(artifact_file)
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
            signed_state = (query.get("state") or [""])[0].strip()
            if signed_state:
                decoded_state = self._decode_signed_connect_state(signed_state)
                if decoded_state is None:
                    self._send_text(HTTPStatus.BAD_REQUEST, "Invalid GitHub connect state.")
                    return
                session_id = str(decoded_state.get("session_id") or "").strip()
                if session_id:
                    self.server.database.update_github_connect_session(session_id, status="redirected_to_github")
                self._redirect(self.server.github_client.build_user_authorization_url(signed_state))
                return

            session_id = (query.get("session_id") or [""])[0].strip()
            session = self.server.database.get_github_connect_session(session_id)
            if session is None:
                self._send_text(HTTPStatus.NOT_FOUND, "Unknown GitHub connect session.")
                return

            signed_state = self._build_signed_connect_state(session)
            self.server.database.update_github_connect_session(session_id, status="redirected_to_github")
            self._redirect(self.server.github_client.build_user_authorization_url(signed_state))
            return

        if parsed.path in {
            "/oauth/github/callback",
            "/browser/github-connect/callback",
            "/browser/github-bootstrap/callback",
        }:
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
            self._send_json(HTTPStatus.OK, {"clusters": self._assess_notes(notes)})
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
                    {
                        "error": "github_required",
                        "message": "GitHub must be connected before Sidekick can generate a paper.",
                    },
                )
                return

            since = (utc_now() - timedelta(days=1)).isoformat()
            recent_jobs = self.server.database.count_recent_jobs_for_install(install_session["id"], since)
            if recent_jobs >= self.server.config.backend_max_jobs_per_install_per_day:
                self._send_json(HTTPStatus.TOO_MANY_REQUESTS, {"error": "install_daily_limit_reached"})
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
                "must_use_sources": payload.get("must_use_sources") or [],
                "domain_guidance": str(payload.get("domain_guidance") or "").strip(),
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

        decoded_state = self._decode_signed_connect_state(state)
        if decoded_state is None:
            self._send_text(HTTPStatus.BAD_REQUEST, "Unknown or expired GitHub OAuth state.")
            return
        session_id = str(decoded_state.get("session_id") or "").strip()
        install_session_id = str(decoded_state.get("install_session_id") or "").strip()
        raw_state = str(decoded_state.get("nonce") or "").strip()
        expires_at = str(decoded_state.get("expires_at") or "").strip()
        if not session_id or not install_session_id or not raw_state or not expires_at:
            self._send_text(HTTPStatus.BAD_REQUEST, "Unknown or expired GitHub OAuth state.")
            return

        session = self.server.database.ensure_github_connect_session(
            session_id=session_id,
            install_session_id=install_session_id,
            state=raw_state,
            expires_at=expires_at,
        )

        if oauth_error:
            message = error_description or oauth_error
            self.server.database.update_github_connect_session(session["id"], status="failed", error_message=message)
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
            repo = self.server.github_client.ensure_sidekick_repository(access_token, owner=user.login)
            self.server.database.upsert_github_connection(
                install_session_id=session["install_session_id"],
                github_login=user.login,
                repo_owner=user.login,
                repo_name=repo.name,
                repo_full_name=repo.full_name,
                repo_url=repo.html_url or f"https://github.com/{repo.full_name}",
                access_token_encrypted=encrypt_text(access_token, self.server.config.encryption_secret),
                visibility=repo.visibility,
            )
            self.server.database.update_github_connect_session(session["id"], status="completed", error_message=None)
            self._send_text(HTTPStatus.OK, "GitHub connected. You can return to Sidekick.")
        except GitHubClientError as error:
            self.server.database.update_github_connect_session(session["id"], status="failed", error_message=str(error))
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
        signed_state = self._build_signed_connect_state(session)
        return {
            "session_id": session["id"],
            "status": session["status"],
            "error_message": session["error_message"],
            "created_at": session["created_at"],
            "updated_at": session["updated_at"],
            "expires_at": session["expires_at"],
            "browser_url": self.server.github_client.build_user_authorization_url(signed_state),
            "connection": self._github_connection_payload(connection),
        }

    def _build_signed_connect_state(self, session: dict[str, Any]) -> str:
        payload = {
            "session_id": session["id"],
            "install_session_id": session["install_session_id"],
            "nonce": session["state"],
            "expires_at": session["expires_at"],
        }
        raw_payload = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        signature = hmac.new(
            self.server.config.encryption_secret.encode("utf-8"),
            raw_payload,
            hashlib.sha256,
        ).digest()
        encoded_payload = base64.urlsafe_b64encode(raw_payload).decode("ascii").rstrip("=")
        encoded_signature = base64.urlsafe_b64encode(signature).decode("ascii").rstrip("=")
        return f"{encoded_payload}.{encoded_signature}"

    def _decode_signed_connect_state(self, token: str) -> dict[str, Any] | None:
        parts = token.split(".", 1)
        if len(parts) != 2:
            return None
        encoded_payload, encoded_signature = parts
        try:
            raw_payload = base64.urlsafe_b64decode(encoded_payload + "=" * (-len(encoded_payload) % 4))
            signature = base64.urlsafe_b64decode(encoded_signature + "=" * (-len(encoded_signature) % 4))
        except Exception:
            return None

        expected_signature = hmac.new(
            self.server.config.encryption_secret.encode("utf-8"),
            raw_payload,
            hashlib.sha256,
        ).digest()
        if not hmac.compare_digest(signature, expected_signature):
            return None

        try:
            payload = json.loads(raw_payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict):
            return None

        expires_at = str(payload.get("expires_at") or "").strip()
        if not expires_at:
            return None
        try:
            if datetime.fromisoformat(expires_at) <= utc_now():
                return None
        except ValueError:
            return None
        return payload

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
