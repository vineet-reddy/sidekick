from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from github_bootstrap_service.bootstrap_service.config import BootstrapServiceConfig
from github_bootstrap_service.bootstrap_service.openai_client import OpenAIClient
from github_bootstrap_service.bootstrap_service.pipeline_engine import (
    PaperPipelineEngine,
    PipelineExecutionError,
    build_validation_error_message,
    read_json_file,
    write_json_file,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNS_ROOT = REPO_ROOT / "paperlab" / "runs"
FIXTURES_ROOT = REPO_ROOT / "paperlab" / "fixtures"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except PipelineExecutionError as error:
        print(f"[{error.stage}] {error}", file=sys.stderr)
        return 1
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="paperlab", description="Terminal-first harness for the Sidekick paper engine.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Run the full pipeline locally.")
    add_payload_arguments(run_parser)
    run_parser.add_argument("--run-id", help="Optional run id. Defaults to a generated timestamp slug.")
    run_parser.set_defaults(func=run_command)

    workspace_parser = subparsers.add_parser("workspace", help="Run or rerun the workspace stage for a saved run.")
    add_run_ref_argument(workspace_parser)
    workspace_parser.set_defaults(func=workspace_command)

    validate_parser = subparsers.add_parser("validate", help="Run or rerun the validation stage for a saved run.")
    add_run_ref_argument(validate_parser)
    validate_parser.set_defaults(func=validate_command)

    write_parser = subparsers.add_parser("write", help="Run or rerun the writer stage for a saved run.")
    add_run_ref_argument(write_parser)
    write_parser.set_defaults(func=write_command)

    render_parser = subparsers.add_parser("render", help="Rerender LaTeX and PDF from saved sections without new model calls.")
    add_run_ref_argument(render_parser)
    render_parser.set_defaults(func=render_command)

    inspect_parser = subparsers.add_parser("inspect", help="Inspect a saved run and its local artifacts.")
    add_run_ref_argument(inspect_parser)
    inspect_parser.add_argument(
        "--file",
        choices=["input", "ledger", "validation", "sections", "bundle", "events", "metrics"],
        help="Print one saved artifact instead of the summary.",
    )
    inspect_parser.set_defaults(func=inspect_command)

    open_parser = subparsers.add_parser("open", help="Open a saved run artifact in Finder/default app.")
    add_run_ref_argument(open_parser)
    open_parser.add_argument("--target", choices=["pdf", "tex", "dir", "compile-log"], default="pdf")
    open_parser.set_defaults(func=open_command)

    latest_parser = subparsers.add_parser("latest", help="Print the latest local run directory.")
    latest_parser.set_defaults(func=latest_command)

    return parser


def add_payload_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--input", help="JSON file with the full request payload.")
    parser.add_argument("--title", help="Title for the run when not using --input.")
    parser.add_argument("--theme", help="Theme for the run when not using --input.")
    parser.add_argument("--notes", help="Research prompt text.")
    parser.add_argument("--notes-file", help="File containing the research prompt text.")
    parser.add_argument("--domain-guidance", help="Optional domain guidance text.")
    parser.add_argument("--domain-guidance-file", help="File containing optional domain guidance text.")
    parser.add_argument("--must-use-sources", help="JSON file containing must-use materials.")


def add_run_ref_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("run_ref", help="Run id, absolute path, or `latest`.")


def run_command(args: argparse.Namespace) -> int:
    request_payload = resolve_request_payload(args)
    run_id = args.run_id or generate_run_id(request_payload["title"])
    runtime = CLIRuntime(run_id=run_id)
    engine = build_engine(runtime=runtime)
    run_directory = engine.run_directory(run_id)
    write_json_file(run_directory / "input.json", request_payload)
    print(f"run_id: {run_id}")
    print(f"run_dir: {run_directory}")
    outputs = engine.execute(run_id=run_id, request_payload=request_payload)
    print_summary(run_directory, outputs["validation"], outputs["bundle"])
    return 0


