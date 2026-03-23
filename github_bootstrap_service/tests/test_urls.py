import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.github_client import GitHubClient


class GitHubURLTests(unittest.TestCase):
    def test_connector_install_url_is_prescoped_to_one_repo(self) -> None:
        config = BootstrapServiceConfig(
            github_client_id="cid",
            github_client_secret="secret",
            github_bootstrap_redirect_base_url="https://bootstrap.sidekick.example",
        )
        client = GitHubClient(config)

        url = client.build_connector_install_url(
            github_account_id=42,
            repository_id=99,
        )

        self.assertIn("suggested_target_id=42", url)
        self.assertIn("repository_ids%5B%5D=99", url)
        self.assertIn("/apps/chatgpt-codex-connector/installations/new/permissions", url)


if __name__ == "__main__":
    unittest.main()
