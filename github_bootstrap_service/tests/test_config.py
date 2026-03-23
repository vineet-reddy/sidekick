import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig


class BootstrapServiceConfigTests(unittest.TestCase):
    def test_from_env_reads_backend_settings(self) -> None:
        env = {
            "GITHUB_CLIENT_ID": "cid",
            "GITHUB_CLIENT_SECRET": "secret",
            "SIDEKICK_BACKEND_BASE_URL": "https://bootstrap.sidekick.example",
            "OPENAI_API_KEY": "sk-test",
            "SIDEKICK_GITHUB_REPO_NAME": "sidekick-research",
            "SIDEKICK_GITHUB_REPO_VISIBILITY": "public",
            "SIDEKICK_BACKEND_MAX_DAILY_SPEND_USD": "12.5",
        }
        original = os.environ.copy()
        try:
            os.environ.update(env)
            config = BootstrapServiceConfig.from_env()
        finally:
            os.environ.clear()
            os.environ.update(original)

        self.assertEqual(config.backend_base_url, "https://bootstrap.sidekick.example")
        self.assertEqual(config.github_repo_name, "sidekick-research")
        self.assertEqual(config.github_repo_visibility, "public")
        self.assertEqual(config.openai_api_key, "sk-test")
        self.assertEqual(config.backend_max_daily_spend_usd, 12.5)


if __name__ == "__main__":
    unittest.main()
