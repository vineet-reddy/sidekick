from __future__ import annotations

import csv
import math
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


TECTONIC_DEFAULT_VERSION = "0.15.0"


def normalize_manuscript_sections(raw_sections: dict[str, Any], *, title_fallback: str) -> dict[str, Any]:
    if not isinstance(raw_sections, dict):
        raw_sections = {}
    references = raw_sections.get("references")
    if not isinstance(references, list):
        references = []
    return {
        "title": str(raw_sections.get("title") or title_fallback).strip() or title_fallback,
        "abstract": str(raw_sections.get("abstract") or "").strip(),
        "introduction": str(raw_sections.get("introduction") or "").strip(),
        "methods": str(raw_sections.get("methods") or "").strip(),
        "results": str(raw_sections.get("results") or "").strip(),
        "discussion": str(raw_sections.get("discussion") or "").strip(),
        "conclusion": str(raw_sections.get("conclusion") or "").strip(),
        "limitations": str(raw_sections.get("limitations") or "").strip(),
        "references": [str(entry).strip() for entry in references if str(entry).strip()],
    }


def results_to_markdown(sections: dict[str, Any], *, manuscript_kind: str) -> str:
    heading = "Research Memo" if manuscript_kind == "memo" else "Paper"
    blocks = [
        f"# {sections.get('title') or 'Untitled Manuscript'}",
        f"_{heading}_",
    ]
    ordered_sections = [
        ("Abstract", sections.get("abstract")),
        ("Introduction", sections.get("introduction")),
        ("Methods", sections.get("methods")),
        ("Results", sections.get("results")),
        ("Discussion", sections.get("discussion")),
        ("Conclusion", sections.get("conclusion")),
        ("Limitations", sections.get("limitations")),
    ]
    for title, body in ordered_sections:
        text = _display_inline_tokens(str(body or "").strip())
        if text:
            blocks.append(f"## {title}\n\n{text}")

    references = [str(entry).strip() for entry in sections.get("references") or [] if str(entry).strip()]
    if references:
        blocks.append("## References\n\n" + "\n".join(f"{index + 1}. {entry}" for index, entry in enumerate(references)))

    return "\n\n".join(blocks).strip()


def format_reference_from_source(source: dict[str, Any]) -> str:
    label = str(source.get("label") or source.get("title") or "Source").strip() or "Source"
    accession_id = str(source.get("accession_id") or "").strip()
    download_url = str(source.get("download_url") or "").strip()
    landing_page_url = str(source.get("landing_page_url") or "").strip()
    api_endpoint = str(source.get("api_endpoint") or "").strip()
    notes = str(source.get("notes") or "").strip()
    parts = [label]
    if accession_id:
        parts.append(f"Accession: {accession_id}")
    if download_url:
        parts.append(download_url)
    elif api_endpoint:
        parts.append(api_endpoint)
    elif landing_page_url:
        parts.append(landing_page_url)
    if notes:
        parts.append(notes)
    return ". ".join(part for part in parts if part).strip()


