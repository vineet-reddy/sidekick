from __future__ import annotations

import base64
import hashlib
import json
import mimetypes
import re
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .config import BootstrapServiceConfig
from .manuscript import (
    build_manuscript_manifest,
    compile_pdf,
    normalize_manuscript_sections,
    render_latex,
    results_to_markdown,
)
from .openai_client import OpenAIClient, OpenAIContainerFile, OpenAIResponseResult
from .pipeline_runtime import SidekickRunStore
from .resolver import SourceFamilyResolver

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
            try:
                payload, _ = decoder.raw_decode(_repair_json_like_text(raw_text[index:]))
            except json.JSONDecodeError:
                continue
        if isinstance(payload, dict):
            return payload
    raise ValueError("Model output did not contain a JSON object.")


def _repair_json_like_text(raw_text: str) -> str:
    repaired: list[str] = []
    in_string = False
    index = 0
    while index < len(raw_text):
        character = raw_text[index]
        if not in_string:
            repaired.append(character)
            if character == '"':
                in_string = True
            index += 1
            continue
        if character == "\\":
            next_character = raw_text[index + 1] if index + 1 < len(raw_text) else ""
            if next_character in {'"', "\\", "/", "b", "f", "n", "r", "t"}:
                repaired.extend(["\\", next_character])
                index += 2
                continue
            repaired.extend(["\\", "\\"])
            index += 1
            continue
        if character == "\n":
            repaired.append("\\n")
            index += 1
            continue
        if character == "\r":
            repaired.append("\\r")
            index += 1
            continue
        if character == "\t":
            repaired.append("\\t")
            index += 1
            continue
        repaired.append(character)
        if character == '"':
            in_string = False
        index += 1
    return "".join(repaired)


def normalize_text_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def derive_note_title(content: str, *, fallback: str) -> str:
    for line in content.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:120]
    return fallback


def normalize_request_notes(value: Any) -> list[dict[str, str]]:
    if isinstance(value, list):
        normalized_notes: list[dict[str, str]] = []
        for index, entry in enumerate(value):
            if isinstance(entry, dict):
                content = str(entry.get("content") or "").strip()
                note_id = str(entry.get("id") or f"note_{index + 1}").strip() or f"note_{index + 1}"
                title = str(entry.get("title") or "").strip()
            else:
                content = str(entry).strip()
                note_id = f"note_{index + 1}"
                title = ""
            if not content:
                continue
            normalized_notes.append(
                {
                    "id": note_id,
                    "title": title or derive_note_title(content, fallback=f"Note {index + 1}"),
                    "content": content,
                }
            )
        return normalized_notes
    if isinstance(value, str) and value.strip():
        content = value.strip()
        return [{"id": "note_1", "title": derive_note_title(content, fallback="Note 1"), "content": content}]
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


def build_validation_error_message(validation: dict[str, Any]) -> str:
    message = str(validation.get("feedback_message") or validation.get("summary") or "Validation blocked the paper.").strip()
    if message:
        return message
    return "Validation blocked the paper."


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    return {
        "artifact_id": str(entry.get("artifact_id") or f"artifact_{index + 1}").strip() or f"artifact_{index + 1}",
        "path": artifact_path_value(entry),
        "kind": str(entry.get("kind") or entry.get("artifact_type") or "artifact").strip() or "artifact",
        "mime_type": str(entry.get("mime_type") or "").strip(),
        "description": str(entry.get("description") or entry.get("caption") or "").strip(),
        "source_ids": artifact_source_ids(entry),
    }


