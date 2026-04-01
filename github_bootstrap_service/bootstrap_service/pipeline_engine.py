from __future__ import annotations

import ast
import base64
import csv
import hashlib
import json
import math
import mimetypes
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

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
        if character not in {"{", "["}:
            continue
        try:
            payload, _ = decoder.raw_decode(raw_text[index:])
        except json.JSONDecodeError:
            try:
                payload, _ = decoder.raw_decode(_repair_json_like_text(raw_text[index:]))
            except json.JSONDecodeError:
                payload = _extract_python_literal(raw_text[index:])
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


def _extract_python_literal(raw_text: str) -> dict[str, Any] | None:
    start = raw_text.find("{")
    if start < 0:
        return None
    for end in range(len(raw_text), start, -1):
        candidate = raw_text[start:end].strip()
        if not candidate.endswith("}"):
            continue
        try:
            payload = ast.literal_eval(candidate)
        except (SyntaxError, ValueError):
            continue
        if isinstance(payload, dict):
            return payload
    return None


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


def _is_http_url(value: str) -> bool:
    lowered = value.strip().lower()
    return lowered.startswith("https://") or lowered.startswith("http://")


def _normalize_download_entry(entry: Any, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        entry = {}
    status = str(entry.get("status") or entry.get("attempt_status") or "").strip().lower()
    classification = str(entry.get("classification") or entry.get("substrate_class") or "").strip().lower()
    saved_path = sanitize_relative_path(
        str(entry.get("saved_path") or entry.get("path") or "").strip(),
        fallback=f"downloads/entry_{index + 1}",
    )
    bytes_downloaded = entry.get("bytes_downloaded", entry.get("bytes"))
    latency_ms = entry.get("latency_ms")
    http_status = entry.get("http_status")
    usable_for_analysis = entry.get("usable_for_analysis")
    return {
        "entry_id": str(entry.get("entry_id") or f"download_{index + 1}").strip() or f"download_{index + 1}",
        "url": str(entry.get("url") or "").strip(),
        "source_family": str(entry.get("source_family") or "").strip(),
        "retrieval_target": str(entry.get("retrieval_target") or entry.get("target") or "").strip(),
        "method": str(entry.get("method") or "http_get").strip() or "http_get",
        "status": status or "unknown",
        "http_status": int(http_status) if isinstance(http_status, int) else None,
        "error_kind": str(entry.get("error_kind") or "").strip(),
        "error_message": str(entry.get("error_message") or "").strip(),
        "latency_ms": int(latency_ms) if isinstance(latency_ms, int | float) else None,
        "bytes_downloaded": int(bytes_downloaded) if isinstance(bytes_downloaded, int | float) else 0,
        "saved_path": saved_path,
        "saved_file_kind": str(entry.get("saved_file_kind") or entry.get("file_kind") or "").strip(),
        "content_type": str(entry.get("content_type") or "").strip(),
        "classification": classification or "unknown",
        "usable_for_analysis": bool(usable_for_analysis),
        "notes": str(entry.get("notes") or "").strip(),
    }


def _network_attempts_tsv(entries: list[dict[str, Any]]) -> str:
    header = [
        "entry_id",
        "url",
        "source_family",
        "retrieval_target",
        "method",
        "status",
        "http_status",
        "error_kind",
        "latency_ms",
        "bytes_downloaded",
        "saved_path",
        "saved_file_kind",
        "classification",
        "usable_for_analysis",
        "notes",
    ]
    rows = ["\t".join(header)]
    for entry in entries:
        row = [
            str(entry.get("entry_id") or ""),
            str(entry.get("url") or ""),
            str(entry.get("source_family") or ""),
            str(entry.get("retrieval_target") or ""),
            str(entry.get("method") or ""),
            str(entry.get("status") or ""),
            "" if entry.get("http_status") is None else str(entry.get("http_status")),
            str(entry.get("error_kind") or ""),
            "" if entry.get("latency_ms") is None else str(entry.get("latency_ms")),
            str(entry.get("bytes_downloaded") or 0),
            str(entry.get("saved_path") or ""),
            str(entry.get("saved_file_kind") or ""),
            str(entry.get("classification") or ""),
            "true" if entry.get("usable_for_analysis") else "false",
            str(entry.get("notes") or ""),
        ]
        rows.append("\t".join(value.replace("\t", " ").replace("\n", " ").strip() for value in row))
    return "\n".join(rows) + "\n"


def _http_fetch(
    url: str,
    *,
    timeout_seconds: int = 60,
    user_agent: str = "sidekick-backend",
    accept: str = "*/*",
    max_attempts: int = 3,
    retry_backoff_seconds: float = 1.0,
) -> dict[str, Any]:
    attempts = max(1, int(max_attempts))
    last_result: dict[str, Any] | None = None
    for attempt in range(1, attempts + 1):
        request = Request(
            url=url,
            headers={
                "User-Agent": user_agent,
                "Accept": accept,
            },
            method="GET",
        )
        started = time.time()
        try:
            with urlopen(request, timeout=timeout_seconds) as response:
                payload = response.read()
                status_code = int(getattr(response, "status", 200) or 200)
                content_type = str(response.headers.get("Content-Type") or "").strip()
                final_url = str(response.geturl() or url).strip() or url
            return {
                "ok": 200 <= status_code < 300,
                "status_code": status_code,
                "content_type": content_type,
                "bytes": payload,
                "final_url": final_url,
                "latency_ms": max(0, int((time.time() - started) * 1000)),
                "error_kind": "",
                "error_message": "",
                "attempts": attempt,
            }
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            last_result = {
                "ok": False,
                "status_code": int(getattr(error, "code", 0) or 0),
                "content_type": str(error.headers.get("Content-Type") or "").strip() if error.headers else "",
                "bytes": b"",
                "final_url": url,
                "latency_ms": max(0, int((time.time() - started) * 1000)),
                "error_kind": "http_error",
                "error_message": detail.strip() or f"HTTP {getattr(error, 'code', 0)}",
                "attempts": attempt,
            }
            if attempt >= attempts or last_result["status_code"] not in {408, 425, 429, 500, 502, 503, 504}:
                return last_result
        except URLError as error:
            reason = str(error.reason or "").strip()
            lowered = reason.lower()
            if "timed out" in lowered:
                error_kind = "timeout"
            elif "ssl" in lowered or "tls" in lowered or "certificate" in lowered:
                error_kind = "tls_error"
            elif "name or service not known" in lowered or "nodename nor servname provided" in lowered or "temporary failure in name resolution" in lowered:
                error_kind = "dns_error"
            else:
                error_kind = "network_error"
            last_result = {
                "ok": False,
                "status_code": 0,
                "content_type": "",
                "bytes": b"",
                "final_url": url,
                "latency_ms": max(0, int((time.time() - started) * 1000)),
                "error_kind": error_kind,
                "error_message": reason or "Network request failed.",
                "attempts": attempt,
            }
            if attempt >= attempts or error_kind in {"dns_error", "tls_error"}:
                return last_result
        time.sleep(retry_backoff_seconds * attempt)
    return last_result or {
        "ok": False,
        "status_code": 0,
        "content_type": "",
        "bytes": b"",
        "final_url": url,
        "latency_ms": 0,
        "error_kind": "network_error",
        "error_message": "Network request failed.",
        "attempts": attempts,
    }


def _decode_text_payload(payload: bytes) -> str:
    for encoding in ("utf-8", "latin-1"):
        try:
            return payload.decode(encoding)
        except UnicodeDecodeError:
            continue
    return payload.decode("utf-8", errors="replace")


def _safe_accession(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value or "").strip())


def _geo_values(text: str, field_name: str) -> list[str]:
    prefix = f"!{field_name} = "
    return [line[len(prefix):].strip() for line in text.splitlines() if line.startswith(prefix)]


def _geo_table_section(text: str, begin_marker: str, end_marker: str) -> str:
    start = text.find(begin_marker)
    end = text.find(end_marker)
    if start < 0 or end < 0 or end <= start:
        return ""
    body = text[start + len(begin_marker):end].strip()
    return body + ("\n" if body else "")


def _write_text_file(path: Path, content: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path.stat().st_size


def _write_csv_rows(path: Path, fieldnames: list[str], rows: list[dict[str, Any]], *, delimiter: str = ",") -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=delimiter)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})
    return path.stat().st_size


def _parse_tsv_rows(content: str) -> list[dict[str, str]]:
    stripped = content.strip()
    if not stripped:
        return []
    reader = csv.DictReader(stripped.splitlines(), delimiter="\t")
    rows: list[dict[str, str]] = []
    for row in reader:
        if not isinstance(row, dict):
            continue
        rows.append({str(key or "").strip(): str(value or "").strip() for key, value in row.items()})
    return rows


def _parse_float(value: str) -> float | None:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _pearson_correlation(left: list[float], right: list[float]) -> float:
    if len(left) != len(right) or not left:
        return 0.0
    left_mean = sum(left) / len(left)
    right_mean = sum(right) / len(right)
    left_var = sum((value - left_mean) ** 2 for value in left)
    right_var = sum((value - right_mean) ** 2 for value in right)
    if left_var <= 0 or right_var <= 0:
        return 0.0
    covariance = sum((l - left_mean) * (r - right_mean) for l, r in zip(left, right))
    return covariance / math.sqrt(left_var * right_var)


def _solve_linear_3x3(matrix: list[list[float]], vector: list[float]) -> list[float]:
    augmented = [row[:] + [vector[index]] for index, row in enumerate(matrix)]
    for column in range(3):
        pivot = max(range(column, 3), key=lambda row: abs(augmented[row][column]))
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        pivot_value = augmented[column][column]
        if abs(pivot_value) < 1e-12:
            return [0.0, 0.0, 0.0]
        for inner in range(column, 4):
            augmented[column][inner] /= pivot_value
        for row in range(3):
            if row == column:
                continue
            factor = augmented[row][column]
            for inner in range(column, 4):
                augmented[row][inner] -= factor * augmented[column][inner]
    return [augmented[row][3] for row in range(3)]


def _fit_fixed_period_cosine(timepoints_hours: list[float], values: list[float], *, period_hours: float = 24.0) -> dict[str, float]:
    if len(timepoints_hours) != len(values) or not values:
        return {"mean_expression": 0.0, "amplitude": 0.0, "phase_hours": 0.0, "r_squared": 0.0}
    cosine_terms = [math.cos(2 * math.pi * hour / period_hours) for hour in timepoints_hours]
    sine_terms = [math.sin(2 * math.pi * hour / period_hours) for hour in timepoints_hours]
    normal_matrix = [
        [float(len(values)), sum(cosine_terms), sum(sine_terms)],
        [sum(cosine_terms), sum(term * term for term in cosine_terms), sum(c * s for c, s in zip(cosine_terms, sine_terms))],
        [sum(sine_terms), sum(c * s for c, s in zip(cosine_terms, sine_terms)), sum(term * term for term in sine_terms)],
    ]
    right_hand_side = [
        sum(values),
        sum(value * cosine for value, cosine in zip(values, cosine_terms)),
        sum(value * sine for value, sine in zip(values, sine_terms)),
    ]
    intercept, beta_cosine, beta_sine = _solve_linear_3x3(normal_matrix, right_hand_side)
    fitted = [intercept + beta_cosine * cosine + beta_sine * sine for cosine, sine in zip(cosine_terms, sine_terms)]
    mean_expression = sum(values) / len(values)
    total_sum_squares = sum((value - mean_expression) ** 2 for value in values)
    residual_sum_squares = sum((value - fit) ** 2 for value, fit in zip(values, fitted))
    amplitude = math.sqrt(beta_cosine ** 2 + beta_sine ** 2)
    phase_hours = (math.atan2(-beta_sine, beta_cosine) % (2 * math.pi)) * period_hours / (2 * math.pi)
    r_squared = 0.0 if total_sum_squares <= 0 else max(0.0, 1.0 - (residual_sum_squares / total_sum_squares))
    return {
        "mean_expression": mean_expression,
        "amplitude": amplitude,
        "phase_hours": phase_hours,
        "r_squared": r_squared,
    }


