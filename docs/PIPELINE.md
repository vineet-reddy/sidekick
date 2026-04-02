# Paper Generation Pipeline

The pipeline transforms a scientist's notes into a complete, reproducible research paper published to GitHub. It runs on the Sidekick backend, orchestrated by `pipeline_engine.py`.

## Pipeline Stages

```
Notes + Dataset IDs
       │
       v
┌──────────────────────────────────────┐
│  Stage 1: Dataset Search & Resolution │
│  Classify paper mode, match datasets  │
│  Select primary data source           │
└──────────────┬───────────────────────┘
               │
               v
┌──────────────────────────────────────┐
│  Stage 2: Research Workspace          │
│  OpenAI code interpreter runs         │
│  Downloads data, runs analysis        │
│  Produces figures, tables, stats      │
└──────────────┬───────────────────────┘
               │
               v
┌──────────────────────────────────────┐
│  Stage 2.5: Artifact Materialization  │
│  Download files from OpenAI containers│
│  SHA256 hash, build manifest          │
└──────────────┬───────────────────────┘
               │
               v
┌──────────────────────────────────────┐
│  Stage 3: Manuscript Writing          │
│  LLM writes LaTeX from analysis       │
│  Validate: no synthetic data claims   │
│  Compile PDF via Tectonic             │
└──────────────┬───────────────────────┘
               │
               v
┌──────────────────────────────────────┐
│  Stage 4: GitHub Publication          │
│  Ensure user's sidekick repo exists   │
│  Commit all artifacts                 │
│  Record commit SHA                    │
└──────────────────────────────────────┘
```

## Stage 1: Dataset Search & Resolution

**Module:** `resolver.py`

**Purpose:** Determine what kind of paper to write and which data source to use.

### Paper Modes

Defined in `resources/paper_modes.json`:

| Mode | Description | Constraints |
|------|-------------|-------------|
| `empirical_dataset` | Analysis of real experimental data | Cannot use literature-only sources (OpenAlex, PubMed) as primary |
| `bibliometric` | Quantitative analysis of publication patterns | Can use literature APIs |
| `literature_review` | Systematic review of existing work | Can use literature APIs |
| `methods_simulation` | Computational methods with synthetic benchmarks | Relaxed data requirements |
| `theoretical_commentary` | Theoretical framework or commentary | Minimal data requirements |

The resolver classifies the paper mode from the input notes using keyword detection.

### Source Families

Defined in `resources/source_families.json`. Ten curated families:

| Family | Type | Modalities |
|--------|------|------------|
| `gdc_cancer_genomics` | `direct_runtime_source` | Cancer genomics |
| `cbioportal_cancer_studies` | `direct_runtime_source` | Cancer genomics |
| `geo_functional_genomics` | `domain_repository` | Gene expression |
| `dandi_neurophysiology` | `direct_runtime_source` | Neurophysiology |
| `openneuro_neurophysiology` | `direct_runtime_source` | Neurophysiology |
| `harvard_dataverse_open_data` | `general_repository` | Multi-domain |
| `zenodo_open_research` | `general_repository` | Multi-domain |
| `figshare_open_data` | `general_repository` | Multi-domain |
| `openalex_literature` | `discovery_catalog` | Bibliographic |
| `pubmed_literature` | `discovery_catalog` | Bibliographic |

Each family has:
- **Trusted domains:** Allowlisted API/portal URLs
- **Minimum thresholds:** `case_count` (5), `asset_count` (3), `result_count` (5)
- **Supported paper modes:** Which paper modes can use this family
- **`allow_in_automatic_mode`:** Whether the heartbeat can auto-select this source

### Resolution Output

A `ResolutionBundle` containing:
- `status`: `resolved` or `blocked`
- `paper_mode`: Classified mode
- `candidates`: Ranked source families
- `selected`: Primary dataset for the pipeline

## Stage 2: Research Workspace

**Module:** `pipeline_engine.py`, `openai_client.py`

**Purpose:** Have an AI agent download real data, run statistical analysis, and produce research artifacts.

### How It Works

1. Construct a system prompt with the paper's notes, selected dataset hints, and research instructions
2. Call the OpenAI Responses API with `code_interpreter` tool enabled
3. The AI agent:
   - Downloads datasets from the resolved source (API calls, file downloads)
   - Loads data into pandas/numpy/scipy
   - Runs statistical analysis (t-tests, regressions, correlations, etc.)
   - Generates figures (matplotlib/seaborn plots)
   - Produces summary tables
   - Writes an analysis log describing what was done
4. Returns a ledger with sources, results, artifacts, and methodology

### OpenAI Responses API

The backend uses the Responses API (not Chat Completions) because it supports:
- **Code interpreter:** Sandboxed Python environment with internet access
- **Background execution:** Jobs can run for minutes
- **Container files:** Download generated artifacts (figures, data files)
- **Web search:** Find datasets and references

API flow:
```
POST /responses
  → Create response with tools: [code_interpreter, web_search]
  → Returns response_id

GET /responses/{response_id}  (poll every 5 seconds)
  → Returns status: in_progress | completed | failed

GET /containers/{container_id}/files
  → List files generated by code interpreter

GET /containers/{container_id}/files/{file_id}/content
  → Download individual files
```

### Data Access Limits

| Limit | Value |
|-------|-------|
| Total download size | 250 MB |
| Per-file size | 100 MB |
| Max files | 12 |
| Download timeout | 900 seconds |

## Stage 2.5: Artifact Materialization

**Module:** `pipeline_engine.py`

**Purpose:** Download all files generated by the code interpreter and organize them.

