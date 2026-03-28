# Overnight Plan: Eliminate Metadata-Only Empirical Papers

## Current State

- The hosted pipeline/runtime/publish path is now working end to end.
- The hosted CLI worktree changes were merged back into `main` in commit `9bc2621` (`Add hosted backend commands to sidekick CLI`).
- The GitHub publish rate-limit failure was fixed in commit `00d244d` (`Retry GitHub publication after rate limits`).
- A fresh hosted run completed and published successfully, but the resulting paper was still metadata-level rather than a strong empirical paper.

## The Actual Remaining Problem

The remaining problem is not the pipeline shell anymore. The problem is that the workspace can reach Stage 2, Stage 3, and Stage 4 without ever obtaining a real numeric substrate for the requested dataset. When that happens, the system still has enough material to write a polished paper-shaped document, but it is only a design-reconstruction or metadata paper. That is not credible enough for empirical science.

For GEO-like datasets, this means:

- the run must successfully obtain numeric substrate or tables suitable for real analysis
- the run must record exactly what it downloaded and how much
- the run must refuse to produce an empirical paper if the only recoverable material is metadata

## Why OpenAI Compute Still Hits This Problem

Using OpenAI compute does not mean the workspace has unlimited or frictionless data access.

Practical constraints still exist:

- network egress may fail on some hosts or paths
- large downloads may time out
- some resources may require multiple redirects or unstable endpoints
- agents may spend budget on exploratory fetching instead of targeted retrieval
- raw archives may be too large to pull naively
- the model may choose a bad download path when a smaller processed table would have been enough

So the fix is not "trust the sandbox more." The fix is to make data access explicit, measurable, budgeted, and required.

## What Must Be Built

### 1. Add a Real Data-Acquisition Gate Before Empirical Analysis

For empirical papers, Stage 2 must not begin the actual analysis until the system has produced a concrete acquisition receipt proving that at least one usable numeric substrate was materialized.

Required outputs:

- `data_access_report.json`
- `download_manifest.json`
- `network_attempts.tsv`

Each must record:

- URL attempted
- source family
- method used
- bytes downloaded
- latency
- HTTP status or connection error
- local saved path
- whether the downloaded object is usable for analysis

If no usable numeric substrate is acquired, the run must not proceed to empirical paper writing.

### 2. Make Data Budgets Explicit

The workspace needs a first-class budget contract, not vague prompt language.

Track and enforce:

- maximum total bytes allowed for dataset acquisition
- maximum bytes per file
- maximum number of files downloaded
- maximum time spent in acquisition
- preferred order of retrieval targets

For example, the agent should prefer:

1. processed tables or series matrices
2. sample-level processed tables
3. compact metadata-linked numeric files
4. raw archives only if smaller paths fail

This is not paper-type hyperoptimization. It is a generic acquisition strategy for any dataset family with multiple possible payloads.

### 3. Add Source-Family Acquisition Adapters

The resolver already understands source families. The next step is to give each supported family a minimal acquisition strategy that answers:

- what is the smallest credible numeric substrate for this family?
- what endpoint should be tried first?
- what file patterns count as numeric substrate?
- what file patterns are metadata only?

For GEO specifically:

- try series matrix or processed tables before raw archive expansion
- treat sample HTML and platform HTML as metadata, not substrate
- treat GPRs, matrices, processed sample tables, and expression tables as substrate candidates
- classify the result explicitly as `numeric`, `semi_numeric`, or `metadata_only`

### 4. Add a Hard "No Metadata Paper" Rule for Empirical Runs

An empirical paper should require all of the following:

- resolved primary dataset
- downloaded numeric or semi-numeric substrate
- at least one artifact-backed quantitative result produced in the run
- manuscript language grounded in those results

If those conditions are not met:

- produce a memo, not a paper
- explain exactly which acquisition condition failed
- attach the acquisition report and failure ledger

The system should never silently upgrade a metadata reconstruction into an empirical paper.

### 5. Instrument the Workspace So We Know What Infra We Actually Get

Right now the runs do not expose enough detail about the workspace constraints.

Add structured logging for:

- network failures by host
- redirect chains
- bytes transferred
- disk usage
- extraction size after decompressing archives
- time spent in acquisition vs planning vs analysis
- whether failures came from DNS, TLS, timeout, connection reset, or explicit HTTP response

This should answer questions like:

- can the workspace reach `ncbi.nlm.nih.gov` reliably?
- can it download GEO supplementary files above a certain size?
- does it fail on HTML pages only, binary files only, or both?
- are we hitting time limits, bandwidth limits, or agent-choice mistakes?

### 6. Add Progressive Retrieval Prompts

The Stage 2 agents need a stronger acquisition protocol:

- first prove you have numeric substrate
- report exact saved files and sizes
- only then plan analysis
- if download is too large, pivot to the smallest numeric path
- if all numeric paths fail, stop and emit acquisition failure rather than writing a paper

This keeps flexibility while forcing a deterministic handoff.

### 7. Add Regression Fixtures for Known Failing Datasets

At minimum, add a regression path for `GSE76369`.

The fixture should capture:

- the intended acquisition order
- known candidate URLs
- expected file classes
- what counts as success
- what counts as metadata-only failure

The goal is not to overfit to this paper. The goal is to ensure the system never again treats a known acquisition failure as paper-grade empirical success.

### 8. Expose These Receipts Through the CLI

The new hosted CLI is merged, but it should eventually expose more debugging surfaces for hosted runs.

Needed additions:

- `sidekick hosted fetch-log`
- `sidekick hosted bundle-summary`
- `sidekick hosted acquisition-report`

That makes overnight debugging practical without raw ad hoc scripts.

## Concrete Overnight Execution Plan

1. Add `data_access_report.json`, `download_manifest.json`, and structured network attempt logging to the hosted pipeline.
2. Insert a data-acquisition substage before `dataset-profiler`.
3. Implement generic byte/time/file budgets in config and surface them in logs.
4. Implement the first real family adapter for GEO with processed-first retrieval order.
5. Change validation so empirical runs without numeric substrate cannot become papers.
6. Re-run `GSE76369` until either:
   - numeric substrate is acquired and a true empirical paper is produced, or
   - the system cleanly downgrades to a memo with a precise acquisition failure report.
7. Compare the resulting bundle against the golden paper bar:
   - real numeric result
   - figures and tables from the run
   - convincing abstract and methods
   - no metadata-only framing if empirical paper mode is used

## Acceptance Criteria

This issue is solved only when all of the following are true:

- the hosted pipeline can tell the difference between metadata and numeric substrate
- empirical paper mode requires real downloaded substrate
- acquisition failures are logged with enough detail to debug infra limits
- the CLI can show hosted acquisition receipts
- a rerun of `GSE76369` no longer produces a metadata-only empirical paper

## Worktree / CLI Merge Status

Yes. The hosted CLI worktree changes were merged back into the main codebase.

- worktree branch commit: `5ce3eca`
- merged onto `main` as: `9bc2621`

