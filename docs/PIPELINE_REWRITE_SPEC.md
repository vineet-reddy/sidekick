# Research Paper Pipeline — Rewrite Spec

## Goal

Replace the current convoluted pipeline with a clean, linear agent-handoff architecture that mirrors how a real research lab works: search for data, analyze it, write the paper, publish to GitHub.

---

## Architecture Overview

```
[User Note / Idea]
        │
        ▼
┌──────────────────────────┐
│   STAGE 1: Web Search    │
│   (parallel agents)      │
│                          │
│  Agent A: allow-listed   │──┐
│  Agent B: open internet  │──┤── find relevant dataset
│  Agent C: retry/deeper   │──┘   (spawned only on failure)
└──────────────────────────┘
        │
        │  dataset found? ──No──▶ FAIL the paper. Stop.
        │
        ▼
┌──────────────────────────┐
│   STAGE 2: Data Analyst  │◄─────────────────────┐
│   (compute sandbox)      │                      │
│                          │               feedback loop
│  Download dataset        │               (max 2 retries)
│  Run experiments         │                      │
│  Produce code + figures  │                      │
│  Write figure summaries  │                      │
└──────────────────────────┘                      │
        │                                         │
        ▼                                         │
┌──────────────────────────┐                      │
│  STAGE 2.5: Validation   │                      │
│  (lightweight gate)      │                      │
│                          │                      │
│  Do figures support a    │──FAIL + retries──────┘
│  coherent narrative?     │   (send specific feedback)
│  Any meaningful finding? │
└──────────────────────────┘
        │
        │  passes check? ──No (out of retries)──▶ FAIL. Stop.
        │
        ▼
┌──────────────────────────┐
│   STAGE 3: Paper Writer  │
│                          │
│  Receive code + figures  │
│  + figure interpretations│
│  Write LaTeX paper       │
│  Follow standard template│
└──────────────────────────┘
        │
        ▼
┌──────────────────────────┐
│   STAGE 4: GitHub Push   │
│   (existing wiring)      │
│                          │
│  Push: paper, code,      │
│  figures, reproducible   │
│  analysis                │
└──────────────────────────┘
```

---

## Stage 1: Web Search Agents

### Purpose
Transform a raw note/idea into a validated research question and find a relevant dataset for it.

### Models
- **Agents A and B:** GPT 5.4 Mini or Nano (small, cheap, fast)
- **Agent C (retry):** GPT 5.4 with medium thinking (only spawned if A and B both fail)

### Access Requirements
- Internet access: YES
- Compute sandbox: NO

### Behavior

**Step 1 — Research Question Refinement (do this BEFORE searching for datasets):**
1. Take the raw user note/idea (which is sparse and malformed).
2. Transform it into a well-formed research question.
3. Check whether that research question is already answered online.
4. If it IS already answered, iteratively refine/narrow the question until you arrive at a novel, unanswered research question.

**Step 2 — Parallel Dataset Search:**
- **Agent A** searches for datasets within allow-listed domains only.
- **Agent B** searches for datasets on the open internet (non-allow-listed domains).
- These run in parallel.

**Step 3 — Failure Handling:**
- If both Agent A and Agent B fail to find a relevant dataset:
  - Spawn **Agent C** as a retry. Agent C uses a larger model (GPT 5.4 medium thinking) with fresh context and performs a deeper web search.
- If Agent C also fails: **the paper fails. Stop the pipeline. Do not proceed.**

### Output
- A validated, novel research question
- A dataset (URL, download link, or direct data) relevant to that question

### Design Note
The research question refinement step should be compressed into the web search agents themselves rather than split into a separate agent. Keep it simple.

---

## Stage 2: Data Analyst Agent

### Purpose
Download the dataset, run experiments, and produce reproducible code and figures.

### Model
- GPT 5.4 with **medium** thinking
  - Not high or extra-high (overthinking)
  - Not low (underthinking)

### Access Requirements
- Compute sandbox: **YES** (this is critical — needs a backend compute/storage box)
  - Note: The GPT 5.4 API already supports this via a specific function call or parameter that provisions a compute storage box. Use whatever is already in the codebase for this.
- Internet access: **YES for profiling/planning, optional for execution**
  - The heavy execution substep should not wander back into open-ended web research unless the execution plan explicitly requires it.

