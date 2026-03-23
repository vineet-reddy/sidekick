import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.config import BootstrapServiceConfig
from bootstrap_service.openai_client import OpenAIClient, OpenAIResponseResult, OpenAIUsage


def _config() -> BootstrapServiceConfig:
    return BootstrapServiceConfig(
        github_client_id="client-id",
        github_client_secret="client-secret",
        backend_base_url="https://sidekick.example.com",
        openai_api_key="sk-test",
        backend_database_path=".tmp/backend.sqlite3",
        backend_artifact_root=".tmp/artifacts",
    )


class OpenAIClientTests(unittest.TestCase):
    def test_extracts_container_file_citations_from_output_annotations(self) -> None:
        client = OpenAIClient(_config())
        text = '{"artifacts":[{"path":"artifacts/table_1.csv"}]}'
        annotated_text = "artifacts/table_1.csv"
        start_index = text.index(annotated_text)
        end_index = start_index + len(annotated_text)
        response = OpenAIResponseResult(
            response_id="resp_123",
            output_text=text,
            usage=OpenAIUsage(input_tokens=10, output_tokens=12),
            payload={
                "output": [
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": text,
                                "annotations": [
                                    {
                                        "type": "container_file_citation",
                                        "container_id": "cntr_123",
                                        "file_id": "cfile_123",
                                        "filename": "table_1.csv",
                                        "start_index": start_index,
                                        "end_index": end_index,
                                    }
                                ],
                            }
                        ],
                    }
                ]
            },
        )

        citations = client.extract_container_file_citations(response)
        self.assertEqual(len(citations), 1)
        self.assertEqual(citations[0].container_id, "cntr_123")
        self.assertEqual(citations[0].file_id, "cfile_123")
        self.assertEqual(citations[0].filename, "table_1.csv")
        self.assertEqual(citations[0].annotated_text, annotated_text)


if __name__ == "__main__":
    unittest.main()
