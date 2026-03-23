from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .config import BootstrapServiceConfig


class OpenAIClientError(RuntimeError):
    pass


@dataclass(frozen=True)
class OpenAIUsage:
    input_tokens: int
    output_tokens: int


@dataclass(frozen=True)
class OpenAIResponseResult:
    response_id: str
    output_text: str
    usage: OpenAIUsage


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
    ) -> OpenAIResponseResult:
        selected_model = (model or self._config.openai_model).strip()
        payload: dict[str, Any] = {
            "model": selected_model,
            "background": True,
            "instructions": instructions,
            "input": input_text,
        }
        selected_reasoning_effort = (
            self._config.openai_reasoning_effort
            if reasoning_effort is None
            else reasoning_effort.strip()
        )
        if selected_reasoning_effort:
            payload["reasoning"] = {
                "effort": selected_reasoning_effort,
            }

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

        created = self._request_json("POST", "/responses", payload)
        response_id = str(created.get("id") or "").strip()
        if not response_id:
            raise OpenAIClientError("OpenAI did not return a response id.")

        deadline = time.monotonic() + timeout_seconds
        latest = created
        while time.monotonic() < deadline:
            status = str(latest.get("status") or "").strip().lower()
            if status == "completed":
                return OpenAIResponseResult(
                    response_id=response_id,
                    output_text=self._output_text(latest),
                    usage=self._usage(latest),
                )
            if status in {"failed", "cancelled", "incomplete", "expired"}:
                error_message = self._error_message(latest)
                raise OpenAIClientError(error_message or f"OpenAI response ended with status {status}.")

            time.sleep(5)
            latest = self._request_json("GET", f"/responses/{response_id}", None)

        raise OpenAIClientError("OpenAI response exceeded the configured timeout.")

    def _request_json(self, method: str, path: str, body: dict[str, Any] | None) -> dict[str, Any]:
        url = f"{self._config.openai_base_url.rstrip('/')}{path}"
        headers = {
            "Authorization": f"Bearer {self._config.openai_api_key}",
            "Content-Type": "application/json",
        }
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = Request(url=url, data=data, headers=headers, method=method)

        try:
            with urlopen(request, timeout=60) as response:
                payload = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise OpenAIClientError(f"OpenAI request failed with HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise OpenAIClientError(f"OpenAI request failed: {error.reason}") from error

        if not payload:
            return {}

        try:
            decoded = json.loads(payload.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise OpenAIClientError("OpenAI returned invalid JSON.") from error

        if not isinstance(decoded, dict):
            raise OpenAIClientError("OpenAI returned an unexpected JSON payload.")

        return decoded

    def _output_text(self, payload: dict[str, Any]) -> str:
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
