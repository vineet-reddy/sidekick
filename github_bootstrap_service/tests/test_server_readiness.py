import pathlib
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.server import BootstrapServiceHandler


class _FakeCandidate:
    def __init__(self, *, dataset_id: str, qualifies_as_primary_data: bool) -> None:
        self.dataset_id = dataset_id
        self.qualifies_as_primary_data = qualifies_as_primary_data


class _FakeResolution:
    def __init__(self, payload: dict, selected_candidate: _FakeCandidate | None = None) -> None:
        self._payload = payload
        self.selected_candidate = selected_candidate

    def as_dict(self) -> dict:
        return dict(self._payload)


class _FakeResolver:
    def __init__(self, resolution: _FakeResolution) -> None:
        self.resolution = resolution

    def resolve(self, **_: object) -> _FakeResolution:
        return self.resolution


class ServerReadinessTests(unittest.TestCase):
    def test_empirical_unresolved_cluster_stays_submission_eligible(self) -> None:
        handler = SimpleNamespace()
        handler.server = SimpleNamespace(
            source_resolver=_FakeResolver(
                _FakeResolution(
                    {
                        "paper_mode": "empirical_dataset",
                        "status": "unresolved",
                        "selected_candidate": None,
                    }
                )
            )
        )
        handler._cluster_readiness_mode = lambda resolution: BootstrapServiceHandler._cluster_readiness_mode(handler, resolution)

        clusters = BootstrapServiceHandler._assess_notes(
            handler,
            [{"id": "note-1", "title": "Rare disease weird note", "content": "Rare disease weird note"}],
        )

        self.assertEqual(len(clusters), 1)
        self.assertEqual(clusters[0]["readiness_mode"], "exploratory_ready")
        self.assertTrue(clusters[0]["is_ready"])

    def test_empirical_resolved_primary_data_is_trusted_ready(self) -> None:
        readiness = BootstrapServiceHandler._cluster_readiness_mode(
            SimpleNamespace(),
            {
                "paper_mode": "empirical_dataset",
                "status": "resolved",
                "selected_candidate": {
                    "dataset_id": "gse123",
                    "qualifies_as_primary_data": True,
                },
            },
        )

        self.assertEqual(readiness, "trusted_ready")

    def test_blocked_non_empirical_note_returns_needs_data(self) -> None:
        readiness = BootstrapServiceHandler._cluster_readiness_mode(
            SimpleNamespace(),
            {
                "paper_mode": "unknown",
                "status": "blocked",
                "selected_candidate": None,
            },
        )

        self.assertEqual(readiness, "needs_data")


if __name__ == "__main__":
    unittest.main()
