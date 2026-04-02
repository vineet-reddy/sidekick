# Architecture

## System Overview

Sidekick is a three-tier system: an iOS app (thin client), a Python backend (orchestrator), and OpenAI's infrastructure (compute).

```
┌──────────────┐         HTTPS/JSON          ┌──────────────────┐
│   iOS App    │ ──────────────────────────→  │  Sidekick Backend │
│  (SwiftUI)   │ ←────────────────────────── │  (Python/SQLite)  │
│              │                              │                   │
│  Notes in    │                              │  Pipeline engine  │
│  Papers out  │                              │  GitHub OAuth     │
│              │                              │  Job management   │
└──────────────┘                              └────────┬──────────┘
                                                       │
                                              ┌────────┴──────────┐
                                              │                   │
                                    ┌─────────▼──┐     ┌─────────▼──────┐
                                    │  OpenAI    │     │   GitHub API   │
                                    │  Responses │     │                │
                                    │  API       │     │  Repo creation │
                                    │            │     │  File commits  │
                                    │  Code      │     │  OAuth flow    │
                                    │  Interpreter│     │                │
                                    └────────────┘     └────────────────┘
```

## Component Details

### iOS App (`Sidekick/`)

The app is a SwiftUI application using SwiftData for local persistence. It has three tabs: Notes, Papers, and Settings.

**Service layer:**

| Service | Type | Responsibility |
|---------|------|---------------|
| `HeartbeatManager` | `@MainActor actor` | Orchestrates the entire note-to-paper flow. Runs on app open, foreground, and background refresh. |
| `OpenAIService` | `ObservableObject` | HTTP client for all backend API calls. Handles session token refresh on 401. |
| `GitHubService` | `ObservableObject` | Device session management, GitHub OAuth connection, export context persistence. |
| `TrustedDatasetRegistry` | `actor` | Loads/caches 100+ dataset entries. Scores and selects datasets for each note cluster. |
| `PaperArtifactStore` | Static methods | File-based persistence of pipeline stage artifacts in `~/Library/Application Support/PaperArtifacts/`. |
| `PaperDocumentService` | Static methods | PDF rendering via WKWebView. Caches by content fingerprint. |
| `NotificationService` | `ObservableObject` | Local push notifications when papers complete. |
| `ExportService` | Static methods | LaTeX/PDF export utilities. |

**Data models (SwiftData):**

| Model | Key Fields | Purpose |
|-------|-----------|---------|
| `Note` | `id`, `content`, `createdAt`, `priorityRequestedAt` | User's raw idea input |
| `Paper` | `id`, `title`, `markdown`, `status`, `codexTaskID`, `figureData` | Generated research paper |
| `ResearchRun` | `runID`, `paperID`, `currentStage`, `status`, `queueState`, `sourceNoteIDs`, `datasetIDs` | Pipeline execution state |

### Backend (`github_bootstrap_service/`)

A multi-threaded Python HTTP server using only the standard library (no pip dependencies). SQLite for persistence.

**Module responsibilities:**

| Module | Purpose |
|--------|---------|
| `server.py` | HTTP request routing, endpoint handlers, thread pool for pipeline jobs |
| `config.py` | Model names, token costs, concurrency limits, timeouts |
| `database.py` | SQLite schema, CRUD for sessions/connections/jobs/metrics |
| `pipeline_engine.py` | 5-stage paper generation pipeline (the core logic) |
| `pipeline_runtime.py` | Run state tracking, JSONL event logging, per-call audit trail |
| `openai_client.py` | OpenAI Responses API: create responses, poll status, download container files |
| `github_client.py` | GitHub API: OAuth, repo CRUD, file commits with base64 encoding |
| `manuscript.py` | LaTeX document assembly, section normalization, PDF compilation via Tectonic |
| `resolver.py` | Paper mode classification, dataset-to-source-family matching |
| `store.py` | Bootstrap session state machine |
| `crypto.py` | XOR-stream cipher for encrypting GitHub tokens at rest |

**Database tables:**

