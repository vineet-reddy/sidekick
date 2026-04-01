from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import webbrowser
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from github_bootstrap_service.bootstrap_service.config import BootstrapServiceConfig
from github_bootstrap_service.bootstrap_service.openai_client import OpenAIClient
from github_bootstrap_service.bootstrap_service.pipeline_engine import (
    PaperPipelineEngine,
    PipelineExecutionError,
    read_json_file,
    write_json_file,
)
from github_bootstrap_service.bootstrap_service.pipeline_runtime import (
    DEFAULT_RUN_ROOT,
    SidekickRunStore,
    iter_jsonl,
    load_sidekick_config,
    save_sidekick_config,
)
from paperlab.autoresearch import (
    DEFAULT_AUTORESEARCH_ROOT,
    DEFAULT_PROGRAM_PATH,
    AutoResearchConfig,
    AutoResearchError,
    AutoResearchSession,
    load_session_attempts,
    load_session_summary,
)
from paperlab.paper_quality import PaperQualityVerifier

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNS_ROOT = DEFAULT_RUN_ROOT


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except PipelineExecutionError as error:
        if args.command == "_worker":
            return exit_code_for_stage(error.stage)
        print(str(error), file=sys.stderr)
        return exit_code_for_stage(error.stage)
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 1
    except AutoResearchError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 20


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sidekick", description="Terminal-first research paper pipeline.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Start a pipeline run and return a run id immediately.")
    run_parser.add_argument("note", nargs="?", help="Research note text.")
    run_parser.add_argument("--notes-file", help="Read the note text from a file.")
    run_parser.add_argument("--title", help="Explicit title for the run.")
    run_parser.add_argument("--theme", help="Explicit theme for the run.")
    run_parser.add_argument("--run-id", help="Optional run id.")
    run_parser.add_argument("--foreground", action="store_true", help="Run inline instead of spawning a background worker.")
    run_parser.add_argument("--json", action="store_true", help="Print JSON instead of plain text.")
    run_parser.set_defaults(func=run_command)

    render_parser = subparsers.add_parser("render", help="Legacy compatibility: rerender a saved run.")
    add_run_ref_argument(render_parser)
    render_parser.set_defaults(func=render_command)

    render_status_parser = subparsers.add_parser("render-status", help="Legacy compatibility: inspect Render deploy state.")
    render_status_parser.add_argument("--service-id", default=os.getenv("SIDEKICK_RENDER_SERVICE_ID", ""))
    render_status_parser.add_argument("--service-name", default=os.getenv("SIDEKICK_RENDER_SERVICE_NAME", "sidekick"))
    render_status_parser.add_argument("--service-url", default=os.getenv("SIDEKICK_RENDER_SERVICE_URL", ""))
    render_status_parser.add_argument("--commit")
    render_status_parser.add_argument("--wait", action="store_true")
    render_status_parser.add_argument("--timeout-seconds", type=int, default=300)
    render_status_parser.add_argument("--poll-seconds", type=int, default=5)
    render_status_parser.add_argument("--json", action="store_true")
    render_status_parser.set_defaults(func=render_status_command)

    worker_parser = subparsers.add_parser("_worker")
    worker_parser.add_argument("run_id")
    worker_parser.set_defaults(func=worker_command)

    status_parser = subparsers.add_parser("status", help="Show run state.")
    add_run_ref_argument(status_parser)
    status_parser.add_argument("--watch", action="store_true")
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(func=status_command)

    list_parser = subparsers.add_parser("list", help="List all runs.")
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(func=list_command)

    cancel_parser = subparsers.add_parser("cancel", help="Cancel a running pipeline.")
    add_run_ref_argument(cancel_parser)
    cancel_parser.set_defaults(func=cancel_command)

    logs_parser = subparsers.add_parser("logs", help="Read logs for a run.")
    add_run_ref_argument(logs_parser)
    logs_parser.add_argument("--stage")
    logs_parser.add_argument("--level", choices=["debug", "info", "warn", "error"])
    logs_parser.add_argument("--follow", action="store_true")
    logs_parser.add_argument("--since")
    logs_parser.add_argument("--tail", type=int)
    logs_parser.add_argument("--json", action="store_true")
    logs_parser.set_defaults(func=logs_command)

    log_level_parser = subparsers.add_parser("log-level", help="Get or set the log level for a running run.")
    add_run_ref_argument(log_level_parser)
    log_level_subparsers = log_level_parser.add_subparsers(dest="action", required=True)
    log_level_get = log_level_subparsers.add_parser("get")
    log_level_get.set_defaults(func=log_level_get_command)
    log_level_set = log_level_subparsers.add_parser("set")
    log_level_set.add_argument("level", choices=["debug", "info", "warn", "error"])
    log_level_set.set_defaults(func=log_level_set_command)

    calls_parser = subparsers.add_parser("calls", help="List LLM calls for a run.")
    add_run_ref_argument(calls_parser)
    calls_parser.add_argument("--stage")
    calls_parser.add_argument("--json", action="store_true")
    calls_parser.set_defaults(func=calls_command)

    call_parser = subparsers.add_parser("call", help="Show an individual LLM call.")
    add_run_ref_argument(call_parser)
    call_parser.add_argument("call_id")
    call_parser.add_argument("--prompt", action="store_true")
    call_parser.add_argument("--response", action="store_true")
    call_parser.set_defaults(func=call_command)

    stream_parser = subparsers.add_parser("stream", help="Attach to the active LLM call stream.")
    add_run_ref_argument(stream_parser)
    stream_parser.add_argument("--stage")
    stream_parser.add_argument("--raw", action="store_true")
    stream_parser.set_defaults(func=stream_command)

    artifacts_parser = subparsers.add_parser("artifacts", help="List artifacts produced by a run.")
    add_run_ref_argument(artifacts_parser)
    artifacts_parser.add_argument("--stage")
    artifacts_parser.add_argument("--download")
    artifacts_parser.add_argument("--json", action="store_true")
    artifacts_parser.set_defaults(func=artifacts_command)

    artifact_parser = subparsers.add_parser("artifact", help="Dump an artifact to stdout.")
    add_run_ref_argument(artifact_parser)
    artifact_parser.add_argument("artifact_id")
    artifact_parser.set_defaults(func=artifact_command)

    retries_parser = subparsers.add_parser("retries", help="Inspect retry history.")
    add_run_ref_argument(retries_parser)
    retries_parser.add_argument("--attempt", type=int)
    retries_parser.add_argument("--json", action="store_true")
    retries_parser.set_defaults(func=retries_command)

    events_parser = subparsers.add_parser("events", help="Read structured run events.")
    add_run_ref_argument(events_parser)
    events_parser.add_argument("--stage")
    events_parser.add_argument("--follow", action="store_true")
    events_parser.add_argument("--json", action="store_true")
    events_parser.set_defaults(func=events_command)

    config_parser = subparsers.add_parser("config", help="Manage Sidekick CLI config.")
    config_subparsers = config_parser.add_subparsers(dest="action", required=True)
    config_set = config_subparsers.add_parser("set")
    config_set.add_argument("key")
    config_set.add_argument("value")
    config_set.set_defaults(func=config_set_command)
    config_get = config_subparsers.add_parser("get")
    config_get.add_argument("key")
    config_get.set_defaults(func=config_get_command)
    config_list = config_subparsers.add_parser("list")
    config_list.set_defaults(func=config_list_command)

    hosted_parser = subparsers.add_parser("hosted", help="Interact with the hosted backend pipeline.")
    hosted_subparsers = hosted_parser.add_subparsers(dest="action", required=True)

    hosted_session = hosted_subparsers.add_parser("session", help="Create or refresh a hosted install session.")
    hosted_session.add_argument("--backend-url")
    hosted_session.add_argument("--device-id")
    hosted_session.add_argument("--json", action="store_true")
    hosted_session.set_defaults(func=hosted_session_command)

    hosted_connect = hosted_subparsers.add_parser("connect", help="Start GitHub connect for the hosted backend.")
    hosted_connect.add_argument("--backend-url")
    hosted_connect.add_argument("--session-token")
    hosted_connect.add_argument("--open", action="store_true", help="Open the GitHub OAuth URL in the default browser.")
    hosted_connect.add_argument("--json", action="store_true")
    hosted_connect.set_defaults(func=hosted_connect_command)

    hosted_connect_status = hosted_subparsers.add_parser("connect-status", help="Inspect a hosted GitHub connect session.")
    hosted_connect_status.add_argument("connect_session_id")
    hosted_connect_status.add_argument("--backend-url")
    hosted_connect_status.add_argument("--session-token")
    hosted_connect_status.add_argument("--watch", action="store_true")
    hosted_connect_status.add_argument("--poll-seconds", type=int, default=2)
    hosted_connect_status.add_argument("--timeout-seconds", type=int, default=300)
    hosted_connect_status.add_argument("--json", action="store_true")
    hosted_connect_status.set_defaults(func=hosted_connect_status_command)

    hosted_submit = hosted_subparsers.add_parser("submit", help="Submit a hosted paper job.")
    hosted_submit.add_argument("note", nargs="?", help="Research note text.")
    hosted_submit.add_argument("--notes-file", help="Read the note text from a file.")
    hosted_submit.add_argument("--title", required=True, help="Paper title.")
    hosted_submit.add_argument("--theme", help="Paper theme; defaults to title.")
    hosted_submit.add_argument("--backend-url")
    hosted_submit.add_argument("--session-token")
    hosted_submit.add_argument("--dataset-id", action="append", dest="dataset_ids", default=[])
    hosted_submit.add_argument("--dataset-hint", action="append", dest="dataset_hints", default=[])
    hosted_submit.add_argument("--domain-guidance", default="")
    hosted_submit.add_argument("--json", action="store_true")
    hosted_submit.set_defaults(func=hosted_submit_command)

    hosted_status = hosted_subparsers.add_parser("status", help="Inspect a hosted paper job.")
    hosted_status.add_argument("job_id")
    hosted_status.add_argument("--backend-url")
    hosted_status.add_argument("--session-token")
    hosted_status.add_argument("--watch", action="store_true")
    hosted_status.add_argument("--poll-seconds", type=int, default=5)
    hosted_status.add_argument("--timeout-seconds", type=int, default=3600)
    hosted_status.add_argument("--json", action="store_true")
    hosted_status.set_defaults(func=hosted_status_command)

    hosted_artifacts = hosted_subparsers.add_parser("artifacts", help="Fetch hosted bundle artifacts for a completed job.")
    hosted_artifacts.add_argument("job_id")
    hosted_artifacts.add_argument("--backend-url")
    hosted_artifacts.add_argument("--session-token")
    hosted_artifacts.add_argument("--json", action="store_true")
    hosted_artifacts.set_defaults(func=hosted_artifacts_command)

    add_autorepair_parser(subparsers, name="autorepair", help_text="Run overnight repair loops in isolated git worktrees.")
    add_autorepair_parser(subparsers, name="autoresearch", help_text="Compatibility alias for `autorepair`.")
    add_paper_quality_parser(subparsers)

    return parser


