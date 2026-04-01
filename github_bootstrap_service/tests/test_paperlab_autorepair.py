import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from paperlab import cli
from paperlab.autoresearch import AutoResearchConfig, AutoResearchSession


class FakeAutoResearchSession(AutoResearchSession):
    def __init__(
        self,
        config: AutoResearchConfig,
        *,
        baseline_status: str = "fail",
        baseline_score: float | None = 3.0,
        attempts: list[dict[str, object]] | None = None,
    ):
        self._baseline_status = baseline_status
        self._baseline_score = baseline_score
        self._attempts = list(attempts or [])
        self.session_branch_checked = False
        super().__init__(config)

    def _ensure_source_ready(self) -> None:
        return None

    def _ensure_session_branch(self) -> None:
        self.session_branch_checked = True

    def _run_baseline(self) -> dict[str, object]:
        record = {
            "attempt": 0,
            "status": "keep",
            "description": "baseline",
            "commit": "base-commit",
            "short_commit": "base-co",
            "verifier": {
                "score": self._baseline_score,
                "metric_name": "failure_count",
                "score_text": "0" if self._baseline_score == 0 else str(int(self._baseline_score or 0)),
                "summary": "baseline",
                "verifier_status": self._baseline_status,
                "exit_code": 0 if self._baseline_status == "pass" else 1,
            },
            "verify_command": {"command": self.config.verify_command},
            "failure_summary": "" if self._baseline_status == "pass" else "baseline failed",
        }
        baseline_dir = self.session_dir / "baseline"
        baseline_dir.mkdir(parents=True, exist_ok=True)
        self._write_json(baseline_dir / "baseline.json", record)
        self._append_results_row(
            commit="base-co",
            score_text=record["verifier"]["score_text"],
            duration_s="1.0",
            status="keep",
            description="baseline",
        )
        self._write_state(
            {
                "baseline_complete": True,
                "best_head": "base-commit",
                "best_score": self._baseline_score,
                "best_metric_name": "failure_count",
                "best_summary": "baseline",
            }
        )
        return record

    def _run_attempt(self, *, attempt: int, best_head: str, best_score: float | None, best_status: str) -> dict[str, object]:
        payload = dict(self._attempts[attempt - 1])
        payload.setdefault("attempt", attempt)
        payload.setdefault("base_head", best_head)
        payload.setdefault("commit", f"candidate-{attempt}")
        payload.setdefault("short_commit", f"cand-{attempt}")
        payload.setdefault("description", f"attempt {attempt}")
        payload.setdefault("failure_summary", "")
        verifier = payload.get("verifier")
        if verifier is not None and isinstance(verifier, dict):
            payload.setdefault("kept_head", payload["commit"] if payload.get("status") == "keep" else None)
            self._append_results_row(
                commit=str(payload["short_commit"]),
                score_text=str(verifier.get("score_text") or "n/a"),
                duration_s="1.0",
                status=str(payload.get("status") or "discard"),
                description=str(payload.get("description") or ""),
            )
        else:
            self._append_results_row(
                commit=str(payload["short_commit"]),
                score_text="n/a",
                duration_s="0.0",
                status=str(payload.get("status") or "discard"),
                description=str(payload.get("description") or ""),
            )
        return payload


