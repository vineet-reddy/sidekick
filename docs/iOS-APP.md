# iOS App Developer Guide

## Overview

The Sidekick iOS app is a SwiftUI application targeting iOS 17+. It's a thin client: users write notes, the app sends them to the backend for paper generation, and displays the results. All heavy computation happens server-side.

**Xcode project:** `Sidekick/Sidekick.xcodeproj`

## App Entry Point

`SidekickApp.swift` initializes the SwiftData model container and all service objects:

```
@main struct SidekickApp: App
├── ModelContainer: Note, Paper, ResearchRun
├── @StateObject GitHubService
├── @StateObject OpenAIService
├── @StateObject HeartbeatManager
├── @StateObject NotificationService
└── Body: AppShellView
    ├── Initializes device session on appear
    ├── Registers background refresh task
    ├── Runs foreground heartbeat loop while papers are generating
    └── Contains: ContentView
```

## View Hierarchy

```
ContentView (TabView)
├── Tab 1: Notes
│   └── NoteListView
│       ├── Search bar
│       ├── Inline composer (text field + send button)
│       ├── LazyVStack of note cards
│       │   └── Context menu: Edit, Delete, Prioritize
│       └── Sheet: NoteEditorView (edit/delete individual note)
│
├── Tab 2: Papers
│   └── PaperListView
│       └── NavigationStack
│           ├── Paper cards (title, status pill, progress message)
│           └── NavigationDestination: PaperDetailView
│               ├── Progress card (if .generating/.failed)
│               │   └── Pipeline stage indicators
│               ├── PDF viewer (if .ready)
│               └── Toolbar menu: Open on GitHub, Share PDF, Share LaTeX
│
└── Tab 3: Settings
    └── SettingsView
        ├── GitHub Publishing (connect/reconnect button)
        ├── Execution info
        ├── Usage guardrails
        └── Last sync error display
```

## Data Models (SwiftData)

### Note

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Primary key |
| `content` | `String` | Raw note text |
| `createdAt` | `Date` | Creation timestamp |
| `updatedAt` | `Date` | Last edit timestamp |
| `priorityRequestedAt` | `Date?` | Set when user long-presses "Prioritize" |

Computed: `title` (first non-empty line), `summary` (first 140 chars).

### Paper

| Property | Type | Description |
|----------|------|-------------|
| `id` | `UUID` | Primary key |
| `title` | `String` | Paper title |
| `markdown` | `String` | Full paper content in Markdown |
| `status` | `PaperStatus` | `.generating` / `.ready` / `.failed` |
| `codexTaskID` | `String?` | Backend job ID for polling |
| `sourceNoteIDsJSON` | `String?` | JSON-encoded `[UUID]` |
| `figureDataJSON` | `String?` | JSON-encoded `[{name, base64}]` |
| `createdAt` | `Date` | Creation timestamp |
| `progressMessage` | `String?` | Human-readable status text |

### ResearchRun

| Property | Type | Description |
|----------|------|-------------|
| `runID` | `UUID` | Primary key |
| `paperID` | `UUID` | Links to Paper |
| `currentStage` | `ResearchStage` | `.plan` / `.inspect` / `.analyze` / `.verify` / `.write` / `.typeset` |
| `status` | `RunStatus` | `.queued` / `.running` / `.completed` / `.failed` |
| `queueState` | `QueueState` | `.queued` / `.held` / `.waitingForCurrentPaper` / `.nextInLine` |
| `schedulingDisposition` | `SchedulingDisposition` | `.autoStart` / `.hold` |
| `sourceNoteIDsJSON` | `String?` | JSON-encoded note IDs |
| `datasetIDsJSON` | `String?` | JSON-encoded dataset IDs |
| `allowedDomainsJSON` | `String?` | JSON-encoded allowed domains |
| `registryVersion` | `Int` | Dataset registry version at creation time |
| `stageAttemptsJSON` | `String?` | JSON-encoded retry counts per stage |

## Services

### HeartbeatManager

**The orchestrator.** Drives the entire note-to-paper lifecycle.

**Runs when:**
- App comes to foreground (forced)
- App opens (forced)
- User taps sync button (forced)
- User prioritizes a note (forced)
- New note created (30-second delay)
- Background app refresh (~4 hours)