1. List container files from the OpenAI response
2. Download each file, computing SHA256 hash
3. Classify as figure (PNG/JPG/SVG) or table (CSV/TSV/JSON/TXT)
4. Build an artifact manifest with:
   - Figures: auto-numbered `fig-1`, `fig-2`, etc. with captions
   - Tables: with row counts and column descriptions
5. If fewer than 3 figures, attempt to synthesize simple charts from table data

## Stage 3: Manuscript Writing

**Module:** `pipeline_engine.py`, `manuscript.py`

**Purpose:** Write a complete LaTeX research paper from the analysis results.

### Writing Process

1. Construct a prompt with the analysis ledger, artifact manifest, and notes
2. LLM generates LaTeX sections: abstract, introduction, methods, results, discussion, conclusion, limitations, references
3. `manuscript.py` normalizes sections:
   - Validates required sections are present
   - Auto-generates conclusion from discussion/results if missing
   - Applies LaTeX escaping
   - Inserts figure and table environments
   - Builds bibliography

### Validation

Manuscripts are checked for:
- **Banned phrases:** "synthetic data", "mock data", "placeholder", "illustrative purposes", "simulated", "dummy data"
- **Source verification:** Cross-reference claimed data sources against the analysis ledger
- **Section completeness:** All required sections present with minimum content length
- **Figure/table balance:** Environments properly opened and closed
- **Placeholder patterns:** `[[CITE:]]`, `TODO`, `lorem ipsum`

### PDF Compilation

Uses **Tectonic v0.15.0** (a modern LaTeX engine) to compile PDF. The Dockerfile includes `texlive-latex-base`, `texlive-latex-recommended`, `texlive-latex-extra`, `texlive-fonts-recommended`, and `texlive-bibtex-extra`.

Output: `paper.pdf` or `memo.pdf`.

## Stage 4: GitHub Publication

**Module:** `pipeline_engine.py`, `github_client.py`

**Purpose:** Publish all artifacts to the user's GitHub repository.

### Repository Structure

```
user/sidekick/
└── papers/
    └── 20260402-circadian-metrics-abc123/
        ├── paper.tex          # LaTeX source
        ├── paper.pdf          # Compiled PDF
        ├── references.bib     # Bibliography
        ├── ledger.json        # Analysis provenance
        ├── validation.json    # Quality check results
        ├── images/
        │   ├── fig-1.png
        │   └── fig-2.png
        └── tables/
            ├── table-1.csv
            └── table-2.json
```

### Publication Process

1. **Ensure repo exists:** `github_client.ensure_sidekick_repository()` creates the `sidekick` repo if missing, fixes visibility if needed
2. **Commit files:** Each file committed individually via GitHub Contents API (base64 encoded)
3. **Record provenance:** Final commit SHA and repo path stored in job result
4. **Rate limit handling:** 5 retries with exponential backoff (15-180s delays) for GitHub API rate limits

## Pipeline Runtime

**Module:** `pipeline_runtime.py`

Each pipeline run creates a directory structure for full auditability:

```
~/.sidekick/runs/{run_id}/
├── state.json           # Status, current stage, timestamps
├── events.jsonl         # Structured event log
├── stage-1.log          # Per-stage output logs
├── stage-2.log
├── stage-2.5.log
├── stage-3.log
├── stage-4.log
└── calls/
    └── call_{timestamp}_{pid}.json  # Per-LLM call: prompt, response, tokens, latency
```

Event types: `PIPELINE_STARTED`, `STAGE_STARTED`, `STAGE_COMPLETED`, `ARTIFACT_PRODUCED`, `PIPELINE_COMPLETED`, `PIPELINE_FAILED`.

## Paper Quality Verification

**Module:** `paperlab/paper_quality.py`

A separate verification system for evaluating generated papers. Used by the `paperlab paper-quality verify` CLI command.

### Deterministic Checks

| Check | Points Lost |
|-------|-------------|
| LaTeX compilation failure | -25 |
| Missing required section | -12 each |
| Missing title or author | -12 |
| Figure/table environment imbalance | -12 |
| Missing figure assets | -12 |
| Content below length threshold | -12 |
| Placeholder patterns detected | -12 |
| Missing validation/ledger JSON | -12 |
| No empirical results in ledger | -12 |

Base score: 100. Paper fails below threshold.

### LLM Review

An adversarial LLM reviewer checks for:
- Reward hacking signals (papers that game metrics without real analysis)
- Major methodological failures
- Hallucinated results or references
- Consistency between claimed methods and actual analysis

Final verdict combines deterministic score and LLM review.

## AutoResearch

**Module:** `paperlab/autoresearch.py`

An automated repair loop inspired by Karpathy's autoresearch. Repeatedly attempts to improve paper quality by:

1. Running the pipeline
2. Checking quality with `paper_quality.py`
3. Identifying failures
4. Applying fixes and retrying

Uses git worktrees for isolation. Configurable time budget, max attempts, and verify commands.

## Configuration

### Models (`config.py`)

| Role | Model | Purpose |
|------|-------|---------|
| Paper generation | `gpt-5.4` (configurable) | Main pipeline stages |
| Note assessment | `gpt-5-nano` | Lightweight clustering |
| Quality review | `gpt-5-mini` | Paper evaluation |

### Limits

| Setting | Value |
|---------|-------|
| Max job runtime | 3600 seconds |
| Max daily spend | $100 USD |
| Max concurrent jobs | 4 per install |
| Token cost (input) | $0.25 per million |
| Token cost (output) | $2.00 per million |
| Artifact TTL | 24 hours |
