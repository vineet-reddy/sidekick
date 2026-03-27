from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .config import BootstrapServiceConfig


class OpenAIClientError(RuntimeError):
    pass


@dataclass(frozen=True)
class OpenAIUsage:
    input_tokens: int
    output_tokens: int


@dataclass(frozen=True)
class OpenAIContainerFileCitation:
    container_id: str
    file_id: str
    filename: str
    annotated_text: str


@dataclass(frozen=True)
class OpenAIContainerFile:
    container_id: str
    file_id: str
    filename: str
    path: str
    mime_type: str


@dataclass(frozen=True)
class OpenAIResponseResult:
    response_id: str
    output_text: str
    usage: OpenAIUsage
    payload: dict[str, Any]


class OpenAIClient:
    def __init__(self, config: BootstrapServiceConfig):
        self._config = config

    def generate_json(
        self,
        *,
        instructions: str,
        input_text: str,
        use_code_interpreter: bool,
        use_web_search: bool = False,
        timeout_seconds: int,
        model: str | None = None,
        reasoning_effort: str | None = None,
        on_delta: Callable[[str], None] | None = None,
        on_event: Callable[[dict[str, Any]], None] | None = None,
    ) -> OpenAIResponseResult:
        selected_model = (model or self._config.openai_model).strip()
        payload: dict[str, Any] = {
            "model": selected_model,
            "instructions": instructions,
            "input": input_text,
        }
        selected_reasoning_effort = (
            self._config.openai_reasoning_effort
            if reasoning_effort is None
            else reasoning_effort.strip()
        )
        if selected_reasoning_effort:
            payload["reasoning"] = {"effort": selected_reasoning_effort}

        tools: list[dict[str, Any]] = []
        if use_web_search:
            tools.append({"type": "web_search"})
        if use_code_interpreter:
            tools.append(
                {
                    "type": "code_interpreter",
                    "container": {"type": "auto"},
                }
            )
        if tools:
            payload["tools"] = tools

        if (on_delta is not None or on_event is not None) and not use_code_interpreter:
            return self._generate_streaming_response(
                payload=payload,
                timeout_seconds=timeout_seconds,
                on_delta=on_delta,
                on_event=on_event,
            )

        payload["background"] = True
        created = self._request_json("POST", "/responses", payload)
        response_id = str(created.get("id") or "").strip()
        if not response_id:
            raise OpenAIClientError("OpenAI did not return a response id.")
        if on_event is not None:
            created_event = dict(created)
            created_event.setdefault("event", "response.created")
            on_event(created_event)

        deadline = time.monotonic() + timeout_seconds
        latest = created
        while time.monotonic() < deadline:
            status = str(latest.get("status") or "").strip().lower()
            if status == "completed":
                return OpenAIResponseResult(
                    response_id=response_id,
                    output_text=self._output_text(latest),
                    usage=self._usage(latest),
                    payload=latest,
                )
            if status in {"failed", "cancelled", "incomplete", "expired"}:
                error_message = self._error_message(latest)
                raise OpenAIClientError(error_message or f"OpenAI response ended with status {status}.")

            time.sleep(5)
            latest = self._request_json("GET", f"/responses/{response_id}", None)
            if on_event is not None:
                polled_event = dict(latest)
                polled_event.setdefault("event", "response.polled")
                on_event(polled_event)

        raise OpenAIClientError("OpenAI response exceeded the configured timeout.")

    def _generate_streaming_response(
        self,
        *,
        payload: dict[str, Any],
        timeout_seconds: int,
        on_delta: Callable[[str], None] | None,
        on_event: Callable[[dict[str, Any]], None] | None,
    ) -> OpenAIResponseResult:
        request_payload = dict(payload)
        request_payload["stream"] = True
        started = time.monotonic()
        event_name = ""
        data_lines: list[str] = []
        final_response: dict[str, Any] | None = None
        aggregated_text = ""
        stream_url = f"{self._config.openai_base_url.rstrip('/')}/responses"
        headers = {
            "Authorization": f"Bearer {self._config.openai_api_key}",
            "Content-Type": "application/json",
        }
        request = Request(
            url=stream_url,
            data=json.dumps(request_payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )

        def flush_event() -> None:
            nonlocal event_name, data_lines, final_response, aggregated_text
            if not data_lines:
                event_name = ""
                return
            raw_data = "\n".join(data_lines).strip()
            data_lines = []
            if raw_data == "[DONE]":
                event_name = ""
                return
            try:
                payload_data = json.loads(raw_data)
            except json.JSONDecodeError:
                payload_data = {"raw": raw_data}

            if on_event is not None and isinstance(payload_data, dict):
                callback_payload = dict(payload_data)
                if event_name:
                    callback_payload.setdefault("event", event_name)
                on_event(callback_payload)

            delta_text = self._extract_stream_delta(event_name, payload_data)
            if delta_text:
                aggregated_text += delta_text
                if on_delta is not None:
                    on_delta(delta_text)

            candidate_response = self._extract_stream_response(payload_data)
            if candidate_response is not None:
                final_response = candidate_response
            event_name = ""

        try:
            with urlopen(request, timeout=max(60, timeout_seconds + 60)) as response:
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="replace").rstrip("\n")
                    if not line.strip():
                        flush_event()
                        continue
                    if line.startswith("event:"):
                        event_name = line.partition(":")[2].strip()
                        continue
                    if line.startswith("data:"):
                        data_lines.append(line.partition(":")[2].lstrip())
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise OpenAIClientError(f"OpenAI request failed with HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise OpenAIClientError(f"OpenAI request failed: {error.reason}") from error

        flush_event()
        if final_response is None:
            final_response = {
                "id": "",
                "status": "completed" if aggregated_text else "failed",
                "output_text": aggregated_text,
                "usage": {"input_tokens": 0, "output_tokens": 0},
                "output": [],
            }

        latency_ms = int((time.monotonic() - started) * 1000)
        payload_copy = dict(final_response)
        payload_copy.setdefault("latency_ms", latency_ms)
        return OpenAIResponseResult(
            response_id=str(final_response.get("id") or "").strip(),
            output_text=self._output_text(final_response) or aggregated_text,
            usage=self._usage(final_response),
            payload=payload_copy,
        )

    def _extract_stream_delta(self, event_name: str, payload: Any) -> str:
        if not isinstance(payload, dict):
            return ""
        if "delta" in payload and isinstance(payload.get("delta"), str):
            return str(payload.get("delta") or "")
        if event_name.endswith("output_text.delta"):
            if isinstance(payload.get("text"), str):
                return str(payload.get("text") or "")
            if isinstance(payload.get("delta"), str):
                return str(payload.get("delta") or "")
        return ""

    def _extract_stream_response(self, payload: Any) -> dict[str, Any] | None:
        if not isinstance(payload, dict):
            return None
        response = payload.get("response")
        if isinstance(response, dict):
            return response
        if payload.get("status") in {"completed", "failed", "cancelled", "incomplete", "expired"}:
            return payload
        return None

    def extract_container_file_citations(self, response: OpenAIResponseResult) -> list[OpenAIContainerFileCitation]:
        citations: list[OpenAIContainerFileCitation] = []
        seen: set[tuple[str, str, str, str]] = set()

        for item in response.payload.get("output", []) or []:
            if not isinstance(item, dict):
                continue
            if str(item.get("type") or "").strip() != "message":
                continue

            for content in item.get("content", []) or []:
                if not isinstance(content, dict):
                    continue
                if str(content.get("type") or "").strip() != "output_text":
                    continue

                text = str(content.get("text") or "")
                for annotation in content.get("annotations", []) or []:
                    if not isinstance(annotation, dict):
                        continue
                    if str(annotation.get("type") or "").strip() != "container_file_citation":
                        continue

                    container_id = str(annotation.get("container_id") or "").strip()
                    file_id = str(annotation.get("file_id") or "").strip()
                    filename = str(annotation.get("filename") or "").strip()
                    start_index = annotation.get("start_index")
                    end_index = annotation.get("end_index")
                    annotated_text = ""
                    if isinstance(start_index, int) and isinstance(end_index, int) and 0 <= start_index <= end_index <= len(text):
                        annotated_text = text[start_index:end_index]
                    key = (container_id, file_id, filename, annotated_text)
                    if not container_id or not file_id or key in seen:
                        continue
                    seen.add(key)
                    citations.append(
                        OpenAIContainerFileCitation(
                            container_id=container_id,
                            file_id=file_id,
                            filename=filename,
                            annotated_text=annotated_text,
                        )
                    )

        return citations

    def extract_container_ids(self, response: OpenAIResponseResult) -> list[str]:
        discovered: list[str] = []
        seen: set[str] = set()

        def collect(value: Any) -> None:
            if isinstance(value, dict):
                container_id = value.get("container_id")
                if isinstance(container_id, str):
                    normalized = container_id.strip()
                    if normalized and normalized not in seen:
                        seen.add(normalized)
                        discovered.append(normalized)
                for nested in value.values():
                    collect(nested)
                return

            if isinstance(value, list):
                for nested in value:
                    collect(nested)

        collect(response.payload.get("output"))
        return discovered

    def list_container_files(self, *, container_id: str) -> list[OpenAIContainerFile]:
        files: list[OpenAIContainerFile] = []
        next_after: str | None = None

        while True:
            query = f"?{urlencode({'after': next_after})}" if next_after else ""
            payload = self._request_json("GET", f"/containers/{container_id}/files{query}", None)
            entries = payload.get("data") if isinstance(payload, dict) else None
            if not isinstance(entries, list):
                break

            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                file_id = str(entry.get("id") or "").strip()
                if not file_id:
                    continue
                path = str(entry.get("path") or "").strip()
                filename = path.rsplit("/", 1)[-1] if path else file_id
                files.append(
                    OpenAIContainerFile(
                        container_id=container_id,
                        file_id=file_id,
                        filename=filename,
                        path=path,
                        mime_type=str(entry.get("mime_type") or "").strip(),
                    )
                )

            has_more = bool(payload.get("has_more")) if isinstance(payload, dict) else False
            next_after = str(payload.get("last_id") or "").strip() if isinstance(payload, dict) else ""
            if not has_more or not next_after:
                break

        return files

    def get_container_file_metadata(self, *, container_id: str, file_id: str) -> dict[str, Any]:
        return self._request_json("GET", f"/containers/{container_id}/files/{file_id}", None)

    def download_container_file_bytes(self, *, container_id: str, file_id: str) -> bytes:
        return self._request_bytes("GET", f"/containers/{container_id}/files/{file_id}/content")

    def _request_json(self, method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        payload = self._request(method, path, body, expect_json=True)
        if not isinstance(payload, dict):
            raise OpenAIClientError("OpenAI returned an unexpected JSON payload.")
        return payload

    def _request_bytes(self, method: str, path: str) -> bytes:
        payload = self._request(method, path, None, expect_json=False)
        if not isinstance(payload, bytes):
            raise OpenAIClientError("OpenAI returned an unexpected binary payload.")
        return payload

    def _request(self, method: str, path: str, body: dict[str, Any] | None, *, expect_json: bool) -> dict[str, Any] | bytes:
        url = f"{self._config.openai_base_url.rstrip('/')}{path}"
        headers = {"Authorization": f"Bearer {self._config.openai_api_key}"}
        data: bytes | None = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")

        request = Request(url=url, data=data, headers=headers, method=method)

        try:
            with urlopen(request, timeout=60) as response:
                payload = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise OpenAIClientError(f"OpenAI request failed with HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise OpenAIClientError(f"OpenAI request failed: {error.reason}") from error

        if not expect_json:
            return payload
        if not payload:
            return {}

        try:
            decoded = json.loads(payload.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise OpenAIClientError("OpenAI returned invalid JSON.") from error
        return decoded

    def _output_text(self, payload: dict[str, Any]) -> str:
        direct_text = payload.get("output_text")
        if isinstance(direct_text, str) and direct_text.strip():
            return direct_text.strip()
        collected: list[str] = []
        for item in payload.get("output", []) or []:
            if not isinstance(item, dict):
                continue

            if isinstance(item.get("content"), list):
                for content in item["content"]:
                    if not isinstance(content, dict):
                        continue
                    text = content.get("text")
                    if isinstance(text, str) and text.strip():
                        collected.append(text)

            if isinstance(item.get("summary"), list):
                for content in item["summary"]:
                    if not isinstance(content, dict):
                        continue
                    text = content.get("text")
                    if isinstance(text, str) and text.strip():
                        collected.append(text)

        return "\n\n".join(collected).strip()

    def _usage(self, payload: dict[str, Any]) -> OpenAIUsage:
        usage = payload.get("usage")
        if not isinstance(usage, dict):
            return OpenAIUsage(input_tokens=0, output_tokens=0)
        return OpenAIUsage(
            input_tokens=int(usage.get("input_tokens") or 0),
            output_tokens=int(usage.get("output_tokens") or 0),
        )

    def _error_message(self, payload: dict[str, Any]) -> str | None:
        error = payload.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message.strip():
                return message.strip()
        return None