def build_manuscript_manifest(
    *,
    job_directory: Path,
    artifacts: list[dict[str, Any]],
    sanitize_relative_path: Any,
    artifact_path_value: Any,
    guess_mime_type: Any,
) -> dict[str, Any]:
    figures_directory = job_directory / "figures"
    tables_directory = job_directory / "tables"
    shutil.rmtree(figures_directory, ignore_errors=True)
    shutil.rmtree(tables_directory, ignore_errors=True)
    figures_directory.mkdir(parents=True, exist_ok=True)
    tables_directory.mkdir(parents=True, exist_ok=True)

    manifest: dict[str, Any] = {"figures": [], "tables": []}
    figure_index = 0
    table_index = 0
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        artifact_id = str(artifact.get("artifact_id") or "").strip()
        artifact_path = sanitize_relative_path(
            artifact_path_value(artifact),
            fallback=f"artifacts/{artifact_id or 'artifact'}",
        )
        source_path = job_directory / artifact_path
        if not source_path.exists() or not source_path.is_file():
            continue

        mime_type = str(artifact.get("mime_type") or "").strip() or guess_mime_type(artifact_path)
        description = str(artifact.get("description") or artifact_id or source_path.name).strip() or source_path.name
        if mime_type.startswith("image/"):
            figure_index += 1
            suffix = source_path.suffix or ".png"
            relative_path = f"figures/figure_{figure_index}{suffix}"
            shutil.copy2(source_path, job_directory / relative_path)
            manifest["figures"].append(
                {
                    "artifact_id": artifact_id,
                    "label": _sanitize_label(artifact_id or f"figure-{figure_index}", prefix="fig"),
                    "caption": description,
                    "path": relative_path,
                    "mime_type": mime_type,
                }
            )
            continue

        if str(artifact.get("kind") or "").strip().lower() == "table" or mime_type in {
            "text/csv",
            "text/tab-separated-values",
            "application/json",
            "text/plain",
        }:
            table_index += 1
            suffix = source_path.suffix or ".txt"
            relative_path = f"tables/table_{table_index}{suffix}"
            shutil.copy2(source_path, job_directory / relative_path)
            manifest["tables"].append(
                {
                    "artifact_id": artifact_id,
                    "label": _sanitize_label(artifact_id or f"table-{table_index}", prefix="tab"),
                    "caption": description,
                    "path": relative_path,
                    "mime_type": mime_type,
                    "rows": _load_table_rows(source_path, mime_type=mime_type),
                }
            )

    return manifest


