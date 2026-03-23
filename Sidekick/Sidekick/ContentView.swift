import SwiftData
import SwiftUI

private enum AppTab: Hashable {
    case notes
    case papers
    case settings
}

enum QAFlags {
    private static var arguments: [String] {
        ProcessInfo.processInfo.arguments
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var shouldOpenLatestPaper: Bool {
        if arguments.contains("--qa-open-latest-paper") {
            return true
        }

        return environment["SIDEKICK_QA_OPEN_LATEST_PAPER"] == "1"
    }

    static var shouldForceHeartbeatOnLaunch: Bool {
        if arguments.contains("--qa-force-heartbeat") {
            return true
        }

        return environment["SIDEKICK_QA_FORCE_HEARTBEAT"] == "1"
    }

    static var shouldAutoShareLatestPaper: Bool {
        if arguments.contains("--qa-auto-share-latest-paper") {
            return true
        }

        return environment["SIDEKICK_QA_AUTO_SHARE_LATEST_PAPER"] == "1"
    }

    static var shouldResetContentOnLaunch: Bool {
        if arguments.contains("--qa-reset-content") {
            return true
        }

        return environment["SIDEKICK_QA_RESET_CONTENT"] == "1"
    }

    static var seedNotes: [String] {
        var seeded: [String] = []

        if let filePath = environment["SIDEKICK_QA_SEED_NOTES_FILE"],
           let fileContents = decodeSeedNotesFile(at: filePath) {
            seeded.append(contentsOf: fileContents)
        }

        if let rawJSON = environment["SIDEKICK_QA_SEED_NOTES_JSON"],
           let jsonContents = decodeSeedNotesJSON(rawJSON) {
            seeded.append(contentsOf: jsonContents)
        }

        if let legacySingleNote = legacySeedNoteContent {
            seeded.append(legacySingleNote)
        }

        var uniqueNotes: [String] = []
        var seen = Set<String>()

        for note in seeded {
            let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }

            uniqueNotes.append(note)
        }

        return uniqueNotes
    }

    private static var legacySeedNoteContent: String? {
        guard let raw = environment["SIDEKICK_QA_SEED_NOTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        return raw
    }

    private static func decodeSeedNotesFile(at path: String) -> [String]? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmedPath)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        return decodeSeedNotesJSON(raw)
    }

    private static func decodeSeedNotesJSON(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let strings = json as? [String] {
            return strings
        }

        if let wrapped = json as? [String: Any],
           let notes = wrapped["notes"] {
            return decodeSeedNotesPayload(notes)
        }

        return decodeSeedNotesPayload(json)
    }

    private static func decodeSeedNotesPayload(_ payload: Any) -> [String]? {
        if let strings = payload as? [String] {
            return strings
        }

        if let noteObjects = payload as? [[String: Any]] {
            let notes = noteObjects.compactMap { object in
                object["content"] as? String
            }
            return notes.isEmpty ? nil : notes
        }

        return nil
    }
}

struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Paper.updatedAt, order: .reverse) private var papers: [Paper]
    @Query(sort: \ResearchRun.updatedAt, order: .reverse) private var runs: [ResearchRun]

    @EnvironmentObject private var github: GitHubService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService

    private let foregroundHeartbeatInterval: Duration = .seconds(30)

    var body: some View {
        ContentView()
            .task {
                Task {
                    await notifications.requestAuthorization()
                }
                _ = try? await github.ensureDeviceSession()
                heartbeat.scheduleBackgroundRefresh()
                resetQAContentIfNeeded(modelContext: modelContext)
                seedQANotesIfNeeded(modelContext: modelContext)
                Task {
                    await preloadRecentReadyPapers(modelContext: modelContext)
                }
                if QAFlags.shouldForceHeartbeatOnLaunch || inFlightPaperCount > 0 || heldRunCount > 0 {
                    await heartbeat.run(modelContext: modelContext, force: true)
                } else {
                    await heartbeat.runIfNeeded(modelContext: modelContext)
                }
                BackgroundHeartbeatScheduler.shared.runner = {
                    await preloadRecentReadyPapers(modelContext: modelContext)
                    await heartbeat.run(modelContext: modelContext, force: true)
                    await preloadRecentReadyPapers(modelContext: modelContext)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    return
                }

                Task {
                    _ = try? await github.refreshConnectionSessionIfNeeded()
                    if inFlightPaperCount > 0 || heldRunCount > 0 {
                        await heartbeat.run(modelContext: modelContext, force: true)
                    } else {
                        await heartbeat.runIfNeeded(modelContext: modelContext)
                    }
                }
            }
            .task(id: foregroundHeartbeatTaskKey) {
                await runForegroundHeartbeatLoopIfNeeded(modelContext: modelContext)
            }
            .task(id: githubPollTaskKey) {
                await runGitHubPollLoopIfNeeded(modelContext: modelContext)
            }
    }

    private var inFlightPaperCount: Int {
        runs.filter { $0.status == .running }.count
    }

    private var heldRunCount: Int {
        runs.filter {
            $0.status == .queued && $0.queueState == .held && $0.schedulingDisposition == .hold
        }.count
    }

    private var foregroundHeartbeatTaskKey: String {
        "\(scenePhase == .active)-\(inFlightPaperCount)"
    }

    private var githubPollTaskKey: String {
        "\(scenePhase == .active)-\(github.activeConnectSession?.sessionID ?? "none")-\(github.activeConnectSession?.status ?? "none")"
    }

    private func resetQAContentIfNeeded(modelContext: ModelContext) {
        guard QAFlags.shouldResetContentOnLaunch else {
            return
        }

        do {
            let papers = try modelContext.fetch(FetchDescriptor<Paper>())
            let runs = try modelContext.fetch(FetchDescriptor<ResearchRun>())
            let notes = try modelContext.fetch(FetchDescriptor<Note>())

            for paper in papers {
                modelContext.delete(paper)
            }

            for run in runs {
                modelContext.delete(run)
            }

            for note in notes {
                modelContext.delete(note)
            }

            try modelContext.save()
            purgeTransientQAStorage()
        } catch {
            print("[QA] Failed to purge content: \(error.localizedDescription)")
        }
    }

    private func seedQANotesIfNeeded(modelContext: ModelContext) {
        let notesToSeed = QAFlags.seedNotes
        guard !notesToSeed.isEmpty else {
            return
        }

        do {
            let existingNotes = try modelContext.fetch(FetchDescriptor<Note>())
            var seenContents = Set(
                existingNotes.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            )

            for (index, content) in notesToSeed.enumerated() {
                let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seenContents.insert(normalized).inserted else {
                    continue
                }

                let timestamp = Date().addingTimeInterval(TimeInterval(index))
                let note = Note(content: content, createdAt: timestamp, updatedAt: timestamp)
                modelContext.insert(note)
            }

            try modelContext.save()
        } catch {
            print("[QA] Failed to seed notes: \(error.localizedDescription)")
        }
    }

    private func preloadRecentReadyPapers(modelContext: ModelContext) async {
        do {
            let papers = try modelContext.fetch(
                FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            )
                .filter { $0.status == .ready }

            for paper in papers.prefix(3) {
                await PaperDocumentService.precomputeIfNeeded(for: paper)
            }
        } catch {
            print("[PaperDocs] preload failed: \(error.localizedDescription)")
        }
    }

    private func runForegroundHeartbeatLoopIfNeeded(modelContext: ModelContext) async {
        guard scenePhase == .active, inFlightPaperCount > 0 else {
            return
        }

        while !Task.isCancelled, scenePhase == .active, inFlightPaperCount > 0 {
            try? await Task.sleep(for: foregroundHeartbeatInterval)
            guard !Task.isCancelled, scenePhase == .active, inFlightPaperCount > 0 else {
                break
            }

            await heartbeat.run(modelContext: modelContext, force: true)
        }
    }

    private func runGitHubPollLoopIfNeeded(modelContext: ModelContext) async {
        guard scenePhase == .active,
              let activeConnectSession = github.activeConnectSession,
              !activeConnectSession.isTerminal else {
            return
        }

        while !Task.isCancelled,
              scenePhase == .active,
              let currentSession = github.activeConnectSession,
              !currentSession.isTerminal {
            do {
                let refreshed = try await github.refreshConnectionSessionIfNeeded()
                if refreshed?.connection != nil {
                    await heartbeat.run(modelContext: modelContext, force: true)
                }
            } catch {
                break
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func purgeTransientQAStorage() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        let paperArtifactsDirectory = applicationSupport?
            .appendingPathComponent("PaperArtifacts", isDirectory: true)
        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SidekickExports", isDirectory: true)

        if let paperArtifactsDirectory {
            try? fileManager.removeItem(at: paperArtifactsDirectory)
        }

        try? fileManager.removeItem(at: exportDirectory)
    }
}

struct ContentView: View {
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var github: GitHubService
    @State private var selectedTab: AppTab = QAFlags.shouldOpenLatestPaper ? .papers : .notes

    var body: some View {
        Group {
            if github.isConnected {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        NoteListView()
                    }
                    .tag(AppTab.notes)
                    .tabItem {
                        Label("Notes", systemImage: "square.and.pencil")
                            .accessibilityIdentifier("tab.notes")
                    }
                    .accessibilityIdentifier("tab.notes")

                    PaperListView()
                        .tag(AppTab.papers)
                        .tabItem {
                            Label("Papers", systemImage: "doc.text.magnifyingglass")
                                .accessibilityIdentifier("tab.papers")
                        }
                        .accessibilityIdentifier("tab.papers")

                    NavigationStack {
                        SettingsView()
                    }
                    .tag(AppTab.settings)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                            .accessibilityIdentifier("tab.settings")
                    }
                    .accessibilityIdentifier("tab.settings")
                }
                .accessibilityIdentifier("app.tabView")
                .overlay(alignment: .bottom) {
                    statusDot
                }
            } else {
                GitHubRequiredView()
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if heartbeat.phase != .idle {
            HStack(spacing: 6) {
                if heartbeat.isRunning {
                    Circle()
                        .fill(SidekickTheme.accent)
                        .frame(width: 6, height: 6)
                        .modifier(PulseModifier())
                }

                Text(heartbeat.phase.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.3), value: heartbeat.phase)
            .offset(y: -58)
            .allowsHitTesting(false)
        }
    }
}

