# Sidekick

An iOS app that turns scientists' raw ideas into real, reproducible research papers. You write notes. AI finds datasets, runs analysis, writes the paper, and publishes it to GitHub.

This repo contains **two main components**:

1. **Sidekick iOS App** (`Sidekick/`) — SwiftUI iPhone app where scientists jot down ideas and read generated papers
2. **Sidekick Backend** (`github_bootstrap_service/`) — Python server that runs paper generation jobs via OpenAI, manages GitHub OAuth, and publishes results

There is also a **CLI harness** (`paperlab/`) for local development and testing of the paper pipeline.

## How It Works

```
Scientist writes notes on iPhone
        |
        v
Heartbeat runs (on app open or background refresh)
        |
        v
AI clusters notes, decides which are paper-ready
        |
        v
Backend receives job: notes + dataset IDs
        |
        v
5-stage pipeline runs via OpenAI Responses API:
  1. Dataset search & resolution
  2. Research workspace (code interpreter runs real analysis)
  3. Artifact materialization (figures, tables, data)
  4. Manuscript writing & LaTeX compilation
  5. GitHub publication (code + paper + data)
        |
        v
Paper appears in app with PDF, figures, and GitHub link
```

## Repo Structure

```
sidekick/
├── Sidekick/                        # iOS app (Xcode project)
│   └── Sidekick/
│       ├── SidekickApp.swift        # App entry point, service initialization
│       ├── ContentView.swift        # Tab bar (Notes / Papers / Settings)
│       ├── Models.swift             # SwiftData models: Note, Paper
│       ├── Models/
│       │   └── ResearchRun.swift    # Pipeline execution state model
│       ├── Views/
│       │   ├── NoteListView.swift   # Note list + inline composer
│       │   ├── NoteEditorView.swift # Note editing sheet
│       │   ├── PaperListView.swift  # Paper list with status pills
│       │   └── PaperDetailView.swift# PDF viewer + progress + export
│       ├── Services/
│       │   ├── OpenAIService.swift          # Backend API client
│       │   ├── GitHubService.swift          # Device sessions + GitHub OAuth
│       │   ├── HeartbeatManager.swift       # Orchestrator: note assessment -> paper jobs
│       │   ├── TrustedDatasetRegistry.swift # Dataset catalog + smart selection
│       │   ├── PaperArtifactStore.swift     # File-based artifact persistence
│       │   ├── PaperDocumentService.swift   # PDF rendering (HTML -> WKWebView)
│       │   ├── NotificationService.swift    # Local push notifications
│       │   ├── ExportService.swift          # LaTeX/PDF export utilities
│       │   └── ...                          # Other support services
│       ├── Support/
│       │   ├── MarkdownRenderer.swift       # Markdown -> attributed string
│       │   ├── ShareSheet.swift             # UIActivityViewController wrapper
│       │   └── SafariBrowserView.swift      # SFSafariViewController wrapper
│       └── Resources/
│           └── trusted_datasets.json        # Bundled dataset catalog (100+ entries)
│
├── github_bootstrap_service/        # Backend server (Python, stdlib only)
│   ├── bootstrap_service/
│   │   ├── server.py                # HTTP server + all endpoints
│   │   ├── config.py                # Models, costs, limits, timeouts
│   │   ├── database.py              # SQLite schema + queries
│   │   ├── pipeline_engine.py       # 5-stage paper generation pipeline
│   │   ├── pipeline_runtime.py      # Run state, event logging, call tracking
│   │   ├── openai_client.py         # OpenAI Responses API client
│   │   ├── github_client.py         # GitHub API: repos, commits, OAuth
│   │   ├── manuscript.py            # LaTeX rendering + PDF compilation
│   │   ├── resolver.py              # Dataset resolution + paper mode classification
│   │   ├── store.py                 # Bootstrap session management
│   │   ├── crypto.py                # XOR-stream encryption for tokens
│   │   └── resources/
│   │       ├── paper_modes.json     # 5 paper types with constraints
│   │       └── source_families.json # 10 trusted data source families
│   ├── tests/                       # pytest suite (~3700 lines)
│   ├── Dockerfile                   # Python 3.12 + texlive for LaTeX
│   ├── .env.example                 # Required environment variables
│   └── requirements.txt             # stdlib only (no pip deps)
│
├── paperlab/                        # CLI harness for pipeline dev/testing
│   ├── cli.py                       # Full CLI: run, status, logs, artifacts, etc.
│   ├── paper_quality.py             # Deterministic + LLM paper quality checks
│   ├── autoresearch.py              # Automated repair loop (Karpathy-style)
│   ├── README.md                    # CLI usage docs
│   └── runs/                        # Local pipeline run output
│
├── scripts/                         # Dev utilities
│   ├── run_github_bootstrap_service.sh
│   ├── sidekick-sim-logs.sh         # Simulator log capture + LaunchAgent
│   └── sidekick_sim_log_daemon.py
│
├── docs/                            # Documentation
│   ├── ARCHITECTURE.md              # Technical architecture deep-dive
│   ├── iOS-APP.md                   # iOS app developer guide
│   ├── PIPELINE.md                  # Paper pipeline reference
│   ├── bootstrap-service.md         # Backend deployment & config
│   ├── OVERNIGHT_DATA_ACCESS_PLAN.md
│   └── PIPELINE_REWRITE_SPEC.md
│
├── VISION.md                        # Product vision & relationship to Agent Science
├── TODO.md                          # Known issues & improvement opportunities
├── design.md                        # Original design document
├── render.yaml                      # Render.com deployment config
└── .github/workflows/
    └── render-backend-deploy.yml    # Auto-deploy backend on push to main
```

