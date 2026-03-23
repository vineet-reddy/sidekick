import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig


class BootstrapServiceConfigTests(unittest.TestCase):
    def test_from_env_reads_template_and_branch_protection_settings(self) -> None:
        env = {
            "GITHUB_CLIENT_ID": "cid",
            "GITHUB_CLIENT_SECRET": "secret",
            "GITHUB_BOOTSTRAP_REDIRECT_BASE_URL": "https://bootstrap.sidekick.example",
            "GITHUB_BOOTSTRAP_TEMPLATE_OWNER": "sidekick",
            "GITHUB_BOOTSTRAP_TEMPLATE_REPO": "workspace-template",
            "GITHUB_BOOTSTRAP_PROTECT_DEFAULT_BRANCH": "true",
            "GITHUB_BOOTSTRAP_ALLOW_FORCE_PUSHES": "false",
            "GITHUB_BOOTSTRAP_ALLOW_DELETIONS": "false",
            "GITHUB_BOOTSTRAP_REQUIRE_LINEAR_HISTORY": "true",
            "GITHUB_BOOTSTRAP_ENFORCE_ADMINS": "true",
        }
        original = os.environ.copy()
        try:
            os.environ.update(env)
            config = BootstrapServiceConfig.from_env()
        finally:
            os.environ.clear()
            os.environ.update(original)

        self.assertEqual(config.github_bootstrap_template_owner, "sidekick")
        self.assertEqual(config.github_bootstrap_template_repo, "workspace-template")
        self.assertTrue(config.github_bootstrap_protect_default_branch)
        self.assertFalse(config.github_bootstrap_allow_force_pushes)
        self.assertFalse(config.github_bootstrap_allow_deletions)
        self.assertTrue(config.github_bootstrap_require_linear_history)
        self.assertTrue(config.github_bootstrap_enforce_admins)
        self.assertEqual(config.github_bootstrap_redirect_base_url, "https://bootstrap.sidekick.example")


if __name__ == "__main__":
    unittest.main()
