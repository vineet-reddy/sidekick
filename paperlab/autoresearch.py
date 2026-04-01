from __future__ import annotations

import json
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from github_bootstrap_service.bootstrap_service.pipeline_runtime import (
    atomic_write_json,
    append_jsonl,
    ensure_directory,
)

DEFAULT_AUTORESEARCH_ROOT = Path.home() / ".sidekick" / "autoresearch"
DEFAULT_PROGRAM_PATH = Path(__file__).resolve().with_name("autoresearch_program.md")
DEFAULT_VERIFIER_TIMEOUT_SECONDS = 1800
RECENT_RESULTS_LIMIT = 12
FAILURE_PATTERNS = (
    re.compile(r"(\d+)\s+failed\b", re.IGNORECASE),
    re.compile(r"failures=(\d+)", re.IGNORECASE),
    re.compile(r"errors=(\d+)", re.IGNORECASE),
)


def iso_now() -> str:
    return datetime.now(tz=UTC).isoformat()


def default_run_tag() -> str:
    current = datetime.now(tz=UTC)
    return current.strftime("%b").lower() + str(current.day)


@dataclass(frozen=True)
class CommandResult:
    command: str
    cwd: str
    exit_code: int
    started_at: str
    completed_at: str
    duration_ms: int
    stdout_path: str | None = None
    stderr_path: str | None = None
    stdout_excerpt: str = ""
    stderr_excerpt: str = ""
    timed_out: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "command": self.command,
            "cwd": self.cwd,
            "exit_code": self.exit_code,
            "started_at": self.started_at,
            "completed_at": self.completed_at,
            "duration_ms": self.duration_ms,
            "stdout_path": self.stdout_path,
            "stderr_path": self.stderr_path,
            "stdout_excerpt": self.stdout_excerpt,
            "stderr_excerpt": self.stderr_excerpt,
            "timed_out": self.timed_out,
        }


@dataclass(frozen=True)
class VerifierOutcome:
    score: float | None
    metric_name: str
    score_text: str
    summary: str
    verifier_status: str
    exit_code: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "score": self.score,
            "metric_name": self.metric_name,
            "score_text": self.score_text,
            "summary": self.summary,
            "verifier_status": self.verifier_status,
            "exit_code": self.exit_code,
        }


@dataclass(frozen=True)
class AutoResearchConfig:
    objective: str
    verify_command: str
    repo_root: Path
    source_worktree: Path
    session_root: Path = DEFAULT_AUTORESEARCH_ROOT
    program_path: Path = DEFAULT_PROGRAM_PATH
    codex_bin: str = "codex"
    model: str | None = None
    search_enabled: bool = False
    yolo: bool = False
    max_attempts: int = 0
    time_budget_minutes: int = 480
    allow_dirty: bool = False
    run_tag: str | None = None
    branch_name: str | None = None
    create_branch: bool = True
    verifier_timeout_seconds: int = DEFAULT_VERIFIER_TIMEOUT_SECONDS
    score_regex: str | None = None
    score_direction: str = "lower"
    scope_files: tuple[str, ...] = ()
    continue_on_pass: bool = False


class AutoResearchError(RuntimeError):
    pass