def add_paper_quality_parser(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    paper_quality_parser = subparsers.add_parser("paper-quality", help="Verify manuscript quality for a generated paper.")
    paper_quality_subparsers = paper_quality_parser.add_subparsers(dest="action", required=True)

    verify_parser = paper_quality_subparsers.add_parser("verify", help="Run deterministic and LLM paper-quality verification.")
    verify_parser.add_argument("target_ref", help="Run id, run directory, path to paper.tex/memo.tex, or 'latest'.")
    verify_parser.add_argument("--skip-llm", action="store_true", help="Skip the LLM manuscript judge and run deterministic checks only.")
    verify_parser.add_argument("--golden-root", default="/Users/vineetreddy/Documents/GitHub/test_sidekickdata", help="Golden dataset root used for paper-quality judging.")
    verify_parser.add_argument("--max-golden-examples", type=int, default=3, help="Maximum number of golden examples to include in the LLM judge context.")
    verify_parser.add_argument("--model", help="Optional model override for the LLM manuscript judge.")
    verify_parser.add_argument("--timeout-seconds", type=int, default=300, help="Timeout for the LLM manuscript judge.")
    verify_parser.add_argument("--json", action="store_true", help="Print JSON output.")
    verify_parser.set_defaults(func=paper_quality_verify_command)


def add_autorepair_parser(subparsers: argparse._SubParsersAction[argparse.ArgumentParser], *, name: str, help_text: str) -> None:
    autoresearch_parser = subparsers.add_parser(name, help=help_text)
    autoresearch_subparsers = autoresearch_parser.add_subparsers(dest="action", required=True)

    autoresearch_run = autoresearch_subparsers.add_parser("run", help="Start an autorepair session.")
    autoresearch_run.add_argument("--objective", required=True, help="High-level repair goal given to Codex.")
    autoresearch_run.add_argument("--verify", required=True, help="Shell command that must exit 0 before the session is considered solved.")
    autoresearch_run.add_argument("--program", default=str(DEFAULT_PROGRAM_PATH), help="Path to the autorepair program markdown.")
    autoresearch_run.add_argument("--session-root", default=str(DEFAULT_AUTORESEARCH_ROOT), help="Directory where autorepair session state is stored.")
    autoresearch_run.add_argument("--repo-root", default=str(REPO_ROOT), help="Repository root used for git worktree orchestration.")
    autoresearch_run.add_argument("--source-worktree", default=os.getcwd(), help="Clean git worktree that receives successful fixes.")
    autoresearch_run.add_argument("--max-attempts", type=int, default=12, help="Maximum number of Codex repair attempts.")
    autoresearch_run.add_argument("--time-budget-minutes", type=int, default=480, help="Wall-clock budget for the session.")
    autoresearch_run.add_argument("--codex-bin", default="codex", help="Codex executable to invoke.")
    autoresearch_run.add_argument("--model", help="Optional Codex model override.")
    autoresearch_run.add_argument("--search", action="store_true", help="Enable Codex web search for repair attempts.")
    autoresearch_run.add_argument("--yolo", action="store_true", help="Pass full computer access through to Codex attempts.")
    autoresearch_run.add_argument("--allow-dirty", action="store_true", help="Allow the source worktree to start dirty.")
    autoresearch_run.add_argument("--run-tag", help="Run tag used for the advancing autorepair branch.")
    autoresearch_run.add_argument("--branch", help="Explicit branch name for the advancing best-known branch.")
    autoresearch_run.add_argument("--no-create-branch", action="store_true", help="Do not create or switch the source worktree branch automatically.")
    autoresearch_run.add_argument("--verifier-timeout-seconds", type=int, default=1800, help="Kill verifier runs that exceed this timeout.")
    autoresearch_run.add_argument("--score-regex", help="Optional regex with one capture group for a numeric score to optimize.")
    autoresearch_run.add_argument("--score-direction", choices=["lower", "higher"], default="lower", help="Whether lower or higher scores are better.")
    autoresearch_run.add_argument("--scope-file", action="append", default=[], dest="scope_files", help="Repeatable list of in-scope files or directories.")
    autoresearch_run.add_argument("--continue-on-pass", action="store_true", help="Keep searching for improvements even after the verifier passes once.")
    autoresearch_run.add_argument("--json", action="store_true", help="Print the final session summary as JSON.")
    autoresearch_run.set_defaults(func=autoresearch_run_command)

    autoresearch_status = autoresearch_subparsers.add_parser("status", help="Show autorepair session state.")
    autoresearch_status.add_argument("session_ref", help="Session id, path, or 'latest'.")
    autoresearch_status.add_argument("--session-root", default=str(DEFAULT_AUTORESEARCH_ROOT))
    autoresearch_status.add_argument("--json", action="store_true")
    autoresearch_status.set_defaults(func=autoresearch_status_command)

    autoresearch_attempts = autoresearch_subparsers.add_parser("attempts", help="Show autorepair attempt history.")
    autoresearch_attempts.add_argument("session_ref", help="Session id, path, or 'latest'.")
    autoresearch_attempts.add_argument("--session-root", default=str(DEFAULT_AUTORESEARCH_ROOT))
    autoresearch_attempts.add_argument("--json", action="store_true")
    autoresearch_attempts.set_defaults(func=autoresearch_attempts_command)


def add_run_ref_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("run_ref")


def run_command(args: argparse.Namespace) -> int:
    note = resolve_note_text(args.note, args.notes_file)
    if not note:
        raise ValueError("Provide a note argument or --notes-file.")
    title = str(args.title or derive_title(note)).strip() or "Untitled research run"
    theme = str(args.theme or title).strip() or title
    run_id = args.run_id or generate_run_id(title)
    run_dir = run_directory(run_id)
    write_json_file(
        run_dir / "input.json",
        {
            "title": title,
            "theme": theme,
            "notes": note,
        },
    )
    store = SidekickRunStore(run_id=run_id, root=RUNS_ROOT)
    state = store.read_state()
    state.update({"title": title, "note": note, "updated_at": iso_now()})
    store.write_state(state)

    run_foreground = args.foreground or RUNS_ROOT != DEFAULT_RUN_ROOT
    if run_foreground:
        exit_code = worker_main(run_id)
        if args.json:
            print(json.dumps({"run_id": run_id, "run_dir": str(run_dir), "exit_code": exit_code}, indent=2, sort_keys=True))
        else:
            print(run_id)
        return exit_code

    command = [sys.executable, "-m", "paperlab.cli", "_worker", run_id]
    subprocess.Popen(
        command,
        cwd=str(REPO_ROOT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=os.environ.copy(),
    )
    if args.json:
        print(json.dumps({"run_id": run_id, "run_dir": str(run_dir)}, indent=2, sort_keys=True))
    else:
        print(run_id)
    return 0


def render_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    bundle_path = run_dir / "bundle.json"
    if not bundle_path.exists():
        raise FileNotFoundError(f"Missing bundle.json for {run_dir.name}")
    bundle_payload = read_json_file(bundle_path)
    bundle = bundle_payload.get("bundle") if isinstance(bundle_payload.get("bundle"), dict) else bundle_payload
    if not bundle:
        raise FileNotFoundError(f"Missing bundle payload for {run_dir.name}")
    print(json.dumps(bundle, indent=2, sort_keys=True))
    return 0


def worker_command(args: argparse.Namespace) -> int:
    return worker_main(args.run_id)


def worker_main(run_id: str) -> int:
    run_dir = run_directory(run_id)
    payload = read_json_file(run_dir / "input.json")
    engine = build_engine(require_openai=True)
    store = SidekickRunStore(run_id=run_id, root=RUNS_ROOT)
    try:
        engine.execute(run_id=run_id, request_payload=payload)
        store.complete_stage(stage="4", agent="github-push", artifacts=[])
        store.complete_run(exit_code=0)
        return 0
    except PipelineExecutionError as error:
        return exit_code_for_stage(error.stage)


def status_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    def render() -> None:
        payload = build_status_payload(run_dir)
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print_status_payload(payload)
    if not args.watch:
        render()
        return 0
    while True:
        render()
        payload = build_status_payload(run_dir)
        if payload.get("status") in {"completed", "failed", "cancelled"}:
            return int(payload.get("exit_code") or 0)
        time.sleep(2)


def list_command(args: argparse.Namespace) -> int:
    runs = sorted([path for path in RUNS_ROOT.iterdir() if path.is_dir()], key=lambda path: path.stat().st_mtime, reverse=True)
    payload = [build_status_payload(run) for run in runs]
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    for entry in payload:
        print(
            " | ".join(
                [
                    str(entry.get("run_id") or "-"),
                    str(entry.get("status") or "-"),
                    str(entry.get("current_stage") or "-"),
                    str(entry.get("health") or "-"),
                    str(entry.get("title") or "-"),
                ]
            )
        )
    return 0


def cancel_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    store = SidekickRunStore(run_id=run_dir.name, root=RUNS_ROOT)
    store.request_cancel()
    print(json.dumps({"run_id": run_dir.name, "cancel_requested": True}, indent=2, sort_keys=True))
    return 0


def logs_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    path = log_path(run_dir, args.stage)
    return stream_jsonl_command(path=path, args=args, stage_filter=args.stage, level_filter=args.level)


def log_level_get_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    store = SidekickRunStore(run_id=run_dir.name, root=RUNS_ROOT)
    print(store.current_log_level())
    return 0


def log_level_set_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    store = SidekickRunStore(run_id=run_dir.name, root=RUNS_ROOT)
    state = store.read_state()
    state["log_level"] = args.level
    store.write_state(state)
    print(args.level)
    return 0


def calls_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    entries = []
    for path in sorted((run_dir / "calls").glob("*.json")):
        if path.name.endswith(".stream.json"):
            continue
        payload = read_json_file(path)
        if args.stage and str(payload.get("stage") or "").strip() != args.stage:
            continue
        entries.append(
            {
                "call_id": payload.get("call_id"),
                "stage": payload.get("stage"),
                "agent": payload.get("agent"),
                "model": payload.get("model"),
                "status": payload.get("status"),
                "latency_ms": payload.get("latency_ms"),
                "usage": payload.get("usage"),
            }
        )
    if args.json:
        print(json.dumps(entries, indent=2, sort_keys=True))
        return 0
    for entry in entries:
        print(
            " | ".join(
                [
                    str(entry.get("call_id") or "-"),
                    str(entry.get("stage") or "-"),
                    str(entry.get("model") or "-"),
                    str(entry.get("status") or "-"),
                    str((entry.get("usage") or {}).get("output_tokens") or 0),
                ]
            )
        )
    return 0


def call_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    payload = read_json_file(run_dir / "calls" / f"{args.call_id}.json")
    if args.prompt:
        print(str(payload.get("prompt") or ""))
        return 0
    if args.response:
        print(str(payload.get("response") or ""))
        return 0
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def stream_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    active_call = latest_active_call(run_dir, stage=args.stage)
    if active_call is None:
        raise FileNotFoundError("No active call stream found.")
    stream_path = run_dir / "calls" / f"{active_call}.stream.jsonl"
    position = 0
    while True:
        if not stream_path.exists():
            time.sleep(0.25)
            continue
        with stream_path.open("r", encoding="utf-8") as handle:
            handle.seek(position)
            lines = handle.readlines()
            position = handle.tell()
        for line in lines:
            payload = json.loads(line)
            if args.raw:
                print(json.dumps(payload, sort_keys=True))
            else:
                if payload.get("event") == "delta":
                    print(str(payload.get("delta") or ""), end="", flush=True)
                elif payload.get("event") in {"completed", "failed"}:
                    if payload.get("event") == "completed":
                        print()
                    return 0
        time.sleep(0.25)


def artifacts_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    payload = read_json_file(run_dir / "artifacts.json")
    artifacts = payload.get("artifacts") if isinstance(payload.get("artifacts"), list) else []
    if args.stage:
        artifacts = [artifact for artifact in artifacts if str(artifact.get("stage") or "").strip() == args.stage]
    if args.download:
        destination = Path(args.download).expanduser().resolve()
        destination.mkdir(parents=True, exist_ok=True)
        for artifact in artifacts:
            source = run_dir / str(artifact.get("path") or "")
            if not source.exists() or not source.is_file():
                continue
            target = destination / source.name
            target.write_bytes(source.read_bytes())
    if args.json:
        print(json.dumps(artifacts, indent=2, sort_keys=True))
        return 0
    for artifact in artifacts:
        print(
            " | ".join(
                [
                    str(artifact.get("artifact_id") or "-"),
                    str(artifact.get("stage") or "-"),
                    str(artifact.get("artifact_type") or "-"),
                    str(artifact.get("path") or "-"),
                ]
            )
        )
    return 0


def artifact_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    payload = read_json_file(run_dir / "artifacts.json")
    artifacts = payload.get("artifacts") if isinstance(payload.get("artifacts"), list) else []
    artifact = next((entry for entry in artifacts if str(entry.get("artifact_id") or "") == args.artifact_id), None)
    if artifact is None:
        raise FileNotFoundError(f"Unknown artifact: {args.artifact_id}")
    path = run_dir / str(artifact.get("path") or "")
    if not path.exists():
        raise FileNotFoundError(f"Artifact file does not exist: {path}")
    sys.stdout.write(path.read_text(encoding="utf-8", errors="replace"))
    return 0


def retries_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    payload = read_json_file(run_dir / "retries.json")
    attempts = payload.get("attempts") if isinstance(payload.get("attempts"), list) else []
    if args.attempt is not None:
        attempts = [entry for entry in attempts if int(entry.get("attempt") or 0) == args.attempt]
    if args.json:
        print(json.dumps(attempts, indent=2, sort_keys=True))
        return 0
    for entry in attempts:
        print(
            " | ".join(
                [
                    f"attempt {entry.get('attempt')}",
                    str(entry.get("status") or "-"),
                    str(entry.get("feedback_message") or "-"),
                ]
            )
        )
    return 0


def events_command(args: argparse.Namespace) -> int:
    run_dir = resolve_run_directory(args.run_ref)
    return stream_jsonl_command(path=run_dir / "events.jsonl", args=args, stage_filter=args.stage, level_filter=None)


def config_set_command(args: argparse.Namespace) -> int:
    payload = load_sidekick_config()
    key = str(args.key).strip()
    value: Any = args.value
    if key == "stream_buffer_size":
        value = int(value)
    payload[key] = value
    save_sidekick_config(payload)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def config_get_command(args: argparse.Namespace) -> int:
    payload = load_sidekick_config()
    print(payload.get(args.key))
    return 0


def config_list_command(_: argparse.Namespace) -> int:
    print(json.dumps(load_sidekick_config(), indent=2, sort_keys=True))
    return 0


def hosted_session_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    device_id = resolve_hosted_device_id(args.device_id)
    payload = hosted_request_json(
        "POST",
        backend_url,
        "/api/device/session",
        body={"device_id": device_id},
    )
    save_hosted_config(
        backend_url=backend_url,
        device_id=device_id,
        session_token=str(payload.get("session_token") or "").strip() or None,
        install_session_id=str(payload.get("install_session_id") or "").strip() or None,
    )
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"backend_url: {backend_url}")
        print(f"device_id: {device_id}")
        print(f"install_session_id: {payload.get('install_session_id')}")
        print(f"session_token: {payload.get('session_token')}")
        connection = payload.get("github_connection") if isinstance(payload.get("github_connection"), dict) else None
        print(f"github_connected: {'yes' if connection else 'no'}")
    return 0


def hosted_connect_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    session_token = resolve_hosted_session_token(args.session_token)
    payload = hosted_request_json(
        "POST",
        backend_url,
        "/api/github/connect/start",
        session_token=session_token,
    )
    if args.open:
        webbrowser.open(str(payload.get("browser_url") or ""))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"session_id: {payload.get('session_id')}")
        print(f"status: {payload.get('status')}")
        print(f"browser_url: {payload.get('browser_url')}")
    return 0