## Getting Started

### Prerequisites

- **Xcode 16+** (for iOS app)
- **Python 3.12+** (for backend)
- **OpenAI API key** (for paper generation)
- **GitHub OAuth app** (for user repo publishing)

### iOS App (Simulator)

1. Open `Sidekick/Sidekick.xcodeproj` in Xcode
2. Set the scheme to the Sidekick target
3. Set environment variable in scheme: `SIDEKICK_BACKEND_BASE_URL=http://localhost:8787`
4. Run on simulator (Cmd+R)

The app reads the backend URL from:
- `SIDEKICK_BACKEND_BASE_URL` environment variable (development)
- `SidekickGitHubBootstrapBaseURL` in `Info.plist` (release builds)

### Backend (Local)

```bash
cp github_bootstrap_service/.env.example github_bootstrap_service/.env
# Edit .env with your GitHub OAuth and OpenAI credentials

export $(grep -v '^#' github_bootstrap_service/.env | xargs)
export OPENAI_API_KEY=sk-...
export SIDEKICK_ENCRYPTION_SECRET=any-random-string

./scripts/run_github_bootstrap_service.sh
# Server starts on http://localhost:8787
```

Required environment variables:

| Variable | Purpose |
|----------|---------|
| `GITHUB_CLIENT_ID` | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth app client secret |
| `OPENAI_API_KEY` | OpenAI API key for Responses API |
| `SIDEKICK_ENCRYPTION_SECRET` | Secret for encrypting stored GitHub tokens |
| `SIDEKICK_BACKEND_BASE_URL` | Public URL of the backend (for OAuth callbacks) |

Optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SIDEKICK_OPENAI_MODEL` | `gpt-5.4` | Model for paper generation |
| `SIDEKICK_BACKEND_MAX_JOB_RUNTIME_SECONDS` | `3600` | Max pipeline runtime |
| `SIDEKICK_BACKEND_MAX_DAILY_SPEND_USD` | `100` | Daily spend cap |

### Paperlab CLI

```bash
# Run a paper locally
python -m paperlab.cli run --title "My Paper" --notes "idea text here"

# Check status
python -m paperlab.cli status <run-id>

# Run quality checks on a generated paper
python -m paperlab.cli paper-quality verify <path-to-paper-dir>

# Submit to hosted backend
python -m paperlab.cli hosted session
python -m paperlab.cli hosted connect
python -m paperlab.cli hosted submit --title "My Paper" --notes "idea text"
```

See `paperlab/README.md` for full CLI reference.

### Running Tests

```bash
python -m pytest github_bootstrap_service/tests/ -v
```

### Simulator Logs

Use the log capture script for debugging the iOS app:

```bash
./scripts/sidekick-sim-logs.sh start   # Install LaunchAgent for persistent capture
./scripts/sidekick-sim-logs.sh tail --lines 200 --follow
./scripts/sidekick-sim-logs.sh stream  # Live foreground view
```

Logs are written to `~/Library/Logs/Sidekick/` with a symlink at `.sidekick-runtime/latest-simulator.log`.

## Deployment

The backend deploys to [Render](https://render.com) automatically on push to `main` (any changes under `github_bootstrap_service/` or `render.yaml`).

- **Service**: `sidekick-github-bootstrap` (Docker, Starter plan)
- **Health check**: `GET /health`
- **CI workflow**: `.github/workflows/render-backend-deploy.yml`
- **Service ID**: `srv-d70bar1r0fns73co8f9g`

See `docs/bootstrap-service.md` for full deployment details.

## Key Design Decisions

- **No on-device AI.** The phone is a thin client. All compute runs server-side via OpenAI.
- **No pip dependencies.** The backend uses Python stdlib only for minimal attack surface and fast deploys.
- **Real data, not synthetic.** Papers must use real open datasets. Banned phrases like "synthetic data" and "mock data" are enforced in validation.
- **GitHub-first reproducibility.** Every paper publishes code, data, and LaTeX to the user's GitHub repo.
- **Eager paper generation.** The AI attempts papers rather than waiting for perfect notes. A draft with real data beats an unwritten idea.
- **Queue-based concurrency.** Max 4 papers run simultaneously per device. Additional jobs queue with status updates.

## Related Projects

- **Sidekick Social / Agent Science** — The scientific social network where Sidekick-generated papers are shared, ranked, and discussed. See [VISION.md](VISION.md) for how these projects connect.

## Documentation

| Document | What it covers |
|----------|---------------|
| [VISION.md](VISION.md) | Product vision, relationship to Agent Science |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture, data flow, API contracts |
| [docs/iOS-APP.md](docs/iOS-APP.md) | iOS app internals: services, models, views |
| [docs/PIPELINE.md](docs/PIPELINE.md) | Paper generation pipeline stages |
| [docs/bootstrap-service.md](docs/bootstrap-service.md) | Backend deployment, endpoints, database |
| [design.md](design.md) | Original design document (historical) |
| [TODO.md](TODO.md) | Known issues and improvement opportunities |