class AutoResearchSession:
    def __init__(self, config: AutoResearchConfig):
        self.config = config
        self.repo_root = config.repo_root.expanduser().resolve()
        self.source_worktree = config.source_worktree.expanduser().resolve()
        self.run_tag = (config.run_tag or default_run_tag()).strip()
        self.branch_name = (config.branch_name or f"autoresearch/{self.run_tag}").strip()
        self.session_id = self._generate_session_id(self.run_tag)
        self.session_dir = ensure_directory(config.session_root.expanduser().resolve() / self.session_id)
        self.worktrees_dir = ensure_directory(self.session_dir / "worktrees")
        self.results_tsv_path = self.session_dir / "results.tsv"
        self.attempts_path = self.session_dir / "attempts.jsonl"
        self.state_path = self.session_dir / "state.json"
        self.program_copy_path = self.session_dir / "program.md"
        self.scope_manifest_path = self.session_dir / "scope_files.txt"
        self.program_text = config.program_path.expanduser().resolve().read_text(encoding="utf-8").strip()
        self.program_copy_path.write_text(self.program_text + "\n", encoding="utf-8")
        self.scope_manifest_path.write_text("\n".join(self.config.scope_files) + ("\n" if self.config.scope_files else ""), encoding="utf-8")
        self._initialize_results_tsv()
        self._write_state(
            {
                "session_id": self.session_id,
                "session_dir": str(self.session_dir),
                "status": "queued",
                "objective": config.objective,
                "verify_command": config.verify_command,
                "repo_root": str(self.repo_root),
                "source_worktree": str(self.source_worktree),
                "run_tag": self.run_tag,
                "branch_name": self.branch_name,
                "program_path": str(config.program_path.expanduser().resolve()),
                "program_copy_path": str(self.program_copy_path),
                "scope_manifest_path": str(self.scope_manifest_path),
                "codex_bin": config.codex_bin,
                "model": config.model,
                "search_enabled": config.search_enabled,
                "yolo": config.yolo,
                "max_attempts": config.max_attempts,
                "time_budget_minutes": config.time_budget_minutes,
                "allow_dirty": config.allow_dirty,
                "create_branch": config.create_branch,
                "verifier_timeout_seconds": config.verifier_timeout_seconds,
                "score_regex": config.score_regex,
                "score_direction": config.score_direction,
                "continue_on_pass": config.continue_on_pass,
                "started_at": None,
                "completed_at": None,
                "best_head": None,
                "best_score": None,
                "best_metric_name": None,
                "best_summary": None,
                "attempts_completed": 0,
                "baseline_complete": False,
                "successful_attempt": None,
                "last_error": None,
            }
        )

    def run(self) -> dict[str, Any]:
        self._ensure_source_ready()
        self._ensure_session_branch()
        self._write_state({"status": "running", "started_at": iso_now(), "completed_at": None, "last_error": None})
        baseline = self._run_baseline()
        best_score = baseline["verifier"]["score"]
        best_status = str(baseline["verifier"]["verifier_status"] or "")
        best_head = str(baseline["commit"] or "")
        if best_status == "pass" and not self.config.continue_on_pass:
            self._write_state({"status": "completed", "completed_at": iso_now(), "successful_attempt": 0})
            return self.summary()

        deadline = time.monotonic() + max(1, int(self.config.time_budget_minutes)) * 60
        attempt = 1
        while not self._attempt_limit_reached(attempt) and time.monotonic() < deadline:
            record = self._run_attempt(
                attempt=attempt,
                best_head=best_head,
                best_score=best_score,
                best_status=best_status,
            )
            append_jsonl(self.attempts_path, record)
            self._write_state(
                {
                    "attempts_completed": attempt,
                    "successful_attempt": attempt if record.get("status") == "keep" and str((record.get("verifier") or {}).get("verifier_status") or "") == "pass" else None,
                    "last_error": record.get("failure_summary"),
                }
            )
            if record.get("status") == "keep":
                best_head = str(record.get("kept_head") or best_head)
                verifier = record.get("verifier") if isinstance(record.get("verifier"), dict) else {}
                best_score = verifier.get("score")
                best_status = str(verifier.get("verifier_status") or best_status)
                self._write_state(
                    {
                        "best_head": best_head,
                        "best_score": best_score,
                        "best_metric_name": verifier.get("metric_name"),
                        "best_summary": verifier.get("summary"),
                    }
                )
                if best_status == "pass" and not self.config.continue_on_pass:
                    self._write_state({"status": "completed", "completed_at": iso_now(), "successful_attempt": attempt})
                    return self.summary()
            attempt += 1
        final_status = "failed"
        if time.monotonic() >= deadline:
            final_status = "timed_out"
        self._write_state({"status": final_status, "completed_at": iso_now()})
        return self.summary()

    def summary(self) -> dict[str, Any]:
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def iter_attempts(self) -> list[dict[str, Any]]:
        if not self.attempts_path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with self.attempts_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped:
                    continue
                payload = json.loads(stripped)
                if isinstance(payload, dict):
                    rows.append(payload)
        return rows

    def _run_baseline(self) -> dict[str, Any]:
        baseline_dir = ensure_directory(self.session_dir / "baseline")
        baseline_head = self._git_output("rev-parse HEAD", cwd=self.source_worktree)
        verify_result = self._run_verifier(cwd=self.source_worktree, output_dir=baseline_dir)
        verifier = self._score_verifier(verify_result)
        short_head = self._short_commit(baseline_head)
        self._append_results_row(
            commit=short_head,
            score_text=verifier.score_text,
            duration_s=f"{verify_result.duration_ms / 1000:.1f}",
            status="keep",
            description="baseline",
        )
        record = {
            "attempt": 0,
            "status": "keep",
            "description": "baseline",
            "commit": baseline_head,
            "short_commit": short_head,
            "verifier": verifier.as_dict(),
            "verify_command": verify_result.as_dict(),
            "failure_summary": "" if verifier.verifier_status == "pass" else verifier.summary,
        }
        self._write_json(baseline_dir / "baseline.json", record)
        self._write_state(
            {
                "baseline_complete": True,
                "best_head": baseline_head,
                "best_score": verifier.score,
                "best_metric_name": verifier.metric_name,
                "best_summary": verifier.summary,
            }
        )
        return record

    def _run_attempt(self, *, attempt: int, best_head: str, best_score: float | None, best_status: str) -> dict[str, Any]:
        branch_name = f"{self.branch_name}-attempt-{attempt:03d}"
        worktree_path = self.worktrees_dir / f"attempt-{attempt:03d}"
        attempt_dir = ensure_directory(self.session_dir / f"attempt-{attempt:03d}")
        self._run_git(f"worktree add -b {branch_name} {shlex.quote(str(worktree_path))} {best_head}", cwd=self.repo_root)
        codex_result: CommandResult | None = None
        verifier_result: CommandResult | None = None
        try:
            prompt = self._build_codex_prompt(
                attempt=attempt,
                best_head=best_head,
                best_score=best_score,
                best_status=best_status,
            )
            (attempt_dir / "prompt.md").write_text(prompt, encoding="utf-8")
            codex_result = self._run_codex(prompt=prompt, cwd=worktree_path, attempt_dir=attempt_dir)
            candidate_head = self._ensure_candidate_commit(worktree_path=worktree_path, base_head=best_head, attempt=attempt)
            description = self._attempt_description(attempt_dir, attempt)
            if candidate_head is None:
                self._append_results_row(
                    commit=self._short_commit(best_head),
                    score_text=self._score_text(best_score),
                    duration_s="0.0",
                    status="discard",
                    description=f"{description} (no code change)",
                )
                return {
                    "attempt": attempt,
                    "status": "discard",
                    "description": description,
                    "base_head": best_head,
                    "kept_head": None,
                    "commit": best_head,
                    "short_commit": self._short_commit(best_head),
                    "verifier": None,
                    "codex": codex_result.as_dict() if codex_result else None,
                    "failure_summary": "Codex exited without producing a committed code change.",
                }

            verifier_result = self._run_verifier(cwd=worktree_path, output_dir=attempt_dir)
            verifier = self._score_verifier(verifier_result)
            improvement = self._is_improvement(
                candidate_score=verifier.score,
                candidate_status=verifier.verifier_status,
                best_score=best_score,
                best_status=best_status,
            )
            status = "keep" if improvement else ("crash" if verifier.verifier_status == "crash" else "discard")
            kept_head: str | None = None
            applied_commits: list[str] = []
            if improvement:
                applied_commits = self._apply_candidate(base_head=best_head, candidate_head=candidate_head)
                kept_head = self._git_output("rev-parse HEAD", cwd=self.source_worktree)
            self._append_results_row(
                commit=self._short_commit(candidate_head),
                score_text=verifier.score_text,
                duration_s=f"{verifier_result.duration_ms / 1000:.1f}",
                status=status,
                description=description,
            )
            return {
                "attempt": attempt,
                "status": status,
                "description": description,
                "base_head": best_head,
                "commit": candidate_head,
                "short_commit": self._short_commit(candidate_head),
                "kept_head": kept_head,
                "applied_commits": applied_commits,
                "codex": codex_result.as_dict() if codex_result else None,
                "verify_command": verifier_result.as_dict(),
                "verifier": verifier.as_dict(),
                "failure_summary": "" if improvement or verifier.verifier_status == "pass" else verifier.summary,
            }
        finally:
            self._cleanup_attempt(branch_name=branch_name, worktree_path=worktree_path)

    def _ensure_source_ready(self) -> None:
        repo_root = self._git_output("rev-parse --show-toplevel", cwd=self.source_worktree)
        if Path(repo_root).resolve() != self.repo_root:
            raise AutoResearchError("source_worktree must belong to repo_root.")
        git_dir = self._git_output("rev-parse --git-dir", cwd=self.source_worktree)
        if "worktrees" not in git_dir:
            raise AutoResearchError("Run autoresearch from a dedicated git worktree, not the primary checkout.")
        if not self.config.allow_dirty:
            status = self._git_status(cwd=self.source_worktree)
            if status.strip():
                raise AutoResearchError("Source worktree must be clean before autoresearch starts. Commit or stash local changes first.")

    def _ensure_session_branch(self) -> None:
        current_branch = self._git_output("branch --show-current", cwd=self.source_worktree)
        if current_branch == self.branch_name:
            return
        if not self.config.create_branch:
            raise AutoResearchError(
                f"Source worktree is on branch `{current_branch}`. Switch to `{self.branch_name}` or rerun with branch creation enabled."
            )
        if self._branch_exists(self.branch_name):
            raise AutoResearchError(f"Branch `{self.branch_name}` already exists. Use a new --run-tag or switch the worktree onto that branch explicitly.")
        self._run_git(f"checkout -b {self.branch_name}", cwd=self.source_worktree)

    def _build_codex_prompt(self, *, attempt: int, best_head: str, best_score: float | None, best_status: str) -> str:
        recent_results = self._recent_results_tsv()
        best_log_excerpt = self._latest_best_excerpt()
        scope_text = "\n".join(f"- {path}" for path in self.config.scope_files) if self.config.scope_files else "- Entire repository, prioritizing harness and pipeline code paths relevant to the verifier."
        metric_text = self._metric_description()
        return (
            f"{self.program_text}\n\n"
            "## Session Setup\n"
            f"- Objective: {self.config.objective}\n"
            f"- Run tag: {self.run_tag}\n"
            f"- Advancing branch: {self.branch_name}\n"
            f"- Attempt number: {attempt}\n"
            f"- Current best commit: {best_head}\n"
            f"- Current best status: {best_status}\n"
            f"- Current best score: {self._score_text(best_score)}\n"
            f"- Verifier command: `{self.config.verify_command}`\n"
            f"- Metric policy: {metric_text}\n"
            "\n## In-Scope Files\n"
            f"{scope_text}\n"
            "\n## Recent Results\n"
            "```tsv\n"
            f"{recent_results}\n"
            "```\n"
            "\n## Best Known Failure Context\n"
            "```text\n"
            f"{best_log_excerpt}\n"
            "```\n"
            "\n## Required Behavior\n"
            "- Work like an autonomous overnight repair engineer for the Sidekick service and CLI harness.\n"
            "- Use the current worktree as a disposable experiment branch off the current best commit.\n"
            "- Read the in-scope files, inspect logs, and form one concrete repair hypothesis.\n"
            "- Make code changes, run the verifier command yourself, and iterate inside this worktree until you have your best candidate for this attempt.\n"
            "- Prefer durable fixes that improve the pipeline, backend service, CLI harness, or tests over hacks that only silence a symptom.\n"
            "- If the verifier still fails, leave the worktree in the most promising state you found for this attempt.\n"
            "- Do not stop to ask for confirmation. Keep working until this attempt has a concrete outcome.\n"
            "\n## Final Response Format\n"
            "- First line: a short experiment description of at most 12 words.\n"
            "- Then 2-6 concise lines covering the root cause, the code changes, and the verifier result.\n"
        )

    def _run_codex(self, *, prompt: str, cwd: Path, attempt_dir: Path) -> CommandResult:
        stdout_path = attempt_dir / "codex.jsonl"
        stderr_path = attempt_dir / "codex.stderr.log"
        last_message_path = attempt_dir / "codex-last-message.txt"
        command = [
            self.config.codex_bin,
            "exec",
            "-",
            "--cd",
            str(cwd),
            "--json",
            "--output-last-message",
            str(last_message_path),
            "--color",
            "never",
        ]
        if self.config.model:
            command.extend(["--model", self.config.model])
        if self.config.search_enabled:
            command.append("--search")
        if self.config.yolo:
            command.append("--dangerously-bypass-approvals-and-sandbox")
        else:
            command.extend(["--sandbox", "workspace-write"])
        return self._run_process_logged(
            command=command,
            cwd=cwd,
            input_text=prompt,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            timeout_seconds=None,
        )

    def _run_verifier(self, *, cwd: Path, output_dir: Path) -> CommandResult:
        return self._run_shell_logged(
            command=self.config.verify_command,
            cwd=cwd,
            log_path=output_dir / "verify.log",
            timeout_seconds=max(1, int(self.config.verifier_timeout_seconds)),
        )

    def _score_verifier(self, result: CommandResult) -> VerifierOutcome:
        combined = result.stdout_excerpt.strip()
        full_text = ""
        if result.stdout_path:
            full_text = Path(result.stdout_path).read_text(encoding="utf-8", errors="replace")
        metric_name = "failure_count"
        score: float | None = None
        if self.config.score_regex:
            regex = re.compile(self.config.score_regex, re.MULTILINE)
            match = regex.search(full_text)
            if match:
                try:
                    score = float(match.group(1))
                except (IndexError, ValueError):
                    score = None
                metric_name = "custom_score"
        if score is None:
            parsed_failure_count = self._parse_failure_count(full_text)
            if parsed_failure_count is not None:
                score = float(parsed_failure_count)
                metric_name = "failure_count"
        if score is None and result.exit_code == 0:
            score = 0.0
            metric_name = "failure_count"

        if result.timed_out:
            return VerifierOutcome(
                score=None,
                metric_name=metric_name,
                score_text="timeout",
                summary=f"Verifier exceeded {self.config.verifier_timeout_seconds} seconds.",
                verifier_status="crash",
                exit_code=result.exit_code,
            )
        if result.exit_code == 0:
            return VerifierOutcome(
                score=score,
                metric_name=metric_name,
                score_text=self._score_text(score),
                summary="Verifier passed cleanly.",
                verifier_status="pass",
                exit_code=result.exit_code,
            )
        if score is not None:
            plural = "" if int(score) == 1 else "s"
            return VerifierOutcome(
                score=score,
                metric_name=metric_name,
                score_text=self._score_text(score),
                summary=f"Verifier still reports {int(score)} failing check{plural}.",
                verifier_status="fail",
                exit_code=result.exit_code,
            )
        failure_excerpt = self._clip_text(full_text.strip() or combined or "Verifier failed without parseable output.", limit=500)
        return VerifierOutcome(
            score=None,
            metric_name=metric_name,
            score_text="crash",
            summary=failure_excerpt,
            verifier_status="crash",
            exit_code=result.exit_code,
        )

    def _is_improvement(
        self,
        *,
        candidate_score: float | None,
        candidate_status: str,
        best_score: float | None,
        best_status: str,
    ) -> bool:
        if candidate_status == "pass" and best_status != "pass":
            return True
        if candidate_status == "pass" and best_status == "pass":
            if candidate_score is None or best_score is None:
                return False
            return self._score_better(candidate_score, best_score)
        if candidate_score is None:
            return False
        if best_score is None:
            return candidate_status != "crash"
        return self._score_better(candidate_score, best_score)

    def _score_better(self, candidate: float, best: float) -> bool:
        direction = str(self.config.score_direction or "lower").strip().lower()
        if direction == "higher":
            return candidate > best
        return candidate < best

    def _ensure_candidate_commit(self, *, worktree_path: Path, base_head: str, attempt: int) -> str | None:
        status = self._git_status(cwd=worktree_path)
        current_head = self._git_output("rev-parse HEAD", cwd=worktree_path)
        if not status.strip() and current_head == base_head:
            return None
        if status.strip():
            self._run_git("add -A", cwd=worktree_path)
            self._run_git(f"commit -m {shlex.quote(f'autoresearch attempt {attempt:03d}')} --no-gpg-sign", cwd=worktree_path)
        candidate_head = self._git_output("rev-parse HEAD", cwd=worktree_path)
        return candidate_head if candidate_head != base_head else None

    def _apply_candidate(self, *, base_head: str, candidate_head: str) -> list[str]:
        commits = self._git_output(f"rev-list --reverse {base_head}..{candidate_head}", cwd=self.repo_root)
        commit_list = [line.strip() for line in commits.splitlines() if line.strip()]
        if not commit_list:
            raise AutoResearchError("No commits were available to apply from the successful attempt.")
        for commit in commit_list:
            try:
                self._run_git(f"cherry-pick {commit} --allow-empty", cwd=self.source_worktree)
            except AutoResearchError as error:
                try:
                    self._run_git("cherry-pick --abort", cwd=self.source_worktree)
                except AutoResearchError:
                    pass
                raise AutoResearchError(f"Failed to apply successful attempt commit {commit}: {error}") from error
        return commit_list

    def _cleanup_attempt(self, *, branch_name: str, worktree_path: Path) -> None:
        try:
            self._run_git(f"worktree remove --force {shlex.quote(str(worktree_path))}", cwd=self.repo_root)
        except AutoResearchError:
            pass
        try:
            self._run_git(f"branch -D {branch_name}", cwd=self.repo_root)
        except AutoResearchError:
            pass

    def _run_git(self, command: str, *, cwd: Path) -> CommandResult:
        result = self._run_shell(command=f"git {command}", cwd=cwd)
        if result.exit_code != 0:
            raise AutoResearchError(result.stderr_excerpt or result.stdout_excerpt or f"`git {command}` failed.")
        return result

    def _git_output(self, command: str, *, cwd: Path) -> str:
        return self._run_git(command, cwd=cwd).stdout_excerpt.strip()

    def _git_status(self, *, cwd: Path) -> str:
        return self._run_shell(command="git status --short", cwd=cwd).stdout_excerpt

    def _branch_exists(self, branch_name: str) -> bool:
        result = self._run_process(
            command=["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch_name}"],
            cwd=self.repo_root,
        )
        return result.exit_code == 0

    def _run_shell(self, *, command: str, cwd: Path) -> CommandResult:
        return self._run_process(command=[self._default_shell(), "-lc", command], cwd=cwd)

    def _run_shell_logged(self, *, command: str, cwd: Path, log_path: Path, timeout_seconds: int) -> CommandResult:
        started = datetime.now(tz=UTC)
        started_at = started.isoformat()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        timed_out = False
        exit_code = 0
        with log_path.open("w", encoding="utf-8") as output_handle:
            try:
                completed = subprocess.run(
                    [self._default_shell(), "-lc", command],
                    cwd=str(cwd),
                    stdout=output_handle,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=timeout_seconds,
                )
                exit_code = int(completed.returncode)
            except subprocess.TimeoutExpired:
                timed_out = True
                exit_code = 124
                output_handle.write(f"\n[autoresearch] verifier timed out after {timeout_seconds} seconds\n")
        ended = datetime.now(tz=UTC)
        excerpt = self._tail_text(log_path)
        return CommandResult(
            command=command,
            cwd=str(cwd),
            exit_code=exit_code,
            started_at=started_at,
            completed_at=ended.isoformat(),
            duration_ms=int((ended - started).total_seconds() * 1000),
            stdout_path=str(log_path),
            stdout_excerpt=excerpt,
            timed_out=timed_out,
        )

    def _run_process(
        self,
        *,
        command: list[str],
        cwd: Path,
        input_text: str | None = None,
        timeout_seconds: int | None = None,
    ) -> CommandResult:
        started = datetime.now(tz=UTC)
        started_at = started.isoformat()
        timed_out = False
        exit_code = 0
        stdout = ""
        stderr = ""
        try:
            completed = subprocess.run(
                command,
                cwd=str(cwd),
                input=input_text,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
            exit_code = int(completed.returncode)
            stdout = str(completed.stdout or "")
            stderr = str(completed.stderr or "")
        except subprocess.TimeoutExpired as error:
            timed_out = True
            exit_code = 124
            stdout = str(error.stdout or "")
            stderr = str(error.stderr or "")
        ended = datetime.now(tz=UTC)
        return CommandResult(
            command=" ".join(shlex.quote(part) for part in command),
            cwd=str(cwd),
            exit_code=exit_code,
            started_at=started_at,
            completed_at=ended.isoformat(),
            duration_ms=int((ended - started).total_seconds() * 1000),
            stdout_excerpt=self._clip_text(stdout.strip(), limit=8000),
            stderr_excerpt=self._clip_text(stderr.strip(), limit=4000),
            timed_out=timed_out,
        )

    def _run_process_logged(
        self,
        *,
        command: list[str],
        cwd: Path,
        stdout_path: Path,
        stderr_path: Path,
        input_text: str | None,
        timeout_seconds: int | None,
    ) -> CommandResult:
        started = datetime.now(tz=UTC)
        started_at = started.isoformat()
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        timed_out = False
        exit_code = 0
        with stdout_path.open("w", encoding="utf-8") as stdout_handle, stderr_path.open("w", encoding="utf-8") as stderr_handle:
            try:
                completed = subprocess.run(
                    command,
                    cwd=str(cwd),
                    input=input_text,
                    stdout=stdout_handle,
                    stderr=stderr_handle,
                    text=True,
                    timeout=timeout_seconds,
                )
                exit_code = int(completed.returncode)
            except subprocess.TimeoutExpired:
                timed_out = True
                exit_code = 124
                stderr_handle.write("[autoresearch] codex command timed out\n")
        ended = datetime.now(tz=UTC)
        return CommandResult(
            command=" ".join(shlex.quote(part) for part in command),
            cwd=str(cwd),
            exit_code=exit_code,
            started_at=started_at,
            completed_at=ended.isoformat(),
            duration_ms=int((ended - started).total_seconds() * 1000),
            stdout_path=str(stdout_path),
            stderr_path=str(stderr_path),
            stdout_excerpt=self._tail_text(stdout_path),
            stderr_excerpt=self._tail_text(stderr_path),
            timed_out=timed_out,
        )

    def _attempt_description(self, attempt_dir: Path, attempt: int) -> str:
        last_message_path = attempt_dir / "codex-last-message.txt"
        if not last_message_path.exists():
            return f"attempt {attempt}"
        lines = [line.strip() for line in last_message_path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
        if not lines:
            return f"attempt {attempt}"
        return self._sanitize_tsv(lines[0])[:140] or f"attempt {attempt}"

    def _metric_description(self) -> str:
        if self.config.score_regex:
            direction = "lower is better" if self.config.score_direction != "higher" else "higher is better"
            return f"Extract numeric score with regex `{self.config.score_regex}`; {direction}; full verifier pass still wins."
        return "Lower is better. The supervisor first tries to parse failing-test/error counts from verifier output; a clean pass scores 0."

    def _latest_best_excerpt(self) -> str:
        baseline_log = self.session_dir / "baseline" / "verify.log"
        if baseline_log.exists():
            return self._clip_text(baseline_log.read_text(encoding="utf-8", errors="replace").strip(), limit=4000) or "(baseline log was empty)"
        return "(no prior verifier log available)"

    def _recent_results_tsv(self) -> str:
        rows = self.results_tsv_path.read_text(encoding="utf-8").splitlines()
        if len(rows) <= 1:
            return rows[0] if rows else "commit\tscore\tduration_s\tstatus\tdescription"
        return "\n".join([rows[0], *rows[-RECENT_RESULTS_LIMIT:]])

    def _initialize_results_tsv(self) -> None:
        if self.results_tsv_path.exists():
            return
        self.results_tsv_path.write_text("commit\tscore\tduration_s\tstatus\tdescription\n", encoding="utf-8")

    def _append_results_row(self, *, commit: str, score_text: str, duration_s: str, status: str, description: str) -> None:
        row = "\t".join(
            [
                self._sanitize_tsv(commit),
                self._sanitize_tsv(score_text),
                self._sanitize_tsv(duration_s),
                self._sanitize_tsv(status),
                self._sanitize_tsv(description),
            ]
        )
        with self.results_tsv_path.open("a", encoding="utf-8") as handle:
            handle.write(row + "\n")

    def _write_state(self, updates: dict[str, Any]) -> None:
        payload: dict[str, Any] = {}
        if self.state_path.exists():
            payload = json.loads(self.state_path.read_text(encoding="utf-8"))
        payload.update(updates)
        payload["updated_at"] = iso_now()
        atomic_write_json(self.state_path, payload)

    @staticmethod
    def _write_json(path: Path, payload: dict[str, Any]) -> None:
        atomic_write_json(path, payload)

    @staticmethod
    def _parse_failure_count(text: str) -> int | None:
        values: list[int] = []
        for pattern in FAILURE_PATTERNS:
            values.extend(int(match) for match in pattern.findall(text))
        if not values:
            return None
        return max(values)

    @staticmethod
    def _tail_text(path: Path, *, limit: int = 6000) -> str:
        if not path.exists():
            return ""
        text = path.read_text(encoding="utf-8", errors="replace")
        if len(text) <= limit:
            return text
        return text[-limit:]

    @staticmethod
    def _score_text(score: float | None) -> str:
        if score is None:
            return "n/a"
        if abs(score - int(score)) < 1e-9:
            return str(int(score))
        return f"{score:.6f}"

    @staticmethod
    def _short_commit(commit: str) -> str:
        return commit[:7]

    @staticmethod
    def _sanitize_tsv(value: str) -> str:
        return str(value).replace("\t", " ").replace("\n", " ").strip()

    @staticmethod
    def _clip_text(value: str, *, limit: int) -> str:
        stripped = value.strip()
        if len(stripped) <= limit:
            return stripped
        return stripped[: limit - 20] + "\n...[truncated]..."

    @staticmethod
    def _default_shell() -> str:
        return "/bin/zsh" if sys.platform == "darwin" else "/bin/bash"

    @staticmethod
    def _generate_session_id(run_tag: str) -> str:
        return datetime.now(tz=UTC).strftime(f"%Y%m%d-%H%M%S-{run_tag}")

    def _attempt_limit_reached(self, next_attempt: int) -> bool:
        max_attempts = int(self.config.max_attempts)
        if max_attempts <= 0:
            return False
        return next_attempt > max_attempts


def resolve_session_directory(session_root: Path, session_ref: str) -> Path:
    root = session_root.expanduser().resolve()
    if session_ref == "latest":
        candidates = [path for path in root.iterdir() if path.is_dir()] if root.exists() else []
        if not candidates:
            raise FileNotFoundError("No autoresearch sessions exist yet.")
        return max(candidates, key=lambda path: path.stat().st_mtime)
    candidate = Path(session_ref).expanduser()
    if candidate.exists():
        return candidate.resolve()
    candidate = root / session_ref
    if candidate.exists():
        return candidate.resolve()
    raise FileNotFoundError(f"Unknown autoresearch session: {session_ref}")


def load_session_summary(session_root: Path, session_ref: str) -> dict[str, Any]:
    session_dir = resolve_session_directory(session_root, session_ref)
    state_path = session_dir / "state.json"
    if not state_path.exists():
        raise FileNotFoundError(f"Missing autoresearch state for {session_dir.name}")
    return json.loads(state_path.read_text(encoding="utf-8"))


def load_session_attempts(session_root: Path, session_ref: str) -> list[dict[str, Any]]:
    session_dir = resolve_session_directory(session_root, session_ref)
    attempts_path = session_dir / "attempts.jsonl"
    if not attempts_path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with attempts_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            payload = json.loads(stripped)
            if isinstance(payload, dict):
                rows.append(payload)
    return rows