def hosted_connect_status_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    session_token = resolve_hosted_session_token(args.session_token)
    deadline = time.monotonic() + max(1, int(args.timeout_seconds))
    while True:
        payload = hosted_request_json(
            "GET",
            backend_url,
            f"/api/github/connect/sessions/{args.connect_session_id}",
            session_token=session_token,
        )
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            connection = payload.get("connection") if isinstance(payload.get("connection"), dict) else None
            print(f"session_id: {payload.get('session_id')}")
            print(f"status: {payload.get('status')}")
            print(f"repo: {(connection or {}).get('repo_full_name') or '-'}")
            print(f"updated_at: {payload.get('updated_at')}")
        if not args.watch:
            return 0
        if str(payload.get("status") or "").strip() in {"completed", "failed"}:
            return 0 if payload.get("connection") else 1
        if time.monotonic() >= deadline:
            return 1
        time.sleep(max(1, int(args.poll_seconds)))


def hosted_submit_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    session_token = resolve_hosted_session_token(args.session_token)
    note = resolve_note_text(args.note, args.notes_file)
    if not note:
        raise ValueError("Provide a note argument or --notes-file.")
    title = str(args.title or "").strip()
    theme = str(args.theme or title).strip() or title
    payload = hosted_request_json(
        "POST",
        backend_url,
        "/api/papers",
        session_token=session_token,
        body={
            "title": title,
            "theme": theme,
            "notes": [{"id": "note_1", "title": title, "content": note}],
            "dataset_ids": list(args.dataset_ids or []),
            "dataset_hints": list(args.dataset_hints or []),
            "domain_guidance": str(args.domain_guidance or "").strip(),
        },
    )
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(str(payload.get("job_id") or ""))
    return 0


