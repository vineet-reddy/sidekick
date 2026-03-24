import base64
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.database import SidekickDatabase
from bootstrap_service.manuscript import compile_pdf, render_latex
from bootstrap_service.openai_client import OpenAIContainerFile
from bootstrap_service.server import JobProcessor


def _config(root: pathlib.Path) -> BootstrapServiceConfig:
    return BootstrapServiceConfig(
        github_client_id="client-id",
        github_client_secret="client-secret",
        backend_base_url="https://sidekick.example.com",
        openai_api_key="sk-test",
        backend_database_path=str(root / "backend.sqlite3"),
        backend_artifact_root=str(root / "artifacts"),
        openai_workspace_model="gpt-5.4",
        openai_writer_model="gpt-5.4-mini",
    )


def _processor(root: pathlib.Path, *, openai_client: object | None = None) -> JobProcessor:
    config = _config(root)
    database = SidekickDatabase(config)
    return JobProcessor(
        config=config,
        database=database,
        github_client=object(),
        openai_client=openai_client or object(),
    )


def _write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _methods_text() -> str:
    return (
        "We downloaded the public source file, inspected the available columns, cleaned the extracted values, "
        "computed the requested summary statistics in Python, and saved the resulting analysis table for this run. "
        "We compared the observed prevalence estimate across the retrieved records, checked the intermediate outputs, "
        "and recorded the final result only after the saved artifact matched the reported calculation."
    )


