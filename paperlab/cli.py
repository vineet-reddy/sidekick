from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
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
from github_bootstrap_service.bootstrap_service.resolver import SourceFamilyResolver

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNS_ROOT = REPO_ROOT / "paperlab" / "runs"
FIXTURES_ROOT = REPO_ROOT / "paperlab" / "fixtures"
DEFAULT_RENDER_SERVICE_ID = os.getenv("SIDEKICK_RENDER_SERVICE_ID", "srv-d70bar1r0fns73co8f9g").strip() or "srv-d70bar1r0fns73co8f9g"
DEFAULT_RENDER_SERVICE_NAME = os.getenv("SIDEKICK_RENDER_SERVICE_NAME", "sidekick").strip() or "sidekick"
DEFAULT_RENDER_SERVICE_URL = os.getenv("SIDEKICK_RENDER_SERVICE_URL", "https://sidekick-ion1.onrender.com").strip() or "https://sidekick-ion1.onrender.com"
RENDER_SUCCESS_STATES = {"live"}
RENDER_FAILURE_STATES = {"build_failed", "update_failed", "canceled", "failed"}
RENDER_TERMINAL_STATES = RENDER_SUCCESS_STATES | RENDER_FAILURE_STATES | {"deactivated"}


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

    resolve_parser = subparsers.add_parser("resolve", help="Resolve the primary dataset/source family for a payload.")
    add_payload_arguments(resolve_parser)
    resolve_parser.set_defaults(func=resolve_command)

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

    runs_parser = subparsers.add_parser("runs", help="List recent local runs with approval and dataset status.")
    runs_parser.add_argument("--limit", type=int, default=10, help="Maximum number of runs to print.")
    runs_parser.set_defaults(func=runs_command)

    app_state_parser = subparsers.add_parser("app-state", help="Inspect the Sidekick simulator SwiftData store.")
    add_app_state_arguments(app_state_parser)
    app_state_parser.set_defaults(func=app_state_command)

    render_status_parser = subparsers.add_parser("render-status", help="Inspect or wait on Render backend deploy status.")
    add_render_status_arguments(render_status_parser)
    render_status_parser.set_defaults(func=render_status_command)

    return parser


def add_payload_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--input", help="JSON file with the full request payload.")
    parser.add_argument("--title", help="Title for the run when not using --input.")
    parser.add_argument("--theme", help="Theme for the run when not using --input.")
    parser.add_argument("--notes", help="Research prompt text.")
    parser.add_argument("--notes-file", help="File containing the research prompt text.")
    parser.add_argument("--dataset-id", action="append", default=[], help="Explicit dataset id to preserve during resolution.")
    parser.add_argument("--domain-guidance", help="Optional domain guidance text.")
    parser.add_argument("--domain-guidance-file", help="File containing optional domain guidance text.")
    parser.add_argument("--must-use-sources", help="JSON file containing must-use materials.")


def add_run_ref_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("run_ref", help="Run id, absolute path, or `latest`.")


def add_app_state_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "section",
        nargs="?",
        default="summary",
        choices=["summary", "notes", "papers", "runs", "all"],
        help="Which section to print.",
    )
    parser.add_argument("--bundle-id", default="com.vineet.Sidekick", help="App bundle ID. Defaults to Sidekick.")
    parser.add_argument("--device", default="booted", help="Simulator device selector for simctl. Defaults to `booted`.")
    parser.add_argument("--store-path", help="Use an explicit SwiftData store path instead of resolving via simctl.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of the human-readable summary.")


def add_render_status_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--service-id", default=DEFAULT_RENDER_SERVICE_ID, help="Render service id. Defaults to the Sidekick backend.")
    parser.add_argument("--service-name", default=DEFAULT_RENDER_SERVICE_NAME, help="Display name for the Render service.")
    parser.add_argument("--service-url", default=DEFAULT_RENDER_SERVICE_URL, help="Display URL for the Render service.")
    parser.add_argument("--commit", help="Commit sha or prefix to match against deploys.")
    parser.add_argument("--wait", action="store_true", help="Poll until the matched deploy reaches a terminal state.")
    parser.add_argument("--timeout-seconds", type=int, default=300, help="Maximum time to wait when --wait is set.")
    parser.add_argument("--poll-seconds", type=int, default=5, help="Polling interval when --wait is set.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of the human-readable summary.")


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