def hosted_status_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    session_token = resolve_hosted_session_token(args.session_token)
    deadline = time.monotonic() + max(1, int(args.timeout_seconds))
    while True:
        payload = hosted_request_json(
            "GET",
            backend_url,
            f"/api/papers/{args.job_id}",
            session_token=session_token,
        )
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True))
        else:
            print_hosted_job_payload(payload)
        if not args.watch:
            return 0
        if str(payload.get("status") or "").strip() in {"completed", "failed", "cancelled"}:
            return 0 if str(payload.get("status") or "").strip() == "completed" else 1
        if time.monotonic() >= deadline:
            return 1
        time.sleep(max(1, int(args.poll_seconds)))


def hosted_artifacts_command(args: argparse.Namespace) -> int:
    backend_url = resolve_hosted_backend_url(args.backend_url)
    session_token = resolve_hosted_session_token(args.session_token)
    payload = hosted_request_json(
        "GET",
        backend_url,
        f"/api/papers/{args.job_id}/artifacts",
        session_token=session_token,
    )
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def paper_quality_verify_command(args: argparse.Namespace) -> int:
    target = PaperQualityVerifier.resolve_target_from_ref(target_ref=args.target_ref, runs_root=RUNS_ROOT)
    openai_client = None
    model = str(args.model).strip() if args.model else None
    if not args.skip_llm:
        try:
            config = build_local_config(require_openai=True)
        except ValueError:
            config = None
        if config is not None:
            openai_client = OpenAIClient(config)
            if model is None:
                model = config.openai_validation_model
    verifier = PaperQualityVerifier(
        openai_client=openai_client,
        llm_model=model,
        llm_timeout_seconds=max(30, int(args.timeout_seconds)),
        golden_root=Path(args.golden_root).expanduser().resolve(),
        max_golden_examples=max(1, int(args.max_golden_examples)),
    )
    payload = verifier.verify_target(target, skip_llm=bool(args.skip_llm))
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"target: {payload['target']['tex_path']}")
        print(f"overall_status: {payload.get('overall_status')}")
        print(f"score: {payload.get('score')}")
        print(f"deterministic_passed: {(payload.get('deterministic') or {}).get('passed')}")
        print(f"llm_verdict: {(payload.get('llm_review') or {}).get('verdict')}")
        print(f"summary: {payload.get('summary')}")
    return 0 if bool(payload.get("passed")) else 1


