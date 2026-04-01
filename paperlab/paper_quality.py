from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from github_bootstrap_service.bootstrap_service.manuscript import compile_pdf
from github_bootstrap_service.bootstrap_service.openai_client import OpenAIClient, OpenAIClientError


REQUIRED_SECTION_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("abstract", ("abstract",)),
    ("introduction", ("introduction",)),
    ("data and methods", ("data and methods", "methods", "materials and methods")),
    ("results", ("results",)),
    ("discussion", ("discussion",)),
    ("conclusion", ("conclusion",)),
    ("references", ("references",)),
)

PLACEHOLDER_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("placeholder_citation", re.compile(r"\[\[(?:CITE|REF):", re.IGNORECASE)),
    ("todo_marker", re.compile(r"\b(?:TODO|TBD|FIXME|XXX)\b", re.IGNORECASE)),
    ("lorem_ipsum", re.compile(r"lorem ipsum", re.IGNORECASE)),
)

COMPILE_ERROR_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("undefined_control_sequence", re.compile(r"Undefined control sequence", re.IGNORECASE)),
    ("latex_error", re.compile(r"! LaTeX Error:", re.IGNORECASE)),
    ("emergency_stop", re.compile(r"Emergency stop", re.IGNORECASE)),
    ("undefined_reference", re.compile(r"Reference `[^`]+` .* undefined", re.IGNORECASE)),
    ("undefined_citation", re.compile(r"Citation `[^`]+` .* undefined", re.IGNORECASE)),
    ("rerun_cross_references", re.compile(r"Label\(s\) may have changed\. Rerun", re.IGNORECASE)),
)

COMPILE_WARNING_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("overfull_hbox", re.compile(r"Overfull \\hbox", re.IGNORECASE)),
    ("underfull_hbox", re.compile(r"Underfull \\hbox", re.IGNORECASE)),
    ("multiply_defined_label", re.compile(r"multiply defined", re.IGNORECASE)),
)

FIGURE_REF_PATTERN = re.compile(r"\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}")
SECTION_PATTERN = re.compile(r"\\section\{([^}]+)\}", re.IGNORECASE)
ABSTRACT_PATTERN = re.compile(r"\\begin\{abstract\}(.*?)\\end\{abstract\}", re.IGNORECASE | re.DOTALL)
BEGIN_ENV_PATTERN = re.compile(r"\\begin\{(figure|table)\}")
END_ENV_PATTERN = re.compile(r"\\end\{(figure|table)\}")
TITLE_PATTERN = re.compile(r"\\title\{([^}]*)\}")
AUTHOR_PATTERN = re.compile(r"\\author\{([^}]*)\}")
BIBLIOGRAPHY_PATTERN = re.compile(r"\\bibliography\{([^}]*)\}")
THEBIB_PATTERN = re.compile(r"\\begin\{thebibliography\}", re.IGNORECASE)
CITE_PATTERN = re.compile(r"\\cite[a-zA-Z*]*\{[^}]+\}")
BIBITEM_PATTERN = re.compile(r"\\bibitem\{[^}]+\}")


@dataclass(frozen=True)
class VerificationTarget:
    run_directory: Path
    tex_path: Path
    manuscript_kind: str


