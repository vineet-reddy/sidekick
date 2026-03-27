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

    def test_resolves_explicit_zenodo_dataset_id_before_fuzzy_search(self) -> None:
        resolver = FakeResolver(
            {
                "zenodo.org/api/records/14676310": {
                    "id": 14676310,
                    "doi_url": "https://doi.org/10.5281/zenodo.14676310",
                    "metadata": {
                        "title": "Data for: Changes in the prevalence of autism spectrum disorder among fee-for-service Medicare beneficiaries, 2007-2018",
                        "description": "Administrative prevalence dataset for autism.",
                        "access_right": "open",
                    },
                    "files": [
                        {
                            "key": "autism-prevalence.zip",
                            "links": {"self": "https://zenodo.org/api/records/14676310/files/autism-prevalence.zip/content"},
                        }
                    ],
                },
                "zenodo.org/api/records?q=": {"hits": {"hits": []}},
            }
        )

        resolution = resolver.resolve(
            title="Autism prevalence follow-up",
            theme="Use the already selected prevalence dataset",
            notes=[{"title": "Autism", "content": "Use the explicit dataset that was selected upstream."}],
            dataset_hints=[],
            dataset_ids=["zenodo:14676310"],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.dataset_id, "zenodo:14676310")
        self.assertTrue(resolution.selected_candidate.title.startswith("Data for: Changes"))

    def test_explicit_dataset_id_short_circuits_family_search(self) -> None:
        class StrictExplicitResolver(FakeResolver):
            def _request_json(
                self,
                url: str,
                *,
                method: str = "GET",
                body: dict[str, Any] | None = None,
            ) -> Any:
                if "zenodo.org/api/records?q=" in url:
                    raise AssertionError("fuzzy Zenodo search should not run when dataset_ids are explicit")
                return super()._request_json(url, method=method, body=body)

        resolver = StrictExplicitResolver(
            {
                "zenodo.org/api/records/14676310": {
                    "id": 14676310,
                    "doi_url": "https://doi.org/10.5281/zenodo.14676310",
                    "metadata": {
                        "title": "Data for: Changes in the prevalence of autism spectrum disorder among fee-for-service Medicare beneficiaries, 2007-2018",
                        "description": "Administrative prevalence dataset for autism.",
                        "access_right": "open",
                    },
                    "files": [
                        {
                            "key": "autism-prevalence.zip",
                            "links": {"self": "https://zenodo.org/api/records/14676310/files/autism-prevalence.zip/content"},
                        }
                    ],
                }
            }
        )

        resolution = resolver.resolve(
            title="Autism prevalence follow-up",
            theme="Use the already selected prevalence dataset",
            notes=[{"title": "Autism", "content": "Use the explicit dataset that was selected upstream."}],
            dataset_hints=[],
            dataset_ids=["zenodo:14676310"],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.dataset_id, "zenodo:14676310")

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
            title="Children with epilepsy dataset",
            theme="Children with epilepsy cohort",
            notes=[{"title": "Epilepsy", "content": "Need real data on children with epilepsy."}],
            dataset_hints=["children epilepsy"],
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

    def test_classifies_majorana_threshold_note_as_theoretical_commentary(self) -> None:
        resolver = FakeResolver({})

        resolution = resolver.resolve(
            title="Fault-Tolerance Thresholds for Majorana Tetron Qubits",
            theme="Majorana tetron threshold analysis",
            notes=[
                {
                    "title": "Majorana thresholds",
                    "content": "Need the Kitaev chain Hamiltonian, BdG formalism, braiding operators for Clifford gates, and a heavy math paper deriving the surface code threshold.",
                }
            ],
            dataset_hints=[],
        )

        self.assertEqual(resolution.paper_mode, "theoretical_commentary")

    def test_prefers_topic_relevant_dandi_match_over_generic_modality_match(self) -> None:
        resolver = FakeResolver(
            {
                "api.dandiarchive.org/api/dandisets/": {
                    "results": [
                        {
                            "identifier": "000932",
                            "most_recent_published_version": {
                                "name": "An electroencephalogram microdisplay to visualize neuronal activity on the brain surface",
                                "asset_count": 238,
                                "description": "General electrocorticography methods dataset.",
                            },
                        },
                        {
                            "identifier": "001044",
                            "most_recent_published_version": {
                                "name": "Dataset of long-term multi-site LFP activity with spontaneous chronic seizures recorded in temporal lobe epilepsy rats.",
                                "asset_count": 162,
                                "description": "Chronic epilepsy recordings with seizure annotations.",
                            },
                        },
                    ]
                }
            }
        )

        resolution = resolver.resolve(
            title="Pediatric epilepsy prevalence",
            theme="Need real pediatric epilepsy recordings, not simulation.",
            notes=[{"title": "Epilepsy", "content": "Need real pediatric epilepsy recordings, not simulation."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.dataset_id, "001044")

    def test_epilepsy_prevalence_note_prefers_cohort_dataset_over_recording_dataset(self) -> None:
        resolver = FakeResolver(
            {
                "api.dandiarchive.org/api/dandisets/": {
                    "results": [
                        {
                            "identifier": "001044",
                            "most_recent_published_version": {
                                "name": "Dataset of long-term multi-site LFP activity with spontaneous chronic seizures recorded in temporal lobe epilepsy rats.",
                                "asset_count": 162,
                                "description": "Chronic epilepsy recordings with seizure annotations.",
                            },
                        }
                    ]
                },
                "zenodo.org/api/records": {
                    "hits": {
                        "hits": [
                            {
                                "id": 5117823,
                                "doi_url": "https://doi.org/10.5061/dryad.7sqv9s4s7",
                                "metadata": {
                                    "title": "Epidemiology of epilepsy in Nigeria: A community-based study from 3 sites",
                                    "description": "Population prevalence and incidence tables for epilepsy.",
                                    "access_right": "open",
                                },
                                "files": [
                                    {
                                        "key": "Epidemiology_Data_Incidence___Prevalence_2018_FINAL.xlsx",
                                        "links": {"self": "https://zenodo.org/api/records/5117823/files/file.xlsx/content"},
                                    }
                                ],
                            }
                        ]
                    }
                },
                "dataverse.harvard.edu/api/search": {
                    "data": {
                        "items": [
                            {
                                "name": "Magnetic Resonance Imaging (MRI) Analysis and Neurocognitive Assessment of Children and Young Adults with Chronic Kidney Disease (CKD) \"NiCK\" Study",
                                "global_id": "doi:10.7910/DVN/E7TAHQ",
                                "url": "https://doi.org/10.7910/DVN/E7TAHQ",
                                "description": "Cross-sectional pediatric chronic kidney disease cohort study.",
                                "subjects": ["Medicine, Health and Life Sciences"],
                                "citation": "NiCK Study.",
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
                                    "label": "nick-study.csv",
                                    "dataFile": {
                                        "id": 11460373,
                                        "filename": "nick-study.csv",
                                        "contentType": "text/csv",
                                    },
                                }
                            ]
                        }
                    }
                },
            }
        )

        resolution = resolver.resolve(
            title="Pediatric epilepsy prevalence",
            theme="Need real pediatric epilepsy prevalence data, not recordings.",
            notes=[{"title": "Epilepsy", "content": "Need real pediatric epilepsy prevalence data, not recordings."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.dataset_id, "zenodo:5117823")

    def test_negated_recording_and_gene_expression_terms_do_not_drive_modalities(self) -> None:
        resolver = FakeResolver({})

        resolution = resolver.resolve(
            title="Epilepsy in pediatric Asian populations",
            theme="Epidemiology",
            notes=[
                {
                    "title": "Epilepsy prevalence",
                    "content": "Estimate the prevalence of epilepsy in pediatric Asian populations using real cohort or registry data, not EEG recordings or gene-expression datasets.",
                }
            ],
            dataset_hints=[],
        )

        self.assertIn("clinical_cohort", resolution.inferred_modalities)
        self.assertNotIn("neurophysiology", resolution.inferred_modalities)
        self.assertNotIn("gene_expression", resolution.inferred_modalities)

    def test_cancer_survival_note_prefers_tcga_cohort_over_geo_expression_series(self) -> None:
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
                "eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi": {
                    "esearchresult": {"idlist": ["200305349"]}
                },
                "eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi": {
                    "result": {
                        "uids": ["200305349"],
                        "200305349": {
                            "accession": "GSE305349",
                            "title": "Epigenetic evolution of IDHwt glioblastomas",
                            "summary": "Glioblastoma expression profiling series.",
                            "gdstype": "Expression profiling by high throughput sequencing",
                            "samples": [{"sample": 1}] * 24,
                        },
                    }
                },
                "cbioportal.org/api/studies": [],
            }
        )

        resolution = resolver.resolve(
            title="GBM survival by sex and IDH status",
            theme="glioblastoma survival",
            notes=[{"title": "GBM", "content": "Need survival outcomes stratified by sex and IDH mutation status."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.family_id, "gdc_cancer_genomics")
        self.assertEqual(resolution.selected_candidate.dataset_id, "TCGA-GBM")

    def test_cancer_mutation_note_accepts_public_cbioportal_study_as_primary_data(self) -> None:
        resolver = FakeResolver(
            {
                "api.gdc.cancer.gov/projects": {"data": {"hits": []}},
                "cbioportal.org/api/studies": [
                    {
                        "studyId": "brca_fuscc_2020",
                        "name": "Triple-Negative Breast Cancer (FUSCC, Cell Research 2020)",
                        "description": "Mutation landscape of triple-negative breast cancer including BRCA carriers.",
                        "cancerTypeId": "brca",
                        "allSampleCount": 1,
                        "publicStudy": True,
                        "readPermission": True,
                    }
                ],
                "eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi": {
                    "esearchresult": {"idlist": ["200113909"]}
                },
                "eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi": {
                    "result": {
                        "uids": ["200113909"],
                        "200113909": {
                            "accession": "GSE113909",
                            "title": "Myoepithelial cell perturbations in BRCA mutation carriers",
                            "summary": "Gene expression in BRCA mutation carriers.",
                            "gdstype": "Expression profiling by high throughput sequencing",
                            "samples": [{"sample": 1}] * 12,
                        },
                    }
                },
            }
        )

        resolution = resolver.resolve(
            title="BRCA mutation landscape in triple-negative breast cancer",
            theme="somatic mutation landscape",
            notes=[{"title": "TNBC", "content": "Need a mutation landscape for BRCA carriers vs non-carriers."}],
            dataset_hints=[],
        )

        self.assertEqual(resolution.status, "resolved")
        self.assertIsNotNone(resolution.selected_candidate)
        self.assertEqual(resolution.selected_candidate.family_id, "cbioportal_cancer_studies")
        self.assertTrue(resolution.selected_candidate.qualifies_as_primary_data)


if __name__ == "__main__":
    unittest.main()