def render_latex(
    *,
    title: str,
    sections: dict[str, Any],
    manifest: dict[str, Any],
    manuscript_kind: str,
    reference_catalog: list[dict[str, Any]],
) -> tuple[str, str]:
    catalog_by_key = {
        str(entry.get("key") or "").strip(): str(entry.get("text") or "").strip()
        for entry in reference_catalog
        if str(entry.get("key") or "").strip() and str(entry.get("text") or "").strip()
    }
    prose_blocks = [_normalize_inline_commands(str(sections.get(key) or "")) for key in (
        "abstract",
        "introduction",
        "methods",
        "results",
        "discussion",
        "conclusion",
        "limitations",
    )]
    cited_keys: list[str] = []
    for block in prose_blocks:
        for match in re.findall(r"\\cite\{([^}]+)\}", block):
            for key in [part.strip() for part in match.split(",") if part.strip()]:
                if key not in cited_keys:
                    cited_keys.append(key)

    reference_texts = [str(entry).strip() for entry in sections.get("references") or [] if str(entry).strip()]
    if not cited_keys and reference_texts:
        cited_keys = [f"ref{index + 1}" for index in range(len(reference_texts))]
    bibliography_lines: list[str] = []
    for index, key in enumerate(cited_keys):
        reference_text = reference_texts[index] if index < len(reference_texts) else ""
        if not reference_text:
            reference_text = catalog_by_key.get(key, "")
        if not reference_text:
            continue
        reference_title = _reference_bib_title(reference_text, fallback=f"Reference {index + 1}")
        reference_year = _reference_bib_year(reference_text)
        bibliography_lines.append(
            "\n".join(
                [
                    f"@misc{{{key},",
                    f"  title = {{{_latex_escape_bib_value(reference_title)}}},",
                    f"  year = {{{_latex_escape_bib_value(reference_year)}}},",
                    f"  key = {{{_latex_escape_bib_value(f'Reference {index + 1}')}}},",
                    f"  note = {{{_latex_escape_bib_value(reference_text)}}}",
                    "}",
                ]
            )
        )
    references_bib = "\n\n".join(bibliography_lines).strip()

    abstract_body = _latex_escape_prose(str(sections.get("abstract") or ""))
    section_blocks = [
        ("Introduction", _latex_escape_prose(str(sections.get("introduction") or ""))),
        ("Data And Methods", _latex_escape_prose(str(sections.get("methods") or ""))),
        ("Results", _latex_escape_prose(str(sections.get("results") or ""))),
        ("Discussion", _latex_escape_prose(str(sections.get("discussion") or ""))),
        ("Conclusion", _latex_escape_prose(str(sections.get("conclusion") or ""))),
        ("Limitations", _latex_escape_prose(str(sections.get("limitations") or ""))),
    ]
    rendered_sections: list[str] = []
    for heading, body in section_blocks:
        if body:
            rendered_sections.append(f"\\section{{{heading}}}\n{body}")

    figure_blocks = []
    for figure in manifest.get("figures", []):
        figure_blocks.append(
            "\n".join(
                [
                    "\\begin{figure}[tbp]",
                    "\\centering",
                    f"\\includegraphics[width=0.94\\linewidth]{{{_latex_escape_text(str(figure.get('path') or ''))}}}",
                    f"\\caption{{{_latex_escape_prose(str(figure.get('caption') or ''))}}}",
                    f"\\label{{{_latex_escape_text(str(figure.get('label') or ''))}}}",
                    "\\end{figure}",
                ]
            )
        )

    table_blocks = []
    for table in manifest.get("tables", []):
        rows = table.get("rows") or []
        if rows:
            header = [_display_table_cell(cell, header_cell=True) for cell in rows[0]]
            body_rows = [[_display_table_cell(cell) for cell in row] for row in rows[1:]]
            column_count = max(1, min(6, len(header)))
            column_spec = "".join([">{\\raggedright\\arraybackslash}X"] * column_count)
            table_lines = [
                "\\begin{table}[tbp]",
                "\\centering",
                "\\small",
                f"\\caption{{{_latex_escape_prose(str(table.get('caption') or ''))}}}",
                f"\\label{{{_latex_escape_text(str(table.get('label') or ''))}}}",
                f"\\begin{{tabularx}}{{\\linewidth}}{{{column_spec}}}",
                "\\toprule",
                " & ".join(_latex_escape_text(cell) for cell in header[:column_count]) + " \\\\",
                "\\midrule",
            ]
            for row in body_rows[:8]:
                table_lines.append(
                    " & ".join(_latex_escape_text(cell) for cell in row[:column_count]) + " \\\\"
                )
            table_lines.extend(["\\bottomrule", "\\end{tabularx}", "\\end{table}"])
            table_blocks.append("\n".join(table_lines))
        else:
            table_blocks.append(
                "\n".join(
                    [
                        "\\begin{table}[t]",
                        "\\centering",
                        f"\\caption{{{_latex_escape_prose(str(table.get('caption') or ''))}}}",
                        f"\\label{{{_latex_escape_text(str(table.get('label') or ''))}}}",
                        f"\\texttt{{{_latex_escape_text(str(table.get('path') or ''))}}}",
                        "\\end{table}",
                    ]
                )
            )

    manuscript_label = "Research Memo" if manuscript_kind == "memo" else "Research Paper"
    bibliography_block = "\\bibliographystyle{plainnat}\n\\bibliography{references}" if references_bib else ""
    float_blocks = table_blocks + figure_blocks
    if float_blocks and rendered_sections:
        rendered_sections[2 if len(rendered_sections) >= 3 else -1] = (
            rendered_sections[2 if len(rendered_sections) >= 3 else -1]
            + "\n\n"
            + "\n\n".join(float_blocks)
        )
        figure_blocks = []
        table_blocks = []
    latex = "\n\n".join(
        [
            "\\documentclass[11pt]{article}",
            "\\usepackage[T1]{fontenc}",
            "\\usepackage[utf8]{inputenc}",
            "\\usepackage[margin=1in]{geometry}",
            "\\usepackage{graphicx}",
            "\\usepackage{amsmath}",
            "\\usepackage{amssymb}",
            "\\usepackage{booktabs}",
            "\\usepackage{array}",
            "\\usepackage{tabularx}",
            "\\usepackage{caption}",
            "\\usepackage{float}",
            "\\usepackage{microtype}",
            "\\usepackage{lmodern}",
            "\\usepackage{natbib}",
            "\\usepackage[hidelinks]{hyperref}",
            "\\captionsetup{font=small,labelfont=bf}",
            "\\setlength{\\parindent}{1.25em}",
            "\\setlength{\\parskip}{0pt}",
            "\\title{" + _latex_escape_text(title) + "}",
            "\\author{}",
            "\\date{}",
            "\\begin{document}",
            "\\maketitle",
            "\\begin{center}\\small\\textit{" + _latex_escape_text(manuscript_label) + "}\\end{center}",
            "\\begin{abstract}",
            abstract_body,
            "\\end{abstract}",
            *rendered_sections,
            *figure_blocks,
            *table_blocks,
            bibliography_block,
            "\\end{document}",
        ]
    ).strip() + "\n"
    return latex, references_bib


