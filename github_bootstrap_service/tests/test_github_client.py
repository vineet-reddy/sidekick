import io
import json
import pathlib
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.github_client import GitHubClient, GitHubClientError


class _Response:
    def __init__(self, payload: dict[str, object]):
        self._payload = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._payload

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


class GitHubClientTests(unittest.TestCase):
    def setUp(self) -> None:
        config = BootstrapServiceConfig(
            github_client_id="cid",
            github_client_secret="secret",
            backend_base_url="https://bootstrap.sidekick.example",
            openai_api_key="sk-test",
        )
        self.client = GitHubClient(config)

    def test_request_json_retries_retry_after_rate_limit_errors(self) -> None:
        rate_limit_error = HTTPError(
            url="https://api.github.com/test",
            code=403,
            msg="Forbidden",
            hdrs={"Retry-After": "2"},
            fp=io.BytesIO(b'{"message":"secondary rate limit exceeded"}'),
        )

        with patch("bootstrap_service.github_client.urlopen", side_effect=[rate_limit_error, _Response({"ok": True})]) as mocked_urlopen, patch(
            "bootstrap_service.github_client.time.sleep"
        ) as mocked_sleep:
            payload = self.client._request_json(method="GET", url="https://api.github.com/test", access_token="token")

        self.assertEqual(payload, {"ok": True})
        self.assertEqual(mocked_urlopen.call_count, 2)
        mocked_sleep.assert_called_once_with(2.0)

    def test_request_json_raises_after_exhausting_rate_limit_retries(self) -> None:
        rate_limit_error = HTTPError(
            url="https://api.github.com/test",
            code=403,
            msg="Forbidden",
            hdrs={"Retry-After": "1"},
            fp=io.BytesIO(b'{"message":"API rate limit exceeded for user"}'),
        )

        with patch("bootstrap_service.github_client.urlopen", side_effect=[rate_limit_error] * 5), patch(
            "bootstrap_service.github_client.time.sleep"
        ):
            with self.assertRaises(GitHubClientError) as context:
                self.client._request_json(method="PUT", url="https://api.github.com/test", access_token="token", body={"ok": True})

        self.assertIn("HTTP 403", str(context.exception))


if __name__ == "__main__":
    unittest.main()
