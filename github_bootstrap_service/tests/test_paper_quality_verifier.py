import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from github_bootstrap_service.bootstrap_service.openai_client import OpenAIResponseResult, OpenAIUsage
from paperlab import cli
from paperlab.paper_quality import PaperQualityVerifier


class FakeOpenAIClient:
    def __init__(self, payload: dict[str, object]) -> None:
        self._payload = payload

    def generate_json(self, **_: object) -> OpenAIResponseResult:
        return OpenAIResponseResult(
            response_id="resp_paper_quality",
            output_text=json.dumps(self._payload),
            usage=OpenAIUsage(100, 50),
            payload={"status": "completed", "output_text": json.dumps(self._payload)},
        )


class PaperQualityVerifierTests(unittest.TestCase):
    INTRO_TEXT = "This introduction explains the biological setting, the dataset provenance, and the specific empirical question under study."
    METHODS_TEXT = "The methods section describes the preprocessing workflow, the modeling choices, and the exact thresholds used to evaluate candidate signals."
    RESULTS_TEXT = "The results section reports the dominant quantitative findings, ties them to the generated artifacts, and states which outcomes were robust."
    DISCUSSION_TEXT = "The discussion interprets the observed effect sizes carefully, distinguishes signal from uncertainty, and explains why the manuscript remains grounded."
    CONCLUSION_TEXT = "The conclusion restates the empirical contribution in restrained language and limits claims to what the recorded run actually demonstrated."

    def _make_run(self, root: pathlib.Path, tex_text: str) -> pathlib.Path:
        run_dir = root / "run-1"
        run_dir.mkdir(parents=True)
        (run_dir / "paper.tex").write_text(tex_text, encoding="utf-8")
        (run_dir / "references.bib").write_text("@misc{ref1,title={Ref},year={2024}}", encoding="utf-8")
        (run_dir / "ledger.json").write_text(json.dumps({"results": [{"text": "Result 1"}]}), encoding="utf-8")
        (run_dir / "validation.json").write_text(json.dumps({"status": "paper"}), encoding="utf-8")
        (run_dir / "artifact_manifest.json").write_text(
            json.dumps({"figures": [{"path": "figures/figure_1.png"}], "tables": [{"path": "tables/table_1.csv"}]}),
            encoding="utf-8",
        )
        (run_dir / "figures").mkdir()
        (run_dir / "figures" / "figure_1.png").write_bytes(b"fake")
        (run_dir / "tables").mkdir()
        (run_dir / "tables" / "table_1.csv").write_text("a,b\n1,2\n", encoding="utf-8")
        return run_dir

    def test_deterministic_review_catches_placeholders_and_missing_sections(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            golden_root = root / "goldens"
            golden_root.mkdir()
            (golden_root / "rules.md").write_text("rules", encoding="utf-8")
            run_dir = self._make_run(
                root,
                r"""
\documentclass{article}
\title{Test}
\author{}
\begin{document}
\maketitle
\begin{abstract}
Abstract [[CITE:ref1]]
\end{abstract}
\section{Introduction}
Intro
\section{Results}
Results
\bibliography{references}
\end{document}
""".strip(),
            )
            verifier = PaperQualityVerifier(openai_client=None, golden_root=golden_root)
            with patch("paperlab.paper_quality.compile_pdf", return_value={"ok": True, "error": "", "log": "", "pdf_path": "paper.pdf"}):
                payload = verifier.verify_target(PaperQualityVerifier.resolve_target_from_ref(target_ref=str(run_dir), runs_root=root), skip_llm=True)

            self.assertFalse(payload["deterministic"]["passed"])
            self.assertIn("placeholder_citation", payload["deterministic"]["failed_checks"])
            self.assertIn("missing_required_sections", payload["deterministic"]["failed_checks"])
            self.assertEqual(payload["overall_status"], "fail")

    def test_hybrid_review_requires_llm_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            golden_root = root / "goldens"
            case_dir = golden_root / "01_case"
            case_dir.mkdir(parents=True)
            (golden_root / "rules.md").write_text("rules", encoding="utf-8")
            (case_dir / "golden.tex").write_text(r"\documentclass{article}\section{Introduction}", encoding="utf-8")
            (case_dir / "notes.txt").write_text("clock and cancer", encoding="utf-8")
            run_dir = self._make_run(
                root,
                r"""
\documentclass{article}
\title{Good Paper}
\author{Author}
\begin{document}
\maketitle
\begin{abstract}
This abstract summarizes the motivating question, the evidence produced by the run, and the narrow conclusion supported by those results.
\end{abstract}
\section{Introduction}
"""
                + self.INTRO_TEXT
                + r"""
\section{Data And Methods}
"""
                + self.METHODS_TEXT
                + r"""
\section{Results}
"""
                + self.RESULTS_TEXT
                + r"""
\section{Discussion}
"""
                + self.DISCUSSION_TEXT
                + r"""
\section{Conclusion}
"""
                + self.CONCLUSION_TEXT
                + r"""
\bibliography{references}
\end{document}
""".strip(),
            )
            verifier = PaperQualityVerifier(
                openai_client=FakeOpenAIClient(
                    {
                        "verdict": "pass",
                        "scientific_credibility_score": 4,
                        "formatting_quality_score": 4,
                        "artifact_grounding_score": 5,
                        "golden_style_match_score": 4,
                        "clarity_score": 4,
                        "major_failures": [],
                        "reward_hacking_signals": [],
                        "summary": "Looks strong and grounded.",
                    }
                ),
                llm_model="gpt-5-mini",
                golden_root=golden_root,
            )
            with patch("paperlab.paper_quality.compile_pdf", return_value={"ok": True, "error": "", "log": "", "pdf_path": "paper.pdf"}):
                payload = verifier.verify_target(PaperQualityVerifier.resolve_target_from_ref(target_ref=str(run_dir), runs_root=root), skip_llm=False)

            self.assertTrue(payload["deterministic"]["passed"])
            self.assertEqual(payload["llm_review"]["verdict"], "pass")
            self.assertTrue(payload["passed"])

    def test_cli_paper_quality_verify_supports_skip_llm(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            run_root = root / "runs"
            golden_root = root / "goldens"
            case_dir = golden_root / "01_case"
            case_dir.mkdir(parents=True)
            (golden_root / "rules.md").write_text("rules", encoding="utf-8")
            (case_dir / "golden.tex").write_text(r"\documentclass{article}\section{Introduction}", encoding="utf-8")
            (case_dir / "notes.txt").write_text("sample", encoding="utf-8")
            run_dir = self._make_run(
                run_root,
                r"""
\documentclass{article}
\title{Paper}
\author{Author}
\begin{document}
\maketitle
\begin{abstract}This abstract states the question, the observed result, and the grounded conclusion without relying on placeholders or filler text.\end{abstract}
\section{Introduction}"""
                + self.INTRO_TEXT
                + r"""
\section{Data And Methods}"""
                + self.METHODS_TEXT
                + r"""
\section{Results}"""
                + self.RESULTS_TEXT
                + r"""
\section{Discussion}"""
                + self.DISCUSSION_TEXT
                + r"""
\section{Conclusion}"""
                + self.CONCLUSION_TEXT
                + r"""
\bibliography{references}
\end{document}
""".strip(),
            )

            with patch.object(cli, "RUNS_ROOT", run_root), patch(
                "paperlab.paper_quality.compile_pdf",
                return_value={"ok": True, "error": "", "log": "", "pdf_path": "paper.pdf"},
            ):
                exit_code = cli.main(
                    [
                        "paper-quality",
                        "verify",
                        str(run_dir),
                        "--skip-llm",
                        "--golden-root",
                        str(golden_root),
                        "--json",
                    ]
                )

            self.assertEqual(exit_code, 1)

    def test_abstract_environment_counts_as_required_section(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            golden_root = root / "goldens"
            golden_root.mkdir()
            (golden_root / "rules.md").write_text("rules", encoding="utf-8")
            run_dir = self._make_run(
                root,
                r"""
\documentclass{article}
\title{Abstract Paper}
\author{Author}
\begin{document}
\maketitle
\begin{abstract}
This abstract provides enough content to count as a meaningful manuscript summary for deterministic validation.
\end{abstract}
\section{Introduction}"""
                + self.INTRO_TEXT
                + r"""
\section{Methods}"""
                + self.METHODS_TEXT
                + r"""
\section{Results}"""
                + self.RESULTS_TEXT
                + r"""
\section{Discussion}"""
                + self.DISCUSSION_TEXT
                + r"""
\section{Conclusion}"""
                + self.CONCLUSION_TEXT
                + r"""
\bibliography{references}
\end{document}
""".strip(),
            )
            verifier = PaperQualityVerifier(openai_client=None, golden_root=golden_root)
            with patch("paperlab.paper_quality.compile_pdf", return_value={"ok": True, "error": "", "log": "", "pdf_path": "paper.pdf"}):
                payload = verifier.verify_target(PaperQualityVerifier.resolve_target_from_ref(target_ref=str(run_dir), runs_root=root), skip_llm=True)

            self.assertNotIn("missing_required_sections", payload["deterministic"]["failed_checks"])
            self.assertIn("abstract", payload["deterministic"]["sections_present"])


if __name__ == "__main__":
    unittest.main()
