from __future__ import annotations

import json
import os
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = {
    "log_level": "info",
    "log_retention": "30d",
    "stream_buffer_size": 1000,
}

LOG_LEVEL_ORDER = {
    "debug": 10,
    "info": 20,
    "warn": 30,
    "error": 40,
}

STAGE_LOG_FILES = {
    "1": "stage-1.log",
    "2": "stage-2.log",
    "2.5": "stage-2.5.log",
    "3": "stage-3.log",
    "4": "stage-4.log",
}

DEFAULT_RUN_ROOT = Path.home() / ".sidekick" / "runs"
DEFAULT_CONFIG_PATH = Path.home() / ".sidekick" / "config.json"


def utc_now() -> datetime:
    return datetime.now(tz=UTC)


def iso_now() -> str:
    return utc_now().isoformat()


def ensure_directory(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{time.time_ns()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def read_json(path: Path, default: dict[str, Any] | None = None) -> dict[str, Any]:
    if not path.exists():
        return {} if default is None else dict(default)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {} if default is None else dict(default)


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def load_sidekick_config(config_path: Path = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    payload = read_json(config_path, default=DEFAULT_CONFIG)
    normalized = dict(DEFAULT_CONFIG)
    normalized.update({key: value for key, value in payload.items() if value is not None})
    return normalized


def save_sidekick_config(payload: dict[str, Any], config_path: Path = DEFAULT_CONFIG_PATH) -> None:
    normalized = dict(DEFAULT_CONFIG)
    normalized.update({key: value for key, value in payload.items() if value is not None})
    atomic_write_json(config_path, normalized)


def iter_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                rows.append(payload)
    return rows


@dataclass(frozen=True)
class CallHandle:
    call_id: str
    stage: str
    agent: str


class SidekickRunStore:
    def __init__(self, *, run_id: str, root: Path | None = None):
        self.run_id = run_id
        self.root = ensure_directory((root or DEFAULT_RUN_ROOT) / run_id)
        self.logs_dir = ensure_directory(self.root / "logs")
        self.calls_dir = ensure_directory(self.root / "calls")
        self._lock = threading.RLock()
        if not self.state_path.exists():
            self.write_state(
                {
                    "run_id": run_id,
                    "status": "queued",
                    "current_stage": None,
                    "current_agent": None,
                    "started_at": None,
                    "updated_at": iso_now(),
                    "completed_at": None,
                    "exit_code": None,
                    "note": "",
                    "title": "",
                    "log_level": load_sidekick_config().get("log_level", "info"),
                    "cancel_requested": False,
                }
            )

    @property
    def state_path(self) -> Path:
        return self.root / "state.json"

    @property
    def input_path(self) -> Path:
        return self.root / "input.json"

    @property
    def events_path(self) -> Path:
        return self.root / "events.jsonl"

    @property
    def artifacts_path(self) -> Path:
        return self.root / "artifacts.json"

    @property
    def retries_path(self) -> Path:
        return self.root / "retries.json"

    def read_state(self) -> dict[str, Any]:
        with self._lock:
            return read_json(self.state_path)

    def write_state(self, payload: dict[str, Any]) -> None:
        with self._lock:
            atomic_write_json(self.state_path, payload)

    def update_state(self, **updates: Any) -> dict[str, Any]:
        with self._lock:
            payload = self.read_state()
            payload.update(updates)
            payload["updated_at"] = iso_now()
            atomic_write_json(self.state_path, payload)
            return payload

    def current_log_level(self) -> str:
        payload = self.read_state()
        value = str(payload.get("log_level") or "info").strip().lower()
        return value if value in LOG_LEVEL_ORDER else "info"

    def should_log(self, level: str) -> bool:
        current = LOG_LEVEL_ORDER.get(self.current_log_level(), 20)
        requested = LOG_LEVEL_ORDER.get(level, 20)
        return requested >= current

    def request_cancel(self) -> None:
        self.update_state(cancel_requested=True)

    def cancel_requested(self) -> bool:
        return bool(self.read_state().get("cancel_requested"))

    def begin_run(self, *, note: str, title: str) -> None:
        self.update_state(
            status="running",
            note=note,
            title=title,
            started_at=iso_now(),
            completed_at=None,
            exit_code=None,
            cancel_requested=False,
        )
        self.emit_event("PIPELINE_STARTED", note=note, title=title)

    def complete_run(self, *, exit_code: int) -> None:
        self.update_state(status="completed", completed_at=iso_now(), exit_code=exit_code, current_agent=None)
        self.emit_event("PIPELINE_COMPLETED", total_duration_ms=self.elapsed_ms())

    def fail_run(self, *, stage: str, reason: str, exit_code: int) -> None:
        self.update_state(
            status="failed",
            current_stage=stage,
            completed_at=iso_now(),
            exit_code=exit_code,
            current_agent=None,
        )
        self.emit_event("PIPELINE_FAILED", stage_failed_at=stage, reason=reason)
        self.log(stage=stage, agent="pipeline", level="error", message=reason)

    def mark_cancelled(self) -> None:
        self.update_state(status="cancelled", completed_at=iso_now(), exit_code=10, current_agent=None)
        self.emit_event("PIPELINE_FAILED", stage_failed_at=self.read_state().get("current_stage"), reason="Cancelled")

    def elapsed_ms(self) -> int:
        payload = self.read_state()
        started_at = str(payload.get("started_at") or "").strip()
        if not started_at:
            return 0
        try:
            started = datetime.fromisoformat(started_at)
        except ValueError:
            return 0
        return int((utc_now() - started).total_seconds() * 1000)

    def set_stage(self, *, stage: str, agent: str, model: str | None = None) -> None:
        self.update_state(current_stage=stage, current_agent=agent)
        metadata = {"model": model} if model else {}
        self.emit_event("STAGE_STARTED", stage=stage, agent=agent, model=model)
        self.log(stage=stage, agent=agent, level="info", message=f"Stage {stage} started.", metadata=metadata)

    def complete_stage(self, *, stage: str, agent: str, artifacts: list[str] | None = None, duration_ms: int | None = None) -> None:
        self.emit_event(
            "STAGE_COMPLETED",
            stage=stage,
            agent=agent,
            duration_ms=duration_ms,
            artifacts=artifacts or [],
        )
        self.log(
            stage=stage,
            agent=agent,
            level="info",
            message=f"Stage {stage} completed.",
            metadata={"duration_ms": duration_ms, "artifacts": artifacts or []},
        )

    def fail_stage(self, *, stage: str, agent: str, reason: str, retries_remaining: int | None = None) -> None:
        self.emit_event(
            "STAGE_FAILED",
            stage=stage,
            agent=agent,
            reason=reason,
            retries_remaining=retries_remaining,
        )
        self.log(
            stage=stage,
            agent=agent,
            level="warn" if retries_remaining else "error",
            message=reason,
            metadata={"retries_remaining": retries_remaining},
        )

    def emit_event(self, event_type: str, **metadata: Any) -> None:
        payload = {
            "timestamp": iso_now(),
            "run_id": self.run_id,
            "event": event_type,
        }
        payload.update({key: value for key, value in metadata.items() if value is not None})
        append_jsonl(self.events_path, payload)

    def log(
        self,
        *,
        stage: str,
        agent: str,
        level: str,
        message: str,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        payload = {
            "timestamp": iso_now(),
            "run_id": self.run_id,
            "stage": stage,
            "agent": agent,
            "level": level,
            "message": message,
            "metadata": metadata or {},
        }
        append_jsonl(self.logs_dir / "combined.log", payload)
        append_jsonl(self.logs_dir / STAGE_LOG_FILES.get(stage, "combined.log"), payload)

    def record_artifact(
        self,
        *,
        stage: str,
        artifact_id: str,
        artifact_type: str,
        path: str,
        description: str = "",
        metadata: dict[str, Any] | None = None,
    ) -> None:
        with self._lock:
            payload = read_json(self.artifacts_path, default={"artifacts": []})
            artifacts = payload.setdefault("artifacts", [])
            artifacts = [artifact for artifact in artifacts if artifact.get("artifact_id") != artifact_id]
            artifacts.append(
                {
                    "artifact_id": artifact_id,
                    "stage": stage,
                    "artifact_type": artifact_type,
                    "path": path,
                    "description": description,
                    "metadata": metadata or {},
                    "timestamp": iso_now(),
                }
            )
            payload["artifacts"] = artifacts
            atomic_write_json(self.artifacts_path, payload)
        self.emit_event("ARTIFACT_PRODUCED", stage=stage, artifact_type=artifact_type, artifact_path=path)

    def record_retry(
        self,
        *,
        attempt: int,
        status: str,
        feedback_message: str,
        experiment_summary: str,
        validation: dict[str, Any],
    ) -> None:
        with self._lock:
            payload = read_json(self.retries_path, default={"attempts": []})
            attempts = payload.setdefault("attempts", [])
            attempts = [entry for entry in attempts if int(entry.get("attempt") or 0) != attempt]
            attempts.append(
                {
                    "attempt": attempt,
                    "status": status,
                    "feedback_message": feedback_message,
                    "experiment_summary": experiment_summary,
                    "validation": validation,
                    "timestamp": iso_now(),
                }
            )
            attempts.sort(key=lambda entry: int(entry.get("attempt") or 0))
            payload["attempts"] = attempts
            atomic_write_json(self.retries_path, payload)

    def start_call(
        self,
        *,
        stage: str,
        agent: str,
        model: str,
        prompt: str,
        parameters: dict[str, Any],
    ) -> CallHandle:
        call_id = f"call_{time.time_ns()}_{os.getpid()}"
        payload = {
            "call_id": call_id,
            "run_id": self.run_id,
            "stage": stage,
            "agent": agent,
            "model": model,
            "status": "running",
            "started_at": iso_now(),
            "completed_at": None,
            "latency_ms": None,
            "prompt": prompt,
            "response": "",
            "parameters": parameters,
            "usage": {},
            "raw_events": [],
        }
        atomic_write_json(self.calls_dir / f"{call_id}.json", payload)
        append_jsonl(self.calls_dir / f"{call_id}.stream.jsonl", {"event": "call_started", "timestamp": iso_now()})
        self.emit_event("LLM_CALL_STARTED", stage=stage, call_id=call_id, model=model)
        return CallHandle(call_id=call_id, stage=stage, agent=agent)

    def append_call_delta(self, handle: CallHandle, delta_text: str, *, raw_event: dict[str, Any] | None = None) -> None:
        if not delta_text and raw_event is None:
            return
        with self._lock:
            path = self.calls_dir / f"{handle.call_id}.json"
            payload = read_json(path)
            payload["response"] = str(payload.get("response") or "") + delta_text
            if raw_event:
                raw_events = payload.setdefault("raw_events", [])
                raw_events.append(raw_event)
            atomic_write_json(path, payload)
        if delta_text:
            append_jsonl(
                self.calls_dir / f"{handle.call_id}.stream.jsonl",
                {"event": "delta", "timestamp": iso_now(), "delta": delta_text},
            )
            self.emit_event(
                "LLM_CALL_STREAMING",
                stage=handle.stage,
                call_id=handle.call_id,
                delta_token=delta_text,
            )

    def complete_call(
        self,
        handle: CallHandle,
        *,
        response_text: str,
        usage: dict[str, Any],
        latency_ms: int,
        raw_payload: dict[str, Any],
    ) -> None:
        with self._lock:
            path = self.calls_dir / f"{handle.call_id}.json"
            payload = read_json(path)
            payload.update(
                {
                    "status": "completed",
                    "completed_at": iso_now(),
                    "latency_ms": latency_ms,
                    "response": response_text,
                    "usage": usage,
                    "payload": raw_payload,
                }
            )
            atomic_write_json(path, payload)
        append_jsonl(
            self.calls_dir / f"{handle.call_id}.stream.jsonl",
            {"event": "completed", "timestamp": iso_now(), "latency_ms": latency_ms},
        )
        self.emit_event(
            "LLM_CALL_COMPLETED",
            stage=handle.stage,
            call_id=handle.call_id,
            response_tokens=usage.get("output_tokens"),
            total_tokens=(usage.get("input_tokens", 0) or 0) + (usage.get("output_tokens", 0) or 0),
            latency_ms=latency_ms,
        )

    def fail_call(self, handle: CallHandle, *, error: str, latency_ms: int | None = None) -> None:
        with self._lock:
            path = self.calls_dir / f"{handle.call_id}.json"
            payload = read_json(path)
            payload.update(
                {
                    "status": "failed",
                    "completed_at": iso_now(),
                    "latency_ms": latency_ms,
                    "error": error,
                }
            )
            atomic_write_json(path, payload)
        append_jsonl(
            self.calls_dir / f"{handle.call_id}.stream.jsonl",
            {"event": "failed", "timestamp": iso_now(), "error": error},
        )
        self.emit_event("LLM_CALL_FAILED", stage=handle.stage, call_id=handle.call_id, error=error)

    def reset_logs(self) -> None:
        shutil.rmtree(self.logs_dir, ignore_errors=True)
        shutil.rmtree(self.calls_dir, ignore_errors=True)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        self.calls_dir.mkdir(parents=True, exist_ok=True)
