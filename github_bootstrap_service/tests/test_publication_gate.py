import base64
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.database import SidekickDatabase
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


def _processor(root: pathlib.Path) -> JobProcessor:
    config = _config(root)
    database = SidekickDatabase(config)
    return JobProcessor(
        config=config,
        database=database,
        github_client=object(),  # not used by these tests
        openai_client=object(),  # not used by these tests
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


if __name__ == "__main__":
    unittest.main()