### Generic Research Protocol
Stage 2 must use a bounded handoff workflow, similar to how frontier coding models handle large code changes:
1. Inspect the current substrate
2. Propose a bounded execution plan
3. Execute the selected work
4. Package outputs for the next stage

This is a workflow constraint, not a science constraint. The protocol is generic; the experiments remain dataset-specific and question-specific.

### Behavior
Stage 2 consists of four generic substeps inside the same stage:

#### Stage 2A — Dataset Profiler
1. Download the dataset (or a relevant subset if the dataset is very large) onto the compute box.
2. Inspect what files, tables, columns, and samples are actually available.
3. Determine what is analyzable and what constraints exist.

Output:
- retrieval summary
- dataset profile
- available assets
- constraints
- suggested analysis targets

This substep does **not** design experiments yet.

#### Stage 2B — Experiment Planner
1. Read the validated research question.
2. Read the dataset profile.
3. Research what experiments already exist in this area.
4. Propose a small number of concrete candidate analyses.
5. Select the best 1-2 experiments to run now.

Output:
- concise execution plan
- rationale for the selected experiments
- expected artifacts
- fallback plan if a selected experiment fails

Important:
- This is not a library of pre-baked experiment templates by paper type.
- The planner stays flexible and dataset-specific.

#### Stage 2C — Data Analyst Execution
1. Re-acquire the dataset or subset if needed inside the compute sandbox.
2. Execute the selected experiments.
3. Save real reproducible artifacts.
4. Produce a bounded execution handoff rather than a full paper ledger:
   - **Executable code** for all experiments (must be reproducible)
   - **Figures** (charts, plots, visualizations)
   - **Figure summaries in plain markdown** — for each figure, write a text description of what the figure shows. This is important: downstream agents should NOT need to use vision/image capabilities to understand the results. The markdown descriptions are the source of truth.
   - findings / limitations / provenance
   - saved artifact paths

This execution call should stay focused on doing the work and writing files, not on packaging the entire final ledger shape.

If an experiment fails:
- say so explicitly
- pivot once to another reasonable experiment on the same dataset
- do not fabricate success

#### Stage 2D — Research Packager
1. Read the execution handoff from Stage 2C.
2. Read the actual workspace file inventory.
3. Assemble the bounded ledger consumed by Stage 3.

Output:
- normalized artifact manifest
- source list
- figure summaries
- results ledger
- short code summary

Important:
- The packager does not do new science.
- The packager does not invent files that are not present in the workspace.
- This substep exists to keep the heavy compute run small and the handoff deterministic.

### Output (handed off to Stage 3)
- All experiment code
- All generated figures
- Markdown interpretations of every figure

### Note
The determinism comes from the handoff protocol, not from hardcoded experiment recipes. The system should never say "all papers of type X run Y and Z." The workflow is structured; the science is still open-ended.

### Handoff Files
Stage 2 should pass structured state via bounded files rather than one giant fragile blob:
- `stage2_profile.json`
- `stage2_plan.json`
- `stage2_execution.json`
- `ledger.json`

The backend should be tolerant to structured-output formatting quirks. Perfect JSON is ideal, but a Python-dict-style structured object is an acceptable fallback when needed. The goal is robust handoff, not serialization purism.

The design principle is the same one frontier coding models follow for large diffs: the system should pass bounded work products between steps instead of asking one giant call to both do the work and serialize the entire final output perfectly.

---

## Stage 2.5: Validation Gate (with Feedback Loop)

### Purpose
A quick sanity check between the data analyst and the paper writer. Catches obvious garbage before it gets written up into a full paper. If the experiments don't tell a coherent story, this stage doesn't just kill the paper -- it sends specific feedback back to the data analyst so it can try different experiments or redo figures. You already have the dataset and the compute spun up, so it's wasteful to throw all that away without at least one retry.

### Model
- GPT 5.4 Mini or Nano (this should be fast and cheap, not a deep thinker)

### Access Requirements
- Internet access: No
- Compute sandbox: No

### Inputs
- The validated research question from Stage 1
- Markdown figure interpretations from Stage 2
- A summary of what experiments were run

### Behavior
Run a single validation prompt that asks:
1. Do these figures and experiments actually relate to the research question?
2. Do the results support a coherent narrative, or are they scattered/contradictory/nonsensical?
3. Is there at least one meaningful finding that a paper could be built around?

### Output: Three possible outcomes

**PASS:** Proceed to Stage 3 with all Stage 2 outputs unchanged.

**FAIL (retries remaining):** Loop back to Stage 2 (Data Analyst). The validation gate must produce a **specific feedback message** explaining:
- What's wrong with the current experiments/figures
- What's missing or incoherent
- A concrete suggestion for what to try differently

This feedback message gets appended to the data analyst's context alongside everything it already has (dataset, research question, its previous outputs). The data analyst then re-runs experiments with this guidance and produces new code, figures, and markdown summaries. The new outputs go through Stage 2.5 again.

**FAIL (no retries remaining):** Hard fail the paper. Log the reason. Stop the pipeline.

### Retry Policy
- **Maximum retries: 2** (so the data analyst gets up to 3 total attempts: the original run + 2 feedback-driven retries)
- Each retry must receive the validation feedback from the previous attempt so the data analyst doesn't repeat the same mistakes
- The data analyst's previous outputs should also be included in context so it knows what it already tried

### Design Notes
- The validation prompt itself stays lightweight. One prompt, one decision per loop iteration. The "weight" of this stage comes from potentially re-running the data analyst, not from the validation logic itself.
- The bar for passing should be low: "is there a coherent story here?" not "is this publishable in Nature?" If there's anything reasonable to work with, pass it through.
- The feedback message is the critical piece. A vague "try again" is useless. The validation gate must articulate what specifically doesn't work so the data analyst can course-correct.
- After 3 total data analyst attempts, if it still can't produce a coherent set of experiments, the dataset or research question is probably the problem, not the analysis. Fail the paper at that point.

---

## Stage 3: Paper Writer Agent

### Purpose
Take all experiment outputs and write a complete research paper in LaTeX.

### Model
- GPT 5.4 with **medium** thinking

### Access Requirements
- Internet access: **YES** (needs to find related work, write references, check what other papers exist in this area)
- Compute sandbox: Not required

### Inputs
- Code from Stage 2
- Figures from Stage 2
- Markdown figure interpretations from Stage 2
- The validated research question from Stage 1
- A **standard LaTeX template** (see below)

### Behavior
1. Receive all inputs from the data analyst agent.
2. Use the standard LaTeX template as the structural backbone for the paper.
3. Write the full paper in LaTeX, including:
   - Abstract (requires internet to see what other papers exist in this space)
   - Introduction
   - Related work / references (requires internet)
   - Methods
   - Results (using the figures and their markdown descriptions)
   - Discussion
   - Conclusion
   - References / bibliography
4. Output a complete, compilable LaTeX document.

### LaTeX Template
- Create a single standard LaTeX template that ALL papers produced by this app will use.
- Keep it simple and conventional (standard academic paper format).
- The paper writer agent receives this template and follows it.
- Don't build deterministic validation checks for now. If the agent follows the template >95% of the time, that's good enough. We can A/B test later to measure compliance.

### Output
- A complete LaTeX paper
- (The code and figures from Stage 2 are also carried forward)

---

## Stage 4: GitHub Push

### Purpose
Publish everything to a GitHub repository.

### Behavior
Use the **existing wiring in the codebase** to push to GitHub. No new infrastructure needed here.

Push the following to the repo:
- The LaTeX paper
- All experiment code (reproducible)
- All figures
- Any supporting files

---

## CLI Observability & Agent-Friendly Debugging

### Context

Coding agents running in a terminal are the ones building, operating, and debugging this pipeline. Every design decision in this section optimizes for that: the CLI must give a terminal-based agent (or a human) complete, real-time insight into what every stage is doing, what every LLM call is returning, and what went wrong when something fails. The feedback loop between "run the pipeline" and "understand what happened" must be as tight as possible.

### Design Principles

1. **The CLI is the primary interface.** There is no dashboard, no web UI. Everything — launching a run, inspecting progress, reading logs, replaying LLM calls — must be doable from a single terminal session via CLI commands.

2. **Agents are first-class operators.** Assume the caller is a coding agent, not a human. That means: structured output by default (JSON), parseable exit codes, no interactive prompts, no color-code-only information. Human-readable formatting is a flag (`--pretty`), not the default.

3. **Full observability at every granularity.** The CLI must support zooming from high-level ("which stage is running?") all the way down to low-level ("what tokens is the LLM streaming right now for this specific call?").

### CLI Command Surface

The following commands (or subcommands of a top-level CLI) must exist:

#### Run & Status

| Command | Description |
|---------|-------------|
| `sidekick run <note>` | Start a pipeline run. Returns a run ID immediately. |
| `sidekick status <run-id>` | Show current stage, sub-step, elapsed time, and whether the run is healthy/stalled/failed. |
| `sidekick status <run-id> --watch` | Continuously poll and stream status updates (like `tail -f` for pipeline state). |
| `sidekick list` | List all runs (active, completed, failed) with their run IDs and current status. |
| `sidekick cancel <run-id>` | Cancel a running pipeline. |

#### Logs

| Command | Description |
|---------|-------------|
| `sidekick logs <run-id>` | Dump all logs for a run (all stages, chronological). |
| `sidekick logs <run-id> --stage <N>` | Filter logs to a specific stage (1, 2, 2.5, 3, 4). |
| `sidekick logs <run-id> --level <level>` | Filter by log level: `debug`, `info`, `warn`, `error`. |
| `sidekick logs <run-id> --follow` | Stream logs in real time as the run progresses. |
| `sidekick logs <run-id> --since <timestamp>` | Show logs after a given timestamp. |
| `sidekick logs <run-id> --tail <N>` | Show the last N log lines. |
| `sidekick logs <run-id> --json` | Output logs as newline-delimited JSON (for agent consumption). |

Logging toggle at runtime:

| Command | Description |
|---------|-------------|
| `sidekick log-level <run-id> set debug` | Dynamically change the log verbosity of a running pipeline without restarting it. |
| `sidekick log-level <run-id> get` | Show the current log level for a running pipeline. |

#### LLM Call Inspection

Every LLM API call made during the pipeline must be logged and inspectable after the fact. This is critical for debugging prompt issues, understanding model behavior, and iterating on the pipeline.

| Command | Description |
|---------|-------------|
| `sidekick calls <run-id>` | List all LLM calls made during a run (stage, model, token count, latency, status). |
| `sidekick calls <run-id> --stage <N>` | Filter to calls from a specific stage. |
| `sidekick call <run-id> <call-id>` | Show full detail for a single LLM call: prompt, response, model, parameters, token usage, latency. |
| `sidekick call <run-id> <call-id> --prompt` | Show only the prompt sent. |
| `sidekick call <run-id> <call-id> --response` | Show only the response received. |

#### LLM Streaming

When an LLM call is in progress, the CLI must expose the most useful live signal for that call. For plain-text stages this is usually token streaming. For long-running compute-sandbox stages this is usually lifecycle status and heartbeat events.

| Command | Description |
|---------|-------------|
| `sidekick stream <run-id>` | Attach to the currently active LLM call and stream its live output or lifecycle events in real time. |
| `sidekick stream <run-id> --stage <N>` | Attach to the active LLM call for a specific stage. |
| `sidekick stream <run-id> --raw` | Stream raw delta tokens or raw lifecycle events (for agent parsing) instead of assembled text. |

Implementation note:
- For plain text model calls, token streaming via SSE is preferred.
- For long-running compute-sandbox calls, response ids, queued/in-progress/completed states, and heartbeat events are more important than token deltas.
- The CLI must surface whichever live signal the backend can provide for that call type.

#### Artifacts

| Command | Description |
|---------|-------------|
| `sidekick artifacts <run-id>` | List all artifacts produced by a run (datasets, code files, figures, LaTeX, markdown summaries). |
| `sidekick artifact <run-id> <artifact-id>` | Dump the contents of a specific artifact to stdout. |
| `sidekick artifacts <run-id> --stage <N>` | Filter artifacts to a specific stage. |
| `sidekick artifacts <run-id> --download <dir>` | Download all artifacts to a local directory. |

#### Retry & Feedback Inspection

Since Stage 2/2.5 has a feedback loop, the CLI must make the retry history fully transparent:

