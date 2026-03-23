import pathlib
import sys
import unittest
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.database import SidekickDatabase
from bootstrap_service.github_client import GitHubClient
from bootstrap_service.server import create_server


class GitHubURLTests(unittest.TestCase):
    def test_github_authorization_url_includes_callback_and_scope(self) -> None:
        config = BootstrapServiceConfig(
            github_client_id="cid",
            github_client_secret="secret",
            backend_base_url="https://bootstrap.sidekick.example",
            openai_api_key="sk-test",
        )
        client = GitHubClient(config)

        url = client.build_user_authorization_url("opaque-state")

        self.assertIn("client_id=cid", url)
        self.assertIn("state=opaque-state", url)
        self.assertIn("scope=public_repo+read%3Auser", url)
        self.assertIn("redirect_uri=https%3A%2F%2Fbootstrap.sidekick.example%2Fbrowser%2Fgithub-connect%2Fcallback", url)

    def test_connect_payload_browser_url_points_directly_to_github(self) -> None:
        config = BootstrapServiceConfig(
            github_client_id="cid",
            github_client_secret="secret",
            backend_base_url="https://bootstrap.sidekick.example",
            openai_api_key="sk-test",
            encryption_secret="test-secret",
            backend_database_path=".tmp-sidekick-tests/backend.sqlite3",
            backend_artifact_root=".tmp-sidekick-tests/artifacts",
        )
        database = SidekickDatabase(config)
        server = create_server(
            "127.0.0.1",
            0,
            config=config,
            database=database,
            github_client=GitHubClient(config),
        )
        handler = object.__new__(server.RequestHandlerClass)
        handler.server = server

        install_session = database.ensure_install_session("device-1")
        connect_session = database.create_github_connect_session(install_session["id"], 300)
        payload = handler._github_connect_session_payload(connect_session)

        parsed = urlparse(payload["browser_url"])
        self.assertEqual(parsed.netloc, "github.com")
        self.assertEqual(parsed.path, "/login/oauth/authorize")
        self.assertEqual(
            parse_qs(parsed.query)["redirect_uri"][0],
            "https://bootstrap.sidekick.example/browser/github-connect/callback",
        )
        self.assertIn(".", parse_qs(parsed.query)["state"][0])

        server.job_processor.stop()
        server.server_close()


if __name__ == "__main__":
    unittest.main()