class PublicationGateTests(unittest.TestCase):
    def test_validation_routes_artifact_backed_result_to_paper(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            processor = _processor(root)
            job_id = "job-paper"
            _write(root / "artifacts" / job_id / "artifacts" / "table_1.csv", b"metric,value\nprevalence,0.18\n")

            ledger = {
                "title": "Validated study",
                "research_question": "What prevalence is visible in the public table?",
                "methods": _methods_text(),
                "limitations": ["Single public table only."],
                "sources": [
                    {
                        "source_id": "source_1",
                        "label": "CDC public table",
                        "download_url": "https://example.org/download/table_1.csv",
                    }
                ],
                "artifacts": [
                    {
                        "artifact_id": "artifact_1",
                        "path": "artifacts/table_1.csv",
                        "kind": "table",
                        "mime_type": "text/csv",
                        "source_ids": ["source_1"],
                    }
                ],
                "results": [
                    {
                        "result_id": "result_1",
                        "text": "The public table reports a prevalence estimate of 0.18 in the retrieved slice.",
                        "artifact_ids": ["artifact_1"],
                    }
                ],
            }

            validation = processor._validate_ledger(job_id, ledger)

            self.assertEqual(validation["status"], "paper")
            self.assertEqual(validation["manuscript_kind"], "paper")
            self.assertEqual(validation["approved_result_ids"], ["result_1"])
            self.assertEqual(len(validation["reference_catalog"]), 1)

    def test_validation_routes_weak_run_to_memo(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            processor = _processor(root)
            job_id = "job-memo"

            ledger = {
                "title": "Weak run",
                "research_question": "Can the idea be answered with current material?",
                "methods": "We reviewed public literature and summarized what others reported.",
                "limitations": ["No direct analysis completed."],
                "sources": [
                    {
                        "source_id": "source_1",
                        "label": "Landing page only",
                        "landing_page_url": "https://example.org/study",
                    }
                ],
                "artifacts": [],
                "results": [],
            }

            validation = processor._validate_ledger(job_id, ledger)

            self.assertEqual(validation["status"], "memo")
            self.assertEqual(validation["final_format"], "memo")
            self.assertFalse(validation["paper_checks"]["described_work_performed_here"])
            self.assertIn("paper gate", validation["summary"].lower())
            self.assertTrue(validation["memo_reasons"])

    def test_render_latex_includes_sections_figures_tables_and_bibliography(self) -> None:
        sections = {
            "title": "Example manuscript",
            "abstract": "We measured a public prevalence estimate.",
            "introduction": "This study investigates the public estimate.",
            "methods": "We downloaded the file and computed the statistic in Python.",
            "results": "The estimate was 0.18 (Table \\ref{tab:artifact-2}; Figure \\ref{fig:artifact-1}; \\cite{ref1}).",
            "discussion": "The result is descriptive but useful.",
            "limitations": "Only one public slice was available.",
            "references": ["Example public source."],
        }
        manifest = {
            "figures": [
                {
                    "artifact_id": "artifact_1",
                    "label": "fig:artifact-1",
                    "caption": "Main figure",
                    "path": "figures/figure_1.png",
                }
            ],
            "tables": [
                {
                    "artifact_id": "artifact_2",
                    "label": "tab:artifact-2",
                    "caption": "Main table",
                    "path": "tables/table_1.csv",
                    "rows": [["metric", "value"], ["prevalence", "0.18"]],
                }
            ],
        }

        latex, references_bib = render_latex(
            title="Example manuscript",
            sections=sections,
            manifest=manifest,
            manuscript_kind="paper",
            reference_catalog=[{"key": "ref1", "text": "Example public source."}],
        )

        self.assertIn("\\section{Results}", latex)
        self.assertIn("\\includegraphics", latex)
        self.assertIn("\\begin{table}", latex)
        self.assertIn("\\bibliography{references}", latex)
        self.assertIn("@misc{ref1", references_bib)

    def test_compile_pdf_reports_missing_runtime_tools(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            job_dir = root / "artifacts" / "job-compile"
            job_dir.mkdir(parents=True, exist_ok=True)
            (job_dir / "paper.tex").write_text("\\documentclass{article}\\begin{document}Test\\end{document}", encoding="utf-8")
            (job_dir / "references.bib").write_text("", encoding="utf-8")

            with patch("bootstrap_service.manuscript.subprocess.run", side_effect=FileNotFoundError):
                result = compile_pdf(job_dir, tex_filename="paper.tex")

            self.assertFalse(result["ok"])
            self.assertIn("not installed", result["error"])

    def test_bundle_figures_use_saved_image_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            processor = _processor(root)
            job_id = "job-figures"
            png_bytes = base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn4x3sAAAAASUVORK5CYII="
            )
            _write(root / "artifacts" / job_id / "artifacts" / "figure_1.png", png_bytes)

            ledger = {
                "artifacts": [
                    {
                        "artifact_id": "artifact_1",
                        "path": "artifacts/figure_1.png",
                        "kind": "figure",
                        "mime_type": "image/png",
                        "description": "Main figure",
                    }
                ]
            }

            figures = processor._bundle_figures_from_ledger(job_id, ledger)
            self.assertEqual(len(figures), 1)
            self.assertEqual(figures[0]["filename"], "figure_1.png")
            self.assertEqual(figures[0]["caption"], "Main figure")
            self.assertEqual(figures[0]["mime_type"], "image/png")
            self.assertEqual(base64.b64decode(figures[0]["base64_data"]), png_bytes)

    def test_workspace_artifacts_can_be_materialized_without_message_annotations(self) -> None:
        class FakeOpenAIClient:
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

        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            openai_client = FakeOpenAIClient()
            processor = _processor(root, openai_client=openai_client)
            job_id = "job-materialized"
            ledger = {
                "title": "Materialized study",
                "research_question": "What prevalence is visible in the public table?",
                "methods": _methods_text(),
                "sources": [
                    {
                        "source_id": "source_1",
                        "label": "CDC public table",
                        "download_url": "https://example.org/download/table_1.csv",
                    }
                ],
                "artifacts": [
                    {
                        "artifact_id": "artifact_1",
                        "path": "artifacts/table_1.csv",
                        "kind": "table",
                        "source_ids": ["source_1"],
                    }
                ],
                "results": [
                    {
                        "result_id": "result_1",
                        "text": "The retrieved table reports a prevalence estimate of 0.18.",
                        "artifact_ids": ["artifact_1"],
                    }
                ],
            }

            downloaded = processor._materialize_workspace_files(
                job_id,
                ledger,
                container_ids=["cntr_123"],
            )
            processor._apply_downloaded_files_to_ledger(ledger, downloaded)
            validation = processor._validate_ledger(job_id, ledger)

            self.assertEqual(getattr(openai_client, "container_id", None), "cntr_123")
            self.assertEqual(getattr(openai_client, "downloaded", None), ("cntr_123", "cfile_1"))
            self.assertEqual(validation["status"], "paper")
            self.assertEqual(validation["approved_result_ids"], ["result_1"])


if __name__ == "__main__":
    unittest.main()