def _normalize_figure_summary(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    artifact_id = str(entry.get("artifact_id") or f"artifact_{index + 1}").strip() or f"artifact_{index + 1}"
    return {
        "artifact_id": artifact_id,
        "title": str(entry.get("title") or f"Figure {index + 1}").strip() or f"Figure {index + 1}",
        "summary_markdown": str(entry.get("summary_markdown") or entry.get("summary") or "").strip(),
    }


def source_matches_resolution_source(source: dict[str, Any], selected_candidate: dict[str, Any]) -> bool:
    dataset_id = str(selected_candidate.get("dataset_id") or "").strip().lower()
    access_url = str(selected_candidate.get("access_url") or "").strip().lower()
    source_values = [
        str(source.get("accession_id") or "").strip().lower(),
        str(source.get("download_url") or "").strip().lower(),
        str(source.get("landing_page_url") or "").strip().lower(),
        str(source.get("api_endpoint") or "").strip().lower(),
    ]
    if dataset_id and any(dataset_id == value or dataset_id in value for value in source_values if value):
        return True
    if access_url and any(access_url == value or access_url in value for value in source_values if value):
        return True
    return False


class PaperPipelineEngine:
    def __init__(
        self,
        *,
        config: BootstrapServiceConfig,
        openai_client: OpenAIClient,
        status_callback: StatusCallback | None = None,
        metrics_callback: MetricsCallback | None = None,
        source_resolver: SourceFamilyResolver | None = None,
    ):
        self._config = config
        self._openai_client = openai_client
        self._status_callback = status_callback
        self._metrics_callback = metrics_callback
        self._source_resolver = source_resolver

    def resolve_request_payload(self, request_payload: dict[str, Any]) -> dict[str, Any]:
        resolved = dict(request_payload)
        resolved["notes"] = normalize_request_notes(resolved.get("notes"))
        if not resolved.get("title"):
            resolved["title"] = derive_note_title(
                "\n\n".join(note["content"] for note in resolved["notes"]),
                fallback="Untitled research run",
            )
        if not resolved.get("theme"):
            resolved["theme"] = resolved["title"]
        return resolved

    def execute(self, *, run_id: str, request_payload: dict[str, Any]) -> dict[str, Any]:
        payload = self.resolve_request_payload(request_payload)
        store = self._run_store(run_id)
        run_directory = self.run_directory(run_id)
        store.reset_logs()
        write_json_file(run_directory / "input.json", payload)
        note_text = "\n\n".join(note["content"] for note in payload.get("notes", []))
        store.begin_run(note=note_text, title=str(payload.get("title") or "Research paper"))
        try:
            search = self._resolved_stage_one_search(request_payload=payload)
            if search is not None:
                self._persist_resolved_stage_one_search(run_id=run_id, search=search)
            else:
                search = self.run_stage_one(run_id=run_id, request_payload=payload)
            ledger, validation = self.run_stage_two_loop(run_id=run_id, request_payload=payload, search=search)
            bundle = self.write_bundle(
                run_id=run_id,
                request_payload=payload,
                ledger=ledger,
                validation=validation,
            )
            return {"search": search, "ledger": ledger, "validation": validation, "bundle": bundle}
        except PipelineExecutionError as error:
            store.fail_run(stage=error.stage, reason=str(error), exit_code=self._exit_code_for_stage(error.stage))
            raise
        except Exception as error:
            store.fail_run(stage="internal", reason=str(error), exit_code=20)
            raise PipelineExecutionError(str(error), stage="internal") from error

    def run_stage_one(self, *, run_id: str, request_payload: dict[str, Any]) -> dict[str, Any]:
        store = self._run_store(run_id)
        resolved_search = self._resolved_stage_one_search(request_payload=request_payload)
        if resolved_search is not None:
            self._persist_resolved_stage_one_search(run_id=run_id, search=resolved_search)
            return resolved_search
        allowlist = request_payload.get("allowed_domains") or [
            "nih.gov", "cdc.gov", "data.gov", "zenodo.org", "figshare.com",
            "dataverse.harvard.edu", "openneuro.org", "dandiarchive.org", "physionet.org",
        ]
        prompt_payload = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "notes": request_payload.get("notes") or [],
            "allow_list_domains": allowlist,
        }
        instructions = """
You are a Sidekick web search agent.
Rewrite the user's rough note into a specific research question, check whether that question already appears answered online, and narrow it until the question is plausibly novel.
Then find a real dataset that can answer it.
Return strict JSON only:
{
  "status": "found or not_found",
  "research_question": "string",
  "novelty_rationale": "string",
  "existing_work_gap": "string",
  "dataset": {
    "label": "string",
    "landing_page_url": "string",
    "download_url": "string",
    "accession_id": "string",
    "notes": "string",
    "domain": "string"
  },
  "related_work": ["string"],
  "failure_reason": "string"
}
Rules:
- If you cannot find a dataset that genuinely fits, return status=not_found.
- Prefer direct dataset access, accession ids, or download links over vague landing pages.
- Do not invent novelty. If the current question is already answered, narrow it.
- Keep the answer concrete and operational for a downstream data analyst.
"""

        def run_agent(agent: str, domain_mode: str, model: str, reasoning_effort: str | None) -> dict[str, Any]:
            store.log(stage="1", agent=agent, level="info", message=f"Searching for a dataset via {domain_mode}.")
            domain_guidance = (
                f"Search only within these allow-listed domains: {', '.join(str(domain) for domain in allowlist)}."
                if domain_mode == "allow_list"
                else "Search the open web without allow-list restrictions."
            )
            output = self._run_model_json(
                run_id=run_id,
                stage="1",
                agent=agent,
                model=model,
                instructions=instructions,
                input_text=json.dumps(prompt_payload, sort_keys=True) + "\n\n" + domain_guidance,
                use_code_interpreter=False,
                use_web_search=True,
                timeout_seconds=min(900, self._config.backend_max_job_runtime_seconds),
                reasoning_effort=reasoning_effort,
            )
            output["agent"] = agent
            output["domain_mode"] = domain_mode
            return output

        store.set_stage(stage="1", agent="search-a", model=self._config.openai_search_model)
        with ThreadPoolExecutor(max_workers=2) as executor:
            future_a = executor.submit(run_agent, "search-a", "allow_list", self._config.openai_search_model, None)
            future_b = executor.submit(run_agent, "search-b", "open_web", self._config.openai_search_model, None)
            result_a = future_a.result()
            result_b = future_b.result()

        winner = self._choose_search_winner([result_a, result_b])
        if winner is None:
            winner = self._choose_legacy_search_candidate([result_a, result_b])
        if winner is None:
            store.log(stage="1", agent="search-c", level="warn", message="Primary search agents failed; escalating to deeper retry.")
            store.emit_event("RETRY_STARTED", stage="1", attempt=1, feedback_from_previous="Both search agents failed to find a dataset.")
            winner = run_agent("search-c", "open_web", self._config.openai_workspace_model, "medium")

        if str(winner.get("status") or "").strip().lower() != "found":
            if winner.get("research_question") and (winner.get("sources") or winner.get("artifacts")):
                sources = winner.get("sources") if isinstance(winner.get("sources"), list) else []
                dataset_source = sources[0] if sources and isinstance(sources[0], dict) else {}
                precomputed_ledger = {
                    "title": str(request_payload.get("title") or "Research paper"),
                    "research_question": str(winner.get("research_question") or "").strip(),
                    "dataset": {
                        "label": str(dataset_source.get("label") or "Primary dataset").strip(),
                        "landing_page_url": str(dataset_source.get("landing_page_url") or "").strip(),
                        "download_url": str(dataset_source.get("download_url") or "").strip(),
                        "accession_id": str(dataset_source.get("accession_id") or "").strip(),
                        "notes": str(dataset_source.get("notes") or "").strip(),
                    },
                    "experiment_summary": str(winner.get("methods") or "").strip(),
                    "experiments": [str(winner.get("methods") or "").strip()] if str(winner.get("methods") or "").strip() else [],
                    "findings": [
                        str(entry.get("text") or "").strip()
                        for entry in winner.get("results") or []
                        if isinstance(entry, dict) and str(entry.get("text") or "").strip()
                    ],
                    "limitations": normalize_text_list(winner.get("limitations")),
                    "code_summary": "",
                    "sources": [_normalize_source(entry, index) for index, entry in enumerate(winner.get("sources") or [])],
                    "artifacts": [_normalize_artifact(entry, index) for index, entry in enumerate(winner.get("artifacts") or [])],
                    "figure_summaries": [],
                    "results": winner.get("results") or [],
                    "attempt": 1,
                }
                winner["status"] = "found"
                winner["dataset"] = precomputed_ledger["dataset"]
                winner["_precomputed_ledger"] = precomputed_ledger
                if winner.get("_response") is not None:
                    winner["_precomputed_container_ids"] = self._openai_client.extract_container_ids(winner["_response"])
            else:
                reason = str(winner.get("failure_reason") or "No relevant dataset found.").strip() or "No relevant dataset found."
                store.fail_stage(stage="1", agent=str(winner.get("agent") or "search-c"), reason=reason, retries_remaining=0)
                raise PipelineExecutionError(reason, stage="1")

        dataset = winner.get("dataset") if isinstance(winner.get("dataset"), dict) else {}
        search = {
            "research_question": str(winner.get("research_question") or "").strip(),
            "novelty_rationale": str(winner.get("novelty_rationale") or "").strip(),
            "existing_work_gap": str(winner.get("existing_work_gap") or "").strip(),
            "dataset": {
                "label": str(dataset.get("label") or "").strip(),
                "landing_page_url": str(dataset.get("landing_page_url") or "").strip(),
                "download_url": str(dataset.get("download_url") or "").strip(),
                "accession_id": str(dataset.get("accession_id") or "").strip(),
                "notes": str(dataset.get("notes") or "").strip(),
                "domain": str(dataset.get("domain") or dataset.get("domain_mode") or "").strip(),
            },
            "related_work": normalize_text_list(winner.get("related_work")),
            "selected_agent": str(winner.get("agent") or "").strip(),
        }
        if winner.get("_precomputed_ledger"):
            search["_precomputed_ledger"] = winner["_precomputed_ledger"]
            search["_precomputed_container_ids"] = winner.get("_precomputed_container_ids") or []
        write_json_file(self.run_directory(run_id) / "stage1.json", search)
        store.record_artifact(
            stage="1",
            artifact_id="stage1-search",
            artifact_type="search_record",
            path="stage1.json",
            description="Validated research question and dataset selection.",
        )
        store.complete_stage(stage="1", agent=str(winner.get("agent") or "search"), artifacts=["stage1.json"])
        return search

    def _resolved_stage_one_search(self, *, request_payload: dict[str, Any]) -> dict[str, Any] | None:
        resolution = request_payload.get("resolution") if isinstance(request_payload.get("resolution"), dict) else {}
        if not resolution and self._source_resolver is not None and normalize_text_list(request_payload.get("dataset_ids")):
            resolution = self._source_resolver.resolve(
                title=str(request_payload.get("title") or "Research paper"),
                theme=str(request_payload.get("theme") or request_payload.get("title") or ""),
                notes=normalize_request_notes(request_payload.get("notes")),
                dataset_hints=normalize_text_list(request_payload.get("dataset_hints")),
                dataset_ids=normalize_text_list(request_payload.get("dataset_ids")),
            ).as_dict()
        selected_candidate = resolution.get("selected_candidate") if isinstance(resolution.get("selected_candidate"), dict) else {}
        if str(resolution.get("status") or "").strip().lower() != "resolved" or not selected_candidate:
            return None
        return {
            "research_question": str(request_payload.get("theme") or request_payload.get("title") or "").strip(),
            "novelty_rationale": str(resolution.get("summary") or "").strip(),
            "existing_work_gap": str(resolution.get("summary") or "").strip(),
            "dataset": {
                "label": str(selected_candidate.get("title") or request_payload.get("title") or "Primary dataset").strip(),
                "landing_page_url": str(selected_candidate.get("access_url") or "").strip(),
                "download_url": (
                    str((selected_candidate.get("download_urls") or [""])[0] or "").strip()
                    if isinstance(selected_candidate.get("download_urls"), list)
                    else ""
                ),
                "accession_id": str(selected_candidate.get("dataset_id") or "").strip(),
                "notes": str(selected_candidate.get("provenance_note") or resolution.get("summary") or "").strip(),
                "domain": str(selected_candidate.get("primary_domain") or "").strip(),
            },
            "related_work": [],
            "selected_agent": "resolver",
        }

    def _persist_resolved_stage_one_search(self, *, run_id: str, search: dict[str, Any]) -> None:
        store = self._run_store(run_id)
        store.set_stage(stage="1", agent="resolver", model="resolver")
        self._emit_status(
            run_id,
            stage="1",
            progress_message="resolver selected the dataset from the trusted source resolver.",
            status="running",
        )
        write_json_file(self.run_directory(run_id) / "stage1.json", search)
        store.record_artifact(
            stage="1",
            artifact_id="stage1-search",
            artifact_type="search_record",
            path="stage1.json",
            description="Resolved dataset selection carried forward from the trusted source resolver.",
        )
        store.complete_stage(stage="1", agent="resolver", artifacts=["stage1.json"])

    def run_stage_two_loop(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        search: dict[str, Any],
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        retries_remaining = 2
        feedback_messages: list[str] = []
        prior_attempts: list[dict[str, Any]] = []
        attempt = 1
        last_ledger: dict[str, Any] | None = None
        last_validation: dict[str, Any] | None = None
        if isinstance(search.get("_precomputed_ledger"), dict):
            ledger = dict(search["_precomputed_ledger"])
            container_ids = [str(entry).strip() for entry in search.get("_precomputed_container_ids") or [] if str(entry).strip()]
            if container_ids:
                downloaded_files = self.materialize_workspace_files(
                    run_id=run_id,
                    ledger=ledger,
                    container_ids=container_ids,
                )
                self.apply_downloaded_files_to_ledger(ledger, downloaded_files)
            if "artifact_files" not in ledger:
                ledger["artifact_files"] = []
            self._ensure_artifact_metadata(ledger)
            write_json_file(self.run_directory(run_id) / "ledger.json", ledger)
            validation = self.validate_ledger(run_id=run_id, ledger=ledger, request_payload=request_payload)
            return ledger, validation
        while attempt <= 3:
            ledger = self.run_research_workspace(
                run_id=run_id,
                request_payload=request_payload,
                search=search,
                attempt=attempt,
                feedback_messages=feedback_messages,
                prior_attempts=prior_attempts,
            )
            validation = self.validate_ledger(
                run_id=run_id,
                ledger=ledger,
                request_payload=request_payload,
            )
            self._run_store(run_id).record_retry(
                attempt=attempt,
                status=str(validation.get("status") or "fail"),
                feedback_message=str(validation.get("feedback_message") or "").strip(),
                experiment_summary=str(ledger.get("experiment_summary") or "").strip(),
                validation=validation,
            )
            if str(validation.get("status") or "").strip().lower() == "pass":
                return ledger, validation
            retries_remaining -= 1
            if retries_remaining < 0:
                break
            feedback = str(validation.get("feedback_message") or validation.get("summary") or "").strip()
            feedback_messages.append(feedback)
            prior_attempts.append(
                {
                    "attempt": attempt,
                    "experiment_summary": ledger.get("experiment_summary"),
                    "figure_summaries": ledger.get("figure_summaries") or [],
                    "findings": ledger.get("findings") or [],
                    "feedback_message": feedback,
                }
            )
            self._run_store(run_id).emit_event(
                "RETRY_STARTED",
                stage="2",
                attempt=attempt + 1,
                feedback_from_previous=feedback,
            )
            attempt += 1
            last_ledger = ledger
            last_validation = validation
        reason = build_validation_error_message(last_validation or {})
        self._run_store(run_id).fail_stage(stage="2.5", agent="validation", reason=reason, retries_remaining=0)
        raise PipelineExecutionError(reason, stage="2.5")

    def run_research_workspace(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        search: dict[str, Any] | None = None,
        attempt: int = 1,
        feedback_messages: list[str] | None = None,
        prior_attempts: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        if search is None:
            stage1_path = self.run_directory(run_id) / "stage1.json"
            if stage1_path.exists():
                search = read_json_file(stage1_path)
        if search is None and self._source_resolver is not None:
            resolution = self._source_resolver.resolve(
                title=str(request_payload.get("title") or "Research paper"),
                theme=str(request_payload.get("theme") or request_payload.get("title") or ""),
                notes=normalize_request_notes(request_payload.get("notes")),
                dataset_hints=normalize_text_list(request_payload.get("dataset_hints")),
                dataset_ids=normalize_text_list(request_payload.get("dataset_ids")),
            ).as_dict()
            if str(resolution.get("paper_mode") or "").strip() == "empirical_dataset" and str(resolution.get("status") or "").strip() == "blocked":
                message = str(resolution.get("blocking_reason") or resolution.get("summary") or "No qualifying dataset found.").strip()
                raise PipelineExecutionError(message, stage="inspect")
        if search is None:
            raise PipelineExecutionError("Stage 1 search output is missing.", stage="1")
        feedback_messages = feedback_messages or []
        prior_attempts = prior_attempts or []
        store = self._run_store(run_id)
        store.set_stage(stage="2", agent="data-analyst", model=self._config.openai_workspace_model)
        instructions = """
You are Sidekick's data analyst.
Download the dataset, research what experiments already exist in this area, design meaningful experiments, run them, and save reproducible analysis files in the compute sandbox.
Return strict JSON only:
{
  "research_question": "string",
  "dataset": {
    "label": "string",
    "landing_page_url": "string",
    "download_url": "string",
    "accession_id": "string",
    "notes": "string"
  },
  "experiment_summary": "string",
  "experiments": ["string"],
  "findings": ["string"],
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
      "path": "analysis/run_analysis.py",
      "kind": "code or figure or table or notebook or dataset or log",
      "mime_type": "text/x-python",
      "description": "string",
      "source_ids": ["source_1"]
    }
  ],
  "figure_summaries": [
    {
      "artifact_id": "artifact_2",
      "title": "Figure 1",
      "summary_markdown": "plain markdown description of what the figure shows"
    }
  ],
  "code_summary": "string"
}
Rules:
- Use the dataset from the task payload. Do not swap in a different substrate.
- Save executable code files, generated figures, and any key intermediate tables as real files.
- Figure summaries are mandatory and are the source of truth for the writer.
- If validation feedback is provided, directly address it instead of repeating the same experiment.
- Be honest. If a line of inquiry fails, say so and pivot to a better experiment on the same data.
"""
        analyst_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": search.get("research_question"),
            "dataset": search.get("dataset"),
            "related_work": search.get("related_work") or [],
            "attempt": attempt,
            "validation_feedback": feedback_messages,
            "prior_attempts": prior_attempts,
        }
        response_payload = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="data-analyst",
            model=self._config.openai_workspace_model,
            instructions=instructions,
            input_text=json.dumps(analyst_input, sort_keys=True),
            use_code_interpreter=True,
            use_web_search=True,
            timeout_seconds=self._config.backend_max_job_runtime_seconds,
            reasoning_effort="medium",
        )
        response = response_payload.pop("_response")
        ledger = {
            "title": str(request_payload.get("title") or "Research paper"),
            "research_question": str(response_payload.get("research_question") or search.get("research_question") or "").strip(),
            "dataset": search.get("dataset") or {},
            "experiment_summary": str(response_payload.get("experiment_summary") or "").strip(),
            "experiments": normalize_text_list(response_payload.get("experiments")),
            "findings": normalize_text_list(response_payload.get("findings")),
            "limitations": normalize_text_list(response_payload.get("limitations")),
            "code_summary": str(response_payload.get("code_summary") or "").strip(),
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(response_payload.get("sources") or [])],
            "artifacts": [_normalize_artifact(entry, index) for index, entry in enumerate(response_payload.get("artifacts") or [])],
            "figure_summaries": [
                _normalize_figure_summary(entry, index) for index, entry in enumerate(response_payload.get("figure_summaries") or [])
            ],
            "search": search,
            "attempt": attempt,
        }
        downloaded_files = self.materialize_workspace_files(
            run_id=run_id,
            ledger=ledger,
            container_ids=self._openai_client.extract_container_ids(response),
        )
        self.apply_downloaded_files_to_ledger(ledger, downloaded_files)
        if not ledger["sources"]:
            ledger["sources"].append(
                _normalize_source(
                    {
                        "source_id": "source_dataset",
                        "label": search.get("dataset", {}).get("label") or "Primary dataset",
                        "landing_page_url": search.get("dataset", {}).get("landing_page_url"),
                        "download_url": search.get("dataset", {}).get("download_url"),
                        "accession_id": search.get("dataset", {}).get("accession_id"),
                        "notes": search.get("dataset", {}).get("notes"),
                    },
                    0,
                )
            )
        self._ensure_artifact_metadata(ledger)
        write_json_file(self.run_directory(run_id) / "ledger.json", ledger)
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            path = str(artifact.get("path") or "").strip()
            if not path:
                continue
            store.record_artifact(
                stage="2",
                artifact_id=str(artifact.get("artifact_id") or Path(path).stem),
                artifact_type=str(artifact.get("kind") or "artifact"),
                path=path,
                description=str(artifact.get("description") or "").strip(),
            )
        store.complete_stage(stage="2", agent="data-analyst", artifacts=[artifact.get("path") for artifact in ledger.get("artifacts", []) if artifact.get("path")])
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
                    and artifact_candidates & (path_candidates(container_file.path) | path_candidates(container_file.filename))
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
            relative_path = sanitize_relative_path(declared_path or f"artifacts/{fallback_name}", fallback=f"artifacts/{fallback_name}")
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
        by_artifact_id = {entry.artifact_id: entry for entry in downloaded_files if entry.artifact_id}
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

    def validate_ledger(
        self,
        *,
        run_id: str,
        ledger: dict[str, Any],
        request_payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if (ledger.get("results") or not getattr(self._openai_client, "generate_json", None)):
            return self._legacy_validate_ledger(run_id=run_id, ledger=ledger, request_payload=request_payload)
        store = self._run_store(run_id)
        store.set_stage(stage="2.5", agent="validation", model=self._config.openai_validation_model)
        input_payload = {
            "research_question": ledger.get("research_question"),
            "experiment_summary": ledger.get("experiment_summary"),
            "experiments": ledger.get("experiments") or [],
            "findings": ledger.get("findings") or [],
            "figure_summaries": ledger.get("figure_summaries") or [],
            "attempt": ledger.get("attempt"),
        }
        instructions = """
You are Sidekick's lightweight validation gate.
Decide whether the current analysis gives the writer a coherent story to write up.
Return strict JSON only:
{
  "decision": "pass or fail",
  "summary": "string",
  "feedback_message": "string",
  "coherent_narrative": true,
  "meaningful_finding": true
}
Rules:
- The bar is low. Pass any run that has a coherent story and at least one meaningful finding.
- If failing, feedback_message must say what is incoherent or missing and what the analyst should try differently next.
- Do not ask for perfection.
"""
        result = self._run_model_json(
            run_id=run_id,
            stage="2.5",
            agent="validation",
            model=self._config.openai_validation_model,
            instructions=instructions,
            input_text=json.dumps(input_payload, sort_keys=True),
            use_code_interpreter=False,
            use_web_search=False,
            timeout_seconds=300,
            reasoning_effort=None,
        )
        decision = str(result.get("decision") or "").strip().lower()
        status = "pass" if decision == "pass" else "fail"
        validation = {
            "status": status,
            "manuscript_kind": "paper" if status == "pass" else "blocked",
            "summary": str(result.get("summary") or "").strip(),
            "feedback_message": str(result.get("feedback_message") or result.get("summary") or "").strip(),
            "coherent_narrative": bool(result.get("coherent_narrative")),
            "meaningful_finding": bool(result.get("meaningful_finding")),
            "attempt": ledger.get("attempt"),
            "approved_results": [
                {
                    "result_id": f"finding_{index + 1}",
                    "text": text,
                    "artifact_ids": [entry.get("artifact_id") for entry in ledger.get("figure_summaries", []) if entry.get("artifact_id")],
                }
                for index, text in enumerate(ledger.get("findings") or [])
                if str(text).strip()
            ],
            "reference_catalog": self._reference_catalog(ledger),
        }
        write_json_file(self.run_directory(run_id) / "validation.json", validation)
        if status == "pass":
            store.emit_event("VALIDATION_PASSED", attempt=ledger.get("attempt"))
            store.complete_stage(stage="2.5", agent="validation", artifacts=["validation.json"])
        else:
            retries_remaining = max(0, 3 - int(ledger.get("attempt") or 1))
            store.emit_event(
                "VALIDATION_FAILED",
                attempt=ledger.get("attempt"),
                feedback_message=validation["feedback_message"],
                retries_remaining=retries_remaining,
            )
            store.fail_stage(stage="2.5", agent="validation", reason=validation["feedback_message"], retries_remaining=retries_remaining)
        return validation

    def _legacy_validate_ledger(
        self,
        *,
        run_id: str,
        ledger: dict[str, Any],
        request_payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        run_directory = self.run_directory(run_id)
        request_payload = self.resolve_request_payload(request_payload or {})
        request_notes = normalize_request_notes(request_payload.get("notes"))
        expected_note_ids = [str(note.get("id") or "").strip() for note in request_notes if str(note.get("id") or "").strip()]
        resolution = request_payload.get("resolution") if isinstance(request_payload.get("resolution"), dict) else {}
        selected_candidate = resolution.get("selected_candidate") if isinstance(resolution.get("selected_candidate"), dict) else {}

        valid_sources: dict[str, dict[str, Any]] = {}
        validation_issues: list[str] = []
        for source in ledger.get("sources", []):
            if not isinstance(source, dict):
                continue
            source_id = str(source.get("source_id") or "").strip()
            if not source_id:
                continue
            if str(source.get("accession_id") or "").strip() or str(source.get("download_url") or "").strip() or (
                str(source.get("api_endpoint") or "").strip() and source.get("api_query")
            ):
                valid_sources[source_id] = source
            else:
                validation_issues.append(f"{source_id} is missing reproducible retrieval info.")

        valid_artifacts: dict[str, dict[str, Any]] = {}
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            artifact_path = sanitize_relative_path(artifact_path_value(artifact), fallback=f"artifacts/{artifact_id or 'artifact'}")
            if artifact_id and (run_directory / artifact_path).exists():
                artifact["path"] = artifact_path
                valid_artifacts[artifact_id] = artifact

        approved_results: list[dict[str, Any]] = []
        dropped_results: list[dict[str, Any]] = []
        for index, result in enumerate(ledger.get("results", []) or []):
            if not isinstance(result, dict):
                continue
            artifact_ids = [artifact_id for artifact_id in normalize_text_list(result.get("artifact_ids")) if artifact_id in valid_artifacts]
            note_ids = [note_id for note_id in normalize_text_list(result.get("note_ids")) if note_id in expected_note_ids]
            if not note_ids and len(expected_note_ids) == 1:
                note_ids = expected_note_ids.copy()
            source_ids: list[str] = []
            for artifact_id in artifact_ids:
                for source_id in artifact_source_ids(valid_artifacts[artifact_id]):
                    if source_id in valid_sources and source_id not in source_ids:
                        source_ids.append(source_id)
            reasons: list[str] = []
            if not artifact_ids:
                reasons.append("result does not reference a saved artifact")
            if not source_ids:
                reasons.append("result does not resolve to reproducible source provenance")
            if expected_note_ids and not note_ids:
                reasons.append("result does not map to a requested note")
            if selected_candidate and not any(source_matches_resolution_source(valid_sources.get(source_id, {}), selected_candidate) for source_id in source_ids):
                reasons.append("result does not resolve to the required primary dataset")
            if reasons:
                dropped_results.append({"result_id": str(result.get("result_id") or f"result_{index + 1}"), "reasons": reasons})
                continue
            approved_results.append(
                {
                    "result_id": str(result.get("result_id") or f"result_{index + 1}"),
                    "text": str(result.get("text") or "").strip(),
                    "artifact_ids": artifact_ids,
                    "source_ids": source_ids,
                    "note_ids": note_ids,
                }
            )

        missing_note_ids = [note_id for note_id in expected_note_ids if note_id not in {note for result in approved_results for note in result.get("note_ids", [])}]
        methods_text = str(ledger.get("methods") or ledger.get("experiment_summary") or "").strip().lower()
        did_original_work = any(token in methods_text for token in ["downloaded", "cleaned", "computed", "analyzed", "calculated", "fit", "estimated", "processed"])
        paper_checks = {
            "described_work_performed_here": did_original_work,
            "has_original_result": bool(ledger.get("results") or ledger.get("findings")),
            "has_artifact_backed_result": bool(approved_results),
            "covers_requested_notes": not expected_note_ids or not missing_note_ids,
            "uses_resolved_primary_dataset": not selected_candidate or any(
                source_matches_resolution_source(valid_sources.get(source_id, {}), selected_candidate)
                for result in approved_results for source_id in result.get("source_ids", [])
            ),
        }
        manuscript_kind = "paper" if all(paper_checks.values()) else "memo"
        memo_reasons: list[str] = []
        if not paper_checks["described_work_performed_here"]:
            memo_reasons.append("methods did not clearly describe substantial work performed in this run")
        if not paper_checks["has_artifact_backed_result"]:
            memo_reasons.append("no original result resolved to a real saved artifact")
        if not paper_checks["covers_requested_notes"]:
            memo_reasons.append("not every requested note is covered by a validated finding")
        if not paper_checks["uses_resolved_primary_dataset"]:
            memo_reasons.append("validated findings did not stay anchored to the resolved primary dataset")
        validation = {
            "status": manuscript_kind,
            "manuscript_kind": manuscript_kind,
            "final_format": manuscript_kind,
            "approved_results": approved_results,
            "approved_result_ids": [entry["result_id"] for entry in approved_results],
            "dropped_results": dropped_results,
            "validation_issues": validation_issues,
            "paper_checks": paper_checks,
            "memo_reasons": [] if manuscript_kind == "paper" else memo_reasons or ["paper gate did not pass"],
            "reference_catalog": self._reference_catalog(ledger),
            "missing_note_ids": missing_note_ids,
            "resolution": resolution,
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
        validation_status = str(validation.get("status") or "").strip().lower()
        validation_kind = str(validation.get("manuscript_kind") or "").strip().lower()
        if validation_status not in {"pass", "paper"} and validation_kind != "paper":
            raise PipelineExecutionError(build_validation_error_message(validation), stage="2.5")
        store = self._run_store(run_id)
        store.set_stage(stage="3", agent="paper-writer", model=self._config.openai_writer_model)
        template = {
            "documentclass": "article",
            "sections": ["Abstract", "Introduction", "Data And Methods", "Results", "Discussion", "Conclusion", "Limitations", "References"],
        }
        instructions = """
You are Sidekick's paper writer.
Use the provided standard LaTeX paper template structure and write a full manuscript.
Return strict JSON only:
{
  "title": "string",
  "abstract": "string",
  "introduction": "string",
  "methods": "string",
  "results": "string",
  "discussion": "string",
  "conclusion": "string",
  "limitations": "string",
  "references": ["formatted reference string"]
}
Rules:
- Use the research question, experiments, findings, figure summaries, and related work to write a conventional paper.
- The figure summaries are the source of truth for what each figure shows.
- Use internet access to ground related work and references, but do not invent experiments or results beyond the validated analysis.
- Keep the tone scientific and concrete.
"""
        writer_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": ledger.get("research_question"),
            "dataset": ledger.get("dataset"),
            "experiment_summary": ledger.get("experiment_summary"),
            "experiments": ledger.get("experiments") or [],
            "findings": ledger.get("findings") or [],
            "figure_summaries": ledger.get("figure_summaries") or [],
            "limitations": ledger.get("limitations") or [],
            "reference_catalog": validation.get("reference_catalog") or [],
            "standard_template": template,
        }
        written = self._run_model_json(
            run_id=run_id,
            stage="3",
            agent="paper-writer",
            model=self._config.openai_writer_model,
            instructions=instructions,
            input_text=json.dumps(writer_input, sort_keys=True),
            use_code_interpreter=False,
            use_web_search=True,
            timeout_seconds=min(1200, self._config.backend_max_job_runtime_seconds),
            reasoning_effort="medium",
        )
        sections = normalize_manuscript_sections(
            written,
            title_fallback=str(ledger.get("title") or request_payload.get("title") or "Research paper"),
        )
        bundle = self.render_bundle(
            run_id=run_id,
            request_payload=request_payload,
            ledger=ledger,
            validation=validation,
            sections=sections,
        )
        store.complete_stage(stage="3", agent="paper-writer", artifacts=["sections.json", "paper.tex", "paper.pdf"])
        return bundle

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
            title_fallback=str(ledger.get("title") or request_payload.get("title") or "Research paper"),
        )
        artifact_manifest = build_manuscript_manifest(
            job_directory=run_directory,
            artifacts=ledger.get("artifacts") or [],
            sanitize_relative_path=sanitize_relative_path,
            artifact_path_value=artifact_path_value,
            guess_mime_type=guess_mime_type,
        )
        latex, references_bib = render_latex(
            title=str(written.get("title") or ledger.get("title") or request_payload.get("title") or "Research paper"),
            sections=written,
            manifest=artifact_manifest,
            manuscript_kind="paper",
            reference_catalog=validation.get("reference_catalog") or [],
        )
        tex_filename = "paper.tex"
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
        figures = self.bundle_figures_from_ledger(run_id=run_id, ledger=ledger)
        markdown_preview = results_to_markdown(written, manuscript_kind="paper")
        bundle = {
            "title": str(written.get("title") or request_payload.get("title") or "Research paper"),
            "manuscript_kind": "paper",
            "sections": written,
            "latex": latex,
            "references_bib": references_bib,
            "artifact_manifest": artifact_manifest,
            "pdf": {
                "ok": bool(compile_result.get("ok")),
                "filename": compile_result.get("pdf_path") or "paper.pdf",
                "error": str(compile_result.get("error") or "").strip(),
                "log": str(compile_result.get("log") or "").strip(),
            },
            "figures": figures,
            "draft": {"title": bundle_title(written, request_payload), "markdown": markdown_preview},
            "ledger": ledger,
            "validation": validation,
            "artifact_files": ledger.get("artifact_files", []),
        }
        write_json_file(run_directory / "bundle.json", {"bundle": bundle, "publication": None})
        self._run_store(run_id).record_artifact(stage="3", artifact_id="paper-tex", artifact_type="latex", path="paper.tex", description="Compiled manuscript source.")
        self._run_store(run_id).record_artifact(stage="3", artifact_id="paper-pdf", artifact_type="pdf", path="paper.pdf", description="Compiled manuscript PDF.")
        return bundle

    def bundle_figures_from_ledger(self, *, run_id: str, ledger: dict[str, Any]) -> list[dict[str, Any]]:
        figures: list[dict[str, Any]] = []
        run_directory = self.run_directory(run_id)
        summaries_by_artifact_id = {
            str(entry.get("artifact_id") or "").strip(): entry for entry in ledger.get("figure_summaries", []) if isinstance(entry, dict)
        }
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
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            summary = summaries_by_artifact_id.get(artifact_id) or {}
            figures.append(
                {
                    "filename": path.name,
                    "caption": str(artifact.get("description") or summary.get("title") or "").strip(),
                    "summary_markdown": str(summary.get("summary_markdown") or "").strip(),
                    "mime_type": mime_type,
                    "base64_data": base64.b64encode(path.read_bytes()).decode("utf-8"),
                }
            )
        return figures

    def run_directory(self, run_id: str) -> Path:
        directory = self._config.artifact_root / run_id
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def _run_store(self, run_id: str) -> SidekickRunStore:
        return SidekickRunStore(run_id=run_id, root=self._config.artifact_root)

    def _run_model_json(
        self,
        *,
        run_id: str,
        stage: str,
        agent: str,
        model: str,
        instructions: str,
        input_text: str,
        use_code_interpreter: bool,
        use_web_search: bool,
        timeout_seconds: int,
        reasoning_effort: str | None,
    ) -> dict[str, Any]:
        store = self._run_store(run_id)
        prompt = f"{instructions.strip()}\n\nINPUT\n{input_text.strip()}"
        handle = store.start_call(
            stage=stage,
            agent=agent,
            model=model,
            prompt=prompt,
            parameters={
                "use_code_interpreter": use_code_interpreter,
                "use_web_search": use_web_search,
                "timeout_seconds": timeout_seconds,
                "reasoning_effort": reasoning_effort,
            },
        )
        self._emit_status(
            run_id,
            stage=stage,
            progress_message=f"{agent} started.",
            status="running",
        )
        seen_response_id = ""
        seen_status = ""

        def _handle_event(event: dict[str, Any]) -> None:
            nonlocal seen_response_id, seen_status
            store.append_call_delta(handle, "", raw_event=event)
            response = event.get("response") if isinstance(event.get("response"), dict) else None
            response_id = str(
                event.get("id")
                or event.get("response_id")
                or (response.get("id") if response is not None else "")
                or ""
            ).strip()
            status_value = str(event.get("status") or (response.get("status") if response is not None else "") or "").strip().lower()
            should_emit = False
            if response_id and response_id != seen_response_id:
                seen_response_id = response_id
                should_emit = True
            if status_value and status_value not in {"completed", "failed", "cancelled", "incomplete", "expired"} and status_value != seen_status:
                seen_status = status_value
                should_emit = True
            if not should_emit:
                return
            progress_message = f"{agent} {status_value.replace('_', ' ')}." if status_value else f"{agent} started."
            self._emit_status(
                run_id,
                stage=stage,
                progress_message=progress_message,
                status="running",
                openai_response_id=seen_response_id or None,
            )

        started_ms = store.elapsed_ms()
        try:
            response = self._openai_client.generate_json(
                instructions=instructions,
                input_text=input_text,
                use_code_interpreter=use_code_interpreter,
                use_web_search=use_web_search,
                timeout_seconds=timeout_seconds,
                model=model,
                reasoning_effort=reasoning_effort,
                on_delta=lambda delta: store.append_call_delta(handle, delta),
                on_event=_handle_event,
            )
        except Exception as error:
            store.fail_call(handle, error=str(error), latency_ms=max(0, store.elapsed_ms() - started_ms))
            raise
        latency_ms = max(0, store.elapsed_ms() - started_ms)
        usage = {"input_tokens": response.usage.input_tokens, "output_tokens": response.usage.output_tokens}
        store.complete_call(handle, response_text=response.output_text, usage=usage, latency_ms=latency_ms, raw_payload=response.payload)
        self._emit_status(run_id, stage=stage, progress_message=f"{agent} completed.", status="running", openai_response_id=response.response_id)
        self._emit_metrics(run_id, model=model, input_tokens=response.usage.input_tokens, output_tokens=response.usage.output_tokens)
        payload = extract_json_object(response.output_text)
        payload["_response"] = response
        return payload

    def _reference_catalog(self, ledger: dict[str, Any]) -> list[dict[str, Any]]:
        catalog: list[dict[str, Any]] = []
        for index, source in enumerate(ledger.get("sources") or []):
            if not isinstance(source, dict):
                continue
            key = f"ref{index + 1}"
            parts = [str(source.get("label") or "Source").strip()]
            for field in ("accession_id", "download_url", "landing_page_url", "notes"):
                value = str(source.get(field) or "").strip()
                if value:
                    parts.append(value)
            catalog.append({"key": key, "source_id": source.get("source_id"), "text": ". ".join(parts)})
        return catalog

    def _ensure_artifact_metadata(self, ledger: dict[str, Any]) -> None:
        summaries_by_artifact_id = {
            str(entry.get("artifact_id") or "").strip(): entry for entry in ledger.get("figure_summaries", []) if isinstance(entry, dict)
        }
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            path = str(artifact.get("path") or "").strip()
            if not path:
                continue
            artifact["mime_type"] = artifact.get("mime_type") or guess_mime_type(path)
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            if artifact["mime_type"].startswith("image/") and artifact_id in summaries_by_artifact_id:
                artifact["description"] = artifact.get("description") or summaries_by_artifact_id[artifact_id].get("title") or artifact.get("description")

    def _choose_search_winner(self, candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
        valid = [candidate for candidate in candidates if str(candidate.get("status") or "").strip().lower() == "found"]
        if not valid:
            return None
        valid.sort(
            key=lambda candidate: (
                0 if candidate.get("domain_mode") == "allow_list" else 1,
                0 if str((candidate.get("dataset") or {}).get("download_url") or "").strip() else 1,
                0 if str((candidate.get("dataset") or {}).get("accession_id") or "").strip() else 1,
            )
        )
        return valid[0]

    def _choose_legacy_search_candidate(self, candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
        for candidate in candidates:
            if candidate.get("research_question") and (candidate.get("sources") or candidate.get("artifacts")):
                return candidate
        return None

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
        self._metrics_callback(run_id, model=model, input_tokens=input_tokens, output_tokens=output_tokens)

    def _exit_code_for_stage(self, stage: str) -> int:
        if stage == "1":
            return 1
        if stage == "2.5":
            return 2
        if stage == "3":
            return 3
        if stage == "4":
            return 4
        return 20


def bundle_title(written: dict[str, Any], request_payload: dict[str, Any]) -> str:
    return str(written.get("title") or request_payload.get("title") or "Research paper").strip() or "Research paper"