| Table | Purpose |
|-------|---------|
| `install_sessions` | Device registration. One per phone. Contains session token for auth. |
| `github_connect_sessions` | Transient OAuth state (3600s TTL) |
| `github_connections` | Completed OAuth: encrypted access token, repo owner/name, visibility |
| `paper_jobs` | Pipeline job state: queued/running/completed/failed, stage tracking |
| `paper_job_metrics` | Token usage and cost estimates per job |

### Paperlab CLI (`paperlab/`)

Terminal-first interface for running and debugging the pipeline locally. Shares the same `pipeline_engine.py` and `pipeline_runtime.py` as the backend.

Key commands: `run`, `status`, `logs`, `calls`, `artifacts`, `paper-quality verify`, `autoresearch run`.

## Data Flow: Notes to Papers

### Phase 1: Heartbeat Assessment

The `HeartbeatManager` runs on a 20-minute cooldown (forced on app open/foreground).

```
HeartbeatManager.runHeartbeat()
│
├── 1. resolveInFlightPapers()
│      For each Paper with status=.generating:
│        → GET /api/papers/{jobID}
│        → Update stage, progress message
│        → If completed: GET /api/papers/{jobID}/artifacts
│        → Apply artifacts (markdown, figures, export metadata)
│        → Mark paper .ready, send push notification
│
├── 2. reconsiderHeldResearchRunsIfNeeded()
│      If GitHub just connected: unblock held ResearchRuns
│
├── 3. admitQueuedResearchRunsIfPossible()
│      If < 4 papers running: admit next queued ResearchRun
│        → POST /api/papers (submit the job)
│
└── 4. discoverNewPaperCandidates()
       ├── submitManuallyPrioritizedNotes()
       │     Notes with priorityRequestedAt set → immediate paper creation
       │
       └── assessNotesWithRescue()
             → POST /api/notes/assess (up to 3 rounds)
             → Returns NoteCluster[] with theme, title, datasetIDs, readiness
             → Deduplicate, score, select top clusters
             → For each selected cluster:
                → TrustedDatasetRegistry.selectSource()
                → POST /api/papers (prepare, get scheduling disposition)
                → Create Paper + ResearchRun in SwiftData
                → Queue for admission
```

### Phase 2: Pipeline Execution (Backend)

When a job is submitted to the backend, it runs through 5 stages:

```
Stage 1: Dataset Search & Resolution
  → Classify paper mode (empirical, bibliometric, literature_review, etc.)
  → Resolve source families from trusted registry
  → Select primary dataset

Stage 2: Research Workspace
  → OpenAI Responses API with code_interpreter tool
  → Agent downloads real data, runs analysis, produces figures/tables
  → Returns ledger with sources, results, artifacts

Stage 2.5: Artifact Materialization
  → Download files from OpenAI containers
  → SHA256 hash each artifact
  → Build artifact manifest (figures, tables)

Stage 3: Manuscript Writing
  → LLM writes LaTeX (abstract, methods, results, discussion, etc.)
  → Validation: ban synthetic data claims, check source reality
  → Compile PDF via Tectonic

Stage 4: GitHub Publication
  → Ensure user's sidekick repo exists
  → Commit: paper.tex, paper.pdf, figures/, tables/, references.bib, ledger.json
  → Directory: papers/{date}-{slug}-{job_id[:6]}/
  → Record commit SHA
```

### Phase 3: Artifact Delivery

```
Backend marks job completed
  → iOS app polls, sees completion
  → Downloads artifact bundle (markdown, figures, export metadata)
  → Persists to SwiftData (Paper.markdown, Paper.figureData)
  → Persists to PaperArtifactStore (stage artifacts, export metadata)
  → Renders PDF via PaperDocumentService
  → Sends local push notification
```

## API Contract

All requests from the iOS app include `Authorization: Bearer {sessionToken}`.

### Device & Auth Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/device/session` | Create/resume device session. Body: `{device_id}`. Returns: `{install_session_id, session_token}` |
| `POST` | `/api/github/connect/start` | Start GitHub OAuth. Returns: `{session_id, browser_url}` |
| `GET` | `/api/github/connect/sessions/{id}` | Poll OAuth completion. Returns connection status + export context |