def workspace_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    request_payload = read_json_file(run_directory / "input.json")
    runtime = CLIRuntime(run_id=run_directory.name, run_directory=run_directory)
    engine = build_engine(runtime=runtime)
    ledger = engine.run_research_workspace(run_id=run_directory.name, request_payload=request_payload)
    print(f"ledger: {run_directory / 'ledger.json'}")
    print(f"results: {len(ledger.get('results') or [])}")
    return 0


def validate_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    runtime = CLIRuntime(run_id=run_directory.name, run_directory=run_directory)
    engine = build_engine(runtime=runtime, require_openai=False)
    validation = engine.validate_ledger(
        run_id=run_directory.name,
        ledger=read_json_file(run_directory / "ledger.json"),
    )
    print(f"validation: {run_directory / 'validation.json'}")
    print(f"manuscript_kind: {validation.get('manuscript_kind')}")
    print(validation.get("summary") or "")
    return 0


def write_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    runtime = CLIRuntime(run_id=run_directory.name, run_directory=run_directory)
    engine = build_engine(runtime=runtime, require_openai=True)
    bundle = engine.write_bundle(
        run_id=run_directory.name,
        request_payload=read_json_file(run_directory / "input.json"),
        ledger=read_json_file(run_directory / "ledger.json"),
        validation=read_json_file(run_directory / "validation.json"),
    )
    print_bundle_paths(run_directory, bundle)
    return 0


def render_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    runtime = CLIRuntime(run_id=run_directory.name, run_directory=run_directory)
    engine = build_engine(runtime=runtime, require_openai=False)
    bundle = engine.render_bundle(
        run_id=run_directory.name,
        request_payload=read_json_file(run_directory / "input.json"),
        ledger=read_json_file(run_directory / "ledger.json"),
        validation=read_json_file(run_directory / "validation.json"),
        sections=read_json_file(run_directory / "sections.json"),
    )
    print_bundle_paths(run_directory, bundle)
    return 0


def inspect_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    if args.file:
        print_artifact(run_directory, args.file)
        return 0

    input_payload = maybe_read_json(run_directory / "input.json")
    ledger = maybe_read_json(run_directory / "ledger.json")
    validation = maybe_read_json(run_directory / "validation.json")
    sections = maybe_read_json(run_directory / "sections.json")
    bundle_envelope = maybe_read_json(run_directory / "bundle.json")
    bundle = bundle_envelope.get("bundle") if isinstance(bundle_envelope, dict) else {}

    print(f"run_dir: {run_directory}")
    if input_payload:
        print(f"title: {input_payload.get('title')}")
        print(f"theme: {input_payload.get('theme')}")
    if ledger:
        print(f"ledger results: {len(ledger.get('results') or [])}")
        print(f"ledger artifacts: {len(ledger.get('artifacts') or [])}")
        print(f"ledger sources: {len(ledger.get('sources') or [])}")
    if validation:
        print(f"manuscript_kind: {validation.get('manuscript_kind')}")
        print(f"approved_results: {len(validation.get('approved_results') or [])}")
        print(f"summary: {validation.get('summary')}")
        if validation.get("manuscript_kind") != "paper":
            print(build_validation_error_message(validation))
    if sections:
        print(f"sections: {', '.join(sorted(key for key in sections.keys() if key != 'references'))}")
    if bundle:
        pdf = bundle.get("pdf") or {}
        print(f"pdf_ok: {pdf.get('ok')}")
        print(f"pdf_file: {run_directory / (pdf.get('filename') or 'paper.pdf')}")
        print(f"tex_file: {run_directory / ('memo.tex' if bundle.get('manuscript_kind') == 'memo' else 'paper.tex')}")
    print("artifacts:")
    for candidate in ["input.json", "ledger.json", "validation.json", "sections.json", "bundle.json", "compile.log"]:
        path = run_directory / candidate
        if path.exists():
            print(f"  {path}")
    return 0


def open_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    target = {
        "pdf": first_existing(run_directory / "paper.pdf", run_directory / "memo.pdf", run_directory / "paper.tex", run_directory / "memo.tex"),
        "tex": first_existing(run_directory / "paper.tex", run_directory / "memo.tex"),
        "dir": run_directory,
        "compile-log": run_directory / "compile.log",
    }[args.target]
    if target is None or not target.exists():
        raise FileNotFoundError(f"No {args.target} artifact exists for {run_directory.name}.")

    if sys.platform == "darwin":
        subprocess.run(["open", str(target)], check=True)
    else:
        print(target)
    return 0


