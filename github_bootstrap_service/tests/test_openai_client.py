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

    def test_extracts_container_ids_from_response_payload(self) -> None:
        client = OpenAIClient(_config())
        response = OpenAIResponseResult(
            response_id="resp_123",
            output_text="{}",
            usage=OpenAIUsage(input_tokens=10, output_tokens=12),
            payload={
                "output": [
                    {"type": "code_interpreter_call", "container_id": "cntr_123"},
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": "done",
                                "annotations": [
                                    {
                                        "type": "container_file_citation",
                                        "container_id": "cntr_123",
                                        "file_id": "cfile_123",
                                        "filename": "table_1.csv",
                                    }
                                ],
                            }
                        ],
                    },
                ]
            },
        )

        self.assertEqual(client.extract_container_ids(response), ["cntr_123"])

    def test_lists_container_files_across_pages(self) -> None:
        class StubOpenAIClient(OpenAIClient):
            def __init__(self) -> None:
                super().__init__(_config())
                self.paths: list[str] = []

            def _request_json(self, method: str, path: str, body: dict[str, object] | None) -> dict[str, object]:
                self.paths.append(path)
                if path == "/containers/cntr_123/files":
                    return {
                        "data": [
                            {
                                "id": "cfile_1",
                                "path": "/mnt/data/artifacts/table_1.csv",
                                "mime_type": "text/csv",
                            }
                        ],
                        "has_more": True,
                        "last_id": "cfile_1",
                    }
                if path == "/containers/cntr_123/files?after=cfile_1":
                    return {
                        "data": [
                            {
                                "id": "cfile_2",
                                "path": "/mnt/data/artifacts/figure_1.png",
                                "mime_type": "image/png",
                            }
                        ],
                        "has_more": False,
                        "last_id": "cfile_2",
                    }
                raise AssertionError(f"Unexpected path: {path}")

        client = StubOpenAIClient()
        files = client.list_container_files(container_id="cntr_123")

        self.assertEqual(client.paths, ["/containers/cntr_123/files", "/containers/cntr_123/files?after=cfile_1"])
        self.assertEqual([file.file_id for file in files], ["cfile_1", "cfile_2"])
        self.assertEqual(files[0].filename, "table_1.csv")
        self.assertEqual(files[1].mime_type, "image/png")


if __name__ == "__main__":
    unittest.main()