### Paper Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/notes/assess` | Cluster notes for paper readiness. Body: `{notes: [{id, text}]}`. Returns: `{clusters: [NoteCluster]}` |
| `POST` | `/api/papers` | Submit paper job. Body: `{notes, title, theme, dataset_ids}`. Returns: `{job_id}` |
| `GET` | `/api/papers/{job_id}` | Poll job status. Returns: `{status, stage, progress_message}` |
| `GET` | `/api/papers/{job_id}/artifacts` | Download completed artifacts. Returns: figures, markdown, export metadata |

### Health

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Returns 200 if server is running |

## Authentication Flow

```
iOS App                          Backend                        GitHub
  │                                │                              │
  │  POST /api/device/session      │                              │
  │  {device_id: UUID}             │                              │
  │──────────────────────────────→ │                              │
  │  {session_token, install_id}   │                              │
  │←────────────────────────────── │                              │
  │                                │                              │
  │  POST /api/github/connect/start│                              │
  │──────────────────────────────→ │                              │
  │  {browser_url}                 │                              │
  │←────────────────────────────── │                              │
  │                                │                              │
  │  [User opens browser_url]      │                              │
  │                                │  OAuth redirect              │
  │                                │────────────────────────────→ │
  │                                │  Authorization code          │
  │                                │←──────────────────────────── │
  │                                │  Exchange for access token   │
  │                                │────────────────────────────→ │
  │                                │  {access_token}              │
  │                                │←──────────────────────────── │
  │                                │  Create/ensure sidekick repo │
  │                                │────────────────────────────→ │
  │                                │                              │
  │  GET /api/github/connect/sessions/{id}                        │
  │──────────────────────────────→ │                              │
  │  {connection: {completed},     │                              │
  │   export_context: {repo_url}}  │                              │
  │←────────────────────────────── │                              │
```

The backend holds the GitHub OAuth client secret and the user's GitHub access token (encrypted at rest). The iOS app never touches either.

## Concurrency & Scheduling

- **Max 4 concurrent papers per device** (enforced by `HeartbeatManager`)
- **Heartbeat cooldown:** 20 minutes between automatic runs
- **Foreground polling:** Every 30 seconds while papers are generating
- **Background refresh:** iOS `BGAppRefreshTask`, scheduled ~4 hours apart
- **Backend concurrency:** 4 jobs per install session (`config.py`)
- **Job timeout:** 3600 seconds (1 hour)
- **Daily spend cap:** $100 USD (based on token cost estimates)

## Trusted Dataset Registry

The registry is the bridge between a scientist's ideas and real data. It ships bundled with the app (100+ entries) and refreshes from a remote source every 12 hours.

**Selection algorithm:**
1. Filter to trusted, non-auth-requiring, non-disabled direct sources
2. Score each dataset by semantic similarity to note text (keyword overlap + fuzzy matching)
3. Boost by trust tier (official > curated > discovery) and support tier
4. Filter by minimum fit score
5. If no fit, fall back to discovery catalogs (OpenAlex, PubMed)
6. Return selection with scheduling disposition (autoStart if supported tier, hold otherwise)

**Source families (backend):**
10 curated families: GDC, cBioPortal, GEO, DANDI, OpenNeuro, Harvard Dataverse, Zenodo, Figshare, OpenAlex, PubMed. Each has trusted domains, minimum result thresholds, and supported paper modes.

## Key Configuration

### Backend (`config.py`)

| Setting | Value | Purpose |
|---------|-------|---------|
| OpenAI model | `gpt-5.4` (configurable) | Main model for pipeline |
| Assessment model | `gpt-5-nano` | Lightweight model for note clustering |
| Max job runtime | 3600s | Kill jobs exceeding this |
| Max daily spend | $100 USD | Pause new jobs if exceeded |
| Max concurrent jobs | 4 per install | Queue limit |
| Artifact TTL | 24 hours | Clean up old artifacts |
| Data access limits | 250MB total, 100MB/file, 12 files, 900s timeout | Sandbox constraints |

### iOS App

| Setting | Source | Purpose |
|---------|--------|---------|
| Backend URL | Env var or Info.plist | Where to send API requests |
| Heartbeat cooldown | 20 min (hardcoded) | Minimum time between heartbeats |
| Max in-flight papers | 4 (hardcoded) | Concurrent paper limit |
| Registry refresh | 12 hours | Dataset catalog update interval |