private struct GitHubRequiredView: View {
    @EnvironmentObject private var github: GitHubService

    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var connectTarget: GitHubConnectBrowserTarget?

    var body: some View {
        ZStack {
            SidekickBackground()

            VStack(alignment: .leading, spacing: 18) {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect GitHub To Use Sidekick")
                        .font(.title2.weight(.semibold))

                    Text("GitHub is required before the app unlocks. Sidekick publishes every paper as LaTeX, code, manifests, and figures into a public repo in your GitHub account.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    if let activeSession = github.activeConnectSession,
                       !activeSession.isTerminal {
                        Text("Waiting for GitHub authorization to finish.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        connectGitHub()
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(github.activeConnectSession?.isTerminal == false ? "Continue In GitHub" : "Connect GitHub")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting)
                    .accessibilityIdentifier("github.required.connectButton")

                    if let connectError, !connectError.isEmpty {
                        Text(connectError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let backendError = github.connectionErrorMessage, !backendError.isEmpty {
                        Text(backendError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 24)

                Spacer()
            }
            .padding(20)
        }
        .accessibilityIdentifier("github.required.view")
        .sheet(item: $connectTarget) { target in
            SafariBrowserView(url: target.url)
        }
    }

    private func connectGitHub() {
        connectError = nil
        isConnecting = true

        Task {
            do {
                let url = try await github.beginGitHubConnection()
                await MainActor.run {
                    isConnecting = false
                    if !github.isConnected {
                        connectTarget = GitHubConnectBrowserTarget(url: url)
                    }
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectError = error.localizedDescription
                }
            }
        }
    }
}

private struct GitHubConnectBrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
}

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.4 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