def compile_pdf(job_directory: Path, *, tex_filename: str) -> dict[str, Any]:
    stem = Path(tex_filename).stem
    outputs: list[str] = []
    if shutil.which("pdflatex"):
        compile_commands = [
            ["pdflatex", "-interaction=nonstopmode", tex_filename],
            ["bibtex", stem],
            ["pdflatex", "-interaction=nonstopmode", tex_filename],
            ["pdflatex", "-interaction=nonstopmode", tex_filename],
        ]
        references_path = job_directory / "references.bib"
        for command in compile_commands:
            if command[0] == "bibtex" and (not references_path.exists() or not references_path.read_text(encoding="utf-8").strip()):
                continue
            try:
                completed = subprocess.run(
                    command,
                    cwd=job_directory,
                    capture_output=True,
                    text=False,
                    check=False,
                )
            except FileNotFoundError:
                return {
                    "ok": False,
                    "error": f"{command[0]} is not installed in the backend runtime.",
                    "log": "\n\n".join(outputs).strip(),
                    "pdf_path": "",
                }
            output = _decode_process_output(completed.stdout, completed.stderr)
            if output:
                outputs.append(f"$ {' '.join(command)}\n{output}")
            if completed.returncode != 0:
                return {
                    "ok": False,
                    "error": f"{' '.join(command)} failed with exit code {completed.returncode}",
                    "log": "\n\n".join(outputs).strip(),
                    "pdf_path": "",
                }
    else:
        try:
            tectonic_path = _ensure_tectonic_binary(job_directory.parent / "_toolcache")
        except RuntimeError as error:
            return {
                "ok": False,
                "error": str(error),
                "log": "\n\n".join(outputs).strip(),
                "pdf_path": "",
            }
        command = [
            str(tectonic_path),
            "-X",
            "compile",
            "--keep-intermediates",
            "--keep-logs",
            "--outdir",
            ".",
            tex_filename,
        ]
        completed = subprocess.run(
            command,
            cwd=job_directory,
            capture_output=True,
            text=False,
            check=False,
        )
        output = _decode_process_output(completed.stdout, completed.stderr)
        if output:
            outputs.append(f"$ {' '.join(command)}\n{output}")
        if completed.returncode != 0:
            return {
                "ok": False,
                "error": f"{' '.join(command)} failed with exit code {completed.returncode}",
                "log": "\n\n".join(outputs).strip(),
                "pdf_path": "",
            }

    pdf_path = job_directory / f"{stem}.pdf"
    if not pdf_path.exists() or not pdf_path.is_file():
        return {
            "ok": False,
            "error": f"{pdf_path.name} was not produced by LaTeX compilation.",
            "log": "\n\n".join(outputs).strip(),
            "pdf_path": "",
        }

    return {
        "ok": True,
        "error": "",
        "log": "\n\n".join(outputs).strip(),
        "pdf_path": pdf_path.name,
    }