**Heartbeat phases:**
1. `resolveInFlightPapers()` — Poll backend for status of all `.generating` papers
2. `reconsiderHeldResearchRunsIfNeeded()` — Unblock held runs when GitHub connects
3. `admitQueuedResearchRunsIfPossible()` — Start queued runs if slots available (max 4)
4. `discoverNewPaperCandidates()` — Assess notes, create new papers

**Cooldown:** 20 minutes between automatic runs. Force flag bypasses cooldown.

**Foreground loop:** While any paper has status `.generating`, polls every 30 seconds.

### OpenAIService

**Backend API client.** All HTTP communication with the Sidekick backend.

Key methods:
- `assessNotes([Note])` — POST to `/api/notes/assess`, returns `[NoteCluster]`
- `prepareResearchRun(notes, title, theme, datasetIDs)` — POST to `/api/papers`, returns job ID + scheduling info
- `submitPaperTask(notes, title, theme, datasetIDs)` — POST to `/api/papers`, returns job ID
- `checkTask(taskID)` — GET `/api/papers/{jobID}`, returns status/stage/progress
- `fetchArtifacts(taskID)` — GET `/api/papers/{jobID}/artifacts`, returns paper content

**Session management:** Automatically refreshes the session token via `GitHubService.ensureDeviceSession()` on 401 responses.

### GitHubService

**Device identity and GitHub OAuth.**

Key methods:
- `ensureDeviceSession()` — POST `/api/device/session` with a stable device UUID
- `beginGitHubConnection()` — POST `/api/github/connect/start`, opens browser for OAuth
- `refreshGitHubConnectionStatus(sessionID)` — Polls OAuth completion

**Persistence:** Device session (install ID, session token) stored in `UserDefaults` as JSON. Export context (repo URL, owner, name) also in `UserDefaults`.

**Backend URL:** Read from `SIDEKICK_BACKEND_BASE_URL` env var or `SidekickGitHubBootstrapBaseURL` in Info.plist. Cached; invalidates state if URL changes.

### TrustedDatasetRegistry

**Dataset catalog and smart selection.**

**Loading:** Bundled `trusted_datasets.json` (100+ entries) loaded on first access. Cached version in `ApplicationSupport` checked. Uses whichever has the higher `version` number. Remote refresh every 12 hours.

**Selection algorithm (`selectSource`):**
1. Filter to trusted, non-auth-required, non-disabled direct sources
2. Score each by semantic similarity to note text (keyword/domain overlap + fuzzy Levenshtein matching)
3. Boost by trust tier (official > curated > discovery) and support tier (supported > experimental)
4. Filter by minimum fit score (varies by support tier)
5. If no matches, try discovery catalogs
6. Return `TrustedSourceSelection` with datasets, support tier, and `isAutoStartEligible`

**Term expansion:** Maps semantic variants (e.g., "gbm" to "glioblastoma"). Filters common stopwords.

### PaperArtifactStore

**File-based persistence** in `~/Library/Application Support/PaperArtifacts/{taskID}/`.

Stores:
- Stage artifacts (plan, inspect, analyze, verify, draft) as JSON
- Export metadata (repo URL, commit SHA, repo path, published date)
- Submission tracking (pending submissions with attempt count)

### PaperDocumentService

**PDF rendering** via WKWebView.

Flow:
1. Check cache (keyed by content fingerprint: version + timestamp + title hash + markdown length + figure count/bytes)
2. Build HTML with `PaperHTMLBuilder` (paper-like styling with figures)
3. Try fetching manuscript from GitHub via `PublishedArtifactService`
4. Fall back to local HTML rendering
5. Render HTML to PDF via `WKWebView` + custom page layout (watermarks, page numbers)

Cache location: `~/Library/Application Support/PaperDocuments/`.

### NotificationService

Requests `UNUserNotificationCenter` authorization on first launch. Sends a local notification when a paper transitions to `.ready` status.

### ExportService

Static utilities for LaTeX and PDF export. Provides share-sheet-ready file URLs.

## Build & Run

### Requirements
- Xcode 16+
- iOS 17+ target
- Active backend (local or Render)

### Xcode Configuration

1. Open `Sidekick/Sidekick.xcodeproj`
2. Select the Sidekick scheme
3. Edit scheme > Run > Arguments > Environment Variables:
   - `SIDEKICK_BACKEND_BASE_URL` = `http://localhost:8787` (or your Render URL)
