import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.openai_client import OpenAIContainerFile, OpenAIResponseResult, OpenAIUsage
from paperlab import cli


def _config(root: pathlib.Path) -> BootstrapServiceConfig:
    return BootstrapServiceConfig(
        github_client_id="client-id",
        github_client_secret="client-secret",
        backend_base_url="https://sidekick.example.com",
        openai_api_key="sk-test",
        backend_database_path=str(root / "backend.sqlite3"),
        backend_artifact_root=str((root / "runs").resolve()),
        openai_workspace_model="gpt-5.4",
        openai_writer_model="gpt-5.4",
    )


class FakeOpenAIClient:
    def __init__(self, _: BootstrapServiceConfig) -> None:
        self.calls = 0

    def generate_json(self, **_: object) -> OpenAIResponseResult:
        self.calls += 1
        if self.calls == 1:
            text = """
{
  "title": "CLI study",
  "research_question": "What prevalence estimate is visible in the saved table?",
  "methods": "We downloaded the public CSV, cleaned the extracted values, computed the descriptive prevalence estimate in Python, saved the analysis table, and checked the resulting artifact before recording the result. This run was executed directly in the workspace using the retrieved source file rather than summarizing prior literature.",
  "results": [{"text": "The saved analysis table reports a prevalence estimate of 0.18.", "artifact_ids": ["artifact_1"]}],
  "limitations": ["Only one file was available."],
  "sources": [{"source_id": "source_1", "label": "Public CSV", "download_url": "https://example.org/data/table_1.csv"}],
  "artifacts": [{"artifact_id": "artifact_1", "path": "artifacts/table_1.csv", "kind": "table", "mime_type": "text/csv", "description": "Extracted prevalence table", "source_ids": ["source_1"]}]
}
""".strip()
            return OpenAIResponseResult("resp_workspace", text, OpenAIUsage(10, 20), {"output": [], "status": "completed"})
        text = """
{
  "title": "CLI study",
  "abstract": "Abstract [[CITE:ref1]].",
  "introduction": "Introduction [[CITE:ref1]].",
  "methods": "Methods.",
  "results": "Results [[REF:tab:artifact_1]].",
  "discussion": "Discussion.",
  "limitations": "Limitations.",
  "references": ["Public CSV."]
}
""".strip()
        return OpenAIResponseResult("resp_writer", text, OpenAIUsage(5, 15), {"output": [], "status": "completed"})

    def extract_container_ids(self, response: OpenAIResponseResult) -> list[str]:
        if response.response_id == "resp_workspace":
            return ["cntr_123"]
        return []

    def list_container_files(self, *, container_id: str) -> list[OpenAIContainerFile]:
        return [
            OpenAIContainerFile(
                container_id=container_id,
                file_id="cfile_1",
                filename="table_1.csv",
                path="/mnt/data/artifacts/table_1.csv",
                mime_type="text/csv",
            )
        ]

    def download_container_file_bytes(self, *, container_id: str, file_id: str) -> bytes:
        return b"metric,value\nprevalence,0.18\n"


def _fake_compile(job_directory: pathlib.Path, *, tex_filename: str) -> dict[str, object]:
    pdf_path = job_directory / f"{pathlib.Path(tex_filename).stem}.pdf"
    pdf_path.write_bytes(b"%PDF-1.4\n")
    return {"ok": True, "error": "", "log": "compiled", "pdf_path": pdf_path.name}