def _load_table_rows(path: Path, *, mime_type: str) -> list[list[str]]:
    try:
        raw_text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []

    rows: list[list[str]] = []
    if mime_type == "application/json":
        try:
            payload = json.loads(raw_text)
        except json.JSONDecodeError:
            return []
        if isinstance(payload, list) and payload and isinstance(payload[0], dict):
            headers = [str(key) for key in list(payload[0].keys())[:8]]
            rows.append(headers)
            for entry in payload[:12]:
                if isinstance(entry, dict):
                    rows.append([str(entry.get(header, ""))[:80] for header in headers])
        return rows

    if mime_type == "text/plain":
        lines = [line.strip()[:100] for line in raw_text.splitlines() if line.strip()]
        if not lines:
            return []
        return [["excerpt"], *[[line] for line in lines[:10]]]

    delimiter = "\t" if mime_type == "text/tab-separated-values" or path.suffix.lower() == ".tsv" else ","
    reader = csv.reader(raw_text.splitlines(), delimiter=delimiter)
    for row in reader:
        cleaned = [str(cell).strip()[:80] for cell in row[:8]]
        if any(cleaned):
            rows.append(cleaned)
        if len(rows) >= 12:
            break
    return rows


def _sanitize_label(value: str, *, prefix: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9:-]+", "-", value.strip())
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return f"{prefix}:{cleaned or 'item'}"


def _latex_escape_text(value: str) -> str:
    return (
        value.replace("\\", "\\textbackslash{}")
        .replace("{", "\\{")
        .replace("}", "\\}")
        .replace("&", "\\&")
        .replace("%", "\\%")
        .replace("#", "\\#")
        .replace("_", "\\_")
        .replace("^", "\\textasciicircum{}")
        .replace("~", "\\textasciitilde{}")
    )


def _latex_escape_bib_value(value: str) -> str:
    return _latex_escape_text(value).replace("$", "\\$")


def _latex_escape_prose(value: str) -> str:
    text = _normalize_inline_commands(str(value or "")).strip()
    if not text:
        return ""

    placeholders: dict[str, str] = {}

    def protect(pattern: str, source_text: str, *, flags: int = re.DOTALL) -> str:
        def replace(match: re.Match[str]) -> str:
            token = f"@@LATEX_{len(placeholders)}@@"
            placeholders[token] = match.group(0)
            return token

        return re.sub(pattern, replace, source_text, flags=flags)

    protected = protect(r"\\(?:cite|ref|eqref)\{[^}]+\}", text)
    protected = protect(r"\\(?:emph|textit|textbf|subsection|subsubsection|paragraph)\*?\{[^}]+\}", protected)
    protected = protect(r"\\\[[\s\S]*?\\\]", protected)
    protected = protect(r"\\\([\s\S]*?\\\)", protected)
    protected = protect(
        r"\\begin\{(?:equation|equation\*|align|align\*|gather|gather\*|multline|multline\*)\}[\s\S]*?\\end\{(?:equation|equation\*|align|align\*|gather|gather\*|multline|multline\*)\}",
        protected,
    )
    protected = _protect_inline_math(protected, placeholders)
    escaped = _latex_escape_text(protected).replace("$", "\\$")
    for token, original in placeholders.items():
        escaped = escaped.replace(_latex_escape_text(token), original)
    paragraphs = [paragraph.strip() for paragraph in escaped.split("\n\n") if paragraph.strip()]
    return "\n\n".join(paragraphs)


def _protect_inline_math(text: str, placeholders: dict[str, str]) -> str:
    chunks: list[str] = []
    cursor = 0
    while cursor < len(text):
        start = text.find("$", cursor)
        if start == -1:
            chunks.append(text[cursor:])
            break
        if start > 0 and text[start - 1] == "\\":
            chunks.append(text[cursor : start + 1])
            cursor = start + 1
            continue
        end = text.find("$", start + 1)
        if end == -1:
            chunks.append(text[cursor:])
            break
        candidate = text[start + 1 : end]
        if _looks_like_inline_math(candidate):
            chunks.append(text[cursor:start])
            token = f"@@LATEX_{len(placeholders)}@@"
            placeholders[token] = text[start : end + 1]
            chunks.append(token)
            cursor = end + 1
            continue
        chunks.append(text[cursor : start + 1])
        cursor = start + 1
    return "".join(chunks)


