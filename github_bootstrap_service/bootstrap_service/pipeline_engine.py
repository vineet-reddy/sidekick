from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .config import BootstrapServiceConfig
from .manuscript import (
    build_manuscript_manifest,
    compile_pdf,
    format_reference_from_source,
    normalize_manuscript_sections,
    render_latex,
    results_to_markdown,
)
from .openai_client import OpenAIClient, OpenAIContainerFile

StatusCallback = Callable[..., None]
MetricsCallback = Callable[..., None]


class PipelineExecutionError(RuntimeError):
    def __init__(self, message: str, *, stage: str):
        super().__init__(message)
        self.stage = stage


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


def read_json_file(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json_file(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def extract_json_object(raw_text: str) -> dict[str, Any]:
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


def normalize_text_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def sanitize_relative_path(value: str, *, fallback: str) -> str:
    candidate = value.strip().replace("\\", "/")
    candidate = re.sub(r"^\./+", "", candidate)
    candidate = candidate.lstrip("/")
    parts: list[str] = []
    for part in candidate.split("/"):
        cleaned = part.strip()
        if not cleaned or cleaned in {".", ".."}:
            continue
        parts.append(cleaned)
    sanitized = "/".join(parts)
    return sanitized or fallback


def guess_mime_type(path: str, fallback: str = "application/octet-stream") -> str:
    guessed, _ = mimetypes.guess_type(path)
    return guessed or fallback


def artifact_path_value(artifact: dict[str, Any]) -> str:
    for key in ("path", "file_path", "filename", "relative_path"):
        value = str(artifact.get(key) or "").strip()
        if value:
            return value
    return ""


def artifact_source_ids(artifact: dict[str, Any]) -> list[str]:
    return normalize_text_list(artifact.get("source_ids") or artifact.get("sources"))


def path_candidates(value: str) -> set[str]:
    raw = value.strip()
    if not raw:
        return set()
    sanitized = sanitize_relative_path(raw, fallback="")
    basename = Path(sanitized or raw).name
    return {candidate for candidate in {raw, sanitized, basename} if candidate}


def find_banned_phrases(text: str) -> list[str]:
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


def source_has_reproducible_receipt(source: dict[str, Any]) -> bool:
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


def build_validation_error_message(validation: dict[str, Any]) -> str:
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


def _is_http_url(value: str) -> bool:
    lowered = value.strip().lower()
    return lowered.startswith("https://") or lowered.startswith("http://")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _source_external_urls(source: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    for key in ("download_url", "landing_page_url", "api_endpoint"):
        value = str(source.get(key) or "").strip()
        if _is_http_url(value):
            urls.append(value)
    return urls


def _domain_from_url(url: str) -> str:
    from urllib.parse import urlparse

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
    declared_path = artifact_path_value(entry)
    return {
        "artifact_id": str(entry.get("artifact_id") or f"artifact_{index + 1}").strip() or f"artifact_{index + 1}",
        "path": declared_path,
        "kind": str(entry.get("kind") or entry.get("artifact_type") or "artifact").strip() or "artifact",
        "mime_type": str(entry.get("mime_type") or "").strip(),
        "description": str(entry.get("description") or entry.get("caption") or "").strip(),
        "source_ids": artifact_source_ids(entry),
    }


def _normalize_result(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    return {
        "result_id": str(entry.get("result_id") or entry.get("id") or f"result_{index + 1}").strip() or f"result_{index + 1}",
        "text": str(entry.get("text") or entry.get("result") or "").strip(),
        "artifact_ids": normalize_text_list(entry.get("artifact_ids") or entry.get("artifacts")),
    }


def normalize_ledger(raw_ledger: dict[str, Any], *, title_fallback: str) -> dict[str, Any]:
    sources = [_normalize_source(entry, index) for index, entry in enumerate(raw_ledger.get("sources") or [])]
    artifacts = [_normalize_artifact(entry, index) for index, entry in enumerate(raw_ledger.get("artifacts") or [])]
    results = [_normalize_result(entry, index) for index, entry in enumerate(raw_ledger.get("results") or [])]
    return {
        "title": str(raw_ledger.get("title") or title_fallback).strip() or title_fallback,
        "research_question": str(raw_ledger.get("research_question") or raw_ledger.get("question") or "").strip(),
        "methods": str(raw_ledger.get("methods") or "").strip(),
        "limitations": normalize_text_list(raw_ledger.get("limitations")),
        "sources": sources,
        "artifacts": artifacts,
        "results": results,
    }


def build_task_provenance(ledger: dict[str, Any]) -> dict[str, Any]:
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


def build_verification_payload(validation: dict[str, Any], figures: list[dict[str, Any]]) -> dict[str, Any]:
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
        "sample_warnings": normalize_text_list(validation.get("validation_issues")),
        "required_revisions": [] if validation.get("manuscript_kind") == "paper" else normalize_text_list(validation.get("memo_reasons")),
    }


class PaperPipelineEngine:
    def __init__(
        self,
        *,
        config: BootstrapServiceConfig,
        openai_client: OpenAIClient,
        status_callback: StatusCallback | None = None,
        metrics_callback: MetricsCallback | None = None,
    ):
        self._config = config
        self._openai_client = openai_client
        self._status_callback = status_callback
        self._metrics_callback = metrics_callback

    def execute(self, *, run_id: str, request_payload: dict[str, Any]) -> dict[str, Any]:
        ledger = self.run_research_workspace(run_id=run_id, request_payload=request_payload)
        validation = self.validate_ledger(run_id=run_id, ledger=ledger)
        bundle = self.write_bundle(run_id=run_id, request_payload=request_payload, ledger=ledger, validation=validation)
        return {"ledger": ledger, "validation": validation, "bundle": bundle}

    def run_research_workspace(self, *, run_id: str, request_payload: dict[str, Any]) -> dict[str, Any]:
        self._emit_status(run_id, stage="inspect", status="running", progress_message="Inspecting data and executing the research workspace.")
        instructions = """
You are a scientist. The user has a research idea. Turn it into a real study.

1. Formulate a specific, testable research question from the user's idea.
2. Design a methods approach using available data and tools.
3. Execute the analysis: gather data, run computations, produce figures and tables, and save every artifact as a real file.
4. Record the results honestly.

Return strict JSON only with this exact shape:
{
  "title": "string",
  "research_question": "string",
  "methods": "string describing what you actually did in this run",
  "results": [
    {
      "text": "string",
      "artifact_ids": ["artifact_1"]
    }
  ],
  "limitations": ["string"],
  "sources": [
    {
      "source_id": "source_1",
      "label": "string",
      "landing_page_url": "string",
      "download_url": "string",
      "accession_id": "string",
      "api_endpoint": "string",
      "api_query": "string or object",
      "notes": "string"
    }
  ],
  "artifacts": [
    {
      "artifact_id": "artifact_1",
      "path": "artifacts/table_1.csv",
      "kind": "table or figure or stats or notebook or log",
      "mime_type": "text/csv",
      "description": "string",
      "source_ids": ["source_1"]
    }
  ]
}
Rules:
- Do original analytic work. Do not just summarize what others have found.
- Save every cited artifact as a real file in the container. Do not inline binary data or giant tables into JSON.
- Reference each saved file exactly by the filename or path you created so it can be retrieved later.
- Before returning, ensure every `artifacts[].path` value matches a real saved container file path or basename exactly. Rename files if needed.
- Every result must be backed by an artifact you created and saved in this run.
- Source provenance must include reproducible retrieval information such as an accession id, direct download URL, or concrete API query. Landing pages alone are insufficient.
- If the scientist provided must-use materials, use them as primary inputs.
- Methods must describe what you actually did in this run, not what prior literature says.
- If meaningful original work is not possible with available materials, return no results and explain that honestly in `limitations`.
- Be honest about limitations. Do not overclaim.
- Do not use synthetic, simulated, placeholder, demo, or draft language.
"""
        payload = {
            "title": request_payload["title"],
            "theme": request_payload["theme"],
            "notes": request_payload["notes"],
            "dataset_ids": request_payload.get("dataset_ids") or [],
            "dataset_hints": request_payload.get("dataset_hints") or [],
            "domain_guidance": str(request_payload.get("domain_guidance") or "").strip(),
        }
        must_use_sources = request_payload.get("must_use_sources") or []
        input_prefix_lines: list[str] = []
        if must_use_sources:
            input_prefix_lines.append("The scientist provided these materials as primary inputs. Use them:")
            for source in must_use_sources:
                if not isinstance(source, dict):
                    continue
                kind = str(source.get("kind") or "source").strip() or "source"
                url = str(source.get("url") or "").strip()
                notes = str(source.get("notes") or "").strip()
                if not url:
                    continue
                suffix = f": {notes}" if notes else ""
                input_prefix_lines.append(f"- [{kind}] {url}{suffix}")
        domain_guidance = str(request_payload.get("domain_guidance") or "").strip()
        if domain_guidance:
            input_prefix_lines.extend(["", "Scientist guidance:", domain_guidance])

        input_text = json.dumps(payload, sort_keys=True)
        if input_prefix_lines:
            input_text = "\n".join(input_prefix_lines).strip() + "\n\nTask payload:\n" + input_text

        response = self._openai_client.generate_json(
            instructions=instructions,
            input_text=input_text,
            use_code_interpreter=True,
            use_web_search=True,
            timeout_seconds=self._config.backend_max_job_runtime_seconds,
            model=self._config.openai_workspace_model,
        )
        self._emit_status(
            run_id,
            stage="inspect",
            progress_message="Research workspace complete. Saving artifact files and receipts.",
            openai_response_id=response.response_id,
        )
        self._emit_metrics(
            run_id,
            model=self._config.openai_workspace_model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
        )

        ledger = normalize_ledger(
            extract_json_object(response.output_text),
            title_fallback=str(request_payload.get("title") or "Research paper"),
        )
        downloaded_files = self.materialize_workspace_files(
            run_id=run_id,
            ledger=ledger,
            container_ids=self._openai_client.extract_container_ids(response),
        )
        self.apply_downloaded_files_to_ledger(ledger, downloaded_files)
        write_json_file(self.run_directory(run_id) / "ledger.json", ledger)
        return ledger

    def materialize_workspace_files(
        self,
        *,
        run_id: str,
        ledger: dict[str, Any],
        container_ids: list[str],
    ) -> list[DownloadedArtifactFile]:
        workspace_directory = self.run_directory(run_id)
        downloaded_files: list[DownloadedArtifactFile] = []
        claimed_artifact_ids: set[str] = set()
        container_files: list[OpenAIContainerFile] = []
        seen_file_keys: set[tuple[str, str]] = set()
        for container_id in container_ids:
            for container_file in self._openai_client.list_container_files(container_id=container_id):
                key = (container_file.container_id, container_file.file_id)
                if key in seen_file_keys:
                    continue
                seen_file_keys.add(key)
                container_files.append(container_file)

        claimed_file_keys: set[tuple[str, str]] = set()
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            if artifact_id and artifact_id in claimed_artifact_ids:
                continue
            declared_path = artifact_path_value(artifact)
            artifact_candidates = path_candidates(declared_path)
            if not artifact_candidates:
                continue

            matched_file = next(
                (
                    container_file
                    for container_file in container_files
                    if (container_file.container_id, container_file.file_id) not in claimed_file_keys
                    and artifact_candidates
                    & (path_candidates(container_file.path) | path_candidates(container_file.filename))
                ),
                None,
            )
            if matched_file is None:
                continue

            raw_bytes = self._openai_client.download_container_file_bytes(
                container_id=matched_file.container_id,
                file_id=matched_file.file_id,
            )
            fallback_name = Path(matched_file.path or matched_file.filename or matched_file.file_id).name or f"{matched_file.file_id}.bin"
            relative_path = sanitize_relative_path(
                declared_path or f"artifacts/{fallback_name}",
                fallback=f"artifacts/{fallback_name}",
            )
            destination = workspace_directory / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw_bytes)

            mime_type = matched_file.mime_type or guess_mime_type(relative_path)
            downloaded_files.append(
                DownloadedArtifactFile(
                    artifact_id=artifact_id or None,
                    container_id=matched_file.container_id,
                    file_id=matched_file.file_id,
                    filename=Path(relative_path).name,
                    relative_path=relative_path,
                    metadata_path=matched_file.path,
                    mime_type=mime_type,
                    sha256=_sha256_bytes(raw_bytes),
                )
            )
            claimed_file_keys.add((matched_file.container_id, matched_file.file_id))
            if artifact_id:
                claimed_artifact_ids.add(artifact_id)

        return downloaded_files

    def apply_downloaded_files_to_ledger(self, ledger: dict[str, Any], downloaded_files: list[DownloadedArtifactFile]) -> None:
        by_artifact_id = {
            downloaded_file.artifact_id: downloaded_file
            for downloaded_file in downloaded_files
            if downloaded_file.artifact_id
        }
        artifact_files: list[dict[str, Any]] = []
        for artifact in ledger.get("artifacts", []):
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            downloaded_file = by_artifact_id.get(artifact_id)
            if downloaded_file is None:
                continue
            artifact["path"] = downloaded_file.relative_path
            artifact["mime_type"] = artifact.get("mime_type") or downloaded_file.mime_type
            artifact["sha256"] = downloaded_file.sha256
            artifact_files.append(
                {
                    "artifact_id": artifact_id,
                    "path": downloaded_file.relative_path,
                    "mime_type": artifact.get("mime_type") or downloaded_file.mime_type,
                    "sha256": downloaded_file.sha256,
                }
            )
        ledger["artifact_files"] = artifact_files

    def validate_ledger(self, *, run_id: str, ledger: dict[str, Any]) -> dict[str, Any]:
        self._emit_status(run_id, stage="verify", progress_message="Verifying source receipts, artifacts, and manuscript routing.")
        run_directory = self.run_directory(run_id)
        valid_sources: dict[str, dict[str, Any]] = {}
        source_issues: list[str] = []
        for source in ledger.get("sources", []):
            if not isinstance(source, dict):
                continue
            source_id = str(source.get("source_id") or "").strip()
            if not source_id:
                continue
            if source_has_reproducible_receipt(source):
                valid_sources[source_id] = source
            else:
                source_issues.append(f"{source_id} is missing reproducible retrieval info.")

        valid_artifacts: dict[str, dict[str, Any]] = {}
        artifact_issues: list[str] = []
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            artifact_path = sanitize_relative_path(
                artifact_path_value(artifact),
                fallback=f"artifacts/{artifact_id or 'artifact'}",
            )
            path = run_directory / artifact_path
            if artifact_id and path.exists() and path.is_file():
                artifact["path"] = artifact_path
                artifact["mime_type"] = artifact.get("mime_type") or guess_mime_type(artifact_path)
                valid_artifacts[artifact_id] = artifact
            elif artifact_id:
                artifact_issues.append(f"{artifact_id} does not resolve to a saved file.")

        approved_results: list[dict[str, Any]] = []
        dropped_results: list[dict[str, Any]] = []
        for result in ledger.get("results", []):
            if not isinstance(result, dict):
                continue
            result_id = str(result.get("result_id") or "").strip()
            text = str(result.get("text") or "").strip()
            artifact_ids = [artifact_id for artifact_id in normalize_text_list(result.get("artifact_ids")) if artifact_id in valid_artifacts]

            source_ids: list[str] = []
            for artifact_id in artifact_ids:
                for source_id in artifact_source_ids(valid_artifacts[artifact_id]):
                    if source_id in valid_sources and source_id not in source_ids:
                        source_ids.append(source_id)

            reasons: list[str] = []
            if not text:
                reasons.append("result text is empty")
            banned_hits = find_banned_phrases(text)
            if banned_hits:
                reasons.append("result uses banned language: " + ", ".join(banned_hits))
            if not artifact_ids:
                reasons.append("result does not reference a saved artifact")
            if not source_ids:
                reasons.append("result does not resolve to reproducible source provenance")

            if reasons:
                dropped_results.append({"result_id": result_id or "result", "reasons": reasons, "text": text})
                continue

            approved_results.append(
                {
                    "result_id": result_id or f"result_{len(approved_results) + 1}",
                    "text": text,
                    "artifact_ids": artifact_ids,
                    "source_ids": source_ids,
                }
            )

        methods_text = str(ledger.get("methods") or "").strip()
        methods_lower = methods_text.lower()
        passive_summary_patterns = [
            r"\bwe reviewed\b",
            r"\bwe summarized\b",
            r"\bwe searched for\b",
            r"\bwe surveyed\b",
            r"\bwe examined the literature\b",
            r"\bliterature review\b",
        ]
        active_analysis_patterns = [
            r"\bwe (?:downloaded|queried|processed|cleaned|joined|fit|fitted|modeled|estimated|computed|analyzed|compared|calculated|measured)\b",
            r"\busing python\b",
            r"\bwe created\b",
            r"\bwe generated\b",
            r"\bwe extracted\b",
        ]
        passive_hits = [pattern for pattern in passive_summary_patterns if re.search(pattern, methods_lower)]
        active_hits = [pattern for pattern in active_analysis_patterns if re.search(pattern, methods_lower)]
        did_original_work = len(methods_text) >= 200 and bool(active_hits or not passive_hits)

        paper_checks = {
            "described_work_performed_here": did_original_work,
            "has_original_result": bool(ledger.get("results") or []),
            "has_artifact_backed_result": bool(approved_results),
        }
        memo_reasons: list[str] = []
        if not paper_checks["described_work_performed_here"]:
            memo_reasons.append("methods did not clearly describe substantial work performed in this run")
        if not paper_checks["has_original_result"]:
            memo_reasons.append("no artifact-backed original results survived validation")
        if not paper_checks["has_artifact_backed_result"]:
            memo_reasons.append("no original result resolved to a real saved artifact")

        validation_issues = source_issues + artifact_issues
        manuscript_kind = "paper" if all(paper_checks.values()) else "memo"

        approved_source_ids: list[str] = []
        for result in approved_results:
            for source_id in result.get("source_ids") or []:
                if source_id in valid_sources and source_id not in approved_source_ids:
                    approved_source_ids.append(source_id)
        if not approved_source_ids:
            approved_source_ids = list(valid_sources.keys())

        reference_catalog = [
            {
                "key": f"ref{index + 1}",
                "source_id": source_id,
                "text": format_reference_from_source(valid_sources[source_id]),
            }
            for index, source_id in enumerate(approved_source_ids)
            if source_id in valid_sources
        ]

        validation = {
            "status": manuscript_kind,
            "manuscript_kind": manuscript_kind,
            "final_format": manuscript_kind,
            "approved_results": approved_results,
            "approved_result_ids": [result["result_id"] for result in approved_results],
            "dropped_results": dropped_results,
            "validation_issues": validation_issues,
            "paper_checks": paper_checks,
            "memo_reasons": memo_reasons,
            "reference_catalog": reference_catalog,
            "summary": (
                f"Paper checks passed with {len(approved_results)} artifact-backed result(s)."
                if manuscript_kind == "paper"
                else "Routing to a research memo because the run did not clear the paper gate."
            ),
        }
        write_json_file(run_directory / "validation.json", validation)
        return validation

    def write_bundle(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        ledger: dict[str, Any],
        validation: dict[str, Any],
    ) -> dict[str, Any]:
        self._emit_status(run_id, stage="write", progress_message="Writing manuscript sections from the validated research record.")
        instructions = """
You are Sidekick's paper writer.
You receive a validated research record and must write the final manuscript as a real scientific paper, not as an evidence memo or project log.
Return strict JSON only with this exact shape:
{
  "title": "string",
  "abstract": "string",
  "introduction": "string",
  "methods": "string",
  "results": "string",
  "discussion": "string",
  "limitations": "string",
  "references": ["formatted reference strings"]
}
Writing goals:
- Make the paper read like a credible manuscript submission: specific, analytic, quantitative, and professionally structured.
- Write section bodies as coherent manuscript prose, usually in 2-4 paragraphs when the material supports it.
- Abstract: context, exact system studied, what was done in this run, 2-3 concrete findings with numbers when available, and the main implication.
- Introduction: frame the problem, identify the gap, and state this paper's contribution without boilerplate.
- Methods: describe the actual workflow, assumptions, datasets, models, and analysis steps performed in this run.
- Results: organize around the main empirical patterns, quote the strongest validated quantitative comparisons, and explicitly interpret what the saved figures and tables show.
- Discussion: explain what the findings mean, where they are strongest, and what they imply in practice while staying within the evidence.
- Limitations: concise, honest, and specific.
Rules:
- Use `validation.approved_results` as the only source of empirical findings and quantitative claims. Do not add new findings, estimates, or sources.
- You may use `ledger.research_question`, `ledger.methods`, `ledger.limitations`, `artifact_manifest`, and `validation.reference_catalog` for framing, methods description, and citations.
- Use `validation.manuscript_kind` as authoritative. Do not upgrade a memo into a paper.
- Use citation placeholders like `[[CITE:ref1]]` and cross-reference placeholders like `[[REF:fig:artifact-1]]` or `[[REF:tab:artifact-2]]`.
- Use only citation keys from `validation.reference_catalog`.
- Use only figure/table labels present in `artifact_manifest`.
- You may use standard LaTeX inside section bodies when it improves scientific fidelity, including inline math, display math, `\\emph{...}`, `\\textbf{...}`, and unnumbered `\\subsection*{...}` headings. Do not emit a document preamble or figure/table environments.
- Preserve domain notation, units, inequalities, and mathematical expressions rather than flattening them into generic prose.
- When tables or figures are present, discuss the key empirical pattern they show in the Results section instead of ignoring them.
- Prefer precise titles over generic ones when the record supports a sharper manuscript title.
- Keep the references array aligned with `validation.reference_catalog`; do not invent references outside that catalog.
- Include the research question, methods performed in this run, and limitations honestly.
- Do not use draft, demo, placeholder, simulated, synthetic, or definitive-proof language.
"""
        run_directory = self.run_directory(run_id)
        artifact_manifest = build_manuscript_manifest(
            job_directory=run_directory,
            artifacts=ledger.get("artifacts") or [],
            sanitize_relative_path=sanitize_relative_path,
            artifact_path_value=artifact_path_value,
            guess_mime_type=guess_mime_type,
        )
        input_text = json.dumps(
            {
                "title": request_payload["title"],
                "theme": request_payload["theme"],
                "ledger": ledger,
                "validation": validation,
                "artifact_manifest": artifact_manifest,
            },
            sort_keys=True,
        )
        response = self._openai_client.generate_json(
            instructions=instructions,
            input_text=input_text,
            use_code_interpreter=False,
            use_web_search=False,
            timeout_seconds=min(900, self._config.backend_max_job_runtime_seconds),
            model=self._config.openai_writer_model,
        )
        self._emit_status(
            run_id,
            stage="write",
            progress_message="Manuscript prose complete. Rendering LaTeX and compiling the PDF.",
            openai_response_id=response.response_id,
        )
        self._emit_metrics(
            run_id,
            model=self._config.openai_writer_model,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
        )

        written = normalize_manuscript_sections(
            extract_json_object(response.output_text),
            title_fallback=str(ledger.get("title") or request_payload["title"]),
        )
        reference_catalog_texts = [
            str(entry.get("text") or "").strip()
            for entry in validation.get("reference_catalog") or []
            if str(entry.get("text") or "").strip()
        ]
        if reference_catalog_texts:
            written["references"] = reference_catalog_texts
        prose_for_banned_check = "\n".join(
            [
                written.get("abstract") or "",
                written.get("introduction") or "",
                written.get("methods") or "",
                written.get("results") or "",
                written.get("discussion") or "",
                written.get("limitations") or "",
            ]
        )
        if not prose_for_banned_check.strip():
            raise PipelineExecutionError("Writer did not return manuscript prose.", stage="write")
        banned_hits = find_banned_phrases(prose_for_banned_check)
        if banned_hits:
            raise PipelineExecutionError("Writer returned banned language in manuscript prose.", stage="write")

        return self.render_bundle(
            run_id=run_id,
            request_payload=request_payload,
            ledger=ledger,
            validation=validation,
            sections=written,
        )

    def render_bundle(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        ledger: dict[str, Any],
        validation: dict[str, Any],
        sections: dict[str, Any],
    ) -> dict[str, Any]:
        run_directory = self.run_directory(run_id)
        written = normalize_manuscript_sections(
            sections,
            title_fallback=str(ledger.get("title") or request_payload["title"]),
        )

        figures = self.bundle_figures_from_ledger(run_id=run_id, ledger=ledger)
        verification = build_verification_payload(validation, figures)
        provenance = build_task_provenance(ledger)
        manuscript_kind = str(validation.get("manuscript_kind") or "paper").strip() or "paper"
        title = str(written.get("title") or ledger.get("title") or request_payload["title"]).strip() or request_payload["title"]
        artifact_manifest = build_manuscript_manifest(
            job_directory=run_directory,
            artifacts=ledger.get("artifacts") or [],
            sanitize_relative_path=sanitize_relative_path,
            artifact_path_value=artifact_path_value,
            guess_mime_type=guess_mime_type,
        )
        latex, references_bib = render_latex(
            title=title,
            sections=written,
            manifest=artifact_manifest,
            manuscript_kind=manuscript_kind,
            reference_catalog=validation.get("reference_catalog") or [],
        )
        base_filename = "memo" if manuscript_kind == "memo" else "paper"
        tex_filename = f"{base_filename}.tex"
        (run_directory / tex_filename).write_text(latex, encoding="utf-8")
        (run_directory / "references.bib").write_text(references_bib, encoding="utf-8")
        write_json_file(run_directory / "sections.json", written)
        write_json_file(run_directory / "artifact_manifest.json", artifact_manifest)

        compile_result = compile_pdf(run_directory, tex_filename=tex_filename)
        compile_log = str(compile_result.get("error") or "").strip()
        if str(compile_result.get("log") or "").strip():
            compile_log = (compile_log + "\n\n" if compile_log else "") + str(compile_result.get("log") or "").strip()
        if compile_log:
            (run_directory / "compile.log").write_text(compile_log, encoding="utf-8")

        markdown_preview = results_to_markdown(written, manuscript_kind=manuscript_kind)
        bundle = {
            "title": title,
            "manuscript_kind": manuscript_kind,
            "sections": written,
            "latex": latex,
            "references_bib": references_bib,
            "artifact_manifest": artifact_manifest,
            "pdf": {
                "ok": bool(compile_result.get("ok")),
                "filename": compile_result.get("pdf_path") or f"{base_filename}.pdf",
                "error": str(compile_result.get("error") or "").strip(),
                "log": str(compile_result.get("log") or "").strip(),
            },
            "figures": figures,
            "provenance": provenance,
            "verification": verification,
            "draft": {"title": title, "markdown": markdown_preview},
            "ledger": ledger,
            "validation": validation,
            "artifact_files": ledger.get("artifact_files", []),
        }
        write_json_file(run_directory / "bundle.json", {"bundle": bundle, "publication": None})
        return bundle

    def bundle_figures_from_ledger(self, *, run_id: str, ledger: dict[str, Any]) -> list[dict[str, Any]]:
        figures: list[dict[str, Any]] = []
        run_directory = self.run_directory(run_id)
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            artifact_path = str(artifact.get("path") or "").strip()
            mime_type = str(artifact.get("mime_type") or "").strip() or guess_mime_type(artifact_path)
            if not artifact_path or not mime_type.startswith("image/"):
                continue
            path = run_directory / artifact_path
            if not path.exists() or not path.is_file():
                continue
            figures.append(
                {
                    "filename": path.name,
                    "caption": str(artifact.get("description") or "").strip(),
                    "mime_type": mime_type,
                    "base64_data": base64.b64encode(path.read_bytes()).decode("utf-8"),
                }
            )
        return figures

    def run_directory(self, run_id: str) -> Path:
        directory = self._config.artifact_root / run_id
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def _emit_status(
        self,
        run_id: str,
        *,
        stage: str,
        progress_message: str,
        status: str | None = None,
        openai_response_id: str | None = None,
    ) -> None:
        if self._status_callback is None:
            return
        self._status_callback(
            run_id,
            stage=stage,
            progress_message=progress_message,
            status=status,
            openai_response_id=openai_response_id,
        )

    def _emit_metrics(self, run_id: str, *, model: str, input_tokens: int, output_tokens: int) -> None:
        if self._metrics_callback is None:
            return
        self._metrics_callback(
            run_id,
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )
