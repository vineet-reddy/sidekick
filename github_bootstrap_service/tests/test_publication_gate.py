import base64
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.database import SidekickDatabase
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
        github_client=object(),  # not used by these tests
        openai_client=openai_client or object(),  # not used by these tests
    )


def _write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class PublicationGateTests(unittest.TestCase):
    def test_validation_approves_claim_with_real_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            processor = _processor(root)
            job_id = "job-approved"
            _write(root / "artifacts" / job_id / "artifacts" / "table_1.csv", b"metric,value\nodds_ratio,1.2\n")

            ledger = {
                "title": "Validated ledger",
                "recommended_format": "brief_report",
                "sources": [
                    {
                        "source_id": "source_1",
                        "label": "GEO study",
                        "accession_id": "GSE12345",
                        "download_url": "https://example.org/download/GSE12345.tsv",
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
                "claims": [
                    {
                        "claim_id": "claim_1",
                        "text": "The observed association is positive in this public dataset.",
                        "artifact_ids": ["artifact_1"],
                        "source_ids": ["source_1"],
                    }
                ],
            }

            validation = processor._validate_ledger(job_id, ledger)
            self.assertEqual(validation["status"], "approved")
            self.assertEqual(validation["final_format"], "brief_report")
            self.assertEqual(validation["approved_claim_ids"], ["claim_1"])
            self.assertEqual(len(validation["dropped_claims"]), 0)

    def test_validation_blocks_when_zero_claims_survive(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            processor = _processor(root)
            job_id = "job-blocked"

            ledger = {
                "title": "Blocked ledger",
                "recommended_format": "full_paper",
                "sources": [
                    {
                        "source_id": "source_1",
                        "label": "Landing page only",
                        "landing_page_url": "https://example.org/study",
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
                "claims": [
                    {
                        "claim_id": "claim_1",
                        "text": "This proves the mechanism is causal.",
                        "artifact_ids": ["artifact_1"],
                        "source_ids": ["source_1"],
                    }
                ],
            }

            validation = processor._validate_ledger(job_id, ledger)
            self.assertEqual(validation["status"], "blocked")
            self.assertEqual(validation["final_format"], "blocked")
            self.assertEqual(validation["approved_claim_ids"], [])
            self.assertEqual(len(validation["dropped_claims"]), 1)
            reasons = " ".join(validation["dropped_claims"][0]["reasons"])
            self.assertIn("saved artifact", reasons)
            self.assertIn("reproducible source provenance", reasons)
            self.assertIn("banned language", reasons)

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
                "title": "Materialized ledger",
                "recommended_format": "brief_report",
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
                "claims": [
                    {
                        "claim_id": "claim_1",
                        "text": "The estimated prevalence is reported in the public table.",
                        "artifact_ids": ["artifact_1"],
                        "source_ids": ["source_1"],
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
            self.assertEqual(validation["status"], "approved")
            self.assertEqual(validation["approved_claim_ids"], ["claim_1"])


if __name__ == "__main__":
    unittest.main()
