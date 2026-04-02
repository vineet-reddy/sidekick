# Sidekick Backend

The backend server handles device sessions, GitHub OAuth, hosted paper generation jobs, and GitHub publication. It exists because the iPhone app should not hold the GitHub OAuth client secret or the OpenAI API key.

## What It Does

1. **Device sessions** — Anonymous registration for each phone. Returns a session token used for all subsequent API calls.
2. **GitHub OAuth** — Initiates and completes the OAuth flow so the user's GitHub access token is stored server-side (encrypted), never on the phone.
3. **Paper jobs** — Receives note clusters from the app, runs the 5-stage pipeline via OpenAI, and returns artifacts.
4. **GitHub publication** — Creates/ensures the user's `sidekick` repo, commits papers with all artifacts (LaTeX, PDF, figures, tables, code, references).

## Architecture

```
github_bootstrap_service/
├── bootstrap_service/
│   ├── server.py            # HTTP server, endpoint routing, job thread pool
│   ├── config.py            # Model names, token costs, limits, timeouts
│   ├── database.py          # SQLite schema + CRUD operations
│   ├── pipeline_engine.py   # 5-stage paper generation pipeline
│   ├── pipeline_runtime.py  # Run state, event logs, call tracking
│   ├── openai_client.py     # OpenAI Responses API client
│   ├── github_client.py     # GitHub API: OAuth, repos, commits
│   ├── manuscript.py        # LaTeX assembly + PDF compilation (Tectonic)
│   ├── resolver.py          # Paper mode classification, dataset matching
│   ├── store.py             # Bootstrap session state machine
│   ├── crypto.py            # Token encryption (XOR-stream + SHA256)
│   └── resources/
│       ├── paper_modes.json     # 5 paper types
│       └── source_families.json # 10 trusted data source families
├── tests/                   # pytest suite (~3700 lines, 13 test files)
├── Dockerfile               # Python 3.12-slim + texlive
├── .env.example
└── requirements.txt         # stdlib only (no pip dependencies)
```

## Deployment

### Render (Production)