class AutoRepairTests(unittest.TestCase):
    def test_run_short_circuits_when_baseline_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            (root / "repo").mkdir()
            (root / "wt").mkdir()
            (root / "program.md").write_text("program", encoding="utf-8")
            session = FakeAutoResearchSession(
                AutoResearchConfig(
                    objective="Fix the verifier.",
                    verify_command="pytest -q",
                    repo_root=root / "repo",
                    source_worktree=root / "wt",
                    session_root=root / "sessions",
                    program_path=root / "program.md",
                ),
                baseline_status="pass",
                baseline_score=0.0,
            )

            summary = session.run()

            self.assertTrue(session.session_branch_checked)
            self.assertEqual(summary["status"], "completed")
            self.assertEqual(summary["successful_attempt"], 0)
            self.assertEqual(summary["attempts_completed"], 0)

    def test_run_keeps_improvement_and_updates_best_score(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            program = root / "program.md"
            (root / "repo").mkdir()
            (root / "wt").mkdir()
            program.write_text("program", encoding="utf-8")
            session = FakeAutoResearchSession(
                AutoResearchConfig(
                    objective="Fix the verifier.",
                    verify_command="pytest -q",
                    repo_root=root / "repo",
                    source_worktree=root / "wt",
                    session_root=root / "sessions",
                    program_path=program,
                    max_attempts=3,
                ),
                baseline_status="fail",
                baseline_score=4.0,
                attempts=[
                    {
                        "status": "keep",
                        "commit": "better-commit",
                        "short_commit": "better",
                        "description": "reduce failures",
                        "verifier": {
                            "score": 2.0,
                            "metric_name": "failure_count",
                            "score_text": "2",
                            "summary": "2 failing checks remain.",
                            "verifier_status": "fail",
                            "exit_code": 1,
                        },
                    },
                    {
                        "status": "keep",
                        "commit": "pass-commit",
                        "short_commit": "pass",
                        "description": "clean pass",
                        "verifier": {
                            "score": 0.0,
                            "metric_name": "failure_count",
                            "score_text": "0",
                            "summary": "Verifier passed cleanly.",
                            "verifier_status": "pass",
                            "exit_code": 0,
                        },
                    },
                ],
            )

            summary = session.run()
            attempts = session.iter_attempts()
            results_rows = session.results_tsv_path.read_text(encoding="utf-8").splitlines()

            self.assertEqual(summary["status"], "completed")
            self.assertEqual(summary["successful_attempt"], 2)
            self.assertEqual(summary["best_score"], 0.0)
            self.assertEqual(summary["attempts_completed"], 2)
            self.assertEqual([entry["status"] for entry in attempts], ["keep", "keep"])
            self.assertEqual(len(results_rows), 4)

    def test_run_records_failed_session_when_attempts_do_not_improve(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            program = root / "program.md"
            (root / "repo").mkdir()
            (root / "wt").mkdir()
            program.write_text("program", encoding="utf-8")
            session = FakeAutoResearchSession(
                AutoResearchConfig(
                    objective="Fix the verifier.",
                    verify_command="pytest -q",
                    repo_root=root / "repo",
                    source_worktree=root / "wt",
                    session_root=root / "sessions",
                    program_path=program,
                    max_attempts=2,
                ),
                baseline_status="fail",
                baseline_score=2.0,
                attempts=[
                    {
                        "status": "discard",
                        "description": "no improvement",
                        "verifier": {
                            "score": 2.0,
                            "metric_name": "failure_count",
                            "score_text": "2",
                            "summary": "still 2 failing checks",
                            "verifier_status": "fail",
                            "exit_code": 1,
                        },
                        "failure_summary": "still 2 failing checks",
                    },
                    {
                        "status": "crash",
                        "description": "verifier crash",
                        "verifier": {
                            "score": None,
                            "metric_name": "failure_count",
                            "score_text": "crash",
                            "summary": "verifier crashed",
                            "verifier_status": "crash",
                            "exit_code": 124,
                        },
                        "failure_summary": "verifier crashed",
                    },
                ],
            )

            summary = session.run()

            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["successful_attempt"], None)
            self.assertEqual(summary["attempts_completed"], 2)
            self.assertEqual(summary["last_error"], "verifier crashed")

    def test_cli_autorepair_run_uses_autorepair_name(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            repo_root = root / "repo"
            worktree = root / "wt"
            program = root / "program.md"
            repo_root.mkdir()
            worktree.mkdir()
            program.write_text("program", encoding="utf-8")

            class FakeRunner:
                def __init__(self, config: AutoResearchConfig) -> None:
                    self.session_dir = root / "sessions" / "fake"
                    self.config = config

                def run(self) -> dict[str, object]:
                    return {
                        "session_id": "fake",
                        "status": "completed",
                        "attempts_completed": 1,
                        "successful_attempt": 1,
                        "run_tag": "overnight",
                        "branch_name": "autoresearch/overnight",
                        "best_score": 0.0,
                        "last_error": "",
                    }

            with patch("paperlab.cli.AutoResearchSession", FakeRunner):
                exit_code = cli.main(
                    [
                        "autorepair",
                        "run",
                        "--objective",
                        "Improve paper quality.",
                        "--verify",
                        "python3 verify.py",
                        "--repo-root",
                        str(repo_root),
                        "--source-worktree",
                        str(worktree),
                        "--program",
                        str(program),
                        "--session-root",
                        str(root / "sessions"),
                    ]
                )

            self.assertEqual(exit_code, 0)

    def test_cli_autorepair_status_and_attempts_read_session(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            session_root = root / "sessions"
            session_dir = session_root / "20260401-010203-overnight"
            session_dir.mkdir(parents=True)
            (session_dir / "state.json").write_text(
                json.dumps(
                    {
                        "session_id": session_dir.name,
                        "status": "completed",
                        "objective": "Improve paper quality.",
                        "verify_command": "python3 verify.py",
                        "attempts_completed": 3,
                        "successful_attempt": 2,
                        "run_tag": "overnight",
                        "branch_name": "autoresearch/overnight",
                        "best_score": 0,
                        "started_at": "2026-04-01T00:00:00+00:00",
                        "completed_at": "2026-04-01T01:00:00+00:00",
                        "last_error": "",
                    }
                ),
                encoding="utf-8",
            )
            (session_dir / "attempts.jsonl").write_text(
                json.dumps({"attempt": 1, "status": "discard", "description": "no improvement", "verifier": {"score_text": "2"}}) + "\n"
                + json.dumps({"attempt": 2, "status": "keep", "description": "clean up refs", "verifier": {"score_text": "0"}}),
                encoding="utf-8",
            )

            status_exit = cli.main(["autorepair", "status", "latest", "--session-root", str(session_root), "--json"])
            attempts_exit = cli.main(["autorepair", "attempts", "latest", "--session-root", str(session_root), "--json"])
            alias_exit = cli.main(["autoresearch", "status", "latest", "--session-root", str(session_root), "--json"])

            self.assertEqual(status_exit, 0)
            self.assertEqual(attempts_exit, 0)
            self.assertEqual(alias_exit, 0)


if __name__ == "__main__":
    unittest.main()
