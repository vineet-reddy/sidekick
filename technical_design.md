# Sidekick — Technical Design

See `design.md` for product vision.

---

## Project Structure

```
Sidekick/
├── SidekickApp.swift               # Entry point
├── ContentView.swift                # Tab bar (Notes / Papers / Settings)
├── Models.swift                     # Note + Paper SwiftData models
├── AuthService.swift                # ChatGPT OAuth PKCE
├── OpenAIService.swift              # Clustering + Codex tasks + polling
├── Theme.swift                      # Liquid glass styling
├── Views/
│   ├── NoteListView.swift
│   ├── NoteEditorView.swift
│   ├── PaperListView.swift
│   ├── PaperDetailView.swift
│   └── SettingsView.swift
└── Assets.xcassets
```

No relay server. No backend. The phone talks directly to OpenAI.

---

## Data Models

```swift
@Model
class Note {
    var id: UUID = UUID()
    var content: String = ""
    var createdAt: Date = .now
}

@Model
class Paper {
    var id: UUID = UUID()
    var title: String = ""
    var markdown: String = ""        // full paper body with inline figure refs
    var figureData: [Data] = []      // PNGs, ordered by index
    var status: String = "generating" // "generating" | "ready" | "failed"
    var codexTaskID: String = ""
    var sourceNoteIDs: [UUID] = []
    var createdAt: Date = .now
}
```

Two models. No relationships. Figures are just a `[Data]` on Paper.

---

## Auth — ChatGPT OAuth PKCE

```swift
class AuthService: ObservableObject {
    @Published var isAuthenticated = false

    private let clientID = "sidekick-ios"
    private let redirectURI = "sidekick://oauth/callback"

    // Keychain-backed
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    func signIn() async throws
    func signOut()
    func validToken() async throws -> String   // refreshes if expired
}
```

**Flow:**
1. Generate `code_verifier` + `code_challenge` (SHA256 + base64url)
2. Open `ASWebAuthenticationSession` → OpenAI auth page
3. User logs in → callback with auth code
4. Exchange code for tokens → store in Keychain
5. `validToken()` auto-refreshes when expired

Standard OAuth PKCE. Follows the OpenClaw pattern exactly.

---

## OpenAIService

One service handles everything AI. Two methods that matter.

```swift
class OpenAIService {
    private let auth: AuthService

    /// Lightweight call — sends notes to the Responses API, gets back clusters + readiness
    func assessNotes(_ notes: [Note]) async throws -> [NoteCluster]

    /// Heavyweight call — submits Codex cloud task, returns task ID
    func submitPaperTask(notes: [Note], title: String, theme: String) async throws -> String

    /// Polls a running Codex task, returns nil if still running
    func checkTask(_ taskID: String) async throws -> PaperArtifacts?
}

struct NoteCluster: Codable {
    let noteIDs: [UUID]
    let theme: String
    let suggestedTitle: String
    let isReady: Bool
}

struct PaperArtifacts {
    let markdown: String
    let figures: [Data]    // PNGs
}
```

### assessNotes — Clustering Prompt

Sent through the Codex-backed Responses API, but routed to the latest lightweight GPT-5-family model first. If that alias is not available on the user's ChatGPT-backed Codex surface yet, the app falls back automatically to the next recommended GPT-5 model.

```
You are a research assistant. Group these notes into thematic clusters.
A cluster is "ready" for a paper when it has a testable hypothesis and
relevant open datasets exist. Be eager — a rough paper beats no paper.

Return JSON: { "clusters": [{ "noteIDs": [...], "theme": "...",
"suggestedTitle": "...", "isReady": true/false }] }

Notes:
{{notes as JSON}}
```

### submitPaperTask — Paper Generation Prompt

Sent to a Codex cloud task. The app prefers the latest rolling Codex model alias for long-running sandboxed work and falls back automatically to older Codex snapshots if the backend has not caught up yet. This keeps the app on the newest Codex model without hard-failing when model availability lags.

```
You are a research scientist. Write a complete academic paper.
You have Python with internet access.

1. Read the notes below
2. Find and download relevant data from open sources:
   Semantic Scholar, OpenAlex, PubMed, arXiv, Zenodo, data.gov, WHO, World Bank, etc.
3. Prefer API queries for focused subsets — don't bulk-download large datasets.
   Sample if needed. Use summary endpoints when available.
4. Run real analysis (pandas, scipy, statsmodels, sklearn)
5. Generate figures (matplotlib/seaborn, save as PNG)
6. Write the paper in Markdown

Structure: Title, Abstract, Introduction, Related Work, Methods, Results,
Discussion, Conclusion, References.

Reference figures as ![Figure N: caption](figure_N.png)

Save to /output/: paper.md, figure_1.png, figure_2.png, ..., analysis.py

Notes:
{{cluster notes}}

Title: {{suggestedTitle}}
Theme: {{theme}}
```