The repo includes `render.yaml` for [Render](https://render.com) deployment. Auto-deploys on push to `main` when files under `github_bootstrap_service/` or `render.yaml` change.

**GitHub Actions workflow:** `.github/workflows/render-backend-deploy.yml`
- Triggers Render deploy via API
- Polls until deploy is live (20 min timeout)
- Service ID: `srv-d70bar1r0fns73co8f9g`

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `GITHUB_CLIENT_ID` | GitHub OAuth app client ID |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth app client secret |
| `OPENAI_API_KEY` | OpenAI API key (needs Responses API access) |
| `SIDEKICK_ENCRYPTION_SECRET` | Secret for encrypting GitHub tokens at rest |
| `SIDEKICK_BACKEND_BASE_URL` | Public URL of this service (used for OAuth callback URL construction) |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIDEKICK_OPENAI_MODEL` | `gpt-5.4` | Model for paper generation pipeline |
| `SIDEKICK_BACKEND_MAX_JOB_RUNTIME_SECONDS` | `3600` | Max seconds a pipeline job can run |
| `SIDEKICK_BACKEND_MAX_DAILY_SPEND_USD` | `100` | Daily spend cap (pauses new jobs) |
| `PORT` | `8787` | HTTP server port |

### GitHub OAuth App Settings

Create a GitHub OAuth App with callback URL:

```
https://<your-render-service>.onrender.com/browser/github-connect/callback
```

### iPhone App Configuration

Set the backend URL in the app:

- **Development (simulator):** Set `SIDEKICK_BACKEND_BASE_URL` environment variable in the Xcode scheme
- **Release builds:** Set `SidekickGitHubBootstrapBaseURL` in `Info.plist`

## API Endpoints

### Health

```
GET /health
→ 200 {"status": "ok"}
```

### Device Sessions

```
POST /api/device/session
Body: {"device_id": "<UUID>"}
→ 200 {"install_session_id": "<UUID>", "session_token": "<token>"}
```

Creates a new device session or resumes an existing one. The session token is used as a Bearer token for all subsequent requests.

### GitHub Connection

```
POST /api/github/connect/start
Headers: Authorization: Bearer <session_token>
→ 200 {"session_id": "<UUID>", "browser_url": "<OAuth URL>"}
```

The app opens `browser_url` in Safari. User authorizes, GitHub redirects to the callback, backend exchanges code for token, creates/ensures the user's `sidekick` repo.

```
GET /api/github/connect/sessions/<session_id>
Headers: Authorization: Bearer <session_token>
→ 200 {"status": "completed", "connection": {...}, "export_context": {
    "github_login": "user",
    "repo_owner": "user",
    "repo_name": "sidekick",
    "repo_full_name": "user/sidekick",
    "repo_url": "https://github.com/user/sidekick",
    "visibility": "public"
  }}
```

The app polls this endpoint until the connection completes.

### Note Assessment

```
POST /api/notes/assess
Headers: Authorization: Bearer <session_token>
Body: {"notes": [{"id": "<UUID>", "text": "note content"}]}
→ 200 {"clusters": [
    {
      "note_ids": ["<UUID>", ...],
      "theme": "circadian rhythms",
      "suggested_title": "Circadian Clock Metrics from GEO",
      "is_ready": true,
      "dataset_ids": ["geo_functional_genomics"],
      "readiness_mode": "trusted_ready"
    }
  ]}
```

### Paper Jobs

```
POST /api/papers
Headers: Authorization: Bearer <session_token>
Body: {
  "notes": [{"id": "<UUID>", "text": "..."}],
  "title": "Paper Title",
  "theme": "research theme",
  "dataset_ids": ["geo_functional_genomics"]
}
→ 200 {"job_id": "<UUID>"}
```

```
GET /api/papers/<job_id>
Headers: Authorization: Bearer <session_token>
→ 200 {
    "status": "running",        // queued | running | completed | failed
    "stage": "analyze",         // search | workspace | artifacts | manuscript | publish
    "progress_message": "Running statistical analysis..."
  }
```

```
GET /api/papers/<job_id>/artifacts
Headers: Authorization: Bearer <session_token>
→ 200 {
    "markdown": "# Paper Title\n...",
    "figures": [{"name": "fig-1.png", "data": "<base64>"}],
    "export_metadata": {
      "repo_url": "https://github.com/user/sidekick",
      "commit_sha": "abc123",
      "repo_path": "papers/20260402-circadian-metrics-abc123/"
    }
  }
```

## Database Schema

SQLite database at `.sidekick-runtime/backend.sqlite3` (local dev) or in-memory/persistent depending on deploy.

### `install_sessions`

| Column | Type | Description |
|--------|------|-------------|
| `install_session_id` | TEXT PK | UUID |
| `device_id` | TEXT UNIQUE | Device UUID from phone |
| `session_token` | TEXT | Bearer token for auth |
| `created_at` | TEXT | ISO8601 |
| `updated_at` | TEXT | ISO8601 |

### `github_connect_sessions`

| Column | Type | Description |
|--------|------|-------------|
| `session_id` | TEXT PK | UUID |
| `install_session_id` | TEXT FK | Links to device |
| `state` | TEXT | OAuth state parameter |
| `status` | TEXT | created/pending/completed/failed |
| `created_at` | TEXT | ISO8601, expires after 3600s |

### `github_connections`

| Column | Type | Description |
|--------|------|-------------|
| `install_session_id` | TEXT PK | Links to device |
| `encrypted_access_token` | TEXT | XOR-encrypted GitHub token |
| `github_login` | TEXT | GitHub username |
| `github_account_id` | TEXT | GitHub user ID |
| `repo_owner` | TEXT | Repo owner (usually same as login) |
| `repo_name` | TEXT | Always "sidekick" |
| `repo_visibility` | TEXT | "public" or "private" |

### `paper_jobs`

| Column | Type | Description |
|--------|------|-------------|
| `job_id` | TEXT PK | UUID |
| `install_session_id` | TEXT FK | Links to device |
| `status` | TEXT | queued/running/completed/failed |
| `current_stage` | TEXT | Pipeline stage name |
| `progress_message` | TEXT | Human-readable status |
| `notes_json` | TEXT | JSON array of input notes |
| `title` | TEXT | Paper title |
| `theme` | TEXT | Research theme |
| `dataset_ids_json` | TEXT | JSON array of dataset IDs |
| `result_json` | TEXT | Completed artifact bundle |
| `error_message` | TEXT | Failure reason |
| `created_at` | TEXT | ISO8601 |
| `started_at` | TEXT | ISO8601 |
| `completed_at` | TEXT | ISO8601 |

### `paper_job_metrics`

| Column | Type | Description |
|--------|------|-------------|
| `job_id` | TEXT PK FK | Links to paper_jobs |
| `input_tokens` | INTEGER | Total input tokens used |
| `output_tokens` | INTEGER | Total output tokens used |
| `estimated_cost_usd` | REAL | Estimated cost |

## Local Development

```bash
cd /path/to/sidekick
cp github_bootstrap_service/.env.example github_bootstrap_service/.env
# Edit .env with your credentials

export $(grep -v '^#' github_bootstrap_service/.env | xargs)
export OPENAI_API_KEY=sk-...
export SIDEKICK_ENCRYPTION_SECRET=dev-secret

./scripts/run_github_bootstrap_service.sh
# Server starts on http://localhost:8787
```

### Running Tests

```bash
python -m pytest github_bootstrap_service/tests/ -v
```

Tests are self-contained and don't require environment variables or external services. They mock the OpenAI and GitHub APIs.

## Operational Notes

- **No pip dependencies.** The entire backend uses Python stdlib only. This keeps deploys fast and the attack surface small.
- **Encryption.** GitHub access tokens are encrypted with a XOR-stream cipher (SHA256-based keystream) before storage. The `SIDEKICK_ENCRYPTION_SECRET` is the key.
- **Concurrency.** Pipeline jobs run in a thread pool. Max 4 concurrent jobs per install session.
- **Cost tracking.** Each job's token usage is recorded in `paper_job_metrics`. The daily spend cap is checked before starting new jobs.
- **Artifact TTL.** Completed job artifacts are available for 24 hours, then eligible for cleanup.
- **PDF compilation.** The Dockerfile includes `texlive` packages. Tectonic v0.15.0 is used for LaTeX-to-PDF compilation.