4. Cmd+R to run on simulator

### QA/Debug Environment Variables

These are checked at runtime for testing automation:

| Variable | Effect |
|----------|--------|
| `QA_SKIP_NOTIFICATION_PROMPT` | Skip notification permission dialog |
| `QA_OPEN_LATEST_PAPER` | Auto-navigate to most recent paper on launch |
| `QA_FORCE_HEARTBEAT` | Run heartbeat immediately on launch |
| `QA_SEED_NOTES` | Pre-populate sample notes |
| `QA_RESET_CONTENT` | Clear all data on launch |

These should eventually be guarded by `#if DEBUG`.

## Key Patterns

### Concurrency

- `HeartbeatManager` is a `@MainActor actor` — all state mutations happen on the main thread
- `TrustedDatasetRegistry` is a plain `actor` — thread-safe without main thread requirement
- `OpenAIService` and `GitHubService` are `ObservableObject`s with `@Published` properties
- Network calls use `async/await` with `URLSession`
- Background task registration uses `BGTaskScheduler`

### Data Encoding

- Note IDs and dataset IDs are stored as JSON strings in SwiftData (no array support in SwiftData)
- Figure data stored as JSON-encoded base64 strings
- All dates use ISO8601 encoding/decoding

### Error Handling

- `OpenAIService` throws typed errors (`OpenAIServiceError`)
- `HeartbeatManager` catches and logs errors, updates `lastSyncError` for display in Settings
- `PaperDocumentService` silently falls back on rendering errors (prints to console)
- Network requests have 12-second timeouts

## File Index

### Models
| File | Contents |
|------|----------|
| `Models.swift` | `Note`, `Paper` SwiftData models, `PaperStatus` enum |
| `Models/ResearchRun.swift` | `ResearchRun` model, `ResearchStage`, `RunStatus`, `QueueState`, `SchedulingDisposition` enums |

### Views
| File | Contents |
|------|----------|
| `ContentView.swift` | Tab bar with Notes/Papers/Settings tabs |
| `Views/NoteListView.swift` | Note list, search, inline composer, context menus |
| `Views/NoteEditorView.swift` | Modal note editor with delete option |
| `Views/PaperListView.swift` | Paper list sorted by status then date |
| `Views/PaperDetailView.swift` | PDF viewer, progress card, export menu |
| `Views/SettingsView.swift` | GitHub connection, app info, guardrails |

### Services
| File | Contents |
|------|----------|
| `Services/HeartbeatManager.swift` | Heartbeat orchestrator, note assessment, paper submission, queue management |
| `Services/OpenAIService.swift` | Backend HTTP client, session refresh, artifact decoding |
| `Services/GitHubService.swift` | Device sessions, GitHub OAuth, export context |
| `Services/TrustedDatasetRegistry.swift` | Dataset catalog, smart selection, term expansion |
| `Services/PaperArtifactStore.swift` | File-based artifact persistence |
| `Services/PaperDocumentService.swift` | PDF rendering via WKWebView |
| `Services/NotificationService.swift` | Local push notifications |
| `Services/ExportService.swift` | LaTeX/PDF export |
| `Services/PaperTaskProgress.swift` | Progress tracking types |
| `Services/ContentDeletionService.swift` | Cascade deletion of notes/papers/runs |
| `Services/PublishedArtifactService.swift` | Fetch manuscripts from GitHub raw content |
| `Services/LocalPaperGenerationService.swift` | Stub (unused) |
| `Services/AuthService.swift` | Dead code (old OpenAI OAuth, unused) |
| `Services/ResearchStageFallbackService.swift` | Edge-case dataset fallbacks |

### Support
| File | Contents |
|------|----------|
| `Support/MarkdownRenderer.swift` | Markdown to attributed string conversion |
| `Support/ShareSheet.swift` | UIActivityViewController wrapper |
| `Support/SafariBrowserView.swift` | SFSafariViewController wrapper |
| `Support/SidekickStateKeys.swift` | UserDefaults key constants |

### Resources
| File | Contents |
|------|----------|
| `Resources/trusted_datasets.json` | Bundled dataset catalog (100+ entries, version 3) |