def autoresearch_run_command(args: argparse.Namespace) -> int:
    config = AutoResearchConfig(
        objective=str(args.objective).strip(),
        verify_command=str(args.verify).strip(),
        repo_root=Path(args.repo_root).expanduser().resolve(),
        source_worktree=Path(args.source_worktree).expanduser().resolve(),
        session_root=Path(args.session_root).expanduser().resolve(),
        program_path=Path(args.program).expanduser().resolve(),
        codex_bin=str(args.codex_bin).strip() or "codex",
        model=str(args.model).strip() if args.model else None,
        search_enabled=bool(args.search),
        yolo=bool(args.yolo),
        max_attempts=int(args.max_attempts),
        time_budget_minutes=max(1, int(args.time_budget_minutes)),
        allow_dirty=bool(args.allow_dirty),
        run_tag=str(args.run_tag).strip() if args.run_tag else None,
        branch_name=str(args.branch).strip() if args.branch else None,
        create_branch=not bool(args.no_create_branch),
        verifier_timeout_seconds=max(1, int(args.verifier_timeout_seconds)),
        score_regex=str(args.score_regex).strip() if args.score_regex else None,
        score_direction=str(args.score_direction or "lower").strip(),
        scope_files=tuple(str(entry).strip() for entry in (args.scope_files or []) if str(entry).strip()),
        continue_on_pass=bool(args.continue_on_pass),
    )
    session = AutoResearchSession(config)
    summary = session.run()
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"session_id: {summary.get('session_id')}")
        print(f"status: {summary.get('status')}")
        print(f"attempts_completed: {summary.get('attempts_completed')}")
        print(f"successful_attempt: {summary.get('successful_attempt')}")
        print(f"run_tag: {summary.get('run_tag')}")
        print(f"branch_name: {summary.get('branch_name')}")
        print(f"best_score: {summary.get('best_score')}")
        print(f"session_dir: {session.session_dir}")
        print(f"last_error: {summary.get('last_error')}")
    return 0 if str(summary.get("status") or "").strip() == "completed" else 1