| Command | Description |
|---------|-------------|
| `sidekick retries <run-id>` | Show retry history: how many attempts, what feedback was given at each iteration, what changed. |
| `sidekick retries <run-id> --attempt <N>` | Show detail for a specific attempt (the validation feedback, the data analyst's output, pass/fail result). |

For Stage 2, the CLI must also expose which internal substep is active:
- dataset profiling
- experiment planning
- data analyst execution

An operator should be able to inspect the handoff files for each substep independently.

### Logging Architecture

#### What Gets Logged

Every log entry must include:
- **Timestamp** (ISO 8601, UTC)
- **Run ID**
- **Stage** (1, 2, 2.5, 3, 4)
- **Agent** (e.g., `search-a`, `search-b`, `search-c`, `dataset-profiler`, `experiment-planner`, `data-analyst`, `research-packager`, `validation`, `paper-writer`, `github-push`)
- **Level** (`debug`, `info`, `warn`, `error`)
- **Message** (human-readable string)
- **Structured metadata** (JSON blob with stage-specific context — e.g., model name, token count, call ID, artifact path, retry attempt number)

#### Log Levels — What Goes Where

| Level | Content |
|-------|---------|
| `error` | Pipeline failures, LLM API errors, hard stops, unrecoverable exceptions. |
| `warn` | Validation gate failures (before retry), agent fallbacks (A/B fail → spawn C), rate limits, timeouts that were retried. |
| `info` | Stage transitions, agent spawns, LLM calls initiated/completed (summary: model + tokens + latency), artifacts produced, dataset found, retry triggered. |
| `debug` | Full LLM prompts and responses, raw API payloads, intermediate agent reasoning, compute sandbox commands executed, download progress. |

Default log level for a run: `info`. Agents building the pipeline should set `debug` during development.

#### Log Storage

- Logs are written to a local log directory per run: `~/.sidekick/runs/<run-id>/logs/`
- Each stage writes to its own log file: `stage-1.log`, `stage-2.log`, `stage-2.5.log`, `stage-3.log`, `stage-4.log`
- A combined chronological log also exists: `combined.log`
- All log files are newline-delimited JSON (one JSON object per line) so they're trivially parseable by agents
- LLM call details (full prompts/responses) are stored separately: `~/.sidekick/runs/<run-id>/calls/<call-id>.json`

#### Real-Time Log Streaming

Logs must be streamable in real time, not just readable after the fact. Implementation:
- Each stage writes logs to a file AND publishes them to a local event bus (Unix domain socket or named pipe)
- `sidekick logs --follow` subscribes to this event bus
- If no subscriber is attached, logs still persist to disk — no data loss

### Structured Pipeline Events

Beyond free-text logs, the pipeline must emit structured events at key moments. These are the "state machine transitions" that let an agent know exactly what's happening:

```
PIPELINE_STARTED        { run_id, note, timestamp }
STAGE_STARTED           { run_id, stage, agent, model, timestamp }
STAGE_COMPLETED         { run_id, stage, duration_ms, artifacts[], timestamp }
STAGE_FAILED            { run_id, stage, reason, retries_remaining, timestamp }
LLM_CALL_STARTED        { run_id, stage, call_id, model, prompt_tokens, timestamp }
LLM_CALL_STREAMING      { run_id, stage, call_id, delta_token, timestamp }
LLM_CALL_COMPLETED      { run_id, stage, call_id, response_tokens, total_tokens, latency_ms, timestamp }
LLM_CALL_FAILED         { run_id, stage, call_id, error, timestamp }
VALIDATION_PASSED       { run_id, attempt, timestamp }
VALIDATION_FAILED       { run_id, attempt, feedback_message, retries_remaining, timestamp }
RETRY_STARTED           { run_id, stage, attempt, feedback_from_previous, timestamp }
ARTIFACT_PRODUCED       { run_id, stage, artifact_type, artifact_path, timestamp }
PIPELINE_COMPLETED      { run_id, total_duration_ms, timestamp }
PIPELINE_FAILED         { run_id, stage_failed_at, reason, timestamp }
```

These events are:
1. Written to `~/.sidekick/runs/<run-id>/events.jsonl`
2. Published to the same event bus as logs (so `--follow` captures them)
3. Accessible via `sidekick events <run-id>` (with same filtering flags as `sidekick logs`)

### Exit Codes

The CLI must use meaningful exit codes so agents can branch on outcomes without parsing text:

| Code | Meaning |
|------|---------|
| 0 | Pipeline completed successfully. |
| 1 | Pipeline failed — no dataset found (Stage 1). |
| 2 | Pipeline failed — validation gate exhausted retries (Stage 2.5). |
| 3 | Pipeline failed — paper writing error (Stage 3). |
| 4 | Pipeline failed — GitHub push error (Stage 4). |
| 10 | Pipeline cancelled by user/agent. |
| 20 | Internal error (unexpected crash, API auth failure, etc.). |

### Configuration via CLI

| Command | Description |
|---------|-------------|
| `sidekick config set log-level debug` | Set default log level for all future runs. |
| `sidekick config set log-retention 30d` | Set how long run logs are retained before auto-cleanup. |
| `sidekick config set stream-buffer-size 1000` | Configure how many streaming tokens to buffer before flushing. |
| `sidekick config get <key>` | Read a config value. |
| `sidekick config list` | List all config values. |

### Design Notes

- **No interactivity.** Every command runs and returns. No TUI, no curses, no "press enter to continue." Coding agents can't interact with prompts.
- **Idempotent reads.** All `status`, `logs`, `calls`, `artifacts`, `retries`, and `events` commands are pure reads with no side effects. An agent can call them as often as it wants.
- **Composability.** All commands that output data support `--json` for structured output. Agents can pipe CLI output into their own tooling.
- **Offline-safe log access.** Once a run is complete, all its logs, events, calls, and artifacts are on local disk. An agent can inspect a run's full history without any backend connectivity.

---

## Key Principles

1. **Simplicity over cleverness.** This pipeline should be simple and linear. The only parallelism is in Stage 1 (Agents A and B searching simultaneously). The only loop is between Stage 2 and 2.5 (data analyst retries based on validation feedback). Everything else is sequential handoff.

2. **Mirror a real lab.** The pipeline should feel like how a real research lab operates: find data, analyze data, write paper, publish. That's it.

3. **Fail fast on missing data.** If no dataset is found, the paper fails immediately. Don't try to generate a paper without data.

4. **No heavy deterministic quality checks for now.** The only quality gate is Stage 2.5: a single cheap prompt that asks "is there a coherent story here?" If the answer is no, it loops specific feedback back to the data analyst for up to 2 retries before hard-failing. This is the one place in the pipeline where a loop is justified -- you already have the dataset and compute, so retrying experiments is cheap compared to throwing everything away.

5. **Figure interpretations in markdown, not vision.** Every figure must have a plain-text markdown description so that the paper writer agent never needs to "look at" an image. This keeps things simple and reliable.

6. **Always output the simplest possible implementation first.** Do not over-engineer. Get the linear pipeline working, then optimize.

7. **The CLI is the cockpit.** Coding agents running in a terminal are the primary operators of this pipeline. Every pipeline state transition, every LLM call, every artifact, and every failure must be observable through CLI commands with structured JSON output. If an agent can't figure out what happened from the CLI alone, the observability is insufficient.

8. **Logging is not an afterthought.** Logs, structured events, and LLM call tracing are first-class features, not debug aids bolted on later. They ship with v1 of the pipeline, not v2.

---

## What to Rip Out

The current codebase has a convoluted process with many disjointed moving parts. This rewrite should:
- Remove or replace the existing pipeline logic entirely
- Collapse everything into the four stages described above
- Reuse the existing GitHub push wiring and compute sandbox integration
- Eliminate any unnecessary deterministic checks, redundant agents, or overly complex orchestration

---

## Model Summary

| Stage | Agent | Model | Thinking Level | Internet | Compute Sandbox |
|-------|-------|-------|---------------|----------|-----------------|
| 1 | Web Search A (allow-listed) | GPT 5.4 Mini/Nano | Default | Yes | No |
| 1 | Web Search B (open internet) | GPT 5.4 Mini/Nano | Default | Yes | No |
| 1 | Web Search C (retry, if needed) | GPT 5.4 | Medium | Yes | No |
| 2 | Dataset Profiler | GPT 5.4 | Medium | Yes | Yes |
| 2 | Experiment Planner | GPT 5.4 | Medium | Yes | No |
| 2 | Data Analyst Execution | GPT 5.4 | Medium | Yes | Yes |
| 2.5 | Validation Gate | GPT 5.4 Mini/Nano | Default | No | No |
| 3 | Paper Writer | GPT 5.4 | Medium | Yes | No |
| 4 | GitHub Push | N/A (existing code) | N/A | Yes | No |
