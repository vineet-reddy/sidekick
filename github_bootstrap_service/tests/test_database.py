import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.database import SidekickDatabase


class SidekickDatabaseTests(unittest.TestCase):
    def test_fail_stale_running_jobs_marks_abandoned_run_failed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            config = BootstrapServiceConfig(
                github_client_id="test-client",
                github_client_secret="test-secret",
                backend_base_url="https://example.com",
                openai_api_key="test-key",
                backend_database_path=str(root / "backend.sqlite3"),
                backend_artifact_root=str(root / "artifacts"),
            )
            database = SidekickDatabase(config)
            install = database.ensure_install_session("device-1")
            connection = database.upsert_github_connection(
                install_session_id=install["id"],
                github_login="vineet-testing",
                repo_owner="vineet-testing",
                repo_name="sidekick",
                repo_full_name="vineet-testing/sidekick",
                repo_url="https://github.com/vineet-testing/sidekick",
                access_token_encrypted="token",
                visibility="public",
            )
            job = database.create_paper_job(
                install_session_id=install["id"],
                github_connection_id=connection["id"],
                paper_title="Test paper",
                request_payload={"paper_title": "Test paper"},
            )

            database.update_paper_job(
                job["id"],
                status="running",
                stage="2",
                progress_message="data-analyst started.",
            )
            with database._lock, database._connection() as sql_connection:
                sql_connection.execute(
                    """
                    UPDATE paper_jobs
                    SET updated_at = ?
                    WHERE id = ?
                    """,
                    ("2020-01-01T00:00:00+00:00", job["id"]),
                )

            recovered = database.fail_stale_running_jobs(
                stale_before_iso="2020-01-01T00:05:00+00:00",
                error_message="worker restarted",
            )

            self.assertEqual(recovered, 1)
            updated = database.get_paper_job(job["id"])
            self.assertIsNotNone(updated)
            self.assertEqual(updated["status"], "failed")
            self.assertEqual(updated["error_message"], "worker restarted")
            self.assertEqual(updated["progress_message"], "The hosted worker stopped before this run completed.")
            self.assertIsNotNone(updated["completed_at"])


if __name__ == "__main__":
    unittest.main()