def latest_command(_: argparse.Namespace) -> int:
    print(resolve_run_directory("latest"))
    return 0


def build_engine(*, runtime: "CLIRuntime", require_openai: bool = True) -> PaperPipelineEngine:
    config = build_local_config(require_openai=require_openai)
    return PaperPipelineEngine(
        config=config,
        openai_client=OpenAIClient(config),
        status_callback=runtime.record_status,
        metrics_callback=runtime.record_metrics,
    )


def build_local_config(*, require_openai: bool = True) -> BootstrapServiceConfig:
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if require_openai and not api_key:
        raise ValueError("Missing OPENAI_API_KEY.")

    return BootstrapServiceConfig(
        github_client_id=os.getenv("GITHUB_CLIENT_ID", "paperlab").strip() or "paperlab",
        github_client_secret=os.getenv("GITHUB_CLIENT_SECRET", "paperlab").strip() or "paperlab",
        backend_base_url=os.getenv("SIDEKICK_BACKEND_BASE_URL", "http://localhost").strip() or "http://localhost",
        openai_api_key=api_key or "paperlab-local-only",
        backend_database_path=str((REPO_ROOT / ".sidekick-runtime" / "paperlab.sqlite3").resolve()),
        backend_artifact_root=str(RUNS_ROOT.resolve()),
        openai_model=os.getenv("SIDEKICK_OPENAI_MODEL", "gpt-5.4").strip() or "gpt-5.4",
        openai_workspace_model=os.getenv("SIDEKICK_OPENAI_WORKSPACE_MODEL", "gpt-5.4").strip() or "gpt-5.4",
        openai_writer_model=os.getenv("SIDEKICK_OPENAI_WRITER_MODEL", "gpt-5.4").strip() or "gpt-5.4",
        openai_reasoning_effort=os.getenv("SIDEKICK_OPENAI_REASONING_EFFORT", "").strip(),
        openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip() or "https://api.openai.com/v1",
        encryption_secret=os.getenv("SIDEKICK_ENCRYPTION_SECRET", "paperlab-secret").strip() or "paperlab-secret",
    )


def resolve_request_payload(args: argparse.Namespace) -> dict[str, Any]:
    if args.input:
        return read_json_file(Path(args.input).expanduser().resolve())

    notes = load_optional_text(args.notes, args.notes_file)
    if not notes.strip():
        raise ValueError("Provide --input or --notes/--notes-file.")

    title = (args.title or derive_title(notes)).strip()
    if not title:
        raise ValueError("Could not derive a title. Pass --title explicitly.")

    theme = str(args.theme or title).strip() or title
    domain_guidance = load_optional_text(args.domain_guidance, args.domain_guidance_file).strip()
    must_use_sources = []
    if args.must_use_sources:
        raw_sources = read_json_file(Path(args.must_use_sources).expanduser().resolve())
        if isinstance(raw_sources, dict):
            must_use_sources = raw_sources.get("must_use_sources") or []
        elif isinstance(raw_sources, list):
            must_use_sources = raw_sources

    return {
        "title": title,
        "theme": theme,
        "notes": notes,
        "dataset_ids": [],
        "dataset_hints": [],
        "must_use_sources": must_use_sources,
        "domain_guidance": domain_guidance,
    }


def resolve_run_directory(run_ref: str) -> Path:
    RUNS_ROOT.mkdir(parents=True, exist_ok=True)
    if run_ref == "latest":
        candidates = [path for path in RUNS_ROOT.iterdir() if path.is_dir()]
        if not candidates:
            raise FileNotFoundError("No local paperlab runs exist yet.")
        return max(candidates, key=lambda path: path.stat().st_mtime)

    direct = Path(run_ref).expanduser()
    if direct.exists():
        return direct.resolve()

    candidate = (RUNS_ROOT / run_ref).resolve()
    if candidate.exists():
        return candidate
    raise FileNotFoundError(f"Unknown run reference: {run_ref}")