class PaperQualityVerifier:
    def __init__(
        self,
        *,
        openai_client: OpenAIClient | None,
        llm_model: str | None = None,
        llm_timeout_seconds: int = 300,
        golden_root: Path,
        max_golden_examples: int = 3,
    ):
        self._openai_client = openai_client
        self._llm_model = (llm_model or "").strip() or None
        self._llm_timeout_seconds = max(30, int(llm_timeout_seconds))
        self._golden_root = golden_root.expanduser().resolve()
        self._max_golden_examples = max(1, int(max_golden_examples))

    def verify_target(self, target: VerificationTarget, *, skip_llm: bool = False) -> dict[str, Any]:
        deterministic = self._deterministic_review(target)
        llm_review = self._llm_review(target, deterministic=deterministic, skip_llm=skip_llm)
        overall_passed = bool(deterministic.get("passed")) and str(llm_review.get("verdict") or "").strip().lower() == "pass"
        overall_status = "pass" if overall_passed else "fail"
        if deterministic.get("passed") and str(llm_review.get("status") or "").strip() == "skipped":
            overall_status = "needs_llm_review"
        return {
            "target": {
                "run_directory": str(target.run_directory),
                "tex_path": str(target.tex_path),
                "manuscript_kind": target.manuscript_kind,
            },
            "overall_status": overall_status,
            "passed": overall_passed,
            "deterministic": deterministic,
            "llm_review": llm_review,
            "score": self._combined_score(deterministic=deterministic, llm_review=llm_review),
            "summary": self._overall_summary(deterministic=deterministic, llm_review=llm_review, overall_status=overall_status),
        }

    def _deterministic_review(self, target: VerificationTarget) -> dict[str, Any]:
        tex_text = target.tex_path.read_text(encoding="utf-8", errors="replace")
        compile_result = compile_pdf(target.run_directory, tex_filename=target.tex_path.name)
        compile_log = str(compile_result.get("log") or "").strip()
        if str(compile_result.get("error") or "").strip():
            compile_log = ((compile_log + "\n\n") if compile_log else "") + str(compile_result.get("error") or "").strip()

        failed_checks: list[str] = []
        warnings: list[str] = []

        if not bool(compile_result.get("ok")):
            failed_checks.append("latex_compile_failed")

        for label, pattern in PLACEHOLDER_PATTERNS:
            if pattern.search(tex_text):
                failed_checks.append(label)

        compile_error_hits = self._pattern_hits(COMPILE_ERROR_PATTERNS, compile_log)
        failed_checks.extend(label for label in compile_error_hits if label not in failed_checks)

        compile_warning_hits = self._pattern_hits(COMPILE_WARNING_PATTERNS, compile_log)
        warnings.extend(label for label in compile_warning_hits if label not in warnings)

        present_sections = self._present_sections(tex_text)
        section_details = self._section_details(tex_text)
        missing_sections = [section for section, aliases in REQUIRED_SECTION_GROUPS if not any(alias in present_sections for alias in aliases)]
        if missing_sections:
            failed_checks.append("missing_required_sections")
        short_sections = [section for section, details in section_details.items() if details["content_length"] < 40]
        if short_sections:
            failed_checks.append("low_content_sections")
        out_of_order_sections = self._section_order_issues(section_details)
        if out_of_order_sections:
            failed_checks.append("section_order_violation")

        title_match = TITLE_PATTERN.search(tex_text)
        author_match = AUTHOR_PATTERN.search(tex_text)
        if not title_match or not str(title_match.group(1) or "").strip():
            failed_checks.append("missing_title")
        if not author_match or not str(author_match.group(1) or "").strip():
            warnings.append("missing_authors")

        env_balance = self._environment_balance(tex_text)
        if env_balance["figure"]["begin"] != env_balance["figure"]["end"]:
            failed_checks.append("unbalanced_figure_environments")
        if env_balance["table"]["begin"] != env_balance["table"]["end"]:
            failed_checks.append("unbalanced_table_environments")

        figure_paths = self._resolve_figure_paths(tex_text, target.run_directory)
        missing_figure_paths = [path for path in figure_paths if not path.exists()]
        if missing_figure_paths:
            failed_checks.append("missing_figure_assets")

        bibliography_mode = "thebibliography" if THEBIB_PATTERN.search(tex_text) else "bibtex" if BIBLIOGRAPHY_PATTERN.search(tex_text) else "missing"
        if bibliography_mode == "missing":
            failed_checks.append("missing_bibliography")
        elif bibliography_mode == "bibtex":
            warnings.append("uses_bibtex_not_thebibliography")
        if bibliography_mode == "thebibliography" and not BIBITEM_PATTERN.search(tex_text):
            failed_checks.append("empty_bibliography")
        if not CITE_PATTERN.search(tex_text):
            warnings.append("no_citations_detected")

        artifact_manifest = self._read_json(target.run_directory / "artifact_manifest.json")
        manifest_figures = artifact_manifest.get("figures") if isinstance(artifact_manifest.get("figures"), list) else []
        manifest_tables = artifact_manifest.get("tables") if isinstance(artifact_manifest.get("tables"), list) else []
        if not manifest_figures:
            warnings.append("no_manifest_figures")
        elif len(manifest_figures) < 3:
            warnings.append("fewer_than_three_figures")
        if not manifest_tables:
            warnings.append("no_manifest_tables")

        validation = self._read_json(target.run_directory / "validation.json")
        ledger = self._read_json(target.run_directory / "ledger.json")
        if not validation:
            warnings.append("missing_validation_json")
        if not ledger:
            warnings.append("missing_ledger_json")
        elif not self._ledger_has_empirical_results(ledger):
            failed_checks.append("ledger_missing_empirical_results")

        deterministic_score = max(
            0,
            100
            - (25 * sum(1 for item in failed_checks if item == "latex_compile_failed"))
            - (12 * sum(1 for item in failed_checks if item != "latex_compile_failed"))
            - (3 * len(warnings)),
        )
        summary = "Deterministic manuscript checks passed."
        if failed_checks:
            summary = "Deterministic manuscript checks failed."
        elif warnings:
            summary = "Deterministic manuscript checks passed with warnings."

        return {
            "passed": not failed_checks,
            "score": deterministic_score,
            "failed_checks": failed_checks,
            "warnings": warnings,
            "summary": summary,
            "compile": {
                "ok": bool(compile_result.get("ok")),
                "pdf_path": str(compile_result.get("pdf_path") or ""),
                "error": str(compile_result.get("error") or "").strip(),
                "log_excerpt": self._clip_text(compile_log, limit=4000),
            },
            "sections_present": sorted(present_sections),
            "missing_sections": missing_sections,
            "short_sections": short_sections,
            "out_of_order_sections": out_of_order_sections,
            "figure_asset_count": len(manifest_figures),
            "table_asset_count": len(manifest_tables),
            "bibliography_mode": bibliography_mode,
        }

    def _llm_review(self, target: VerificationTarget, *, deterministic: dict[str, Any], skip_llm: bool) -> dict[str, Any]:
        if skip_llm:
            return {
                "status": "skipped",
                "verdict": "skipped",
                "summary": "LLM manuscript review was skipped.",
                "score": None,
                "major_failures": [],
                "reward_hacking_signals": [],
            }
        if self._openai_client is None:
            return {
                "status": "skipped",
                "verdict": "skipped",
                "summary": "LLM manuscript review was unavailable because no OpenAI client was configured.",
                "score": None,
                "major_failures": [],
                "reward_hacking_signals": [],
            }

        tex_text = target.tex_path.read_text(encoding="utf-8", errors="replace")
        ledger = self._read_json(target.run_directory / "ledger.json")
        validation = self._read_json(target.run_directory / "validation.json")
        artifact_manifest = self._read_json(target.run_directory / "artifact_manifest.json")
        compile_log = ""
        compile_path = target.run_directory / "compile.log"
        if compile_path.exists():
            compile_log = compile_path.read_text(encoding="utf-8", errors="replace")

        goldens = self._select_golden_examples(tex_text)
        rules_text = (self._golden_root / "rules.md").read_text(encoding="utf-8", errors="replace") if (self._golden_root / "rules.md").exists() else ""
        instructions = """
You are Sidekick's paper-quality judge.

You must evaluate whether a generated manuscript is actually good scientific writing, not merely a manuscript that games deterministic checks.

Your job is to detect reward hacking and fail papers that look polished but are not grounded in the run artifacts or do not resemble the golden papers in discipline and credibility.

Return strict JSON only:
{
  "verdict": "pass or fail",
  "scientific_credibility_score": 0,
  "formatting_quality_score": 0,
  "artifact_grounding_score": 0,
  "golden_style_match_score": 0,
  "clarity_score": 0,
  "major_failures": ["string"],
  "reward_hacking_signals": ["string"],
  "summary": "string"
}

Rules:
- Fail the manuscript if it makes claims that are not clearly supported by the ledger/results/artifacts.
- Fail the manuscript if it uses generic scientific filler, hollow paper-like structure, fake-looking rigor, or formatting that still looks sloppy to a human reader.
- Fail the manuscript if it superficially imitates the golden papers without their empirical grounding.
- Do not forgive missing scientific substance just because the manuscript compiles.
- Scores are 0-5 integers, where 5 is strong.
- Use the golden dataset rules and examples as style and rigor references, not as text to copy.
"""
        input_payload = {
            "deterministic_review": deterministic,
            "rules": rules_text,
            "golden_examples": goldens,
            "ledger": ledger,
            "validation": validation,
            "artifact_manifest": artifact_manifest,
            "compile_log_excerpt": self._clip_text(compile_log, limit=3000),
            "manuscript_tex": self._clip_text(tex_text, limit=18000),
        }
        try:
            response = self._openai_client.generate_json(
                instructions=instructions,
                input_text=json.dumps(input_payload, indent=2, sort_keys=True),
                use_code_interpreter=False,
                use_web_search=False,
                timeout_seconds=self._llm_timeout_seconds,
                model=self._llm_model,
                reasoning_effort="medium",
            )
        except OpenAIClientError as error:
            return {
                "status": "error",
                "verdict": "fail",
                "summary": f"LLM manuscript review failed: {error}",
                "score": None,
                "major_failures": ["llm_review_error"],
                "reward_hacking_signals": [],
            }

        parsed = self._extract_json_object(response.output_text)
        scientific = self._bounded_score(parsed.get("scientific_credibility_score"))
        formatting = self._bounded_score(parsed.get("formatting_quality_score"))
        grounding = self._bounded_score(parsed.get("artifact_grounding_score"))
        style = self._bounded_score(parsed.get("golden_style_match_score"))
        clarity = self._bounded_score(parsed.get("clarity_score"))
        score = round(((scientific + formatting + grounding + style + clarity) / 25) * 100, 2)
        verdict = str(parsed.get("verdict") or "fail").strip().lower()
        if verdict not in {"pass", "fail"}:
            verdict = "fail"
        return {
            "status": "completed",
            "verdict": verdict,
            "summary": str(parsed.get("summary") or "").strip() or "LLM manuscript review completed.",
            "score": score,
            "major_failures": self._text_list(parsed.get("major_failures")),
            "reward_hacking_signals": self._text_list(parsed.get("reward_hacking_signals")),
            "subscores": {
                "scientific_credibility": scientific,
                "formatting_quality": formatting,
                "artifact_grounding": grounding,
                "golden_style_match": style,
                "clarity": clarity,
            },
            "response_id": response.response_id,
        }

    def _select_golden_examples(self, tex_text: str) -> list[dict[str, str]]:
        manuscript_tokens = self._tokenize(tex_text)
        candidates: list[tuple[int, Path]] = []
        for path in sorted(self._golden_root.glob("*/golden.tex")):
            folder = path.parent
            note_text = ""
            notes_path = folder / "notes.txt"
            if notes_path.exists():
                note_text = notes_path.read_text(encoding="utf-8", errors="replace")
            score = len(manuscript_tokens & self._tokenize(note_text + "\n" + path.read_text(encoding="utf-8", errors="replace")[:4000]))
            candidates.append((score, path))
        selected = [path for _, path in sorted(candidates, key=lambda item: item[0], reverse=True)[: self._max_golden_examples]]
        return [
            {
                "name": path.parent.name,
                "notes": self._clip_text((path.parent / "notes.txt").read_text(encoding="utf-8", errors="replace") if (path.parent / "notes.txt").exists() else "", limit=2500),
                "golden_tex_excerpt": self._clip_text(path.read_text(encoding="utf-8", errors="replace"), limit=5000),
            }
            for path in selected
        ]

    @staticmethod
    def _resolve_target(target: Path) -> VerificationTarget:
        if target.is_dir():
            tex_path = target / "paper.tex"
            manuscript_kind = "paper"
            if not tex_path.exists():
                tex_path = target / "memo.tex"
                manuscript_kind = "memo"
            if not tex_path.exists():
                raise FileNotFoundError(f"No paper.tex or memo.tex found under {target}")
            return VerificationTarget(run_directory=target, tex_path=tex_path, manuscript_kind=manuscript_kind)
        if target.is_file():
            manuscript_kind = "memo" if target.name == "memo.tex" else "paper"
            return VerificationTarget(run_directory=target.parent, tex_path=target, manuscript_kind=manuscript_kind)
        raise FileNotFoundError(f"Unknown verification target: {target}")

    @staticmethod
    def resolve_target_from_ref(*, target_ref: str, runs_root: Path) -> VerificationTarget:
        if target_ref == "latest":
            candidates = [path for path in runs_root.iterdir() if path.is_dir()] if runs_root.exists() else []
            if not candidates:
                raise FileNotFoundError("No Sidekick runs exist yet.")
            return PaperQualityVerifier._resolve_target(max(candidates, key=lambda path: path.stat().st_mtime))
        candidate = Path(target_ref).expanduser()
        if candidate.exists():
            return PaperQualityVerifier._resolve_target(candidate.resolve())
        candidate = runs_root / target_ref
        if candidate.exists():
            return PaperQualityVerifier._resolve_target(candidate.resolve())
        raise FileNotFoundError(f"Unknown paper-quality target: {target_ref}")

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any]:
        if not path.exists():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
        return payload if isinstance(payload, dict) else {}

    @staticmethod
    def _text_list(value: Any) -> list[str]:
        if not isinstance(value, list):
            return []
        return [str(entry).strip() for entry in value if str(entry).strip()]

    @staticmethod
    def _bounded_score(value: Any) -> int:
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return 0
        return max(0, min(5, parsed))

    @staticmethod
    def _combined_score(*, deterministic: dict[str, Any], llm_review: dict[str, Any]) -> float:
        deterministic_score = float(deterministic.get("score") or 0)
        llm_score = llm_review.get("score")
        if llm_score is None:
            return round(deterministic_score * 0.4, 2)
        return round((deterministic_score * 0.4) + (float(llm_score) * 0.6), 2)

    @staticmethod
    def _overall_summary(*, deterministic: dict[str, Any], llm_review: dict[str, Any], overall_status: str) -> str:
        if overall_status == "pass":
            return "Paper passed deterministic and LLM quality verification."
        if overall_status == "needs_llm_review":
            return "Paper passed deterministic checks but still requires LLM manuscript review."
        return f"{deterministic.get('summary') or 'Deterministic review failed.'} {str(llm_review.get('summary') or '').strip()}".strip()

    @staticmethod
    def _pattern_hits(patterns: tuple[tuple[str, re.Pattern[str]], ...], text: str) -> list[str]:
        hits: list[str] = []
        for label, pattern in patterns:
            if pattern.search(text):
                hits.append(label)
        return hits

    @staticmethod
    def _normalize_section_name(value: str) -> str:
        return " ".join(str(value).strip().lower().split())

    @staticmethod
    def _present_sections(tex_text: str) -> set[str]:
        present_sections = {PaperQualityVerifier._normalize_section_name(name) for name in SECTION_PATTERN.findall(tex_text)}
        if ABSTRACT_PATTERN.search(tex_text):
            present_sections.add("abstract")
        if THEBIB_PATTERN.search(tex_text) or BIBLIOGRAPHY_PATTERN.search(tex_text):
            present_sections.add("references")
        return present_sections

    @staticmethod
    def _section_details(tex_text: str) -> dict[str, dict[str, int]]:
        details: dict[str, dict[str, int]] = {}
        abstract_match = ABSTRACT_PATTERN.search(tex_text)
        if abstract_match:
            abstract_content = PaperQualityVerifier._plaintext_length(abstract_match.group(1))
            details["abstract"] = {"position": abstract_match.start(), "content_length": abstract_content}

        section_matches = list(SECTION_PATTERN.finditer(tex_text))
        for index, match in enumerate(section_matches):
            normalized = PaperQualityVerifier._normalize_section_name(match.group(1))
            next_start = section_matches[index + 1].start() if index + 1 < len(section_matches) else len(tex_text)
            content = tex_text[match.end() : next_start]
            details[normalized] = {
                "position": match.start(),
                "content_length": PaperQualityVerifier._plaintext_length(content),
            }
        if "references" not in details and (THEBIB_PATTERN.search(tex_text) or BIBLIOGRAPHY_PATTERN.search(tex_text)):
            reference_position = tex_text.rfind("\\bibliography{")
            if reference_position == -1:
                reference_position = tex_text.rfind("\\begin{thebibliography}")
            details["references"] = {
                "position": max(reference_position, 0),
                "content_length": len(BIBITEM_PATTERN.findall(tex_text)) * 40 if BIBITEM_PATTERN.search(tex_text) else 80,
            }
        return details

    @staticmethod
    def _section_order_issues(section_details: dict[str, dict[str, int]]) -> list[str]:
        positions: list[tuple[int, str]] = []
        for canonical_name, aliases in REQUIRED_SECTION_GROUPS:
            matched_position = None
            matched_alias = None
            for alias in aliases:
                details = section_details.get(alias)
                if details is None:
                    continue
                matched_position = int(details["position"])
                matched_alias = alias
                break
            if matched_position is not None and matched_alias is not None:
                positions.append((matched_position, canonical_name))
        ordered_names = [name for _, name in sorted(positions, key=lambda item: item[0])]
        expected_names = [name for name, _ in REQUIRED_SECTION_GROUPS if name in ordered_names]
        if ordered_names == expected_names:
            return []
        return ordered_names

    @staticmethod
    def _plaintext_length(tex_text: str) -> int:
        without_commands = re.sub(r"\\[a-zA-Z*]+(?:\[[^\]]*\])?(?:\{[^}]*\})?", " ", tex_text)
        without_braces = re.sub(r"[{}]", " ", without_commands)
        collapsed = " ".join(without_braces.split())
        return len(collapsed)

    @staticmethod
    def _environment_balance(tex_text: str) -> dict[str, dict[str, int]]:
        return {
            "figure": {
                "begin": len(re.findall(r"\\begin\{figure\}", tex_text)),
                "end": len(re.findall(r"\\end\{figure\}", tex_text)),
            },
            "table": {
                "begin": len(re.findall(r"\\begin\{table\}", tex_text)),
                "end": len(re.findall(r"\\end\{table\}", tex_text)),
            },
        }

    @staticmethod
    def _resolve_figure_paths(tex_text: str, run_directory: Path) -> list[Path]:
        paths: list[Path] = []
        for raw_path in FIGURE_REF_PATTERN.findall(tex_text):
            normalized = raw_path.strip()
            if not normalized:
                continue
            candidate = run_directory / normalized
            if candidate.suffix:
                paths.append(candidate)
                continue
            for extension in (".png", ".pdf", ".jpg", ".jpeg"):
                paths.append(candidate.with_suffix(extension))
        return paths

    @staticmethod
    def _extract_json_object(text: str) -> dict[str, Any]:
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            start = text.find("{")
            end = text.rfind("}")
            if start == -1 or end == -1 or end <= start:
                return {}
            try:
                payload = json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                return {}
        return payload if isinstance(payload, dict) else {}

    @staticmethod
    def _tokenize(text: str) -> set[str]:
        return {token for token in re.findall(r"[a-zA-Z]{4,}", text.lower())}

    @staticmethod
    def _ledger_has_empirical_results(ledger: dict[str, Any]) -> bool:
        results = ledger.get("results")
        if isinstance(results, list) and results:
            return True
        artifacts = ledger.get("artifacts")
        return isinstance(artifacts, list) and bool(artifacts)

    @staticmethod
    def _clip_text(value: str, *, limit: int) -> str:
        stripped = str(value or "").strip()
        if len(stripped) <= limit:
            return stripped
        return stripped[: limit - 20] + "\n...[truncated]..."