def autoresearch_status_command(args: argparse.Namespace) -> int:
    summary = load_session_summary(Path(args.session_root), args.session_ref)
    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"session_id: {summary.get('session_id')}")
        print(f"status: {summary.get('status')}")
        print(f"objective: {summary.get('objective')}")
        print(f"verify_command: {summary.get('verify_command')}")
        print(f"attempts_completed: {summary.get('attempts_completed')}")
        print(f"successful_attempt: {summary.get('successful_attempt')}")
        print(f"run_tag: {summary.get('run_tag')}")
        print(f"branch_name: {summary.get('branch_name')}")
        print(f"best_score: {summary.get('best_score')}")
        print(f"started_at: {summary.get('started_at')}")
        print(f"completed_at: {summary.get('completed_at')}")
        print(f"last_error: {summary.get('last_error')}")
    return 0


def autoresearch_attempts_command(args: argparse.Namespace) -> int:
    attempts = load_session_attempts(Path(args.session_root), args.session_ref)
    if args.json:
        print(json.dumps(attempts, indent=2, sort_keys=True))
        return 0
    for entry in attempts:
        print(
            " | ".join(
                [
                    f"attempt {entry.get('attempt')}",
                    str(entry.get("status") or "-"),
                    str(((entry.get("verifier") or {}).get("score_text") if isinstance(entry.get("verifier"), dict) else "-") or "-"),
                    str(entry.get("description") or "-"),
                ]
            )
        )
    return 0


def render_status_command(args: argparse.Namespace) -> int:
    deadline = time.monotonic() + max(1, int(args.timeout_seconds))
    while True:
        deploys = fetch_render_deploys(str(args.service_id))
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
            return 1
        time.sleep(max(1, int(args.poll_seconds)))


def build_engine(*, require_openai: bool) -> PaperPipelineEngine:
    config = build_local_config(require_openai=require_openai)
    return PaperPipelineEngine(
        config=config,
        openai_client=OpenAIClient(config),
        status_callback=lambda run_id, **kwargs: record_status(run_id, **kwargs),
        metrics_callback=lambda run_id, **kwargs: record_metrics(run_id, **kwargs),
    )


def build_local_config(*, require_openai: bool) -> BootstrapServiceConfig:
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if require_openai and not api_key:
        raise ValueError("Missing OPENAI_API_KEY.")
    return BootstrapServiceConfig(
        github_client_id=os.getenv("GITHUB_CLIENT_ID", "sidekick").strip() or "sidekick",
        github_client_secret=os.getenv("GITHUB_CLIENT_SECRET", "sidekick").strip() or "sidekick",
        backend_base_url=os.getenv("SIDEKICK_BACKEND_BASE_URL", "http://localhost").strip() or "http://localhost",
        openai_api_key=api_key or "sidekick-local-only",
        backend_database_path=str((REPO_ROOT / ".sidekick-runtime" / "sidekick.sqlite3").resolve()),
        backend_artifact_root=str(RUNS_ROOT.resolve()),
        openai_model=os.getenv("SIDEKICK_OPENAI_MODEL", "gpt-5-mini").strip() or "gpt-5-mini",
        openai_search_model=os.getenv("SIDEKICK_OPENAI_SEARCH_MODEL", "gpt-5-mini").strip() or "gpt-5-mini",
        openai_validation_model=os.getenv("SIDEKICK_OPENAI_VALIDATION_MODEL", "gpt-5-mini").strip() or "gpt-5-mini",
        openai_workspace_model=os.getenv("SIDEKICK_OPENAI_WORKSPACE_MODEL", "gpt-5.4").strip() or "gpt-5.4",
        openai_writer_model=os.getenv("SIDEKICK_OPENAI_WRITER_MODEL", "gpt-5.4").strip() or "gpt-5.4",
        openai_reasoning_effort=os.getenv("SIDEKICK_OPENAI_REASONING_EFFORT", "").strip(),
        openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").strip() or "https://api.openai.com/v1",
        encryption_secret=os.getenv("SIDEKICK_ENCRYPTION_SECRET", "sidekick-secret").strip() or "sidekick-secret",
    )


