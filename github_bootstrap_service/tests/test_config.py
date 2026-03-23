import os
import pathlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig


class ConfigTests(unittest.TestCase):
    def test_stage_model_defaults_use_current_split(self) -> None:
        env = {
            "GITHUB_CLIENT_ID": "client-id",
            "GITHUB_CLIENT_SECRET": "client-secret",
            "SIDEKICK_BACKEND_BASE_URL": "https://sidekick-ion1.onrender.com",
            "OPENAI_API_KEY": "sk-test",
        }
        with patch.dict(os.environ, env, clear=True):
            config = BootstrapServiceConfig.from_env()

        self.assertEqual(config.openai_model, "gpt-5.4")
        self.assertEqual(config.openai_planner_model, "gpt-5.4-nano")
        self.assertEqual(config.openai_analysis_model, "gpt-5.4")
        self.assertEqual(config.openai_writer_model, "gpt-5.4-mini")
        self.assertEqual(config.openai_auditor_model, "gpt-5.4")

    def test_stage_models_can_be_overridden_independently(self) -> None:
        env = {
            "GITHUB_CLIENT_ID": "client-id",
            "GITHUB_CLIENT_SECRET": "client-secret",
            "SIDEKICK_BACKEND_BASE_URL": "https://sidekick-ion1.onrender.com",
            "OPENAI_API_KEY": "sk-test",
            "SIDEKICK_OPENAI_MODEL": "gpt-5.4",
            "SIDEKICK_OPENAI_PLANNER_MODEL": "gpt-5.4-mini",
            "SIDEKICK_OPENAI_ANALYSIS_MODEL": "gpt-5.4",
            "SIDEKICK_OPENAI_WRITER_MODEL": "gpt-5.4-mini",
            "SIDEKICK_OPENAI_AUDITOR_MODEL": "gpt-5.4-mini",
        }
        with patch.dict(os.environ, env, clear=True):
            config = BootstrapServiceConfig.from_env()

        self.assertEqual(config.openai_planner_model, "gpt-5.4-mini")
        self.assertEqual(config.openai_analysis_model, "gpt-5.4")
        self.assertEqual(config.openai_writer_model, "gpt-5.4-mini")
        self.assertEqual(config.openai_auditor_model, "gpt-5.4-mini")


if __name__ == "__main__":
    unittest.main()
