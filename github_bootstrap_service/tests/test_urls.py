import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.github_client import GitHubClient


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


if __name__ == "__main__":
    unittest.main()