---

## Heartbeat

Two triggers, same logic. No server. No cron.

### Trigger 1: App Open

Runs every time the user opens the app (with cooldown to avoid redundant calls).

### Trigger 2: iOS Background App Refresh

iOS wakes the app periodically in the background (~every few hours, iOS decides based on user habits). We get ~30 seconds — plenty to poll Codex and fire a notification. Zero battery impact — iOS manages scheduling. This is how the user gets a surprise "paper ready" notification without the app being open.

```swift
// SidekickApp.swift — registration
func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.sidekick.heartbeat",
        using: nil
    ) { task in
        self.handleHeartbeat(task: task as! BGAppRefreshTask)
    }
}

// Schedule next heartbeat (call on app launch + after each heartbeat)
func scheduleHeartbeat() {
    let request = BGAppRefreshTaskRequest(identifier: "com.sidekick.heartbeat")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
    try? BGTaskScheduler.shared.submit(request)
}
```

### Heartbeat Logic (shared by both triggers)

```swift
func runHeartbeat() async {
    // 1. Check any in-progress papers
    for paper in generatingPapers {
        if let artifacts = try? await openAI.checkTask(paper.codexTaskID) {
            paper.markdown = artifacts.markdown
            paper.figureData = artifacts.figures
            paper.status = "ready"
            notifyUser(paper: paper)
        }
    }

    // 2. Assess notes for new papers
    let clusters = try? await openAI.assessNotes(allNotes)
    for cluster in (clusters ?? []) where cluster.isReady {
        let notes = allNotes.filter { cluster.noteIDs.contains($0.id) }
        if let taskID = try? await openAI.submitPaperTask(
            notes: notes, title: cluster.suggestedTitle, theme: cluster.theme
        ) {
            let paper = Paper()
            paper.title = cluster.suggestedTitle
            paper.codexTaskID = taskID
            paper.sourceNoteIDs = cluster.noteIDs
            modelContext.insert(paper)
        }
    }

    scheduleHeartbeat() // re-schedule next background run
}
```

That's the entire backend logic. It lives in the app.

---

## Paper Display

`PaperDetailView` renders markdown + inline figures using `WKWebView` with a clean academic CSS. One web view, one HTML string assembled from `paper.markdown` with figure data URIs injected.

```swift
func paperHTML(paper: Paper) -> String {
    var html = markdownToHTML(paper.markdown)
    for (i, data) in paper.figureData.enumerated() {
        let base64 = data.base64EncodedString()
        html = html.replacingOccurrences(
            of: "figure_\(i + 1).png",
            with: "data:image/png;base64,\(base64)"
        )
    }
    return wrapInAcademicCSS(html)
}
```

### Export

**PDF:** `WKWebView.createPDF()` from the rendered HTML. One function call.

**LaTeX:** Simple string replacement on the markdown. The Codex output is well-structured so this is mechanical:
- `# Title` → `\title{Title}`
- `## Section` → `\section{Section}`
- `![caption](fig)` → `\begin{figure}...\end{figure}`
- `**bold**` → `\textbf{bold}`

---

## Voice Input

Use `SFSpeechRecognizer` in `NoteEditorView`. Tap mic → dictate → text appears. iOS handles everything. No external service.

---

## Notifications

Local only. No APNs. No server.

Fired by the heartbeat (foreground or background) when a Codex task completes:

```swift
func notifyUser(paper: Paper) {
    let content = UNMutableNotificationContent()
    content.title = "New Paper"
    content.body = "\"\(paper.title)\" is ready to read"
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: paper.id.uuidString, content: content, trigger: nil)
    )
}
```

Works in background (via Background App Refresh) and foreground. The user gets a surprise notification when a paper is ready — no need to open the app to check.

---

## What's NOT Here

- No relay server
- No backend
- No database besides on-device SwiftData
- No push notification infrastructure
- No user registration system
- No note syncing
- No microservices
- No Docker

The phone talks to OpenAI. That's the entire architecture.

---

## Build Order

1. **App shell** — Xcode project, SwiftData models, tab bar, NoteListView + NoteEditorView with CRUD
2. **Auth** — AuthService, OAuth PKCE, SettingsView sign-in/out
3. **Heartbeat + clustering** — OpenAIService.assessNotes, heartbeat on app open + Background App Refresh
4. **Paper generation** — OpenAIService.submitPaperTask + checkTask, polling, Paper creation
5. **Paper display** — PaperDetailView with WKWebView rendering, PaperListView
6. **Export** — PDF + LaTeX from rendered paper
7. **Voice** — SFSpeechRecognizer in NoteEditorView
8. **Polish** — Liquid glass, animations, haptics, app icon
