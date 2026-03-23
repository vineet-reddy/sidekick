import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from bootstrap_service.server import _find_analysis_bundle_quality_issues, _find_bundle_quality_issues


def _full_markdown() -> str:
    base = """
# Abstract

This paper analyzes a real public dataset and reports empirical results with citations [1], [2].

# Introduction

We study the question in the context of prior literature [1], [2], [3], [4].

# Methods

We download the public data, preprocess it, fit models, and evaluate outcomes with preregistered-style metrics [1].

# Results

We report effect sizes, uncertainty intervals, and robustness checks [2], [3].

# Discussion

We interpret the findings conservatively and compare them with prior work [4].

# Limitations

The analysis depends on public observational data and should be interpreted within that scope.

# References

1. Author A. Real dataset paper. 2022.
2. Author B. Method paper. 2021.
3. Author C. Validation paper. 2020.
4. Author D. Replication paper. 2019.
"""
    filler = "\n".join(
        f"Additional empirical detail sentence {index} with supporting context and citation [1]."
        for index in range(260)
    )
    return f"{base}\n{filler}\n"


def _full_latex() -> str:
    filler = "\n".join(
        f"Empirical sentence {index} with supporting citation \\cite{{ref{(index % 4) + 1}}}."
        for index in range(220)
    )
    return rf"""
\documentclass{{article}}
\begin{{document}}
\begin{{abstract}}
This paper reports empirical results on a real public dataset \cite{{ref1}}.
\end{{abstract}}
\section{{Introduction}}
Background and motivation \cite{{ref1,ref2}}.
\section{{Methods}}
Methods and data processing \cite{{ref2}}.
\section{{Results}}
Results and effect estimates \cite{{ref3}}.
\section{{Discussion}}
Interpretation and caveats \cite{{ref4}}.
\section{{References}}
\begin{{thebibliography}}{{9}}
\bibitem{{ref1}} Ref 1.
\bibitem{{ref2}} Ref 2.
\bibitem{{ref3}} Ref 3.
\bibitem{{ref4}} Ref 4.
\end{{thebibliography}}
{filler}
\end{{document}}
"""


def _valid_bundle() -> dict:
    return {
        "title": "Real public data analysis of interneuron perturbation and spike coupling",
        "markdown": _full_markdown(),
        "latex": _full_latex(),
        "analysis_files": [
            {"path": "analysis.py", "content": "print('run')"},
            {"path": "requirements.txt", "content": "numpy\npandas\nmatplotlib"},
            {"path": "Makefile", "content": "run:\n\tpython analysis.py"},
        ],
        "figures": [
            {
                "filename": "figure_1.png",
                "caption": "Empirical result figure.",
                "mime_type": "image/png",
                "base64_data": "ZmFrZQ==",
            }
        ],
        "manifest": {
            "entrypoint": "analysis.py",
            "python_version": "3.11",
            "run_command": "python analysis.py",
            "notes_hash": "abc",
            "model": "gpt-5.4",
            "dataset_sources": ["DANDI:000123"],
        },
        "provenance": {
            "used_dataset_ids": ["DANDI:000123"],
            "accessed_domains": ["dandiarchive.org"],
            "left_trusted_set": False,
            "external_sources": ["https://dandiarchive.org/dandiset/000123"],
            "notes": "Used a public DANDI dataset and cited external literature.",
        },
        "resolver": {
            "paper_mode": "empirical_dataset",
            "inferred_modalities": ["neurophysiology"],
            "acceptable_units": ["recording_session", "subject"],
            "incompatible_primary_family_ids": ["openalex_literature", "pubmed_literature"],
            "status": "resolved",
            "summary": "Selected DANDI:000123 from DANDI Neurophysiology as the primary empirical source.",
            "blocking_reason": None,
            "selected_candidate": {
                "family_id": "dandi_neurophysiology",
                "family_label": "DANDI Neurophysiology",
                "dataset_id": "DANDI:000123",
                "title": "Example DANDI dataset",
                "summary": "Example empirical neurophysiology dataset.",
                "access_url": "https://dandiarchive.org/dandiset/000123",
                "primary_domain": "dandiarchive.org",
                "trusted_domains": ["dandiarchive.org", "api.dandiarchive.org"],
                "unit_of_analysis": "recording_session_or_subject",
                "modalities": ["neurophysiology"],
                "score": 24.0,
                "evidence_count": 8,
                "qualifies_as_primary_data": True,
                "provenance_note": "Resolved deterministically from the DANDI API.",
            },
            "candidates": [],
        },
        "inspection": {
            "dataset_manifest": {
                "primary_dataset_ids": ["DANDI:000123"],
                "data_sources": ["DANDI Archive"],
                "sample_description": "124 neurons across 8 sessions.",
                "row_count": 128000,
                "selected_variables": ["spike_times", "lfp", "stimulus_epoch"],
                "quality_notes": ["Session QC and artifact rejection completed."],
            },
            "access_notes": "Downloaded public NWB files.",
            "quality_checks": ["QC passed."],
            "analysis_checklist": ["All analysis steps executed."],
        },
        "analysis": {
            "dataset_manifest": {
                "primary_dataset_ids": ["DANDI:000123"],
                "data_sources": ["DANDI Archive"],
                "sample_description": "124 neurons across 8 sessions.",
                "row_count": 128000,
                "selected_variables": ["spike_times", "lfp", "stimulus_epoch"],
                "quality_notes": ["Session QC and artifact rejection completed."],
            },
            "narrative_summary": "Empirical summary of the observed results.",
            "findings": [
                {
                    "claim": "Claim one.",
                    "estimate": "0.14",
                    "uncertainty": "95% CI 0.09 to 0.18",
                    "evidence": "Regression table and figure 1.",
                    "supports_hypothesis": True,
                },
                {
                    "claim": "Claim two.",
                    "estimate": "0.21",
                    "uncertainty": "95% CI 0.11 to 0.29",
                    "evidence": "Permutation analysis and figure 1.",
                    "supports_hypothesis": True,
                },
            ],
            "tables": [
                {
                    "identifier": "table_1",
                    "title": "Main effects",
                    "columns": ["metric", "value"],
                    "rows": [["effect", "0.14"]],
                    "notes": "Main regression output.",
                }
            ],
            "figures": [
                {
                    "filename": "figure_1.png",
                    "caption": "Empirical result figure.",
                    "mime_type": "image/png",
                    "base64_data": "ZmFrZQ==",
                }
            ],
            "limitations": ["Observational dataset limitations are described in the paper."],
            "provenance": {
                "used_dataset_ids": ["DANDI:000123"],
                "accessed_domains": ["dandiarchive.org"],
                "left_trusted_set": False,
                "external_sources": ["https://dandiarchive.org/dandiset/000123"],
                "notes": "The analysis used real public data.",
            },
        },
        "verification": {
            "decision": "proceed",
            "summary": "Evidence supports publication-quality empirical claims.",
            "supported_claims": ["Main effect is supported."],
            "weak_or_unsupported_claims": [],
            "figure_sanity_checks": [{"filename": "figure_1.png", "status": "ok", "issue": ""}],
            "model_warnings": [],
            "sample_warnings": [],
            "required_revisions": [],
        },
        "draft": {
            "title": "Real public data analysis of interneuron perturbation and spike coupling",
            "markdown": _full_markdown(),
        },
    }


