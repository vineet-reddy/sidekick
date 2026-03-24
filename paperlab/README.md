# Paperlab

`paperlab` is the terminal-first harness for the shared Sidekick paper engine.

It runs the same Python pipeline that the backend server uses, but writes every artifact locally so manuscript iteration does not depend on the iPhone app or GitHub publishing.

Quick start:

```bash
python3 -m paperlab.cli run --notes-file prompt.txt --title "My study"
python3 -m paperlab.cli inspect latest
python3 -m paperlab.cli render latest
python3 -m paperlab.cli open latest --target pdf
```

Saved run artifacts live under `paperlab/runs/<run_id>/` and include:

- `input.json`
- `ledger.json`
- `validation.json`
- `sections.json`
- `paper.tex` or `memo.tex`
- `paper.pdf` or `memo.pdf`
- `references.bib`
- `bundle.json`
- `events.jsonl`
- `metrics.jsonl`
- `artifacts/`, `figures/`, `tables/`