def _looks_like_inline_math(candidate: str) -> bool:
    content = candidate.strip()
    if not content or "\n\n" in content:
        return False
    if content.count(" ") > 8 and not re.search(r"[=<>+\-*/_^\\]", content):
        return False
    math_signals = [
        r"\\[A-Za-z]+",
        r"[=<>]|\\leq|\\geq|\\approx|\\sim|\\times",
        r"[_^]",
        r"\b(?:alpha|beta|gamma|delta|theta|lambda|mu|sigma|pi)\b",
        r"\b[A-Za-z]\d*\b",
    ]
    if any(re.search(pattern, content) for pattern in math_signals):
        return True
    return bool(re.fullmatch(r"[-+]?(\d+(\.\d+)?|\.\d+)\s*(?:[%A-Za-z/().-]+)?", content))


def _display_table_cell(value: str, *, header_cell: bool = False) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    if header_cell:
        return re.sub(r"\s+", " ", text.replace("_", " ")).strip()

    normalized = re.sub(r"\s+", " ", text.replace("_", " ")).strip()
    try:
        number = float(normalized.replace(",", ""))
    except ValueError:
        return normalized[:80]

    if not math.isfinite(number):
        return normalized[:80]
    if number.is_integer():
        magnitude = abs(number)
        if magnitude >= 1000:
            return f"{int(number):,}"
        return str(int(number))
    if abs(number) >= 1000:
        return f"{number:,.1f}".rstrip("0").rstrip(".")
    if abs(number) >= 1:
        return f"{number:.3f}".rstrip("0").rstrip(".")
    if abs(number) >= 0.01:
        return f"{number:.4f}".rstrip("0").rstrip(".")
    return f"{number:.2e}"


def _decode_process_output(*streams: bytes | str | None) -> str:
    decoded_parts: list[str] = []
    for stream in streams:
        if stream is None:
            continue
        if isinstance(stream, str):
            text = stream
        else:
            try:
                text = stream.decode("utf-8")
            except UnicodeDecodeError:
                text = stream.decode("utf-8", errors="replace")
        cleaned = text.strip()
        if cleaned:
            decoded_parts.append(cleaned)
    return "\n".join(decoded_parts).strip()


def _normalize_inline_commands(value: str) -> str:
    text = str(value or "")
    if not text:
        return ""
    text = re.sub(r"\[\[CITE:([A-Za-z0-9_, -]+)\]\]", lambda m: f"\\cite{{{m.group(1).strip()}}}", text)
    text = re.sub(r"\[\[REF:([A-Za-z0-9:.-]+)\]\]", lambda m: f"\\ref{{{m.group(1).strip()}}}", text)
    return text


def _display_inline_tokens(value: str) -> str:
    text = str(value or "")
    if not text:
        return ""
    text = re.sub(r"\[\[CITE:([A-Za-z0-9_, -]+)\]\]", lambda m: f"[{m.group(1).strip()}]", text)
    text = re.sub(r"\[\[REF:fig:[^\]]+\]\]", "Figure", text)
    text = re.sub(r"\[\[REF:tab:[^\]]+\]\]", "Table", text)
    text = re.sub(r"\\cite\{([^}]+)\}", lambda m: f"[{m.group(1).strip()}]", text)
    text = re.sub(r"\\ref\{fig:[^}]+\}", "Figure", text)
    text = re.sub(r"\\ref\{tab:[^}]+\}", "Table", text)
    return text


def _reference_bib_title(reference_text: str, *, fallback: str) -> str:
    text = str(reference_text or "").strip()
    if not text:
        return fallback
    primary = text.partition(". Accession:")[0].strip()
    if primary:
        return primary
    sentence = text.split(". ", 1)[0].strip().rstrip(".")
    return sentence or fallback


def _reference_bib_year(reference_text: str) -> str:
    match = re.search(r"\b(19|20)\d{2}\b", str(reference_text or ""))
    return match.group(0) if match else "n.d."