class PaperlabCLITests(unittest.TestCase):
    def test_run_command_creates_local_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            prompt_file = root / "prompt.txt"
            prompt_file.write_text("CLI study\nEstimate the prevalence available in the file.", encoding="utf-8")

            with patch.object(cli, "RUNS_ROOT", root / "runs"), patch.object(
                cli,
                "build_local_config",
                return_value=_config(root),
            ), patch.object(cli, "OpenAIClient", FakeOpenAIClient), patch(
                "github_bootstrap_service.bootstrap_service.pipeline_engine.compile_pdf",
                side_effect=_fake_compile,
            ):
                exit_code = cli.main(["run", "--notes-file", str(prompt_file)])

            self.assertEqual(exit_code, 0)
            run_directories = [path for path in (root / "runs").iterdir() if path.is_dir()]
            self.assertEqual(len(run_directories), 1)
            run_dir = run_directories[0]
            self.assertTrue((run_dir / "input.json").exists())
            self.assertTrue((run_dir / "ledger.json").exists())
            self.assertTrue((run_dir / "validation.json").exists())
            self.assertTrue((run_dir / "sections.json").exists())
            self.assertTrue((run_dir / "paper.tex").exists())
            self.assertTrue((run_dir / "paper.pdf").exists())

    def test_render_command_does_not_require_api_key_for_saved_run(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            prompt_file = root / "prompt.txt"
            prompt_file.write_text("CLI study\nEstimate the prevalence available in the file.", encoding="utf-8")

            with patch.object(cli, "RUNS_ROOT", root / "runs"), patch.object(
                cli,
                "build_local_config",
                side_effect=lambda require_openai=True: _config(root),
            ), patch.object(cli, "OpenAIClient", FakeOpenAIClient), patch(
                "github_bootstrap_service.bootstrap_service.pipeline_engine.compile_pdf",
                side_effect=_fake_compile,
            ):
                exit_code = cli.main(["run", "--notes-file", str(prompt_file)])
                self.assertEqual(exit_code, 0)

            run_directories = [path for path in (root / "runs").iterdir() if path.is_dir()]
            self.assertEqual(len(run_directories), 1)
            run_dir = run_directories[0]

            with patch.dict("os.environ", {}, clear=True), patch.object(cli, "RUNS_ROOT", root / "runs"):
                exit_code = cli.main(["render", str(run_dir)])

            self.assertEqual(exit_code, 0)
            self.assertTrue((run_dir / "paper.pdf").exists())

    def test_render_status_prefers_commit_match(self) -> None:
        deploys = [
            {
                "id": "dep-live",
                "status": "live",
                "updatedAt": "2026-03-25T08:00:00Z",
                "commit": {"id": "abc123456789", "message": "new backend"},
            },
            {
                "id": "dep-old",
                "status": "deactivated",
                "updatedAt": "2026-03-25T07:00:00Z",
                "commit": {"id": "def987654321", "message": "old backend"},
            },
        ]

        selected = cli.select_render_deploy(deploys, "def987")

        self.assertIsNotNone(selected)
        self.assertEqual(selected["id"], "dep-old")

    def test_render_status_waits_for_commit_to_turn_live(self) -> None:
        deploy_payload = json.dumps(
            [
                {
                    "id": "dep-build",
                    "status": "build_in_progress",
                    "updatedAt": "2026-03-25T08:00:00Z",
                    "commit": {"id": "abc123456789", "message": "new backend"},
                }
            ]
        )
        live_payload = json.dumps(
            [
                {
                    "id": "dep-build",
                    "status": "live",
                    "updatedAt": "2026-03-25T08:03:00Z",
                    "commit": {"id": "abc123456789", "message": "new backend"},
                }
            ]
        )

        responses = [
            subprocess.CompletedProcess(args=["render"], returncode=0, stdout=deploy_payload, stderr=""),
            subprocess.CompletedProcess(args=["render"], returncode=0, stdout=live_payload, stderr=""),
        ]

        with patch("paperlab.cli.subprocess.run", side_effect=responses), patch("paperlab.cli.time.sleep", return_value=None):
            exit_code = cli.main(
                [
                    "render-status",
                    "--service-id",
                    "srv-test",
                    "--service-name",
                    "test-service",
                    "--service-url",
                    "https://example.com",
                    "--commit",
                    "abc123",
                    "--wait",
                    "--timeout-seconds",
                    "30",
                    "--poll-seconds",
                    "1",
                ]
            )

        self.assertEqual(exit_code, 0)

    def test_render_status_returns_failure_for_failed_commit(self) -> None:
        failed_payload = json.dumps(
            [
                {
                    "id": "dep-failed",
                    "status": "build_failed",
                    "updatedAt": "2026-03-25T08:01:00Z",
                    "commit": {"id": "abc123456789", "message": "broken backend"},
                }
            ]
        )

        with patch(
            "paperlab.cli.subprocess.run",
            return_value=subprocess.CompletedProcess(args=["render"], returncode=0, stdout=failed_payload, stderr=""),
        ):
            exit_code = cli.main(
                [
                    "render-status",
                    "--service-id",
                    "srv-test",
                    "--service-name",
                    "test-service",
                    "--service-url",
                    "https://example.com",
                    "--commit",
                    "abc123",
                    "--wait",
                ]
            )

        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