def record_status(run_id: str, *, stage: str, progress_message: str, status: str | None = None, openai_response_id: str | None = None) -> None:
    del openai_response_id
    store = SidekickRunStore(run_id=run_id, root=RUNS_ROOT)
    current = store.read_state()
    current["current_stage"] = stage
    current["status"] = status or current.get("status") or "running"
    current["progress_message"] = progress_message
    store.write_state(current)


def record_metrics(run_id: str, *, model: str, input_tokens: int, output_tokens: int) -> None:
    metrics_path = run_directory(run_id) / "metrics.jsonl"
    with metrics_path.open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {
                    "timestamp": iso_now(),
                    "run_id": run_id,
                    "model": model,
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                },
                sort_keys=True,
            )
            + "\n"
        )


def build_status_payload(run_dir: Path) -> dict[str, Any]:
    state = read_json_file(run_dir / "state.json") if (run_dir / "state.json").exists() else {}
    updated_at = str(state.get("updated_at") or "").strip()
    health = "unknown"
    if state.get("status") in {"completed", "failed", "cancelled"}:
        health = "terminal"
    elif updated_at:
        try:
            delta = datetime.now(tz=UTC) - datetime.fromisoformat(updated_at)
            health = "stalled" if delta.total_seconds() > 120 else "healthy"
        except ValueError:
            health = "healthy"
    return {
        "run_id": run_dir.name,
        "title": state.get("title"),
        "status": state.get("status"),
        "current_stage": state.get("current_stage"),
        "current_agent": state.get("current_agent"),
        "progress_message": state.get("progress_message"),
        "started_at": state.get("started_at"),
        "updated_at": state.get("updated_at"),
        "completed_at": state.get("completed_at"),
        "exit_code": state.get("exit_code"),
        "health": health,
        "run_dir": str(run_dir),
    }


def print_status_payload(payload: dict[str, Any]) -> None:
    print(f"run_id: {payload.get('run_id')}")
    print(f"status: {payload.get('status')}")
    print(f"stage: {payload.get('current_stage')}")
    print(f"agent: {payload.get('current_agent')}")
    print(f"health: {payload.get('health')}")
    print(f"message: {payload.get('progress_message')}")
    print(f"elapsed: {payload.get('started_at')} -> {payload.get('updated_at')}")


def stream_jsonl_command(path: Path, args: argparse.Namespace, stage_filter: str | None, level_filter: str | None) -> int:
    def filtered_rows() -> list[dict[str, Any]]:
        rows = iter_jsonl(path)
        if stage_filter:
            rows = [row for row in rows if str(row.get("stage") or "") == stage_filter]
        if level_filter:
            rows = [row for row in rows if str(row.get("level") or "") == level_filter]
        if getattr(args, "since", None):
            rows = [row for row in rows if str(row.get("timestamp") or "") >= str(args.since)]
        if getattr(args, "tail", None):
            rows = rows[-max(0, int(args.tail)) :]
        return rows

    def print_rows(rows: list[dict[str, Any]]) -> None:
        for row in rows:
            if getattr(args, "json", False):
                print(json.dumps(row, sort_keys=True))
            else:
                print(" | ".join([str(row.get("timestamp") or "-"), str(row.get("stage") or "-"), str(row.get("level") or row.get("event") or "-"), str(row.get("message") or row.get("event") or "-")]))

    if not getattr(args, "follow", False):
        print_rows(filtered_rows())
        return 0
    position = 0
    while True:
        if not path.exists():
            time.sleep(0.5)
            continue
        with path.open("r", encoding="utf-8") as handle:
            handle.seek(position)
            lines = handle.readlines()
            position = handle.tell()
        rows = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            payload = json.loads(stripped)
            if stage_filter and str(payload.get("stage") or "") != stage_filter:
                continue
            if level_filter and str(payload.get("level") or "") != level_filter:
                continue
            rows.append(payload)
        print_rows(rows)
        time.sleep(0.5)


def log_path(run_dir: Path, stage: str | None) -> Path:
    if stage:
        return run_dir / "logs" / f"stage-{stage}.log"
    return run_dir / "logs" / "combined.log"


def latest_active_call(run_dir: Path, *, stage: str | None) -> str | None:
    candidates = []
    for path in sorted((run_dir / "calls").glob("call_*.json")):
        payload = read_json_file(path)
        if stage and str(payload.get("stage") or "") != stage:
            continue
        if str(payload.get("status") or "") != "running":
            continue
        candidates.append((str(payload.get("started_at") or ""), str(payload.get("call_id") or "")))
    if not candidates:
        return None
    candidates.sort()
    return candidates[-1][1]