def _looks_like_named_gene(symbol: str) -> bool:
    cleaned = str(symbol or "").strip()
    if not cleaned:
        return False
    if "=" in cleaned or " " in cleaned:
        return False
    if not cleaned[0].isalpha():
        return False
    if sum(1 for character in cleaned if character.isalpha()) < 2:
        return False
    if cleaned.startswith(("LOC", "EST_", "Hs.", "MGC", "DKFZP")):
        return False
    return True


def _extract_geo_timepoint_hours(*values: str) -> str:
    for value in values:
        text = str(value or "").strip()
        if not text:
            continue
        match = re.search(r"time point:\s*([0-9]+(?:\.[0-9]+)?)\s*hr", text, re.IGNORECASE)
        if match:
            return match.group(1)
        match = re.search(r"(?:^|[_\s-])([0-9]+(?:\.[0-9]+)?)\s*(?:hr|hour)\b", text, re.IGNORECASE)
        if match:
            return match.group(1)
    return ""


def _source_family_strategy(dataset: dict[str, Any], request_payload: dict[str, Any]) -> dict[str, Any]:
    resolution = request_payload.get("resolution") if isinstance(request_payload.get("resolution"), dict) else {}
    selected_candidate = resolution.get("selected_candidate") if isinstance(resolution.get("selected_candidate"), dict) else {}
    family_id = str(selected_candidate.get("family_id") or "").strip()
    trusted_domains = normalize_text_list(selected_candidate.get("trusted_domains"))
    if family_id == "geo_functional_genomics" or str(dataset.get("accession_id") or "").strip().upper().startswith(("GSE", "GSM", "GPL")):
        retrieval_order = [
            "series_matrix",
            "processed_sample_table",
            "processed_supplementary_table",
            "platform_annotation",
            "raw_archive",
        ]
        return {
            "family_id": "geo_functional_genomics",
            "family_label": "NCBI GEO Functional Genomics",
            "trusted_domains": trusted_domains or ["ncbi.nlm.nih.gov", "eutils.ncbi.nlm.nih.gov"],
            "retrieval_order": retrieval_order,
            "numeric_targets": ["series_matrix", "processed_sample_table", "processed_expression_table", "gpr", "raw_archive"],
            "metadata_only_targets": ["series_html", "sample_html", "platform_html", "landing_page"],
            "notes": (
                "For GEO, prefer processed tables and series matrix files first. "
                "Do not count sample HTML, platform HTML, or the series landing page as numeric substrate."
            ),
        }
    return {
        "family_id": family_id or "generic_repository",
        "family_label": str(selected_candidate.get("family_label") or "Generic repository").strip() or "Generic repository",
        "trusted_domains": trusted_domains,
        "retrieval_order": ["processed_table", "compact_numeric_file", "supplementary_archive", "raw_archive"],
        "numeric_targets": ["processed_table", "compact_numeric_file", "supplementary_archive", "raw_archive"],
        "metadata_only_targets": ["landing_page", "html_page"],
        "notes": "Prefer the smallest credible numeric or semi-numeric file before attempting larger raw archives.",
    }


def _acquisition_budgets(config: BootstrapServiceConfig) -> dict[str, int]:
    return {
        "max_total_bytes": int(config.data_access_max_total_bytes),
        "max_file_bytes": int(config.data_access_max_file_bytes),
        "max_files": int(config.data_access_max_files),
        "max_seconds": int(config.data_access_max_seconds),
    }


def _normalize_data_access_report(
    *,
    raw_report: dict[str, Any],
    dataset: dict[str, Any],
    request_payload: dict[str, Any],
    config: BootstrapServiceConfig,
) -> dict[str, Any]:
    budgets = _acquisition_budgets(config)
    strategy = _source_family_strategy(dataset, request_payload)
    manifest_entries = [
        _normalize_download_entry(entry, index) for index, entry in enumerate(raw_report.get("download_manifest") or raw_report.get("downloads") or [])
    ]
    substrate_class = str(raw_report.get("substrate_class") or raw_report.get("retrieved_substrate_class") or "").strip().lower()
    if substrate_class not in {"numeric", "semi_numeric", "metadata_only", "none"}:
        if any(entry.get("usable_for_analysis") and entry.get("classification") == "numeric" for entry in manifest_entries):
            substrate_class = "numeric"
        elif any(entry.get("usable_for_analysis") and entry.get("classification") == "semi_numeric" for entry in manifest_entries):
            substrate_class = "semi_numeric"
        elif manifest_entries:
            substrate_class = "metadata_only"
        else:
            substrate_class = "none"
    usable_saved_files = []
    metadata_only_saved_files = []
    for entry in manifest_entries:
        file_record = {
            "path": str(entry.get("saved_path") or ""),
            "bytes_downloaded": int(entry.get("bytes_downloaded") or 0),
            "classification": str(entry.get("classification") or ""),
            "retrieval_target": str(entry.get("retrieval_target") or ""),
        }
        if entry.get("usable_for_analysis"):
            usable_saved_files.append(file_record)
        elif file_record["path"]:
            metadata_only_saved_files.append(file_record)
    if not usable_saved_files:
        usable_saved_files = [
            {
                "path": sanitize_relative_path(str(entry.get("path") or "").strip(), fallback=f"downloads/usable_{index + 1}"),
                "bytes_downloaded": int(entry.get("bytes_downloaded") or 0),
                "classification": str(entry.get("classification") or "numeric"),
                "retrieval_target": str(entry.get("retrieval_target") or ""),
            }
            for index, entry in enumerate(raw_report.get("usable_saved_files") or [])
            if isinstance(entry, dict) and str(entry.get("path") or "").strip()
        ]
    if not metadata_only_saved_files:
        metadata_only_saved_files = [
            {
                "path": sanitize_relative_path(str(entry.get("path") or "").strip(), fallback=f"downloads/metadata_{index + 1}"),
                "bytes_downloaded": int(entry.get("bytes_downloaded") or 0),
                "classification": str(entry.get("classification") or "metadata_only"),
                "retrieval_target": str(entry.get("retrieval_target") or ""),
            }
            for index, entry in enumerate(raw_report.get("metadata_only_saved_files") or [])
            if isinstance(entry, dict) and str(entry.get("path") or "").strip()
        ]
    empirical_ready = bool(raw_report.get("empirical_ready"))
    if not empirical_ready:
        empirical_ready = substrate_class in {"numeric", "semi_numeric"} and bool(usable_saved_files)
    return {
        "status": str(raw_report.get("status") or ("ready" if empirical_ready else "blocked")).strip().lower() or ("ready" if empirical_ready else "blocked"),
        "summary": str(raw_report.get("summary") or "").strip(),
        "blocking_reason": str(raw_report.get("blocking_reason") or "").strip(),
        "substrate_class": substrate_class,
        "empirical_ready": empirical_ready,
        "dataset": {
            "label": str(dataset.get("label") or "").strip(),
            "landing_page_url": str(dataset.get("landing_page_url") or "").strip(),
            "download_url": str(dataset.get("download_url") or "").strip(),
            "accession_id": str(dataset.get("accession_id") or "").strip(),
            "notes": str(dataset.get("notes") or "").strip(),
        },
        "budgets": budgets,
        "strategy": strategy,
        "download_manifest": manifest_entries,
        "usable_saved_files": usable_saved_files,
        "metadata_only_saved_files": metadata_only_saved_files,
        "host_failures": [
            {
                "host": str(entry.get("host") or "").strip(),
                "failures": int(entry.get("failures") or 0),
                "attempts": int(entry.get("attempts") or 0),
                "error_kinds": normalize_text_list(entry.get("error_kinds")),
            }
            for entry in raw_report.get("host_failures") or []
            if isinstance(entry, dict)
        ],
        "sources": [_normalize_source(entry, index) for index, entry in enumerate(raw_report.get("sources") or [])],
        "receipts": {
            "data_access_report_path": "data_access_report.json",
            "download_manifest_path": "download_manifest.json",
            "network_attempts_path": "network_attempts.tsv",
        },
    }


def _data_access_receipt_artifacts() -> list[dict[str, Any]]:
    return [
        {
            "artifact_id": "data_access_report",
            "path": "data_access_report.json",
            "kind": "log",
            "mime_type": "application/json",
            "description": "Structured acquisition summary with substrate classification and empirical-readiness decision.",
            "source_ids": [],
        },
        {
            "artifact_id": "download_manifest",
            "path": "download_manifest.json",
            "kind": "log",
            "mime_type": "application/json",
            "description": "Structured manifest of every acquisition attempt and saved file classification.",
            "source_ids": [],
        },
        {
            "artifact_id": "network_attempts",
            "path": "network_attempts.tsv",
            "kind": "log",
            "mime_type": "text/tab-separated-values",
            "description": "Tabular network-attempt receipt for acquisition debugging.",
            "source_ids": [],
        },
    ]


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


