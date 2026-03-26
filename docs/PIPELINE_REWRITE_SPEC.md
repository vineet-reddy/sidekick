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
- Internet access: **YES** (so it can research what experiments have already been done and avoid redundant/random experiments)

### Behavior
1. Download the dataset (or relevant subset if the dataset is very large) onto the compute storage box.
2. Research what experiments have already been done in this area (using internet access).
3. Design and run meaningful experiments on the data.
4. Produce:
   - **Executable code** for all experiments (must be reproducible)
   - **Figures** (charts, plots, visualizations)
   - **Figure summaries in plain markdown** — for each figure, write a text description of what the figure shows. This is important: downstream agents should NOT need to use vision/image capabilities to understand the results. The markdown descriptions are the source of truth.

### Output (handed off to Stage 3)
- All experiment code
- All generated figures
- Markdown interpretations of every figure

### Note
In practice, GPT 5.4 medium thinking does a great job at this with minimal instructions. Don't over-engineer the prompting here.

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

## Key Principles

1. **Simplicity over cleverness.** This pipeline should be simple and linear. The only parallelism is in Stage 1 (Agents A and B searching simultaneously). The only loop is between Stage 2 and 2.5 (data analyst retries based on validation feedback). Everything else is sequential handoff.

2. **Mirror a real lab.** The pipeline should feel like how a real research lab operates: find data, analyze data, write paper, publish. That's it.

3. **Fail fast on missing data.** If no dataset is found, the paper fails immediately. Don't try to generate a paper without data.

4. **No heavy deterministic quality checks for now.** The only quality gate is Stage 2.5: a single cheap prompt that asks "is there a coherent story here?" If the answer is no, it loops specific feedback back to the data analyst for up to 2 retries before hard-failing. This is the one place in the pipeline where a loop is justified -- you already have the dataset and compute, so retrying experiments is cheap compared to throwing everything away.

5. **Figure interpretations in markdown, not vision.** Every figure must have a plain-text markdown description so that the paper writer agent never needs to "look at" an image. This keeps things simple and reliable.

6. **Always output the simplest possible implementation first.** Do not over-engineer. Get the linear pipeline working, then optimize.

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
| 2 | Data Analyst | GPT 5.4 | Medium | Yes | Yes |
| 2.5 | Validation Gate | GPT 5.4 Mini/Nano | Default | No | No |
| 3 | Paper Writer | GPT 5.4 | Medium | Yes | No |
| 4 | GitHub Push | N/A (existing code) | N/A | Yes | No |