class PublicationGateTests(unittest.TestCase):
    def test_accepts_publication_like_bundle(self) -> None:
        self.assertEqual(_find_bundle_quality_issues(_valid_bundle()), [])

    def test_rejects_synthetic_draft_bundle(self) -> None:
        bundle = _valid_bundle()
        bundle["title"] = "Synthetic demo draft"
        bundle["markdown"] = "# Abstract\nThis draft uses synthetic data and is only illustrative.\n"
        bundle["latex"] = "\\begin{abstract}Synthetic draft\\end{abstract}"
        bundle["manifest"]["dataset_sources"] = []
        bundle["provenance"]["used_dataset_ids"] = []
        bundle["analysis"]["dataset_manifest"]["row_count"] = 0
        bundle["verification"]["decision"] = "blocked"

        issues = _find_bundle_quality_issues(bundle)
        self.assertTrue(any("banned draft/demo language" in issue for issue in issues))
        self.assertTrue(any("Verification did not approve publication" in issue for issue in issues))
        self.assertTrue(any("row count" in issue for issue in issues))

    def test_rejects_bundle_that_ignores_resolver_selected_dataset(self) -> None:
        bundle = _valid_bundle()
        bundle["manifest"]["dataset_sources"] = ["OpenAlex:W123"]
        bundle["analysis"]["dataset_manifest"]["primary_dataset_ids"] = ["OpenAlex:W123"]
        bundle["inspection"]["dataset_manifest"]["primary_dataset_ids"] = ["OpenAlex:W123"]
        bundle["provenance"]["used_dataset_ids"] = ["OpenAlex:W123"]
        bundle["analysis"]["provenance"]["used_dataset_ids"] = ["OpenAlex:W123"]

        issues = _find_bundle_quality_issues(bundle)
        self.assertTrue(any("resolver-selected dataset id" in issue for issue in issues))
        self.assertTrue(any("resolver-selected dataset URL" in issue for issue in issues))

    def test_does_not_reject_bare_placeholder_word_without_fake_data_context(self) -> None:
        bundle = _valid_bundle()
        bundle["provenance"]["notes"] = "Repository cleanup removed an old placeholder comment before final export."
        bundle["analysis"]["provenance"]["notes"] = "A placeholder token in earlier local code was removed before analysis."
        bundle["inspection"]["access_notes"] = "Data were downloaded normally."

        self.assertEqual(_find_analysis_bundle_quality_issues(bundle), [])
        self.assertEqual(_find_bundle_quality_issues(bundle), [])


if __name__ == "__main__":
    unittest.main()