def resolve_command(args: argparse.Namespace) -> int:
    request_payload = resolve_request_payload(args)
    resolution = SourceFamilyResolver().resolve(
        title=str(request_payload.get("title") or "").strip(),
        theme=str(request_payload.get("theme") or "").strip(),
        notes=normalize_cli_notes(request_payload.get("notes")),
        dataset_hints=request_payload.get("dataset_hints") or [],
        dataset_ids=request_payload.get("dataset_ids") or [],
    )
    print(json.dumps(resolution.as_dict(), indent=2, sort_keys=True))
    return 0


def validate_command(args: argparse.Namespace) -> int:
    run_directory = resolve_run_directory(args.run_ref)
    runtime = CLIRuntime(run_id=run_directory.name, run_directory=run_directory)
    engine = build_engine(runtime=runtime, require_openai=False)
    validation = engine.validate_ledger(
        run_id=run_directory.name,
        ledger=read_json_file(run_directory / "ledger.json"),
        request_payload=read_json_file(run_directory / "input.json"),
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
        resolution = input_payload.get("resolution") if isinstance(input_payload.get("resolution"), dict) else {}
        if resolution:
            print(f"paper_mode: {resolution.get('paper_mode')}")
            print(f"resolution: {resolution.get('status')}")
            selected_candidate = resolution.get("selected_candidate") if isinstance(resolution.get("selected_candidate"), dict) else {}
            if selected_candidate:
                print(f"primary_dataset: {selected_candidate.get('dataset_id')}")
    if ledger:
        print(f"ledger results: {len(ledger.get('results') or [])}")
        print(f"ledger artifacts: {len(ledger.get('artifacts') or [])}")
        print(f"ledger sources: {len(ledger.get('sources') or [])}")
    if validation:
        print(f"manuscript_kind: {validation.get('manuscript_kind')}")
        print(f"approved_results: {len(validation.get('approved_results') or [])}")
        print(f"missing_notes: {len(validation.get('missing_note_ids') or [])}")
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


def runs_command(args: argparse.Namespace) -> int:
    RUNS_ROOT.mkdir(parents=True, exist_ok=True)
    runs = sorted(
        [path for path in RUNS_ROOT.iterdir() if path.is_dir()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )[: max(1, args.limit)]

    if not runs:
        print("No local paperlab runs exist yet.")
        return 0

    print("run_id\tkind\tapproved\tmissing_notes\tpaper_mode\tresolution\tprimary_dataset\tlast_event")
    for run_directory in runs:
        input_payload = maybe_read_json(run_directory / "input.json")
        validation = maybe_read_json(run_directory / "validation.json")
        resolution = {}
        if isinstance(input_payload.get("resolution"), dict):
            resolution = input_payload["resolution"]
        elif isinstance(validation.get("resolution"), dict):
            resolution = validation["resolution"]
        selected_candidate = resolution.get("selected_candidate") if isinstance(resolution.get("selected_candidate"), dict) else {}
        print(
            "\t".join(
                [
                    run_directory.name,
                    str(validation.get("manuscript_kind") or "-"),
                    str(len(validation.get("approved_results") or [])),
                    str(len(validation.get("missing_note_ids") or [])),
                    str(resolution.get("paper_mode") or "-"),
                    str(resolution.get("status") or "-"),
                    str(selected_candidate.get("dataset_id") or "-"),
                    last_event_summary(run_directory),
                ]
            )
        )
    return 0


def app_state_command(args: argparse.Namespace) -> int:
    command = [
        sys.executable,
        str((REPO_ROOT / "scripts" / "sidekick_state.py").resolve()),
        args.section,
        "--bundle-id",
        str(args.bundle_id),
        "--device",
        str(args.device),
    ]
    if args.store_path:
        command.extend(["--store-path", str(args.store_path)])
    if args.json:
        command.append("--json")

    completed = subprocess.run(command, check=False)
    return int(completed.returncode)


def render_status_command(args: argparse.Namespace) -> int:
    deadline = time.monotonic() + max(1, int(args.timeout_seconds))
    while True:
        deploys = fetch_render_deploys(args.service_id)
        selected = select_render_deploy(deploys, args.commit)
        payload = build_render_status_payload(
            deploys=deploys,
            selected_deploy=selected,
            service_id=str(args.service_id),
            service_name=str(args.service_name),
            service_url=str(args.service_url),
            commit_ref=str(args.commit or "").strip() or None,
        )

        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print_render_status(payload)

        if not args.wait:
            return 0
        if render_wait_completed(payload, commit_ref=str(args.commit or "").strip() or None):
            return render_wait_exit_code(payload, commit_ref=str(args.commit or "").strip() or None)
        if time.monotonic() >= deadline:
            if not args.json:
                print(f"Timed out after {max(1, int(args.timeout_seconds))}s.")
            return 1
        if not args.json:
            print(f"Polling again in {max(1, int(args.poll_seconds))}s...")
        time.sleep(max(1, int(args.poll_seconds)))


def build_engine(*, runtime: "CLIRuntime", require_openai: bool = True) -> PaperPipelineEngine:
    config = build_local_config(require_openai=require_openai)
    return PaperPipelineEngine(
        config=config,
        openai_client=OpenAIClient(config),
        status_callback=runtime.record_status,
        metrics_callback=runtime.record_metrics,
        source_resolver=SourceFamilyResolver(),
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
        openai_model=os.getenv("SIDEKICK_OPENAI_MODEL", "gpt-5-nano").strip() or "gpt-5-nano",
        openai_workspace_model=os.getenv("SIDEKICK_OPENAI_WORKSPACE_MODEL", "gpt-5-mini").strip() or "gpt-5-mini",
        openai_writer_model=os.getenv("SIDEKICK_OPENAI_WRITER_MODEL", "gpt-5-nano").strip() or "gpt-5-nano",
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
        "dataset_ids": [str(dataset_id).strip() for dataset_id in args.dataset_id if str(dataset_id).strip()],
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


def normalize_cli_notes(value: Any) -> list[dict[str, str]]:
    if isinstance(value, list):
        normalized: list[dict[str, str]] = []
        for index, note in enumerate(value):
            if not isinstance(note, dict):
                continue
            content = str(note.get("content") or "").strip()
            if not content:
                continue
            normalized.append(
                {
                    "id": str(note.get("id") or f"note_{index + 1}").strip() or f"note_{index + 1}",
                    "title": str(note.get("title") or derive_title(content)).strip() or derive_title(content),
                    "content": content,
                }
            )
        return normalized
    if isinstance(value, str) and value.strip():
        content = value.strip()
        return [{"id": "note_1", "title": derive_title(content), "content": content}]
    return []


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


def last_event_summary(run_directory: Path) -> str:
    path = run_directory / "events.jsonl"
    if not path.exists():
        return "-"
    last_line = ""
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                last_line = line
    if not last_line:
        return "-"
    try:
        payload = json.loads(last_line)
    except json.JSONDecodeError:
        return "-"
    stage = str(payload.get("stage") or "").strip()
    message = str(payload.get("progress_message") or "").strip()
    if stage and message:
        return f"{stage}: {message}"
    return message or stage or "-"


def fetch_render_deploys(service_id: str) -> list[dict[str, Any]]:
    try:
        completed = subprocess.run(
            ["render", "deploys", "list", str(service_id), "--output", "json"],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise FileNotFoundError("Render CLI is not installed or not on PATH.") from error
    except subprocess.CalledProcessError as error:
        stderr = (error.stderr or "").strip()
        raise ValueError(stderr or f"Failed to query Render deploys for {service_id}.") from error

    try:
        payload = json.loads(completed.stdout or "[]")
    except json.JSONDecodeError as error:
        raise ValueError("Render CLI returned invalid JSON for deploy status.") from error
    if not isinstance(payload, list):
        raise ValueError("Render CLI returned an unexpected deploy payload.")
    return [deploy for deploy in payload if isinstance(deploy, dict)]


def select_render_deploy(deploys: list[dict[str, Any]], commit_ref: str | None) -> dict[str, Any] | None:
    normalized_commit = (commit_ref or "").strip()
    if not deploys:
        return None
    if not normalized_commit:
        return deploys[0]
    for deploy in deploys:
        commit = deploy.get("commit") if isinstance(deploy.get("commit"), dict) else {}
        commit_id = str(commit.get("id") or "").strip()
        if commit_id == normalized_commit or commit_id.startswith(normalized_commit):
            return deploy
    return None


def build_render_status_payload(
    *,
    deploys: list[dict[str, Any]],
    selected_deploy: dict[str, Any] | None,
    service_id: str,
    service_name: str,
    service_url: str,
    commit_ref: str | None,
) -> dict[str, Any]:
    live_deploy = next((deploy for deploy in deploys if str(deploy.get("status") or "").strip() == "live"), None)
    return {
        "service": {
            "id": service_id,
            "name": service_name,
            "url": service_url,
        },
        "commit_ref": commit_ref,
        "matched": selected_deploy is not None,
        "selected_deploy": summarize_render_deploy(selected_deploy),
        "live_deploy": summarize_render_deploy(live_deploy),
        "recent_deploys": [summarize_render_deploy(deploy) for deploy in deploys[:5]],
    }


def summarize_render_deploy(deploy: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(deploy, dict):
        return None
    commit = deploy.get("commit") if isinstance(deploy.get("commit"), dict) else {}
    return {
        "id": str(deploy.get("id") or "").strip() or None,
        "status": str(deploy.get("status") or "").strip() or None,
        "trigger": str(deploy.get("trigger") or "").strip() or None,
        "created_at": str(deploy.get("createdAt") or "").strip() or None,
        "started_at": str(deploy.get("startedAt") or "").strip() or None,
        "finished_at": str(deploy.get("finishedAt") or "").strip() or None,
        "updated_at": str(deploy.get("updatedAt") or "").strip() or None,
        "commit_id": str(commit.get("id") or "").strip() or None,
        "commit_message": str(commit.get("message") or "").strip() or None,
    }


def print_render_status(payload: dict[str, Any]) -> None:
    service = payload.get("service") if isinstance(payload.get("service"), dict) else {}
    print(f"service: {service.get('name')} ({service.get('id')})")
    print(f"url: {service.get('url')}")
    commit_ref = payload.get("commit_ref")
    if commit_ref:
        print(f"commit_ref: {commit_ref}")

    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    if selected:
        print("selected:")
        print(f"  id: {selected.get('id')}")
        print(f"  status: {selected.get('status')}")
        print(f"  commit: {selected.get('commit_id')}")
        print(f"  message: {selected.get('commit_message')}")
        print(f"  updated_at: {selected.get('updated_at')}")
    elif commit_ref:
        print("selected: no deploy matched that commit yet")
    else:
        print("selected: no deploys found")

    live = payload.get("live_deploy") if isinstance(payload.get("live_deploy"), dict) else None
    if live:
        print("live:")
        print(f"  id: {live.get('id')}")
        print(f"  commit: {live.get('commit_id')}")
        print(f"  message: {live.get('commit_message')}")
        print(f"  updated_at: {live.get('updated_at')}")

    recent = payload.get("recent_deploys") if isinstance(payload.get("recent_deploys"), list) else []
    if recent:
        print("recent:")
        for deploy in recent:
            if not isinstance(deploy, dict):
                continue
            print(
                "  "
                + " | ".join(
                    [
                        str(deploy.get("status") or "-"),
                        str(deploy.get("id") or "-"),
                        str(deploy.get("commit_id") or "-"),
                        str(deploy.get("updated_at") or "-"),
                    ]
                )
            )


def render_wait_completed(payload: dict[str, Any], *, commit_ref: str | None) -> bool:
    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    if commit_ref and selected is None:
        return False
    status = str((selected or {}).get("status") or "").strip()
    if not status:
        return False
    return status in RENDER_TERMINAL_STATES


def render_wait_exit_code(payload: dict[str, Any], *, commit_ref: str | None) -> int:
    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    status = str((selected or {}).get("status") or "").strip()
    if commit_ref and selected is None:
        return 1
    if status in RENDER_SUCCESS_STATES:
        return 0
    return 1


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