def _ensure_tectonic_binary(cache_directory: Path) -> Path:
    cache_directory.mkdir(parents=True, exist_ok=True)
    binary_name = "tectonic.exe" if platform.system().lower() == "windows" else "tectonic"
    binary_path = cache_directory / binary_name
    if binary_path.exists():
        return binary_path

    version = (os.getenv("SIDEKICK_TECTONIC_VERSION", "").strip() or TECTONIC_DEFAULT_VERSION).removeprefix("tectonic@").strip()
    asset_name = _tectonic_asset_name(version)
    asset_url = _tectonic_asset_url(version, asset_name)

    archive_path = cache_directory / asset_name
    _download_file(asset_url, archive_path)
    with tarfile.open(archive_path, "r:gz") as archive:
        with tempfile.TemporaryDirectory() as tempdir:
            _safe_extract_tar(archive, Path(tempdir))
            extracted = Path(tempdir)
            candidate = next(extracted.rglob(binary_name), None)
            if candidate is None:
                raise RuntimeError("Downloaded Tectonic archive did not contain the compiler binary.")
            shutil.copy2(candidate, binary_path)
    archive_path.unlink(missing_ok=True)
    binary_path.chmod(0o755)
    return binary_path


def _tectonic_asset_name(version: str) -> str:
    version = version.removeprefix("tectonic@").strip() or version.strip()
    if not version:
        raise RuntimeError("Unable to determine the latest Tectonic release version.")
    system_name = platform.system().lower()
    machine = platform.machine().lower()
    if system_name == "linux" and machine in {"x86_64", "amd64"}:
        return f"tectonic-{version}-x86_64-unknown-linux-gnu.tar.gz"
    if system_name == "linux" and machine in {"arm64", "aarch64"}:
        return f"tectonic-{version}-aarch64-unknown-linux-musl.tar.gz"
    if system_name == "darwin" and machine in {"arm64", "aarch64"}:
        return f"tectonic-{version}-aarch64-apple-darwin.tar.gz"
    if system_name == "darwin" and machine in {"x86_64", "amd64"}:
        return f"tectonic-{version}-x86_64-apple-darwin.tar.gz"
    raise RuntimeError(f"Tectonic auto-install is not supported on {platform.system()} {platform.machine()}.")


def _tectonic_asset_url(version: str, asset_name: str) -> str:
    encoded_tag = urllib.parse.quote(f"tectonic@{version}", safe="")
    return f"https://github.com/tectonic-typesetting/tectonic/releases/download/{encoded_tag}/{asset_name}"


def _download_file(url: str, destination: Path) -> None:
    headers = {"User-Agent": "sidekick-backend"}
    github_token = os.getenv("GH_TOKEN", "").strip() or os.getenv("GITHUB_TOKEN", "").strip()
    if github_token and "github.com/" in url:
        headers["Authorization"] = f"Bearer {github_token}"
    request = urllib.request.Request(url, headers=headers)
    last_error: Exception | None = None
    destination.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as handle:
                shutil.copyfileobj(response, handle)
            return
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code in {403, 429} and attempt < 3:
                time.sleep(2 * attempt)
                last_error = RuntimeError(f"HTTP {error.code}: {detail or 'rate limited'}")
                continue
            raise RuntimeError(f"Failed to download {url}: HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            if attempt < 3:
                time.sleep(2 * attempt)
                last_error = error
                continue
            raise RuntimeError(f"Failed to download {url}: {error.reason}") from error
    if last_error is not None:
        raise RuntimeError(f"Failed to download {url}: {last_error}")


def _safe_extract_tar(archive: tarfile.TarFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in archive.getmembers():
        member_path = (destination / member.name).resolve()
        if os.path.commonpath([str(destination), str(member_path)]) != str(destination):
            raise RuntimeError(f"Refusing to extract archive member outside destination: {member.name}")
    extract_kwargs: dict[str, Any] = {}
    if "filter" in tarfile.TarFile.extractall.__code__.co_varnames:
        extract_kwargs["filter"] = "data"
    archive.extractall(destination, **extract_kwargs)
