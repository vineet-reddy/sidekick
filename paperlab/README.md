# Paperlab

`paperlab` is the terminal-first harness for the shared Sidekick paper engine.

It runs the same Python pipeline that the backend server uses, but writes every artifact locally so manuscript iteration does not depend on the iPhone app or GitHub publishing.

Quick start:

```bash
python3 -m paperlab.cli run --notes-file prompt.txt --title "My study"
python3 -m paperlab.cli inspect latest
python3 -m paperlab.cli paper-quality verify latest --golden-root /Users/vineetreddy/Documents/GitHub/test_sidekickdata --json
python3 -m paperlab.cli render latest
python3 -m paperlab.cli open latest --target pdf
python3 -m paperlab.cli render-status
python3 -m paperlab.cli render-status --wait --commit "$(git rev-parse HEAD)"
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

## Paper Quality

`sidekick paper-quality verify` is the canonical verifier for overnight manuscript repair loops.

It combines:

- deterministic manuscript checks for compile health, section structure, placeholders, bibliography/citation hygiene, artifact presence, and basic ledger grounding
- an LLM manuscript judge that reads the actual paper, ledger, validation payload, artifact manifest, and the golden dataset

Example:

```bash
python3 -m paperlab.cli paper-quality verify latest \
  --golden-root /Users/vineetreddy/Documents/GitHub/test_sidekickdata \
  --json
```

Use `--skip-llm` only when debugging the deterministic layer locally. A paper is not fully verified until the LLM judge also passes.

## Autorepair

`sidekick autorepair` adds a Karpathy-inspired overnight repair loop on top of the CLI harness.

It expects you to launch it from a clean git worktree, then it will:

- run a verifier command against that worktree
- record a baseline score and treat the current worktree branch as the best-known branch
- create a fresh child git worktree for each repair attempt
- invoke `codex exec` inside the child worktree
- keep only attempts that measurably improve the verifier
- discard non-improving attempts and continue until the budget expires

Example:

```bash
python3 -m paperlab.cli autorepair run \
  --objective "Make the local Sidekick pipeline complete end to end." \
  --verify "python3 -m unittest github_bootstrap_service.tests.test_paperlab_cli -v" \
  --source-worktree "$PWD" \
  --run-tag overnight-pipeline \
  --search \
  --yolo
```

Session state is written under `~/.sidekick/autoresearch/`. Use:

```bash
python3 -m paperlab.cli autorepair status latest --json
python3 -m paperlab.cli autorepair attempts latest --json
```

`sidekick autoresearch` remains available as a compatibility alias.