def classify_artifact_kind(path: str) -> str:
    suffix = Path(path).suffix.lower()
    if suffix in {".py", ".r", ".jl", ".ipynb", ".sh"}:
        return "code"
    if suffix in {".png", ".jpg", ".jpeg", ".svg", ".pdf"}:
        return "figure"
    if suffix in {".csv", ".tsv", ".xlsx", ".parquet"}:
        return "table"
    if suffix in {".json", ".txt", ".md", ".log"}:
        return "log"
    return "artifact"


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
            validation_status = str(validation.get("status") or "").strip().lower()
            validation_kind = str(validation.get("manuscript_kind") or "").strip().lower()
            if validation_status in {"pass", "paper"} or validation_kind == "paper":
                return ledger, validation
            last_ledger = ledger
            last_validation = validation
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
        if last_ledger is not None and str((last_validation or {}).get("manuscript_kind") or "").strip().lower() == "memo":
            return last_ledger, last_validation or {}
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
        resolution = request_payload.get("resolution") if isinstance(request_payload.get("resolution"), dict) else {}
        paper_mode = str(resolution.get("paper_mode") or "").strip().lower()
        data_access: dict[str, Any] | None = None
        if paper_mode == "empirical_dataset":
            store.set_stage(stage="2", agent="data-acquisition", model=self._config.openai_workspace_model)
            acquisition_input = {
                "title": request_payload.get("title"),
                "theme": request_payload.get("theme"),
                "research_question": search.get("research_question"),
                "dataset": search.get("dataset"),
                "attempt": attempt,
                "validation_feedback": feedback_messages,
                "prior_attempts": prior_attempts,
                "budgets": _acquisition_budgets(self._config),
                "strategy": _source_family_strategy(search.get("dataset") if isinstance(search.get("dataset"), dict) else {}, request_payload),
            }
            data_access = self._run_data_acquisition(
                run_id=run_id,
                request_payload=request_payload,
                acquisition_input=acquisition_input,
            )
            if not data_access.get("empirical_ready"):
                return self._build_acquisition_failure_ledger(
                    run_id=run_id,
                    request_payload=request_payload,
                    search=search,
                    data_access=data_access,
                    attempt=attempt,
                )
            strategy = _source_family_strategy(search.get("dataset") if isinstance(search.get("dataset"), dict) else {}, request_payload)
            if str(strategy.get("family_id") or "").strip() == "geo_functional_genomics":
                return self._run_geo_empirical_analysis(
                    run_id=run_id,
                    request_payload=request_payload,
                    search=search,
                    data_access=data_access,
                    attempt=attempt,
                )
        store.set_stage(stage="2", agent="dataset-profiler", model=self._config.openai_workspace_model)
        profiler_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": search.get("research_question"),
            "dataset": search.get("dataset"),
            "data_access": data_access,
            "attempt": attempt,
            "validation_feedback": feedback_messages,
        }
        profile = self._run_dataset_profiler(
            run_id=run_id,
            profiler_input=profiler_input,
        )
        if not bool(profile.get("analyzable", True)):
            reason = str(profile.get("blocking_reason") or profile.get("profile_summary") or "Dataset inspection could not find analyzable data.").strip()
            store.fail_stage(stage="2", agent="dataset-profiler", reason=reason, retries_remaining=max(0, 3 - attempt))
            raise PipelineExecutionError(reason, stage="2")

        store.set_stage(stage="2", agent="experiment-planner", model=self._config.openai_workspace_model)
        planner_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": search.get("research_question"),
            "dataset": search.get("dataset"),
            "dataset_profile": profile,
            "data_access": data_access,
            "related_work": search.get("related_work") or [],
            "attempt": attempt,
            "validation_feedback": feedback_messages,
            "prior_attempts": prior_attempts,
        }
        plan = self._run_experiment_planner(
            run_id=run_id,
            planner_input=planner_input,
        )

        store.set_stage(stage="2", agent="data-analyst", model=self._config.openai_workspace_model)
        analyst_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": search.get("research_question"),
            "dataset": search.get("dataset"),
            "dataset_profile": profile,
            "data_access": data_access,
            "execution_plan": plan,
            "related_work": search.get("related_work") or [],
            "attempt": attempt,
            "validation_feedback": feedback_messages,
            "prior_attempts": prior_attempts,
        }
        response_payload = self._run_data_analyst_execution(
            run_id=run_id,
            analyst_input=analyst_input,
        )
        response = response_payload.pop("_response")
        container_ids = self._openai_client.extract_container_ids(response)
        container_files = self._workspace_file_inventory(container_ids=container_ids)
        store.set_stage(stage="2", agent="research-packager", model=self._config.openai_writer_model)
        packaging_input = {
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": search.get("research_question"),
            "dataset": search.get("dataset"),
            "dataset_profile": profile,
            "data_access": data_access,
            "execution_plan": plan,
            "execution_handoff": response_payload,
            "workspace_files": container_files,
            "attempt": attempt,
        }
        packaged = self._run_research_packager(
            run_id=run_id,
            packager_input=packaging_input,
        )
        ledger = {
            "title": str(packaged.get("title") or request_payload.get("title") or "Research paper"),
            "research_question": str(packaged.get("research_question") or response_payload.get("research_question") or search.get("research_question") or "").strip(),
            "dataset": search.get("dataset") or {},
            "data_access": data_access or {},
            "dataset_profile": profile,
            "execution_plan": plan,
            "execution_handoff": response_payload,
            "experiment_summary": str(packaged.get("experiment_summary") or response_payload.get("execution_summary") or "").strip(),
            "experiments": normalize_text_list(packaged.get("experiments") or response_payload.get("completed_experiments")),
            "findings": normalize_text_list(packaged.get("findings") or response_payload.get("findings")),
            "limitations": normalize_text_list(packaged.get("limitations") or response_payload.get("limitations")),
            "code_summary": str(packaged.get("code_summary") or response_payload.get("packaging_notes") or "").strip(),
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(packaged.get("sources") or response_payload.get("sources") or [])],
            "artifacts": [_normalize_artifact(entry, index) for index, entry in enumerate(packaged.get("artifacts") or [])],
            "figure_summaries": [
                _normalize_figure_summary(entry, index) for index, entry in enumerate(packaged.get("figure_summaries") or response_payload.get("figure_summaries") or [])
            ],
            "results": packaged.get("results") or [],
            "search": search,
            "attempt": attempt,
        }
        if not ledger["artifacts"]:
            ledger["artifacts"] = self._synthesize_artifacts_from_workspace(
                workspace_files=container_files,
                saved_artifact_paths=normalize_text_list(response_payload.get("saved_artifact_paths")),
                source_ids=[source.get("source_id") for source in ledger["sources"] if isinstance(source, dict) and str(source.get("source_id") or "").strip()],
            )
        downloaded_files = self.materialize_workspace_files(
            run_id=run_id,
            ledger=ledger,
            container_ids=container_ids,
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
        if not ledger["dataset"]:
            ledger["dataset"] = profile.get("dataset") or search.get("dataset") or {}
        if not ledger["results"]:
            fallback_artifact_ids = [entry.get("artifact_id") for entry in ledger.get("artifacts", []) if entry.get("artifact_id")]
            ledger["results"] = [
                {
                    "result_id": f"finding_{index + 1}",
                    "text": finding,
                    "artifact_ids": fallback_artifact_ids,
                    "note_ids": [],
                }
                for index, finding in enumerate(ledger.get("findings") or [])
                if str(finding).strip()
            ]
        self._ensure_artifact_metadata(ledger)
        self._attach_data_access_receipt_artifacts(ledger)
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
        store.record_artifact(
            stage="2",
            artifact_id="ledger",
            artifact_type="ledger",
            path="ledger.json",
            description="Packaged Stage 2 ledger for downstream writing.",
        )
        store.complete_stage(stage="2", agent="research-packager", artifacts=["ledger.json"])
        return ledger

    def _run_geo_data_acquisition(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        acquisition_input: dict[str, Any],
    ) -> dict[str, Any]:
        dataset = acquisition_input.get("dataset") if isinstance(acquisition_input.get("dataset"), dict) else {}
        accession = str(dataset.get("accession_id") or dataset.get("dataset_id") or "").strip().upper()
        if not accession:
            raise PipelineExecutionError("GEO acquisition requires a resolved GEO accession.", stage="2")

        run_directory = self.run_directory(run_id)
        downloads_directory = run_directory / "downloads"
        downloads_directory.mkdir(parents=True, exist_ok=True)
        strategy = acquisition_input.get("strategy") if isinstance(acquisition_input.get("strategy"), dict) else {}
        family_label = str(strategy.get("family_label") or "NCBI GEO Functional Genomics").strip() or "NCBI GEO Functional Genomics"
        manifest: list[dict[str, Any]] = []

        def append_entry(
            *,
            retrieval_target: str,
            url: str,
            method: str,
            status: str,
            http_status: int | None,
            error_kind: str,
            error_message: str,
            latency_ms: int | None,
            bytes_downloaded: int,
            saved_path: str,
            saved_file_kind: str,
            content_type: str,
            classification: str,
            usable_for_analysis: bool,
            notes: str,
        ) -> None:
            manifest.append(
                {
                    "entry_id": f"download_{len(manifest) + 1}",
                    "url": url,
                    "source_family": family_label,
                    "retrieval_target": retrieval_target,
                    "method": method,
                    "status": status,
                    "http_status": http_status,
                    "error_kind": error_kind,
                    "error_message": error_message,
                    "latency_ms": latency_ms,
                    "bytes_downloaded": bytes_downloaded,
                    "saved_path": saved_path,
                    "saved_file_kind": saved_file_kind,
                    "content_type": content_type,
                    "classification": classification,
                    "usable_for_analysis": usable_for_analysis,
                    "notes": notes,
                }
            )

        series_matrix_url = f"https://www.ncbi.nlm.nih.gov/geo/download/?acc={accession}&format=file&file={accession}_series_matrix.txt.gz"
        series_matrix_fetch = _http_fetch(series_matrix_url, timeout_seconds=60)
        if series_matrix_fetch["ok"]:
            series_matrix_path = downloads_directory / f"{_safe_accession(accession)}_series_matrix.txt.gz"
            series_matrix_path.write_bytes(series_matrix_fetch["bytes"])
            append_entry(
                retrieval_target="series_matrix",
                url=series_matrix_url,
                method="https_get",
                status="success",
                http_status=series_matrix_fetch["status_code"],
                error_kind="",
                error_message="",
                latency_ms=series_matrix_fetch["latency_ms"],
                bytes_downloaded=len(series_matrix_fetch["bytes"]),
                saved_path=f"downloads/{series_matrix_path.name}",
                saved_file_kind="matrix",
                content_type=series_matrix_fetch["content_type"],
                classification="semi_numeric",
                usable_for_analysis=True,
                notes="Series matrix was available directly from GEO.",
            )
        else:
            append_entry(
                retrieval_target="series_matrix",
                url=series_matrix_url,
                method="https_get",
                status=series_matrix_fetch["error_kind"] or "http_error",
                http_status=series_matrix_fetch["status_code"] or None,
                error_kind=series_matrix_fetch["error_kind"] or "http_error",
                error_message=series_matrix_fetch["error_message"],
                latency_ms=series_matrix_fetch["latency_ms"],
                bytes_downloaded=0,
                saved_path="downloads/series_matrix_unavailable",
                saved_file_kind="",
                content_type=series_matrix_fetch["content_type"],
                classification="failed",
                usable_for_analysis=False,
                notes="Series matrix target was attempted first per the GEO retrieval order.",
            )

        series_text_url = f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={accession}&targ=self&form=text&view=quick"
        series_text_fetch = _http_fetch(series_text_url, timeout_seconds=60, accept="text/plain")
        if not series_text_fetch["ok"]:
            append_entry(
                retrieval_target="series_metadata",
                url=series_text_url,
                method="https_get",
                status=series_text_fetch["error_kind"] or "http_error",
                http_status=series_text_fetch["status_code"] or None,
                error_kind=series_text_fetch["error_kind"] or "http_error",
                error_message=series_text_fetch["error_message"],
                latency_ms=series_text_fetch["latency_ms"],
                bytes_downloaded=0,
                saved_path="downloads/series_metadata_unavailable",
                saved_file_kind="",
                content_type=series_text_fetch["content_type"],
                classification="failed",
                usable_for_analysis=False,
                notes="Series metadata discovery is required to recover GEO sample ids.",
            )
            return {
                "status": "blocked",
                "summary": f"Failed to fetch GEO series metadata for {accession}.",
                "blocking_reason": f"Unable to fetch the GEO series metadata page for {accession}.",
                "substrate_class": "none",
                "empirical_ready": False,
                "download_manifest": manifest,
                "usable_saved_files": [],
                "metadata_only_saved_files": [],
                "host_failures": [],
                "sources": [],
            }

        series_text = _decode_text_payload(series_text_fetch["bytes"])
        sample_ids = [sample_id.strip() for sample_id in _geo_values(series_text, "Series_sample_id") if sample_id.strip().upper().startswith("GSM")]
        platform_ids = [platform_id.strip() for platform_id in _geo_values(series_text, "Series_platform_id") if platform_id.strip().upper().startswith("GPL")]
        platform_id = platform_ids[0] if platform_ids else ""

        sample_metadata_rows: list[dict[str, Any]] = []
        probe_matrix: dict[str, dict[str, str]] = {}
        sample_table_successes = 0
        for sample_id in sample_ids:
            sample_quick_url = f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={sample_id}&targ=self&form=text&view=quick"
            sample_quick_fetch = _http_fetch(sample_quick_url, timeout_seconds=60, accept="text/plain")
            sample_quick_text = _decode_text_payload(sample_quick_fetch["bytes"]) if sample_quick_fetch["ok"] else ""
            append_entry(
                retrieval_target="sample_metadata",
                url=sample_quick_url,
                method="https_get",
                status="success" if sample_quick_fetch["ok"] else (sample_quick_fetch["error_kind"] or "http_error"),
                http_status=sample_quick_fetch["status_code"] or None,
                error_kind="" if sample_quick_fetch["ok"] else (sample_quick_fetch["error_kind"] or "http_error"),
                error_message="" if sample_quick_fetch["ok"] else sample_quick_fetch["error_message"],
                latency_ms=sample_quick_fetch["latency_ms"],
                bytes_downloaded=len(sample_quick_fetch["bytes"]) if sample_quick_fetch["ok"] else 0,
                saved_path=f"downloads/{sample_id}_sample_metadata.txt",
                saved_file_kind="metadata",
                content_type=sample_quick_fetch["content_type"],
                classification="metadata_only" if sample_quick_fetch["ok"] else "failed",
                usable_for_analysis=False,
                notes="Fetched GEO quick-view metadata to recover sample title, source name, and time point.",
            )
            sample_data_url = f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={sample_id}&targ=self&form=text&view=data"
            sample_fetch = _http_fetch(sample_data_url, timeout_seconds=90, accept="text/plain")
            if not sample_fetch["ok"]:
                append_entry(
                    retrieval_target="processed_sample_table",
                    url=sample_data_url,
                    method="https_get",
                    status=sample_fetch["error_kind"] or "http_error",
                    http_status=sample_fetch["status_code"] or None,
                    error_kind=sample_fetch["error_kind"] or "http_error",
                    error_message=sample_fetch["error_message"],
                    latency_ms=sample_fetch["latency_ms"],
                    bytes_downloaded=0,
                    saved_path=f"downloads/{sample_id}_sample_table.tsv",
                    saved_file_kind="",
                    content_type=sample_fetch["content_type"],
                    classification="failed",
                    usable_for_analysis=False,
                    notes="Full processed sample table fetch failed.",
                )
                continue

            sample_text = _decode_text_payload(sample_fetch["bytes"])
            table_body = _geo_table_section(sample_text, "!sample_table_begin", "!sample_table_end")
            if not table_body.strip():
                append_entry(
                    retrieval_target="processed_sample_table",
                    url=sample_data_url,
                    method="https_get",
                    status="metadata_only",
                    http_status=sample_fetch["status_code"],
                    error_kind="missing_table",
                    error_message="GEO sample view did not contain a sample_table payload.",
                    latency_ms=sample_fetch["latency_ms"],
                    bytes_downloaded=0,
                    saved_path=f"downloads/{sample_id}_sample_table.tsv",
                    saved_file_kind="",
                    content_type=sample_fetch["content_type"],
                    classification="metadata_only",
                    usable_for_analysis=False,
                    notes="Sample metadata was reachable but no numeric table body was present.",
                )
                continue

            table_rows = _parse_tsv_rows(table_body)
            sample_table_path = downloads_directory / f"{sample_id}_sample_table.tsv"
            bytes_saved = _write_text_file(sample_table_path, table_body)
            append_entry(
                retrieval_target="processed_sample_table",
                url=sample_data_url,
                method="https_get",
                status="success",
                http_status=sample_fetch["status_code"],
                error_kind="",
                error_message="",
                latency_ms=sample_fetch["latency_ms"],
                bytes_downloaded=bytes_saved,
                saved_path=f"downloads/{sample_table_path.name}",
                saved_file_kind="table",
                content_type=sample_fetch["content_type"],
                classification="semi_numeric",
                usable_for_analysis=True,
                notes=f"Recovered {len(table_rows)} normalized GEO rows for {sample_id}.",
            )
            sample_table_successes += 1

            sample_titles = _geo_values(sample_quick_text, "Sample_title")
            sample_characteristics = _geo_values(sample_quick_text, "Sample_characteristics_ch1")
            sample_descriptions = _geo_values(sample_quick_text, "Sample_description")
            sample_source_names = _geo_values(sample_quick_text, "Sample_source_name_ch1")
            time_point_hours = _extract_geo_timepoint_hours(
                *sample_characteristics,
                *(sample_titles[:1] or []),
                *(sample_source_names[:1] or []),
            )
            raw_file = ""
            dye_label = ""
            for description in sample_descriptions:
                lowered = description.lower()
                if lowered.startswith("green.") or lowered.startswith("red."):
                    dye_label = description
                if "raw data:" in lowered:
                    raw_file = description.partition("raw data:")[2].strip()
            sample_metadata_rows.append(
                {
                    "sample_id": sample_id,
                    "title": sample_titles[0] if sample_titles else sample_id,
                    "time_point_hours": time_point_hours,
                    "dye_label": dye_label,
                    "raw_file": raw_file,
                    "source_name": (sample_source_names or [""])[0],
                    "row_count": str(len(table_rows)),
                    "table_path": f"downloads/{sample_table_path.name}",
                }
            )
            for row in table_rows:
                id_ref = str(row.get("ID_REF") or "").strip()
                value = str(row.get("VALUE") or "").strip()
                if not id_ref or value == "":
                    continue
                probe_matrix.setdefault(id_ref, {})[sample_id] = value

        platform_path_value = ""
        platform_rows: list[dict[str, str]] = []
        if platform_id:
            platform_url = f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={platform_id}&targ=self&form=text&view=data"
            platform_fetch = _http_fetch(platform_url, timeout_seconds=120, accept="text/plain")
            if platform_fetch["ok"]:
                platform_text = _decode_text_payload(platform_fetch["bytes"])
                platform_table = _geo_table_section(platform_text, "!platform_table_begin", "!platform_table_end")
                if platform_table.strip():
                    platform_path = downloads_directory / f"{platform_id}_platform.tsv"
                    platform_bytes = _write_text_file(platform_path, platform_table)
                    platform_path_value = f"downloads/{platform_path.name}"
                    platform_rows = _parse_tsv_rows(platform_table)
                    append_entry(
                        retrieval_target="platform_annotation",
                        url=platform_url,
                        method="https_get",
                        status="success",
                        http_status=platform_fetch["status_code"],
                        error_kind="",
                        error_message="",
                        latency_ms=platform_fetch["latency_ms"],
                        bytes_downloaded=platform_bytes,
                        saved_path=platform_path_value,
                        saved_file_kind="table",
                        content_type=platform_fetch["content_type"],
                        classification="metadata_only",
                        usable_for_analysis=True,
                        notes=f"Recovered {len(platform_rows)} platform annotation rows for {platform_id}.",
                    )
                else:
                    append_entry(
                        retrieval_target="platform_annotation",
                        url=platform_url,
                        method="https_get",
                        status="metadata_only",
                        http_status=platform_fetch["status_code"],
                        error_kind="missing_table",
                        error_message="Platform view did not contain a platform table.",
                        latency_ms=platform_fetch["latency_ms"],
                        bytes_downloaded=0,
                        saved_path=f"downloads/{platform_id}_platform.tsv",
                        saved_file_kind="",
                        content_type=platform_fetch["content_type"],
                        classification="metadata_only",
                        usable_for_analysis=False,
                        notes="Platform metadata was reachable but annotation rows were absent.",
                    )
            else:
                append_entry(
                    retrieval_target="platform_annotation",
                    url=platform_url,
                    method="https_get",
                    status=platform_fetch["error_kind"] or "http_error",
                    http_status=platform_fetch["status_code"] or None,
                    error_kind=platform_fetch["error_kind"] or "http_error",
                    error_message=platform_fetch["error_message"],
                    latency_ms=platform_fetch["latency_ms"],
                    bytes_downloaded=0,
                    saved_path=f"downloads/{platform_id}_platform.tsv",
                    saved_file_kind="",
                    content_type=platform_fetch["content_type"],
                    classification="failed",
                    usable_for_analysis=False,
                    notes="Platform annotation fetch failed.",
                )

        sample_metadata_path = ""
        if sample_metadata_rows:
            sample_metadata_rows.sort(key=lambda row: _parse_float(str(row.get("time_point_hours") or "")) or 0.0)
            metadata_path = downloads_directory / f"{accession}_sample_metadata.csv"
            _write_csv_rows(
                metadata_path,
                ["sample_id", "title", "time_point_hours", "dye_label", "raw_file", "source_name", "row_count", "table_path"],
                sample_metadata_rows,
            )
            sample_metadata_path = f"downloads/{metadata_path.name}"

        probe_matrix_path = ""
        gene_matrix_path = ""
        gene_matrix_rows: list[dict[str, Any]] = []
        if sample_metadata_rows and probe_matrix:
            ordered_sample_ids = [str(row.get("sample_id") or "").strip() for row in sample_metadata_rows]
            probe_rows: list[dict[str, Any]] = []
            for id_ref in sorted(probe_matrix, key=lambda value: int(value) if str(value).isdigit() else value):
                sample_values = probe_matrix.get(id_ref, {})
                if not all(sample_id in sample_values for sample_id in ordered_sample_ids):
                    continue
                row = {"ID_REF": id_ref}
                for sample_id in ordered_sample_ids:
                    row[sample_id] = sample_values[sample_id]
                probe_rows.append(row)
            if probe_rows:
                probe_path = downloads_directory / f"{accession}_probe_matrix.tsv"
                _write_csv_rows(probe_path, ["ID_REF", *ordered_sample_ids], probe_rows, delimiter="\t")
                probe_matrix_path = f"downloads/{probe_path.name}"

            platform_by_id = {str(row.get("ID") or "").strip(): row for row in platform_rows}
            gene_aggregates: dict[str, dict[str, Any]] = {}
            for probe_row in probe_rows:
                platform_row = platform_by_id.get(str(probe_row.get("ID_REF") or "").strip(), {})
                symbol = str(platform_row.get("Symbol") or "").strip()
                if not symbol:
                    continue
                aggregate = gene_aggregates.setdefault(
                    symbol,
                    {
                        "Symbol": symbol,
                        "Name": str(platform_row.get("Name") or "").strip(),
                        "Probe_Count": 0,
                        **{sample_id: 0.0 for sample_id in ordered_sample_ids},
                    },
                )
                aggregate["Probe_Count"] += 1
                for sample_id in ordered_sample_ids:
                    numeric_value = _parse_float(str(probe_row.get(sample_id) or ""))
                    if numeric_value is None:
                        continue
                    aggregate[sample_id] += numeric_value
            for symbol, aggregate in gene_aggregates.items():
                probe_count = int(aggregate.get("Probe_Count") or 0)
                if probe_count <= 0:
                    continue
                row: dict[str, Any] = {
                    "Symbol": symbol,
                    "Name": aggregate.get("Name") or "",
                    "Probe_Count": probe_count,
                }
                for sample_id in ordered_sample_ids:
                    row[sample_id] = f"{float(aggregate[sample_id]) / probe_count:.6f}"
                gene_matrix_rows.append(row)
            gene_matrix_rows.sort(key=lambda row: str(row.get("Symbol") or ""))
            if gene_matrix_rows:
                gene_path = downloads_directory / f"{accession}_gene_matrix.tsv"
                _write_csv_rows(gene_path, ["Symbol", "Name", "Probe_Count", *ordered_sample_ids], gene_matrix_rows, delimiter="\t")
                gene_matrix_path = f"downloads/{gene_path.name}"

        distinct_timepoints = {
            parsed_time
            for row in sample_metadata_rows
            for parsed_time in [_parse_float(str(row.get("time_point_hours") or ""))]
            if parsed_time is not None
        }

        usable_saved_files: list[dict[str, Any]] = []
        if sample_metadata_path:
            usable_saved_files.append(
                {
                    "path": sample_metadata_path,
                    "bytes_downloaded": (run_directory / sample_metadata_path).stat().st_size,
                    "classification": "metadata_only",
                    "retrieval_target": "sample_metadata",
                }
            )
        if probe_matrix_path:
            usable_saved_files.append(
                {
                    "path": probe_matrix_path,
                    "bytes_downloaded": (run_directory / probe_matrix_path).stat().st_size,
                    "classification": "semi_numeric",
                    "retrieval_target": "processed_expression_matrix",
                }
            )
        if gene_matrix_path:
            usable_saved_files.append(
                {
                    "path": gene_matrix_path,
                    "bytes_downloaded": (run_directory / gene_matrix_path).stat().st_size,
                    "classification": "semi_numeric",
                    "retrieval_target": "processed_gene_matrix",
                }
            )
        if platform_path_value:
            usable_saved_files.append(
                {
                    "path": platform_path_value,
                    "bytes_downloaded": (run_directory / platform_path_value).stat().st_size,
                    "classification": "metadata_only",
                    "retrieval_target": "platform_annotation",
                }
            )

        metadata_only_saved_files = [
            entry for entry in usable_saved_files if str(entry.get("classification") or "").strip().lower() == "metadata_only"
        ]
        host_failures: dict[str, dict[str, Any]] = {}
        for entry in manifest:
            url = str(entry.get("url") or "").strip()
            status = str(entry.get("status") or "").strip().lower()
            if not url or status == "success":
                continue
            match = re.search(r"https?://([^/]+)/", url)
            host = match.group(1) if match else "unknown"
            aggregate = host_failures.setdefault(host, {"host": host, "attempts": 0, "failures": 0, "error_kinds": []})
            aggregate["attempts"] += 1
            aggregate["failures"] += 1
            error_kind = str(entry.get("error_kind") or status).strip()
            if error_kind and error_kind not in aggregate["error_kinds"]:
                aggregate["error_kinds"].append(error_kind)

        substrate_class = "semi_numeric" if gene_matrix_path or probe_matrix_path else "none"
        empirical_ready = bool(
            gene_matrix_path
            and sample_table_successes == len(sample_ids)
            and len(distinct_timepoints) >= 4
        )
        sources = [
            {
                "source_id": "source_1",
                "label": f"GEO series landing page for {accession}",
                "landing_page_url": f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={accession}",
                "download_url": series_matrix_url,
                "accession_id": accession,
                "notes": "Primary GEO accession source; staged retrieval began with series matrix and then recovered processed sample tables.",
            }
        ]
        if platform_id:
            sources.append(
                {
                    "source_id": "source_2",
                    "label": f"GEO platform annotation for {platform_id}",
                    "landing_page_url": f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={platform_id}",
                    "download_url": "",
                    "accession_id": platform_id,
                    "notes": "Platform annotation used to map probe IDs onto gene symbols and names.",
                }
            )
        summary = (
            f"Recovered {sample_table_successes} processed GEO sample tables for {accession}, materialized a probe matrix with {len(probe_matrix)} probes, "
            f"and wrote a {len(gene_matrix_rows)}-symbol gene matrix."
            if empirical_ready
            else (
                f"Recovered {sample_table_successes} processed GEO sample tables for {accession}, materialized a probe matrix with {len(probe_matrix)} probes, "
                f"and wrote a {len(gene_matrix_rows)}-symbol gene matrix, but did not recover enough complete timepoint metadata to clear the empirical gate."
                if substrate_class != "none"
                else f"GEO acquisition for {accession} did not recover enough processed sample tables to materialize a usable expression matrix."
            )
        )
        return {
            "status": "ready" if empirical_ready else "blocked",
            "summary": summary,
            "blocking_reason": (
                ""
                if empirical_ready
                else (
                    f"GEO processed-table acquisition recovered semi-numeric tables for {accession}, but the run did not recover enough complete sample/timepoint metadata to support empirical analysis."
                    if substrate_class != "none"
                    else f"GEO processed-table acquisition did not materialize a complete local numeric substrate for {accession}."
                )
            ),
            "substrate_class": substrate_class,
            "empirical_ready": empirical_ready,
            "download_manifest": manifest,
            "usable_saved_files": usable_saved_files,
            "metadata_only_saved_files": metadata_only_saved_files,
            "host_failures": list(host_failures.values()),
            "sources": sources,
        }

    def _run_geo_empirical_analysis(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        search: dict[str, Any],
        data_access: dict[str, Any],
        attempt: int,
    ) -> dict[str, Any]:
        accession = str((search.get("dataset") or {}).get("accession_id") or "").strip().upper()
        run_directory = self.run_directory(run_id)
        sample_metadata_path = run_directory / "downloads" / f"{accession}_sample_metadata.csv"
        gene_matrix_path = run_directory / "downloads" / f"{accession}_gene_matrix.tsv"
        if not sample_metadata_path.exists() or not gene_matrix_path.exists():
            raise PipelineExecutionError("GEO empirical analysis requires the saved sample metadata and gene matrix files.", stage="2")

        with sample_metadata_path.open("r", encoding="utf-8", newline="") as handle:
            sample_rows = list(csv.DictReader(handle))
        sample_rows.sort(key=lambda row: _parse_float(str(row.get("time_point_hours") or "")) or 0.0)
        ordered_sample_ids = [str(row.get("sample_id") or "").strip() for row in sample_rows if str(row.get("sample_id") or "").strip()]
        timepoints = [_parse_float(str(row.get("time_point_hours") or "")) or 0.0 for row in sample_rows]
        probe_matrix_path = run_directory / "downloads" / f"{accession}_probe_matrix.tsv"
        probe_count = 0
        if probe_matrix_path.exists():
            with probe_matrix_path.open("r", encoding="utf-8", newline="") as handle:
                probe_count = max(0, sum(1 for _ in handle) - 1)
        if len(ordered_sample_ids) < 4:
            raise PipelineExecutionError("GEO empirical analysis requires multiple time points.", stage="2")

        gene_rows: list[dict[str, Any]] = []
        with gene_matrix_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            for row in reader:
                symbol = str(row.get("Symbol") or "").strip()
                if not symbol:
                    continue
                values: list[float] = []
                valid = True
                for sample_id in ordered_sample_ids:
                    numeric_value = _parse_float(str(row.get(sample_id) or ""))
                    if numeric_value is None:
                        valid = False
                        break
                    values.append(numeric_value)
                if not valid:
                    continue
                fit = _fit_fixed_period_cosine(timepoints, values)
                gene_rows.append(
                    {
                        "Symbol": symbol,
                        "Name": str(row.get("Name") or "").strip(),
                        "Probe_Count": int(_parse_float(str(row.get("Probe_Count") or "")) or 0),
                        "Amplitude_24h": fit["amplitude"],
                        "R2_24h": fit["r_squared"],
                        "Phase_Hours": fit["phase_hours"],
                        "Mean_Expression": fit["mean_expression"],
                        **{sample_id: values[index] for index, sample_id in enumerate(ordered_sample_ids)},
                    }
                )
        if not gene_rows:
            raise PipelineExecutionError("GEO empirical analysis could not derive any symbol-level expression profiles.", stage="2")

        named_gene_rows = [row for row in gene_rows if _looks_like_named_gene(str(row.get("Symbol") or ""))]
        named_gene_rows.sort(key=lambda row: (float(row.get("R2_24h") or 0.0), float(row.get("Amplitude_24h") or 0.0)), reverse=True)
        top_gene_rows = named_gene_rows[:25] or gene_rows[:25]
        core_clock_symbols = ["ARNTL", "CLOCK", "PER1", "PER2", "PER3", "CRY1", "CRY2", "NR1D1"]
        core_clock_rows = [row for row in gene_rows if str(row.get("Symbol") or "").strip() in core_clock_symbols]
        core_clock_rows.sort(key=lambda row: core_clock_symbols.index(str(row.get("Symbol") or "").strip()))

        sample_vectors = {sample_id: [] for sample_id in ordered_sample_ids}
        for row in gene_rows:
            for sample_id in ordered_sample_ids:
                sample_vectors[sample_id].append(float(row.get(sample_id) or 0.0))
        correlation_rows: list[dict[str, Any]] = []
        for left_id in ordered_sample_ids:
            row = {"sample_id": left_id}
            for right_id in ordered_sample_ids:
                row[right_id] = f"{_pearson_correlation(sample_vectors[left_id], sample_vectors[right_id]):.6f}"
            correlation_rows.append(row)

        artifacts_directory = run_directory / "artifacts"
        sample_metadata_artifact = artifacts_directory / "geo_sample_metadata.csv"
        top_genes_artifact = artifacts_directory / "top_circadian_gene_fits.csv"
        core_clock_artifact = artifacts_directory / "core_clock_gene_fits.csv"
        correlation_artifact = artifacts_directory / "sample_correlation_matrix.csv"
        _write_csv_rows(
            sample_metadata_artifact,
            ["sample_id", "title", "time_point_hours", "dye_label", "raw_file", "source_name", "row_count", "table_path"],
            sample_rows,
        )
        _write_csv_rows(
            top_genes_artifact,
            ["Symbol", "Name", "Probe_Count", "Amplitude_24h", "R2_24h", "Phase_Hours", "Mean_Expression", *ordered_sample_ids],
            [
                {
                    "Symbol": row["Symbol"],
                    "Name": row["Name"],
                    "Probe_Count": row["Probe_Count"],
                    "Amplitude_24h": f"{float(row['Amplitude_24h']):.6f}",
                    "R2_24h": f"{float(row['R2_24h']):.6f}",
                    "Phase_Hours": f"{float(row['Phase_Hours']):.6f}",
                    "Mean_Expression": f"{float(row['Mean_Expression']):.6f}",
                    **{sample_id: f"{float(row[sample_id]):.6f}" for sample_id in ordered_sample_ids},
                }
                for row in top_gene_rows
            ],
        )
        _write_csv_rows(
            core_clock_artifact,
            ["Symbol", "Name", "Probe_Count", "Amplitude_24h", "R2_24h", "Phase_Hours", "Mean_Expression", *ordered_sample_ids],
            [
                {
                    "Symbol": row["Symbol"],
                    "Name": row["Name"],
                    "Probe_Count": row["Probe_Count"],
                    "Amplitude_24h": f"{float(row['Amplitude_24h']):.6f}",
                    "R2_24h": f"{float(row['R2_24h']):.6f}",
                    "Phase_Hours": f"{float(row['Phase_Hours']):.6f}",
                    "Mean_Expression": f"{float(row['Mean_Expression']):.6f}",
                    **{sample_id: f"{float(row[sample_id]):.6f}" for sample_id in ordered_sample_ids},
                }
                for row in core_clock_rows
            ],
        )
        _write_csv_rows(
            correlation_artifact,
            ["sample_id", *ordered_sample_ids],
            correlation_rows,
        )

        top_gene_text = ", ".join(
            f"{row['Symbol']} (R² {float(row['R2_24h']):.3f}, amplitude {float(row['Amplitude_24h']):.3f}, phase {float(row['Phase_Hours']):.1f} h)"
            for row in top_gene_rows[:5]
        )
        arntl = next((row for row in core_clock_rows if str(row.get("Symbol") or "") == "ARNTL"), None)
        per1 = next((row for row in core_clock_rows if str(row.get("Symbol") or "") == "PER1"), None)
        cry2 = next((row for row in core_clock_rows if str(row.get("Symbol") or "") == "CRY2"), None)
        earliest_latest_correlation = _pearson_correlation(sample_vectors[ordered_sample_ids[0]], sample_vectors[ordered_sample_ids[-1]])
        strongest_pair = max(
            (
                (left_row["sample_id"], right_id, float(left_row[right_id]))
                for left_row in correlation_rows
                for right_id in ordered_sample_ids
                if right_id != left_row["sample_id"]
            ),
            key=lambda item: item[2],
        )
        methods_text = (
            f"We downloaded the full GEO processed sample tables for {len(sample_rows)} GSM samples from {accession} using the GEO text-data view, "
            f"downloaded the GPL platform annotation, merged the resulting {probe_count:,} probe profiles across the {len(sample_rows)} recovered time points, "
            f"collapsed probes onto shared gene symbols by mean expression, and fit a fixed 24-hour cosine model to each gene-level profile to quantify amplitude, phase, and goodness of fit."
        )
        experiments = [
            "Recovered the full processed GEO sample tables and platform annotation into the hosted run directory.",
            "Materialized a probe-by-sample matrix and a symbol-collapsed gene-expression matrix for the eight MCF10A time points.",
            "Fit fixed 24-hour cosine models to each gene-level trajectory and ranked genes by fit quality and amplitude.",
            "Computed a sample-by-sample correlation matrix from the recovered expression matrix.",
        ]
        findings = [
            f"The backend recovered {len(sample_rows)} processed GEO sample tables plus the GPL annotation, yielding a {len(gene_rows)}-gene matrix across {len(sample_rows)} time points.",
            f"The strongest named 24-hour cosine fits were {top_gene_text}.",
            (
                f"Among core clock genes, ARNTL/BMAL1 reached amplitude {float(arntl['Amplitude_24h']):.3f} log2 units with R² {float(arntl['R2_24h']):.3f} and phase {float(arntl['Phase_Hours']):.1f} h; "
                f"CRY2 reached amplitude {float(cry2['Amplitude_24h']):.3f} with R² {float(cry2['R2_24h']):.3f}; "
                f"PER1 reached amplitude {float(per1['Amplitude_24h']):.3f} with R² {float(per1['R2_24h']):.3f}."
                if arntl and cry2 and per1
                else "Core-clock genes were retained in the recovered matrix and quantified with the same fixed-period cosine screen."
            ),
            f"The strongest sample-level correlation was {strongest_pair[0]} versus {strongest_pair[1]} at r={strongest_pair[2]:.3f}, and the earliest-vs-latest comparison remained positively correlated at r={earliest_latest_correlation:.3f}.",
        ]
        limitations = [
            "The GEO processed tables are normalized single-channel approximations derived from the deposited two-color workflow, so the analysis is semi-numeric rather than a raw-array reprocessing pipeline.",
            "The time course spans eight samples from 0 to 28 hours, which supports a descriptive fixed-period screen but is still sparse for definitive circadian inference.",
            "Probe collapsing used symbol-level means and therefore does not resolve transcript isoforms or probe-specific cross-hybridization effects.",
        ]
        note_ids = [str(note.get("id") or "").strip() for note in request_payload.get("notes") or [] if str(note.get("id") or "").strip()]
        ledger = {
            "title": str(request_payload.get("title") or "Research paper"),
            "research_question": str(search.get("research_question") or request_payload.get("theme") or request_payload.get("title") or "").strip(),
            "dataset": search.get("dataset") or {},
            "data_access": data_access,
            "dataset_profile": {
                "analyzable": True,
                "blocking_reason": "",
                "profile_summary": f"Recovered {len(sample_rows)} processed sample tables, a probe matrix, and a {len(gene_rows)}-symbol gene matrix for GEO accession {accession}.",
                "retrieval_summary": data_access.get("summary") or "",
                "dataset": search.get("dataset") or {},
                "available_assets": ["processed sample tables", "platform annotation", "probe matrix", "gene matrix"],
                "constraints": ["processed single-channel GEO values", "sparse eight-sample time course"],
                "suggested_analysis_targets": ["gene-level 24-hour cosine fits", "core clock gene trajectories", "sample correlation structure"],
                "sources": data_access.get("sources") or [],
            },
            "execution_plan": {
                "analysis_strategy": "deterministic_geo_processed_table_analysis",
                "period_hours": 24,
                "sample_count": len(sample_rows),
                "gene_count": len(gene_rows),
            },
            "execution_handoff": {
                "analysis_strategy": "deterministic_geo_processed_table_analysis",
                "saved_artifact_paths": [
                    "artifacts/geo_sample_metadata.csv",
                    "artifacts/top_circadian_gene_fits.csv",
                    "artifacts/core_clock_gene_fits.csv",
                    "artifacts/sample_correlation_matrix.csv",
                ],
                "packaging_notes": "Backend-generated GEO empirical analysis from recovered processed sample tables.",
            },
            "experiment_summary": f"The backend recovered the full processed GEO sample tables for {accession}, collapsed them onto {len(gene_rows)} gene symbols, and ranked the resulting time-course trajectories with a fixed 24-hour cosine screen.",
            "experiments": experiments,
            "findings": findings,
            "limitations": limitations,
            "code_summary": methods_text,
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(data_access.get('sources') or [])],
            "artifacts": [
                _normalize_artifact(
                    {
                        "artifact_id": "geo_sample_metadata",
                        "path": "artifacts/geo_sample_metadata.csv",
                        "kind": "table",
                        "mime_type": "text/csv",
                        "description": "Recovered GEO sample metadata with time points, dye labels, and processed-table paths.",
                        "source_ids": ["source_1"],
                    },
                    0,
                ),
                _normalize_artifact(
                    {
                        "artifact_id": "top_circadian_gene_fits",
                        "path": "artifacts/top_circadian_gene_fits.csv",
                        "kind": "table",
                        "mime_type": "text/csv",
                        "description": "Top named gene-level 24-hour cosine fits from the recovered GEO processed tables.",
                        "source_ids": ["source_1", "source_2"],
                    },
                    1,
                ),
                _normalize_artifact(
                    {
                        "artifact_id": "core_clock_gene_fits",
                        "path": "artifacts/core_clock_gene_fits.csv",
                        "kind": "table",
                        "mime_type": "text/csv",
                        "description": "Core clock gene trajectories and fit statistics from the recovered GEO expression matrix.",
                        "source_ids": ["source_1", "source_2"],
                    },
                    2,
                ),
                _normalize_artifact(
                    {
                        "artifact_id": "sample_correlation_matrix",
                        "path": "artifacts/sample_correlation_matrix.csv",
                        "kind": "table",
                        "mime_type": "text/csv",
                        "description": "Sample-level Pearson correlation matrix computed from the recovered GEO gene matrix.",
                        "source_ids": ["source_1", "source_2"],
                    },
                    3,
                ),
            ],
            "figure_summaries": [],
            "results": [
                {
                    "result_id": "result_1",
                    "text": f"The hosted run recovered {len(sample_rows)} processed GEO sample tables and the GPL annotation, yielding a {len(gene_rows)}-gene by {len(sample_rows)}-sample matrix for quantitative analysis.",
                    "artifact_ids": ["geo_sample_metadata", "top_circadian_gene_fits"],
                    "note_ids": note_ids,
                },
                {
                    "result_id": "result_2",
                    "text": f"The strongest named 24-hour cosine fits were {top_gene_text}.",
                    "artifact_ids": ["top_circadian_gene_fits"],
                    "note_ids": note_ids,
                },
                {
                    "result_id": "result_3",
                    "text": (
                        f"ARNTL/BMAL1 reached amplitude {float(arntl['Amplitude_24h']):.3f} log2 units with R² {float(arntl['R2_24h']):.3f} and phase {float(arntl['Phase_Hours']):.1f} h; "
                        f"CRY2 reached amplitude {float(cry2['Amplitude_24h']):.3f} with R² {float(cry2['R2_24h']):.3f}; "
                        f"PER1 reached amplitude {float(per1['Amplitude_24h']):.3f} with R² {float(per1['R2_24h']):.3f}."
                        if arntl and cry2 and per1
                        else "Core-clock genes were quantified from the recovered GEO expression matrix."
                    ),
                    "artifact_ids": ["core_clock_gene_fits"],
                    "note_ids": note_ids,
                },
                {
                    "result_id": "result_4",
                    "text": f"The strongest sample-level correlation was {strongest_pair[0]} versus {strongest_pair[1]} at r={strongest_pair[2]:.3f}, and the earliest-vs-latest comparison remained positively correlated at r={earliest_latest_correlation:.3f}.",
                    "artifact_ids": ["sample_correlation_matrix"],
                    "note_ids": note_ids,
                },
            ],
            "search": search,
            "attempt": attempt,
        }
        self._attach_data_access_receipt_artifacts(ledger)
        self._ensure_artifact_metadata(ledger)
        write_json_file(run_directory / "ledger.json", ledger)
        store = self._run_store(run_id)
        for artifact in ledger.get("artifacts", []):
            if not isinstance(artifact, dict):
                continue
            store.record_artifact(
                stage="2",
                artifact_id=str(artifact.get("artifact_id") or ""),
                artifact_type=str(artifact.get("kind") or "artifact"),
                path=str(artifact.get("path") or ""),
                description=str(artifact.get("description") or "").strip(),
            )
        store.record_artifact(
            stage="2",
            artifact_id="ledger",
            artifact_type="ledger",
            path="ledger.json",
            description="Deterministic GEO empirical analysis ledger.",
        )
        store.complete_stage(stage="2", agent="geo-empirical-analysis", artifacts=["ledger.json"])
        return ledger

    def _run_data_acquisition(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        acquisition_input: dict[str, Any],
    ) -> dict[str, Any]:
        strategy = acquisition_input.get("strategy") if isinstance(acquisition_input.get("strategy"), dict) else {}
        if str(strategy.get("family_id") or "").strip() == "geo_functional_genomics":
            report = self._run_geo_data_acquisition(
                run_id=run_id,
                request_payload=request_payload,
                acquisition_input=acquisition_input,
            )
            normalized = _normalize_data_access_report(
                raw_report=report,
                dataset=acquisition_input.get("dataset") if isinstance(acquisition_input.get("dataset"), dict) else {},
                request_payload=request_payload,
                config=self._config,
            )
            run_directory = self.run_directory(run_id)
            write_json_file(run_directory / "data_access_report.json", normalized)
            write_json_file(run_directory / "download_manifest.json", {"entries": normalized["download_manifest"]})
            (run_directory / "network_attempts.tsv").write_text(
                _network_attempts_tsv(normalized["download_manifest"]),
                encoding="utf-8",
            )
            store = self._run_store(run_id)
            store.record_artifact(
                stage="2",
                artifact_id="data_access_report",
                artifact_type="log",
                path="data_access_report.json",
                description="Structured acquisition summary with substrate classification.",
            )
            store.record_artifact(
                stage="2",
                artifact_id="download_manifest",
                artifact_type="log",
                path="download_manifest.json",
                description="Structured manifest of acquisition attempts and saved files.",
            )
            store.record_artifact(
                stage="2",
                artifact_id="network_attempts",
                artifact_type="log",
                path="network_attempts.tsv",
                description="TSV receipt of network attempts during acquisition.",
            )
            store.complete_stage(
                stage="2",
                agent="data-acquisition",
                artifacts=["data_access_report.json", "download_manifest.json", "network_attempts.tsv"],
            )
            return normalized

        instructions = """
You are Sidekick's data-acquisition gate for empirical runs.
Acquire real numeric or semi-numeric substrate before any empirical analysis can proceed.
Return strict JSON only:
{
  "status": "ready or blocked",
  "summary": "string",
  "blocking_reason": "string",
  "substrate_class": "numeric or semi_numeric or metadata_only or none",
  "empirical_ready": true,
  "download_manifest": [
    {
      "url": "string",
      "source_family": "string",
      "retrieval_target": "string",
      "method": "string",
      "status": "success or http_error or timeout or dns_error or tls_error or blocked or metadata_only",
      "http_status": 200,
      "error_kind": "string",
      "error_message": "string",
      "latency_ms": 123,
      "bytes_downloaded": 123,
      "saved_path": "downloads/file.ext",
      "saved_file_kind": "matrix or table or archive or html or json or txt",
      "content_type": "string",
      "classification": "numeric or semi_numeric or metadata_only or failed",
      "usable_for_analysis": true,
      "notes": "string"
    }
  ],
  "usable_saved_files": [
    {
      "path": "downloads/file.ext",
      "bytes_downloaded": 123,
      "classification": "numeric",
      "retrieval_target": "series_matrix"
    }
  ],
  "metadata_only_saved_files": [
    {
      "path": "downloads/file.ext",
      "bytes_downloaded": 123,
      "classification": "metadata_only",
      "retrieval_target": "sample_html"
    }
  ],
  "host_failures": [
    {
      "host": "ncbi.nlm.nih.gov",
      "attempts": 3,
      "failures": 3,
      "error_kinds": ["timeout"]
    }
  ],
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
  ]
}
Rules:
- Use the explicit budgets and retrieval order from the input.
- Do not treat HTML landing pages, sample pages, or platform pages as numeric substrate.
- For GEO, try series matrix or processed tables first; raw archives come later.
- Save the smallest credible numeric or semi-numeric file you can obtain before spending budget on raw archives.
- If you only recover metadata, set substrate_class=metadata_only and empirical_ready=false.
- If no usable numeric or semi-numeric file is saved locally, block the empirical run.
- Record every attempted URL in download_manifest, including failures.
"""
        report = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="data-acquisition",
            model=self._config.openai_workspace_model,
            instructions=instructions,
            input_text=json.dumps(acquisition_input, sort_keys=True),
            use_code_interpreter=True,
            use_web_search=False,
            timeout_seconds=min(self._config.data_access_max_seconds, self._config.backend_max_job_runtime_seconds),
            reasoning_effort="medium",
        )
        report.pop("_response", None)
        normalized = _normalize_data_access_report(
            raw_report=report,
            dataset=acquisition_input.get("dataset") if isinstance(acquisition_input.get("dataset"), dict) else {},
            request_payload=request_payload,
            config=self._config,
        )
        run_directory = self.run_directory(run_id)
        write_json_file(run_directory / "data_access_report.json", normalized)
        write_json_file(run_directory / "download_manifest.json", {"entries": normalized["download_manifest"]})
        (run_directory / "network_attempts.tsv").write_text(
            _network_attempts_tsv(normalized["download_manifest"]),
            encoding="utf-8",
        )
        store = self._run_store(run_id)
        store.record_artifact(
            stage="2",
            artifact_id="data_access_report",
            artifact_type="log",
            path="data_access_report.json",
            description="Structured acquisition summary with substrate classification.",
        )
        store.record_artifact(
            stage="2",
            artifact_id="download_manifest",
            artifact_type="log",
            path="download_manifest.json",
            description="Structured manifest of acquisition attempts and saved files.",
        )
        store.record_artifact(
            stage="2",
            artifact_id="network_attempts",
            artifact_type="log",
            path="network_attempts.tsv",
            description="TSV receipt of network attempts during acquisition.",
        )
        store.complete_stage(
            stage="2",
            agent="data-acquisition",
            artifacts=["data_access_report.json", "download_manifest.json", "network_attempts.tsv"],
        )
        return normalized

    def _build_acquisition_failure_ledger(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        search: dict[str, Any],
        data_access: dict[str, Any],
        attempt: int,
    ) -> dict[str, Any]:
        summary = str(data_access.get("summary") or "").strip()
        blocking_reason = str(data_access.get("blocking_reason") or "").strip()
        experiment_summary = (
            summary
            or blocking_reason
            or "The empirical run could not acquire numeric or semi-numeric substrate within the configured acquisition budgets."
        )
        findings = [
            f"Empirical acquisition stopped at substrate_class={str(data_access.get('substrate_class') or 'none')}.",
        ]
        if blocking_reason:
            findings.append(blocking_reason)
        if data_access.get("metadata_only_saved_files"):
            findings.append("Only metadata-level files or pages were recovered; no usable numeric substrate was saved.")
        limitations = [
            "No empirical analysis was run because the acquisition gate did not materialize usable numeric or semi-numeric substrate.",
            "See data_access_report.json, download_manifest.json, and network_attempts.tsv for acquisition details.",
        ]
        if blocking_reason:
            limitations.append(blocking_reason)
        ledger = {
            "title": str(request_payload.get("title") or "Research memo"),
            "research_question": str(search.get("research_question") or request_payload.get("theme") or request_payload.get("title") or "").strip(),
            "dataset": search.get("dataset") or {},
            "data_access": data_access,
            "dataset_profile": {},
            "execution_plan": {},
            "execution_handoff": {},
            "experiment_summary": experiment_summary,
            "experiments": ["Data acquisition gate executed before empirical analysis."],
            "findings": findings,
            "limitations": limitations,
            "code_summary": "",
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(data_access.get("sources") or [])],
            "artifacts": _data_access_receipt_artifacts(),
            "figure_summaries": [],
            "results": [
                {
                    "result_id": "result_1",
                    "text": experiment_summary,
                    "artifact_ids": ["data_access_report", "download_manifest", "network_attempts"],
                    "note_ids": [str(note.get("id") or "").strip() for note in request_payload.get("notes") or [] if str(note.get("id") or "").strip()],
                }
            ],
            "search": search,
            "attempt": attempt,
        }
        self._attach_data_access_receipt_artifacts(ledger)
        write_json_file(self.run_directory(run_id) / "ledger.json", ledger)
        return ledger

    def _run_dataset_profiler(self, *, run_id: str, profiler_input: dict[str, Any]) -> dict[str, Any]:
        instructions = """
You are Sidekick's dataset profiler.
Inspect the dataset and return a bounded handoff for later agents.
Download the dataset or the smallest relevant subset, inspect the available files/tables/columns, and report what is actually analyzable.
Return a structured object as JSON. If needed, a Python dict literal is acceptable, but do not return prose outside the object.
{
  "analyzable": true,
  "blocking_reason": "string",
  "profile_summary": "string",
  "retrieval_summary": "string",
  "dataset": {
    "label": "string",
    "landing_page_url": "string",
    "download_url": "string",
    "accession_id": "string",
    "notes": "string"
  },
  "available_assets": ["string"],
  "constraints": ["string"],
  "suggested_analysis_targets": ["string"],
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
  ]
}
Rules:
- Do not design experiments yet.
- Treat the provided data_access report as the source of truth for whether numeric substrate was actually acquired.
- Focus only on inspection of the acquired substrate and what is analyzable.
- Use the dataset from the task payload. Do not swap substrates.
- If only metadata was acquired, set analyzable=false and explain why.
"""
        profile = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="dataset-profiler",
            model=self._config.openai_workspace_model,
            instructions=instructions,
            input_text=json.dumps(profiler_input, sort_keys=True),
            use_code_interpreter=True,
            use_web_search=True,
            timeout_seconds=min(1800, self._config.backend_max_job_runtime_seconds),
            reasoning_effort="medium",
        )
        profile.pop("_response", None)
        normalized = {
            "analyzable": bool(profile.get("analyzable", True)),
            "blocking_reason": str(profile.get("blocking_reason") or "").strip(),
            "profile_summary": str(profile.get("profile_summary") or "").strip(),
            "retrieval_summary": str(profile.get("retrieval_summary") or "").strip(),
            "dataset": {
                "label": str(((profile.get("dataset") or {}) if isinstance(profile.get("dataset"), dict) else {}).get("label") or (profiler_input.get("dataset") or {}).get("label") or "").strip(),
                "landing_page_url": str(((profile.get("dataset") or {}) if isinstance(profile.get("dataset"), dict) else {}).get("landing_page_url") or (profiler_input.get("dataset") or {}).get("landing_page_url") or "").strip(),
                "download_url": str(((profile.get("dataset") or {}) if isinstance(profile.get("dataset"), dict) else {}).get("download_url") or (profiler_input.get("dataset") or {}).get("download_url") or "").strip(),
                "accession_id": str(((profile.get("dataset") or {}) if isinstance(profile.get("dataset"), dict) else {}).get("accession_id") or (profiler_input.get("dataset") or {}).get("accession_id") or "").strip(),
                "notes": str(((profile.get("dataset") or {}) if isinstance(profile.get("dataset"), dict) else {}).get("notes") or (profiler_input.get("dataset") or {}).get("notes") or "").strip(),
            },
            "available_assets": normalize_text_list(profile.get("available_assets")),
            "constraints": normalize_text_list(profile.get("constraints")),
            "suggested_analysis_targets": normalize_text_list(profile.get("suggested_analysis_targets")),
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(profile.get("sources") or [])],
        }
        path = "stage2_profile.json"
        write_json_file(self.run_directory(run_id) / path, normalized)
        self._run_store(run_id).record_artifact(
            stage="2",
            artifact_id="stage2_profile",
            artifact_type="profile",
            path=path,
            description="Dataset inspection handoff for Stage 2.",
        )
        self._run_store(run_id).complete_stage(stage="2", agent="dataset-profiler", artifacts=[path])
        return normalized

    def _run_experiment_planner(self, *, run_id: str, planner_input: dict[str, Any]) -> dict[str, Any]:
        instructions = """
You are Sidekick's experiment planner.
Given the research question, dataset profile, related work, and any validation feedback, propose a small execution plan for the analyst.
Return a structured object as JSON. If needed, a Python dict literal is acceptable, but do not return prose outside the object.
{
  "plan_summary": "string",
  "execution_focus": "string",
  "selected_experiments": [
    {
      "experiment_id": "exp_1",
      "title": "string",
      "rationale": "string",
      "method_summary": "string",
      "expected_artifacts": ["string"],
      "success_criteria": "string",
      "fallback_if_blocked": "string"
    }
  ],
  "deferred_experiments": ["string"]
}
Rules:
- Propose at most 2 experiments to execute now.
- The plan must stay anchored to the available dataset profile.
- The plan must stay within the already acquired substrate and must not assume unavailable numeric files exist.
- Keep this generic and dataset-specific; do not use canned paper-type recipes.
- If validation feedback exists, directly address it.
"""
        plan = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="experiment-planner",
            model=self._config.openai_workspace_model,
            instructions=instructions,
            input_text=json.dumps(planner_input, sort_keys=True),
            use_code_interpreter=False,
            use_web_search=True,
            timeout_seconds=min(900, self._config.backend_max_job_runtime_seconds),
            reasoning_effort="medium",
        )
        plan.pop("_response", None)
        selected_experiments = []
        for index, entry in enumerate(plan.get("selected_experiments") or []):
            if not isinstance(entry, dict):
                continue
            selected_experiments.append(
                {
                    "experiment_id": str(entry.get("experiment_id") or f"exp_{index + 1}").strip() or f"exp_{index + 1}",
                    "title": str(entry.get("title") or f"Experiment {index + 1}").strip() or f"Experiment {index + 1}",
                    "rationale": str(entry.get("rationale") or "").strip(),
                    "method_summary": str(entry.get("method_summary") or "").strip(),
                    "expected_artifacts": normalize_text_list(entry.get("expected_artifacts")),
                    "success_criteria": str(entry.get("success_criteria") or "").strip(),
                    "fallback_if_blocked": str(entry.get("fallback_if_blocked") or "").strip(),
                }
            )
        normalized = {
            "plan_summary": str(plan.get("plan_summary") or "").strip(),
            "execution_focus": str(plan.get("execution_focus") or "").strip(),
            "selected_experiments": selected_experiments,
            "deferred_experiments": normalize_text_list(plan.get("deferred_experiments")),
        }
        path = "stage2_plan.json"
        write_json_file(self.run_directory(run_id) / path, normalized)
        self._run_store(run_id).record_artifact(
            stage="2",
            artifact_id="stage2_plan",
            artifact_type="plan",
            path=path,
            description="Experiment plan handoff for Stage 2.",
        )
        self._run_store(run_id).complete_stage(stage="2", agent="experiment-planner", artifacts=[path])
        return normalized

    def _run_data_analyst_execution(self, *, run_id: str, analyst_input: dict[str, Any]) -> dict[str, Any]:
        instructions = """
You are Sidekick's data analyst.
Use the dataset profile and execution plan to run the most relevant experiments in the compute sandbox and save reproducible artifacts.
Return a structured object as JSON. If needed, a Python dict literal is acceptable, but do not return prose outside the object.
{
  "research_question": "string",
  "execution_summary": "string",
  "completed_experiments": ["string"],
  "failed_experiments": ["string"],
  "findings": ["string"],
  "limitations": ["string"],
  "saved_artifact_paths": ["analysis/run_analysis.py"],
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
  "figure_summaries": [
    {
      "path": "figures/figure_1.png",
      "title": "Figure 1",
      "summary_markdown": "plain markdown description of what the figure shows"
    }
  ],
  "packaging_notes": "string"
}
Rules:
- Use the acquisition report as a hard constraint. Do not pretend metadata pages are numeric substrate.
- Re-download the dataset or subset only within the acquisition strategy and budgets when needed; do not assume prior compute state exists.
- Execute the selected experiments first.
- Save executable code files, generated figures, and key tables as real files.
- Save a concise narrative handoff file named analysis_summary.md in the workspace.
- Figure summaries are mandatory for any figure you generate.
- If a selected experiment fails, say so honestly and pivot once on the same dataset.
- Do not swap in a different substrate.
- Do not attempt to return a full publication ledger here; return only the execution handoff.
"""
        result = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="data-analyst",
            model=self._config.openai_workspace_model,
            instructions=instructions,
            input_text=json.dumps(analyst_input, sort_keys=True),
            use_code_interpreter=True,
            use_web_search=False,
            timeout_seconds=self._config.backend_max_job_runtime_seconds,
            reasoning_effort="medium",
        )
        response = result.get("_response")
        normalized = {
            "research_question": str(result.get("research_question") or analyst_input.get("research_question") or "").strip(),
            "execution_summary": str(result.get("execution_summary") or "").strip(),
            "completed_experiments": normalize_text_list(result.get("completed_experiments")),
            "failed_experiments": normalize_text_list(result.get("failed_experiments")),
            "findings": normalize_text_list(result.get("findings")),
            "limitations": normalize_text_list(result.get("limitations")),
            "saved_artifact_paths": normalize_text_list(result.get("saved_artifact_paths")),
            "sources": [_normalize_source(entry, index) for index, entry in enumerate(result.get("sources") or [])],
            "figure_summaries": [
                {
                    "artifact_id": str(entry.get("artifact_id") or entry.get("path") or f"artifact_{index + 1}").strip() or f"artifact_{index + 1}",
                    "path": sanitize_relative_path(str(entry.get("path") or "").strip(), fallback=f"artifacts/figure_{index + 1}.png"),
                    "title": str(entry.get("title") or f"Figure {index + 1}").strip() or f"Figure {index + 1}",
                    "summary_markdown": str(entry.get("summary_markdown") or entry.get("summary") or "").strip(),
                }
                for index, entry in enumerate(result.get("figure_summaries") or [])
                if isinstance(entry, dict)
            ],
            "packaging_notes": str(result.get("packaging_notes") or "").strip(),
        }
        path = "stage2_execution.json"
        write_json_file(self.run_directory(run_id) / path, normalized)
        self._run_store(run_id).record_artifact(
            stage="2",
            artifact_id="stage2_execution",
            artifact_type="handoff",
            path=path,
            description="Execution handoff produced by the Stage 2 analyst.",
        )
        self._run_store(run_id).complete_stage(stage="2", agent="data-analyst", artifacts=[path])
        if response is not None:
            normalized["_response"] = response
        return normalized

    def _run_research_packager(self, *, run_id: str, packager_input: dict[str, Any]) -> dict[str, Any]:
        instructions = """
You are Sidekick's research packager.
Convert the execution handoff and workspace file inventory into the structured ledger used by the writer.
Return a structured object as JSON. If needed, a Python dict literal is acceptable, but do not return prose outside the object.
{
  "title": "string",
  "research_question": "string",
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
  "results": [
    {
      "result_id": "result_1",
      "text": "string",
      "artifact_ids": ["artifact_1"],
      "note_ids": ["note_1"]
    }
  ],
  "code_summary": "string"
}
Rules:
- Use the provided workspace_files inventory as the source of truth for artifact paths.
- Do not invent files that are not present in workspace_files.
- Keep the ledger anchored to the provided dataset and execution handoff.
- Preserve the acquisition receipts and do not describe metadata-only artifacts as empirical numeric substrate.
- If no explicit artifact mapping is obvious, attach the most relevant saved files to the findings conservatively.
"""
        packaged = self._run_model_json(
            run_id=run_id,
            stage="2",
            agent="research-packager",
            model=self._config.openai_writer_model,
            instructions=instructions,
            input_text=json.dumps(packager_input, sort_keys=True),
            use_code_interpreter=False,
            use_web_search=False,
            timeout_seconds=600,
            reasoning_effort="low",
        )
        packaged.pop("_response", None)
        return packaged

    def _workspace_file_inventory(self, *, container_ids: list[str]) -> list[dict[str, Any]]:
        inventory: list[dict[str, Any]] = []
        seen: set[tuple[str, str]] = set()
        for container_id in container_ids:
            for container_file in self._openai_client.list_container_files(container_id=container_id):
                key = (container_file.container_id, container_file.file_id)
                if key in seen:
                    continue
                seen.add(key)
                normalized_path = sanitize_relative_path(
                    container_file.path or container_file.filename or f"artifacts/{container_file.file_id}",
                    fallback=f"artifacts/{container_file.file_id}",
                )
                inventory.append(
                    {
                        "container_id": container_file.container_id,
                        "file_id": container_file.file_id,
                        "path": normalized_path,
                        "filename": Path(normalized_path).name,
                        "mime_type": container_file.mime_type or guess_mime_type(normalized_path),
                        "kind": classify_artifact_kind(normalized_path),
                    }
                )
        return inventory

    def _synthesize_artifacts_from_workspace(
        self,
        *,
        workspace_files: list[dict[str, Any]],
        saved_artifact_paths: list[str],
        source_ids: list[str],
    ) -> list[dict[str, Any]]:
        prioritized_paths = {sanitize_relative_path(path, fallback=path) for path in saved_artifact_paths if str(path).strip()}
        selected_files = [
            entry for entry in workspace_files
            if prioritized_paths and sanitize_relative_path(str(entry.get("path") or ""), fallback="") in prioritized_paths
        ]
        if not selected_files:
            selected_files = workspace_files
        artifacts: list[dict[str, Any]] = []
        for index, entry in enumerate(selected_files):
            path = sanitize_relative_path(str(entry.get("path") or ""), fallback=f"artifacts/generated_{index + 1}")
            artifacts.append(
                {
                    "artifact_id": f"artifact_{index + 1}",
                    "path": path,
                    "kind": str(entry.get("kind") or classify_artifact_kind(path)).strip() or "artifact",
                    "mime_type": str(entry.get("mime_type") or guess_mime_type(path)).strip(),
                    "description": f"Workspace artifact saved at {path}.",
                    "source_ids": list(source_ids),
                }
            )
        return artifacts

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

    def _attach_data_access_receipt_artifacts(self, ledger: dict[str, Any]) -> None:
        data_access = ledger.get("data_access") if isinstance(ledger.get("data_access"), dict) else {}
        if not data_access:
            return
        source_ids = [entry.get("source_id") for entry in data_access.get("sources") or [] if isinstance(entry, dict) and entry.get("source_id")]
        existing = {
            str(artifact.get("artifact_id") or "").strip()
            for artifact in ledger.get("artifacts", [])
            if isinstance(artifact, dict)
        }
        for artifact in _data_access_receipt_artifacts():
            artifact_id = str(artifact.get("artifact_id") or "").strip()
            if artifact_id in existing:
                continue
            merged = dict(artifact)
            merged["source_ids"] = source_ids
            ledger.setdefault("artifacts", []).append(merged)
            existing.add(artifact_id)
        artifact_files = ledger.setdefault("artifact_files", [])
        existing_paths = {
            str(entry.get("path") or "").strip()
            for entry in artifact_files
            if isinstance(entry, dict)
        }
        for artifact in _data_access_receipt_artifacts():
            path = str(artifact.get("path") or "").strip()
            if not path or path in existing_paths:
                continue
            artifact_files.append(
                {
                    "artifact_id": str(artifact.get("artifact_id") or "").strip(),
                    "path": path,
                    "mime_type": str(artifact.get("mime_type") or "").strip(),
                    "sha256": "",
                }
            )
            existing_paths.add(path)

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
        data_access = ledger.get("data_access") if isinstance(ledger.get("data_access"), dict) else {}
        paper_mode = str(resolution.get("paper_mode") or "").strip().lower()
        empirical_ready = bool(data_access.get("empirical_ready"))
        substrate_class = str(data_access.get("substrate_class") or "").strip().lower()
        has_real_substrate = substrate_class in {"numeric", "semi_numeric"} and empirical_ready
        has_data_access_receipts = all((run_directory / path).exists() for path in [
            "data_access_report.json",
            "download_manifest.json",
            "network_attempts.tsv",
        ])
        quantitative_result_pattern = re.compile(
            r"(\b\d+(?:\.\d+)?\b|\bp\s*[<=>]\s*\d|\bcorrelation\b|\bauc\b|\blog2\b|\bfold\b|\bamplitude\b|\bphase\b|\bpercent\b|\brank\b)",
            re.IGNORECASE,
        )
        has_quantitative_result = any(
            quantitative_result_pattern.search(str(result.get("text") or ""))
            for result in approved_results
        )
        if not has_quantitative_result and has_real_substrate:
            has_quantitative_result = any(
                str(valid_artifacts.get(artifact_id, {}).get("kind") or "").strip().lower() in {"table", "figure"}
                or str(valid_artifacts.get(artifact_id, {}).get("mime_type") or "").strip().lower() in {"text/csv", "text/tab-separated-values"}
                for result in approved_results
                for artifact_id in result.get("artifact_ids", [])
            )
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
        if paper_mode == "empirical_dataset":
            paper_checks["has_real_substrate"] = has_real_substrate
            paper_checks["has_data_access_receipts"] = has_data_access_receipts
            paper_checks["has_quantitative_result"] = has_quantitative_result
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
        if paper_mode == "empirical_dataset" and not paper_checks["has_real_substrate"]:
            memo_reasons.append(
                "empirical paper mode requires real numeric or semi-numeric substrate; metadata-only retrieval cannot clear the paper gate"
            )
        if paper_mode == "empirical_dataset" and not paper_checks["has_data_access_receipts"]:
            memo_reasons.append("empirical paper mode requires data_access_report.json, download_manifest.json, and network_attempts.tsv")
        if paper_mode == "empirical_dataset" and not paper_checks["has_quantitative_result"]:
            memo_reasons.append("empirical paper mode requires at least one artifact-backed quantitative result produced in the run")
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
            "data_access": {
                "substrate_class": substrate_class or "none",
                "empirical_ready": empirical_ready,
                "has_receipts": has_data_access_receipts,
            },
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
        manuscript_kind = "memo" if validation_kind == "memo" else "paper"
        if validation_status not in {"pass", "paper", "memo"} and validation_kind not in {"paper", "memo"}:
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
- Use the research question, experiments, findings, figure summaries, and related work to write the requested manuscript.
- The figure summaries are the source of truth for what each figure shows.
- Use internet access to ground related work and references, but do not invent experiments or results beyond the validated analysis.
- If the manuscript kind is memo, state clearly that the run did not clear the empirical paper gate and explain the failed acquisition or validation condition.
- Keep the tone scientific and concrete.
"""
        writer_input = {
            "manuscript_kind": manuscript_kind,
            "title": request_payload.get("title"),
            "theme": request_payload.get("theme"),
            "research_question": ledger.get("research_question"),
            "dataset": ledger.get("dataset"),
            "data_access": ledger.get("data_access") or {},
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
            manuscript_kind=manuscript_kind,
        )
        tex_name = "memo.tex" if manuscript_kind == "memo" else "paper.tex"
        pdf_name = "memo.pdf" if manuscript_kind == "memo" else "paper.pdf"
        store.complete_stage(stage="3", agent="paper-writer", artifacts=["sections.json", tex_name, pdf_name])
        return bundle

    def render_bundle(
        self,
        *,
        run_id: str,
        request_payload: dict[str, Any],
        ledger: dict[str, Any],
        validation: dict[str, Any],
        sections: dict[str, Any],
        manuscript_kind: str,
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
            manuscript_kind=manuscript_kind,
            reference_catalog=validation.get("reference_catalog") or [],
        )
        tex_filename = "memo.tex" if manuscript_kind == "memo" else "paper.tex"
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
        markdown_preview = results_to_markdown(written, manuscript_kind=manuscript_kind)
        bundle = {
            "title": str(written.get("title") or request_payload.get("title") or "Research paper"),
            "manuscript_kind": manuscript_kind,
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
            "provenance": {
                "research_question": str(ledger.get("research_question") or "").strip(),
                "dataset_accession_id": str((ledger.get("dataset") or {}).get("accession_id") or "").strip(),
                "substrate_class": str(((ledger.get("data_access") or {}) if isinstance(ledger.get("data_access"), dict) else {}).get("substrate_class") or "").strip(),
            },
        }
        write_json_file(run_directory / "bundle.json", {"bundle": bundle, "publication": None})
        self._run_store(run_id).record_artifact(stage="3", artifact_id="manuscript-tex", artifact_type="latex", path=tex_filename, description="Compiled manuscript source.")
        self._run_store(run_id).record_artifact(
            stage="3",
            artifact_id="manuscript-pdf",
            artifact_type="pdf",
            path=str(compile_result.get("pdf_path") or ("memo.pdf" if manuscript_kind == "memo" else "paper.pdf")),
            description="Compiled manuscript PDF.",
        )
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
        last_heartbeat_ms = 0

        def _handle_event(event: dict[str, Any]) -> None:
            nonlocal seen_response_id, seen_status, last_heartbeat_ms
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
            elapsed_ms = store.elapsed_ms()
            if response_id and status_value in {"queued", "in_progress"} and elapsed_ms - last_heartbeat_ms >= 30000:
                should_emit = True
                last_heartbeat_ms = elapsed_ms
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