def fetch_render_deploys(service_id: str) -> list[dict[str, Any]]:
    completed = subprocess.run(
        ["render", "deploys", "list", str(service_id), "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(completed.stdout or "[]")
    return [entry for entry in payload if isinstance(entry, dict)] if isinstance(payload, list) else []


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
        "service": {"id": service_id, "name": service_name, "url": service_url},
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
        "updated_at": str(deploy.get("updatedAt") or "").strip() or None,
        "commit_id": str(commit.get("id") or "").strip() or None,
        "commit_message": str(commit.get("message") or "").strip() or None,
    }


def print_render_status(payload: dict[str, Any]) -> None:
    service = payload.get("service") if isinstance(payload.get("service"), dict) else {}
    print(f"service: {service.get('name')} ({service.get('id')})")
    print(f"url: {service.get('url')}")
    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    if selected:
        print(f"selected: {selected.get('status')} {selected.get('id')} {selected.get('commit_id')}")
    live = payload.get("live_deploy") if isinstance(payload.get("live_deploy"), dict) else None
    if live:
        print(f"live: {live.get('status')} {live.get('id')} {live.get('commit_id')}")


def resolve_hosted_backend_url(value: str | None) -> str:
    if value and str(value).strip():
        return str(value).strip().rstrip("/")
    config = load_sidekick_config()
    configured = str(config.get("hosted_backend_url") or "").strip()
    if configured:
        return configured.rstrip("/")
    env_value = str(os.getenv("SIDEKICK_BACKEND_BASE_URL", "")).strip()
    if env_value:
        return env_value.rstrip("/")
    raise ValueError("Missing hosted backend URL. Use --backend-url or set config hosted_backend_url.")


def resolve_hosted_device_id(value: str | None) -> str:
    if value and str(value).strip():
        return str(value).strip()
    config = load_sidekick_config()
    configured = str(config.get("hosted_device_id") or "").strip()
    if configured:
        return configured
    generated = f"sidekick-cli-{generate_run_id('device')}"
    save_hosted_config(device_id=generated)
    return generated


def resolve_hosted_session_token(value: str | None) -> str:
    if value and str(value).strip():
        return str(value).strip()
    config = load_sidekick_config()
    configured = str(config.get("hosted_session_token") or "").strip()
    if configured:
        return configured
    raise ValueError("Missing hosted session token. Run `sidekick hosted session` first or pass --session-token.")


def save_hosted_config(
    *,
    backend_url: str | None = None,
    device_id: str | None = None,
    session_token: str | None = None,
    install_session_id: str | None = None,
) -> None:
    payload = load_sidekick_config()
    if backend_url is not None:
        payload["hosted_backend_url"] = backend_url
    if device_id is not None:
        payload["hosted_device_id"] = device_id
    if session_token is not None:
        payload["hosted_session_token"] = session_token
    if install_session_id is not None:
        payload["hosted_install_session_id"] = install_session_id
    save_sidekick_config(payload)


def hosted_request_json(
    method: str,
    backend_url: str,
    path: str,
    *,
    session_token: str | None = None,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    url = f"{backend_url.rstrip('/')}{path}"
    headers = {"Content-Type": "application/json"} if body is not None else {}
    if session_token:
        headers["Authorization"] = f"Bearer {session_token}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = Request(url=url, data=data, headers=headers, method=method.upper())
    try:
        with urlopen(request, timeout=60) as response:
            raw_payload = response.read()
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise ValueError(f"Hosted request failed with HTTP {error.code}: {detail}") from error
    except URLError as error:
        raise ValueError(f"Hosted request failed: {error.reason}") from error

    if not raw_payload:
        return {}
    decoded = json.loads(raw_payload.decode("utf-8"))
    if not isinstance(decoded, dict):
        raise ValueError("Hosted backend returned an unexpected payload.")
    return decoded


def print_hosted_job_payload(payload: dict[str, Any]) -> None:
    print(f"job_id: {payload.get('job_id')}")
    print(f"status: {payload.get('status')}")
    print(f"stage: {payload.get('stage')}")
    print(f"message: {payload.get('progress_message')}")
    print(f"openai_response_id: {payload.get('openai_response_id')}")
    print(f"updated_at: {payload.get('updated_at')}")
    print(f"repo_path: {payload.get('repo_path')}")
    metrics = payload.get("metrics") if isinstance(payload.get("metrics"), dict) else {}
    if metrics:
        print(f"model: {metrics.get('model')}")
        print(f"tokens: in={metrics.get('input_tokens')} out={metrics.get('output_tokens')}")
        print(f"estimated_cost_usd: {metrics.get('estimated_cost_usd')}")


def render_wait_completed(payload: dict[str, Any], *, commit_ref: str | None) -> bool:
    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    if commit_ref and selected is None:
        return False
    status = str((selected or {}).get("status") or "").strip()
    return status in {"live", "build_failed", "update_failed", "canceled", "failed", "deactivated"}


def render_wait_exit_code(payload: dict[str, Any], *, commit_ref: str | None) -> int:
    selected = payload.get("selected_deploy") if isinstance(payload.get("selected_deploy"), dict) else None
    if commit_ref and selected is None:
        return 1
    return 0 if str((selected or {}).get("status") or "").strip() == "live" else 1


def run_directory(run_id: str) -> Path:
    directory = RUNS_ROOT / run_id
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def resolve_run_directory(run_ref: str) -> Path:
    if run_ref == "latest":
        candidates = [path for path in RUNS_ROOT.iterdir() if path.is_dir()]
        if not candidates:
            raise FileNotFoundError("No Sidekick runs exist yet.")
        return max(candidates, key=lambda path: path.stat().st_mtime)
    candidate = Path(run_ref).expanduser()
    if candidate.exists():
        return candidate.resolve()
    candidate = RUNS_ROOT / run_ref
    if candidate.exists():
        return candidate.resolve()
    raise FileNotFoundError(f"Unknown run reference: {run_ref}")


def derive_title(note: str) -> str:
    for line in note.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:120]
    return "Untitled research run"


def resolve_note_text(note: str | None, notes_file: str | None) -> str:
    if note and note.strip():
        return note.strip()
    if notes_file and notes_file.strip():
        return Path(notes_file).expanduser().resolve().read_text(encoding="utf-8").strip()
    return ""


def generate_run_id(title: str) -> str:
    timestamp = datetime.now(tz=UTC).strftime("%Y%m%d-%H%M%S")
    slug = re_slug(title)
    return f"{timestamp}-{slug}"


def re_slug(value: str) -> str:
    normalized = value.strip().lower()
    normalized = "".join(character if character.isalnum() else "-" for character in normalized)
    normalized = "-".join(part for part in normalized.split("-") if part)
    return normalized or "paper-run"


def exit_code_for_stage(stage: str) -> int:
    if stage == "1":
        return 1
    if stage == "2.5":
        return 2
    if stage == "3":
        return 3
    if stage == "4":
        return 4
    return 20


def iso_now() -> str:
    return datetime.now(tz=UTC).isoformat()


if __name__ == "__main__":
    raise SystemExit(main())
