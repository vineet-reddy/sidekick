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

    def test_falls_back_to_dataverse_for_niche_empirical_note(self) -> None:
        resolver = FakeResolver(
            {
                "api.dandiarchive.org/api/dandisets/": {"results": []},
                "openneuro.org/crn/graphql": {"data": {"datasets": {"edges": []}}},
                "dataverse.harvard.edu/api/search": {
                    "data": {
                        "items": [
                            {
                                "name": "EM in children with epilepsy all data",
                                "global_id": "doi:10.7910/DVN/W6P50R",
                                "url": "https://doi.org/10.7910/DVN/W6P50R",
                                "description": "Raw data on eye movement abnormalities in children with epilepsy.",
                                "subjects": ["Medicine, Health and Life Sciences"],
                                "citation": "Lunn, Judith, 2016.",
                            }
                        ]
                    }
                },
                "dataverse.harvard.edu/api/datasets/:persistentId/": {
                    "data": {
                        "latestVersion": {
                            "files": [
                                {
                                    "restricted": False,
                                    "label": "EMinCWEProportionsData-2.tab",
                                    "dataFile": {
                                        "id": 2839479,
                                        "filename": "EMinCWEProportionsData-2.tab",
                                        "contentType": "text/tab-separated-values",
                                    },
                                }
                            ]
                        }
                    }
                },
            }
        )

        resolution = resolver.resolve(
            title="Sex differences in pediatric epilepsy responsive neurostimulation",
            theme="Pediatric epilepsy neurophysiology",
            notes=[{"title": "RNS", "content": "Need a small but real pediatric epilepsy dataset if available."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.family_id, "harvard_dataverse_open_data")
        self.assertTrue(resolution.selected_candidate.qualifies_as_primary_data)
        self.assertTrue(resolution.selected_candidate.download_urls)

    def test_rejects_zenodo_pdf_only_hit_as_primary_data(self) -> None:
        resolver = FakeResolver(
            {
                "zenodo.org/api/records": {
                    "hits": {
                        "hits": [
                            {
                                "id": 3662579,
                                "doi_url": "https://doi.org/10.5281/zenodo.3662579",
                                "metadata": {
                                    "title": "Epilepsy methods paper",
                                    "description": "Epilepsy lateralization using scalp EEG.",
                                    "access_right": "open",
                                },
                                "files": [
                                    {
                                        "key": "paper.pdf",
                                        "links": {"self": "https://zenodo.org/api/records/3662579/files/paper.pdf/content"},
                                    }
                                ],
                            }
                        ]
                    }
                }
            }
        )

        resolution = resolver.resolve(
            title="Epilepsy signal analysis",
            theme="Epilepsy neurophysiology",
            notes=[{"title": "Signals", "content": "Need real open data."}],
            dataset_hints=[],
        )

        zenodo_candidates = [candidate for candidate in resolution.candidates if candidate.family_id == "zenodo_open_research"]
        self.assertTrue(zenodo_candidates)
        self.assertFalse(zenodo_candidates[0].qualifies_as_primary_data)


if __name__ == "__main__":
    unittest.main()
