import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.openai_client import OpenAIContainerFile, OpenAIResponseResult, OpenAIUsage
from bootstrap_service.pipeline_engine import PaperPipelineEngine


def _config(root: pathlib.Path) -> BootstrapServiceConfig:
    return BootstrapServiceConfig(
        github_client_id="client-id",
        github_client_secret="client-secret",
        backend_base_url="https://sidekick.example.com",
        openai_api_key="sk-test",
        backend_database_path=str(root / "backend.sqlite3"),
        backend_artifact_root=str(root / "artifacts"),
        openai_workspace_model="gpt-5.4",
        openai_writer_model="gpt-5.4",
    )


class FakeOpenAIClient:
    def __init__(self) -> None:
        self.workspace_result = OpenAIResponseResult(
            response_id="resp_workspace",
            output_text="""
{
  "title": "Example prevalence study",
  "research_question": "What prevalence estimate is visible in the saved table?",
  "methods": "We downloaded the public CSV, cleaned the extracted values, computed the descriptive prevalence estimate in Python, saved the analysis table, and checked the resulting artifact before recording the result. This run was executed directly in the workspace using the retrieved source file rather than summarizing prior literature.",
  "results": [
    {
      "text": "The saved analysis table reports a prevalence estimate of 0.18 in the retrieved slice.",
      "artifact_ids": ["artifact_1"]
    }
  ],
  "limitations": ["Only one public source file was available in this run."],
  "sources": [
    {
      "source_id": "source_1",
      "label": "Public CSV",
      "download_url": "https://example.org/data/table_1.csv"
    }
  ],
  "artifacts": [
    {
      "artifact_id": "artifact_1",
      "path": "artifacts/table_1.csv",
      "kind": "table",
      "mime_type": "text/csv",
      "description": "Extracted prevalence table",
      "source_ids": ["source_1"]
    }
  ]
}
""".strip(),
            usage=OpenAIUsage(input_tokens=100, output_tokens=200),
            payload={"output": [{"type": "message", "content": []}], "status": "completed"},
        )
        self.writer_result = OpenAIResponseResult(
            response_id="resp_writer",
            output_text="""
{
  "title": "Example prevalence study",
  "abstract": "We estimated a descriptive prevalence value from the retrieved public source [[CITE:ref1]].",
  "introduction": "This paper examines the retrieved prevalence measure [[CITE:ref1]].",
  "methods": "We downloaded the file, cleaned the extracted values, and computed the descriptive prevalence estimate in Python.",
  "results": "The prevalence estimate is reported in [[REF:tab:artifact_1]] and supported by [[CITE:ref1]].",
  "discussion": "The result is descriptive but directly answers the scoped question.",
  "limitations": "Only one public source file was available.",
  "references": ["Public CSV."]
}
""".strip(),
            usage=OpenAIUsage(input_tokens=50, output_tokens=120),
            payload={"output": [{"type": "message", "content": []}], "status": "completed"},
        )
        self.calls = 0

    def generate_json(self, **_: object) -> OpenAIResponseResult:
        self.calls += 1
        return self.workspace_result if self.calls == 1 else self.writer_result

    def extract_container_ids(self, response: OpenAIResponseResult) -> list[str]:
        assert response is self.workspace_result
        return ["cntr_123"]

    def list_container_files(self, *, container_id: str) -> list[OpenAIContainerFile]:
        self.container_id = container_id
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
        self.downloaded = (container_id, file_id)
        return b"metric,value\nprevalence,0.18\n"


def _fake_compile(job_directory: pathlib.Path, *, tex_filename: str) -> dict[str, object]:
    pdf_path = job_directory / f"{pathlib.Path(tex_filename).stem}.pdf"
    pdf_path.write_bytes(b"%PDF-1.4\n")
    return {"ok": True, "error": "", "log": "compiled", "pdf_path": pdf_path.name}


class PipelineEngineTests(unittest.TestCase):
    def test_engine_execute_writes_local_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            statuses: list[tuple[str, str]] = []
            metrics: list[tuple[str, int, int]] = []
            engine = PaperPipelineEngine(
                config=_config(root),
                openai_client=FakeOpenAIClient(),
                status_callback=lambda run_id, **kwargs: statuses.append((run_id, str(kwargs.get("stage") or ""))),
                metrics_callback=lambda run_id, **kwargs: metrics.append(
                    (run_id, int(kwargs["input_tokens"]), int(kwargs["output_tokens"]))
                ),
            )
            request_payload = {
                "title": "Example prevalence study",
                "theme": "Example prevalence study",
                "notes": "Estimate the prevalence available in the public file.",
                "dataset_ids": [],
                "dataset_hints": [],
                "domain_guidance": "",
                "must_use_sources": [],
            }

            with patch("bootstrap_service.pipeline_engine.compile_pdf", side_effect=_fake_compile):
                outputs = engine.execute(run_id="run-1", request_payload=request_payload)

            run_dir = root / "artifacts" / "run-1"
            self.assertTrue((run_dir / "ledger.json").exists())
            self.assertTrue((run_dir / "validation.json").exists())
            self.assertTrue((run_dir / "sections.json").exists())
            self.assertTrue((run_dir / "bundle.json").exists())
            self.assertTrue((run_dir / "paper.tex").exists())
            self.assertTrue((run_dir / "paper.pdf").exists())
            self.assertEqual(outputs["validation"]["manuscript_kind"], "paper")
            self.assertEqual(outputs["bundle"]["pdf"]["ok"], True)
            self.assertGreaterEqual(len(statuses), 3)
            self.assertEqual(len(metrics), 2)


if __name__ == "__main__":
    unittest.main()