def print_artifact(run_directory: Path, artifact_name: str) -> None:
    mapping = {
        "input": run_directory / "input.json",
        "ledger": run_directory / "ledger.json",
        "validation": run_directory / "validation.json",
        "sections": run_directory / "sections.json",
        "bundle": run_directory / "bundle.json",
        "events": run_directory / "events.jsonl",
        "metrics": run_directory / "metrics.jsonl",
    }
    path = mapping[artifact_name]
    if not path.exists():
        raise FileNotFoundError(f"{path.name} does not exist for {run_directory.name}.")
    print(path.read_text(encoding="utf-8"))


def print_summary(run_directory: Path, validation: dict[str, Any], bundle: dict[str, Any]) -> None:
    print(f"manuscript_kind: {validation.get('manuscript_kind')}")
    print(f"summary: {validation.get('summary')}")
    if validation.get("manuscript_kind") != "paper":
        print(build_validation_error_message(validation))
    print_bundle_paths(run_directory, bundle)


def print_bundle_paths(run_directory: Path, bundle: dict[str, Any]) -> None:
    manuscript_kind = str(bundle.get("manuscript_kind") or "paper").strip() or "paper"
    base = "memo" if manuscript_kind == "memo" else "paper"
    print(f"sections: {run_directory / 'sections.json'}")
    print(f"tex: {run_directory / f'{base}.tex'}")
    print(f"pdf: {run_directory / f'{base}.pdf'}")
    print(f"bundle: {run_directory / 'bundle.json'}")
    pdf = bundle.get("pdf") or {}
    if not pdf.get("ok"):
        print(f"compile_error: {pdf.get('error')}")


def maybe_read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return read_json_file(path)


def load_optional_text(inline_value: str | None, file_value: str | None) -> str:
    if inline_value and inline_value.strip():
        return inline_value
    if file_value and file_value.strip():
        return Path(file_value).expanduser().resolve().read_text(encoding="utf-8")
    return ""


def derive_title(notes: str) -> str:
    for line in notes.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:120]
    return "Untitled research run"


def generate_run_id(title: str) -> str:
    timestamp = datetime.now(tz=UTC).strftime("%Y%m%d-%H%M%S")
    slug = re_slug(title)
    return f"{timestamp}-{slug}"


def re_slug(value: str) -> str:
    import re

    normalized = value.strip().lower()
    normalized = re.sub(r"[^a-z0-9]+", "-", normalized)
    normalized = re.sub(r"-+", "-", normalized).strip("-")
    return normalized or "paper-run"


def first_existing(*paths: Path) -> Path | None:
    for path in paths:
        if path.exists():
            return path
    return None


class CLIRuntime:
    def __init__(self, *, run_id: str, run_directory: Path | None = None):
        self.run_id = run_id
        self.run_directory = run_directory or (RUNS_ROOT / run_id)
        self.run_directory.mkdir(parents=True, exist_ok=True)

    def record_status(
        self,
        run_id: str,
        *,
        stage: str,
        progress_message: str,
        status: str | None = None,
        openai_response_id: str | None = None,
    ) -> None:
        payload = {
            "kind": "status",
            "timestamp": datetime.now(tz=UTC).isoformat(),
            "run_id": run_id,
            "stage": stage,
            "status": status,
            "progress_message": progress_message,
            "openai_response_id": openai_response_id,
        }
        self._append_jsonl(self.run_directory / "events.jsonl", payload)
        status_text = f"[{stage}] {progress_message}"
        if openai_response_id:
            status_text += f" ({openai_response_id})"
        print(status_text)

    def record_metrics(
        self,
        run_id: str,
        *,
        model: str,
        input_tokens: int,
        output_tokens: int,
    ) -> None:
        payload = {
            "timestamp": datetime.now(tz=UTC).isoformat(),
            "run_id": run_id,
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        }
        self._append_jsonl(self.run_directory / "metrics.jsonl", payload)
        print(f"[metrics] {model} input={input_tokens} output={output_tokens}")

    def _append_jsonl(self, path: Path, payload: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
