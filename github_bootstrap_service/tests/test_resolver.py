import pathlib
import sys
import unittest
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.resolver import SourceFamilyResolver


class FakeResolver(SourceFamilyResolver):
    def __init__(self, responses: dict[str, Any]) -> None:
        super().__init__()
        self._responses = responses

    def _request_json(
        self,
        url: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
    ) -> Any:
        del method, body
        for key, value in self._responses.items():
            if key in url:
                return value
        return None


class ResolverTests(unittest.TestCase):
    def test_resolves_gdc_for_empirical_glioblastoma_note(self) -> None:
        resolver = FakeResolver(
            {
                "api.gdc.cancer.gov/projects": {
                    "data": {
                        "hits": [
                            {
                                "project_id": "TCGA-GBM",
                                "name": "Glioblastoma Multiforme",
                                "primary_site": ["Brain"],
                                "disease_type": ["Glioblastoma"],
                                "summary": {"case_count": 617, "file_count": 1200},
                            }
                        ]
                    }
                },
                "cbioportal.org/api/studies": [],
            }
        )

        resolution = resolver.resolve(
            title="Sex differences in glioblastoma survival",
            theme="Sex differences in glioblastoma survival",
            notes=[{"title": "GBM", "content": "Need a real glioblastoma cohort and survival analysis."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.paper_mode, "empirical_dataset")
        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.family_id, "gdc_cancer_genomics")
        self.assertEqual(resolution.selected_candidate.dataset_id, "TCGA-GBM")

    def test_blocks_empirical_note_without_qualifying_direct_dataset(self) -> None:
        resolver = FakeResolver(
            {
                "api.gdc.cancer.gov/projects": {
                    "data": {
                        "hits": [
                            {
                                "project_id": "TCGA-GBM",
                                "name": "Glioblastoma Multiforme",
                                "primary_site": ["Brain"],
                                "disease_type": ["Glioblastoma"],
                                "summary": {"case_count": 617, "file_count": 1200},
                            }
                        ]
                    }
                },
                "api.dandiarchive.org/api/dandisets/": {"results": []},
                "openneuro.org/crn/graphql": {"data": {"datasets": {"edges": []}}},
            }
        )

        resolution = resolver.resolve(
            title="Sex differences in pediatric epilepsy responsive neurostimulation",
            theme="Pediatric epilepsy neurophysiology",
            notes=[{"title": "RNS", "content": "Need real pediatric epilepsy recordings, not literature metadata."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.paper_mode, "empirical_dataset")
        self.assertEqual(resolution.status, "blocked")
        self.assertIsNone(resolution.selected_candidate)
        self.assertIn("No qualifying open dataset found", resolution.blocking_reason or "")
        self.assertTrue(all(candidate.family_id != "gdc_cancer_genomics" for candidate in resolution.candidates))

    def test_resolves_openalex_for_literature_review_mode(self) -> None:
        resolver = FakeResolver(
            {
                "api.openalex.org/works": {
                    "results": [
                        {
                            "id": "https://openalex.org/W123",
                            "display_name": "Sex differences in glioblastoma: a literature review",
                            "publication_year": 2024,
                        }
                    ]
                }
            }
        )

        resolution = resolver.resolve(
            title="Literature review of sex differences in glioblastoma",
            theme="literature review",
            notes=[{"title": "Review", "content": "This should be a literature review, not a cohort paper."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.paper_mode, "literature_review")
        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.family_id, "openalex_literature")
        self.assertFalse(resolution.selected_candidate.qualifies_as_primary_data)


if __name__ == "__main__":
    unittest.main()
