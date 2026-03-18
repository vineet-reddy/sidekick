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

    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var openAI: OpenAIService
    @State private var hasDismissedOAuthSetupSheet = false
    @State private var isShowingOAuthSetupBrowser = false

    private let foregroundHeartbeatInterval: Duration = .seconds(30)

    var body: some View {
        ContentView()
            .task {
                Task {
                    await notifications.requestAuthorization()
                }
                heartbeat.scheduleBackgroundRefresh()
                resetQAContentIfNeeded(modelContext: modelContext)
                seedQANotesIfNeeded(modelContext: modelContext)
                quarantineRetiredLocalExecutionIfNeeded(modelContext: modelContext)
                await openAI.runQACodexEnvironmentBootstrapProbeIfRequested()
                _ = await openAI.refreshOAuthExecutionSetupStateIfNeeded()
                Task {
                    await preloadRecentReadyPapers(modelContext: modelContext)
                }
                if QAFlags.shouldForceHeartbeatOnLaunch {
                    await heartbeat.run(modelContext: modelContext, force: true)
                } else if inFlightPaperCount > 0 || heldRunCount > 0 {
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
                    _ = await openAI.refreshOAuthExecutionSetupStateIfNeeded()
                    if inFlightPaperCount > 0 || heldRunCount > 0 {
                        await heartbeat.run(modelContext: modelContext, force: true)
                    } else {
                        await heartbeat.runIfNeeded(modelContext: modelContext)
                    }
                }
            }
            .onChange(of: openAI.oauthExecutionSetupMessage) { _, newValue in
                if newValue == nil {
                    hasDismissedOAuthSetupSheet = false
                }
            }
            .onChange(of: openAI.oauthExecutionSetupSheetRequestID) { _, _ in
                hasDismissedOAuthSetupSheet = false
            }
            .task(id: foregroundHeartbeatTaskKey) {
                await runForegroundHeartbeatLoopIfNeeded(modelContext: modelContext)
            }
            .task(id: oauthSetupMonitorTaskKey) {
                await runOAuthSetupMonitorLoopIfNeeded(modelContext: modelContext)
            }
            .sheet(isPresented: oauthSetupSheetBinding) {
                OAuthCloudSetupView(
                    snapshot: openAI.oauthExecutionSetup,
                    openCodexSetup: {
                        isShowingOAuthSetupBrowser = true
                    },
                    retrySetupCheck: {
                        Task {
                            _ = await openAI.refreshOAuthExecutionSetupStateIfNeeded()
                            if openAI.oauthExecutionSetupMessage == nil, heldRunCount > 0 {
                                await heartbeat.run(modelContext: modelContext, force: true)
                            }
                        }
                    },
                    dismiss: {
                        hasDismissedOAuthSetupSheet = true
                    }
                )
            }
            .sheet(isPresented: $isShowingOAuthSetupBrowser) {
                SafariBrowserView(url: URL(string: "https://chatgpt.com/codex/settings/environments")!)
            }
    }

    private var inFlightPaperCount: Int {
        let activePaperIDs = Set(
            runs.compactMap { run in
                (run.status == .running || run.isSchedulerEligible) ? run.paperID : nil
            }
        )
        let trackedRunPaperIDs = Set(runs.map(\.paperID))
        let untrackedGeneratingCount = papers.filter { paper in
            paper.status == .generating && !trackedRunPaperIDs.contains(paper.id)
        }.count

        return activePaperIDs.count + untrackedGeneratingCount
    }

    private var heldRunCount: Int {
        runs.filter {
            $0.status == .queued && $0.queueState == .held && $0.schedulingDisposition == .hold
        }.count
    }

    private var foregroundHeartbeatTaskKey: String {
        "\(scenePhase == .active)-\(inFlightPaperCount)"
    }

    private var oauthSetupMonitorTaskKey: String {
        let phase = openAI.oauthExecutionSetup.phase.rawValue
        let hasMessage = openAI.oauthExecutionSetupMessage != nil
        return "\(scenePhase == .active)-\(isShowingOAuthSetupBrowser)-\(hasMessage)-\(phase)"
    }

    private var oauthSetupSheetBinding: Binding<Bool> {
        Binding(
            get: {
                guard !openAI.hasUserAPIKeyOverride,
                      !openAI.oauthExecutionSetup.isReady,
                      let message = openAI.oauthExecutionSetupMessage,
                      !message.isEmpty else {
                    return false
                }

                return !hasDismissedOAuthSetupSheet
            },
            set: { isPresented in
                guard !isPresented else {
                    return
                }

                hasDismissedOAuthSetupSheet = true
            }
        )
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

            print("[QA] Purged \(notes.count) note(s), \(papers.count) paper(s), and \(runs.count) run(s)")
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
            var insertedCount = 0

            for (index, content) in notesToSeed.enumerated() {
                let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seenContents.insert(normalized).inserted else {
                    continue
                }

                let timestamp = Date().addingTimeInterval(TimeInterval(index))
                let note = Note(content: content, createdAt: timestamp, updatedAt: timestamp)
                modelContext.insert(note)
                insertedCount += 1
            }

            guard insertedCount > 0 else {
                return
            }

            try modelContext.save()
            print("[QA] Seeded \(insertedCount) note(s)")
        } catch {
            print("[QA] Failed to seed notes: \(error.localizedDescription)")
        }
    }

    private func quarantineRetiredLocalExecutionIfNeeded(modelContext: ModelContext) {
        do {
            let papers = try modelContext.fetch(FetchDescriptor<Paper>())
            let runs = try modelContext.fetch(FetchDescriptor<ResearchRun>())
            let localPapers = papers.filter { $0.codexTaskID.hasPrefix("local-") }
            let localRuns = runs.filter { $0.runID.hasPrefix("local-") }

            let retiredMessage = "This paper used a retired on-device validation path and must be regenerated."

            for paper in localPapers {
                paper.status = .failed
                paper.markdown = ""
                paper.figureData = []
            }

            for run in localRuns {
                run.markFailed(message: retiredMessage)
            }

            if !localPapers.isEmpty || !localRuns.isEmpty {
                try modelContext.save()
            }

            purgeRetiredLocalExecutionStorage()

            if !localPapers.isEmpty || !localRuns.isEmpty {
                print("[Migration] Quarantined \(localPapers.count) legacy local paper(s) and \(localRuns.count) local run(s)")
            }
        } catch {
            print("[Migration] Failed to quarantine retired local execution artifacts: \(error.localizedDescription)")
        }
    }

    private func preloadRecentReadyPapers(modelContext: ModelContext) async {
        do {
            let papers = try modelContext.fetch(
                FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            )
                .filter { $0.status == .ready }

            print("[PaperDocs] preloadRecentReadyPapers count=\(papers.count)")

            for paper in papers.prefix(3) {
                print("[PaperDocs] precomputing task=\(paper.codexTaskID) title=\"\(paper.title)\"")
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

    private func runOAuthSetupMonitorLoopIfNeeded(modelContext: ModelContext) async {
        guard scenePhase == .active,
              !openAI.hasUserAPIKeyOverride,
              openAI.oauthExecutionSetupMessage != nil || isShowingOAuthSetupBrowser else {
            return
        }

        while !Task.isCancelled,
              scenePhase == .active,
              !openAI.hasUserAPIKeyOverride,
              openAI.oauthExecutionSetupMessage != nil || isShowingOAuthSetupBrowser {
            let setupMessage = await openAI.refreshOAuthExecutionSetupStateIfNeeded()

            if setupMessage == nil {
                hasDismissedOAuthSetupSheet = false
                isShowingOAuthSetupBrowser = false

                if heldRunCount > 0 {
                    await heartbeat.run(modelContext: modelContext, force: true)
                }
                break
            }

            let interval: Duration
            switch openAI.oauthExecutionSetup.phase {
            case .connectGitHub:
                interval = isShowingOAuthSetupBrowser ? .seconds(4) : .seconds(15)
            case .waitingForMachine, .waitingForEnvironment:
                interval = isShowingOAuthSetupBrowser ? .seconds(4) : .seconds(10)
            case .autoProvisioning:
                interval = .seconds(4)
            case .ready:
                return
            }

            try? await Task.sleep(for: interval)
        }
    }

    private func purgeTransientQAStorage() {
        let fileManager = FileManager.default

        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first

        let paperArtifactsDirectory = applicationSupport?
            .appendingPathComponent("PaperArtifacts", isDirectory: true)
        let localDatasetsDirectory = applicationSupport?
            .appendingPathComponent("LocalDatasets", isDirectory: true)
        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SidekickExports", isDirectory: true)

        if let paperArtifactsDirectory {
            try? fileManager.removeItem(at: paperArtifactsDirectory)
        }

        if let localDatasetsDirectory {
            try? fileManager.removeItem(at: localDatasetsDirectory)
        }

        try? fileManager.removeItem(at: exportDirectory)
    }

    private func purgeRetiredLocalExecutionStorage() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first

        if let paperArtifactsDirectory = applicationSupport?
            .appendingPathComponent("PaperArtifacts", isDirectory: true),
           let artifactKeys = try? fileManager.contentsOfDirectory(atPath: paperArtifactsDirectory.path) {
            for key in artifactKeys where key.hasPrefix("local-") {
                PaperArtifactStore.deleteArtifacts(for: key)
            }
        }

        if let localDatasetsDirectory = applicationSupport?
            .appendingPathComponent("LocalDatasets", isDirectory: true) {
            try? fileManager.removeItem(at: localDatasetsDirectory)
        }
    }
}

private struct OAuthCloudSetupView: View {
    let snapshot: OAuthExecutionSetupSnapshot
    let openCodexSetup: () -> Void
    let retrySetupCheck: () -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SidekickBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeader(
                            eyebrow: "ChatGPT Queue",
                            title: "Finish setup once, in-app",
                            subtitle: "Open the official Codex setup page in ChatGPT. Sidekick keeps checking the backend and will resume held papers automatically."
                        )

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 12) {
                                setupStateGlyph

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(setupHeadline)
                                        .font(.headline)

                                    if let message = snapshot.message, !message.isEmpty {
                                        Text(message)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .glassCard(padding: 22)

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Setup progress")
                                .font(.headline)

                            OAuthSetupStepRow(
                                title: "Connect GitHub to Codex",
                                detail: "This is the only step that still has to happen in ChatGPT itself.",
                                state: githubStepState
                            )

                            OAuthSetupStepRow(
                                title: "Sidekick provisions a runtime",
                                detail: runtimeStepDetail,
                                state: runtimeStepState
                            )

                            OAuthSetupStepRow(
                                title: "Held papers resume",
                                detail: "As soon as the runtime is ready, Sidekick starts the queue again on its own.",
                                state: resumeStepState
                            )
                        }
                        .glassCard(padding: 22)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Alternative")
                                .font(.headline)

                            Text("If you do not want to set up ChatGPT Codex cloud, add your own OpenAI API key in Settings and Sidekick will use that path instead.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .glassCard(padding: 22)
                    }
                    .padding(20)
                    .padding(.bottom, 140)
                }
            }
            .navigationTitle("ChatGPT Queue")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button(primaryActionTitle) {
                        openCodexSetup()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Check again now") {
                        retrySetupCheck()
                    }
                    .buttonStyle(.bordered)

                    Button("Keep writing notes") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var primaryActionTitle: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "Continue in ChatGPT"
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
            return "Open Codex Setup"
        case .ready:
            return "Open Codex Setup"
        }
    }

    private var setupHeadline: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "Connect GitHub once"
        case .waitingForMachine:
            return "Waiting for Codex runtime"
        case .autoProvisioning:
            return "Sidekick is finishing setup"
        case .waitingForEnvironment:
            return "Waiting for the runtime to appear"
        case .ready:
            return "ChatGPT Queue is ready"
        }
    }

    private var githubStepState: OAuthSetupStepState {
        snapshot.requiresGitHubConnection ? .current : .complete
    }

    private var runtimeStepState: OAuthSetupStepState {
        switch snapshot.phase {
        case .connectGitHub:
            return .pending
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
            return .current
        case .ready:
            return .complete
        }
    }

    private var resumeStepState: OAuthSetupStepState {
        snapshot.phase == .ready ? .complete : .pending
    }

    private var runtimeStepDetail: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "After GitHub is linked, Sidekick will try to create a Sidekick Runtime automatically."
        case .waitingForMachine:
            return "GitHub is linked. Sidekick is waiting for Codex to expose a machine template."
        case .autoProvisioning:
            if let machineLabel = snapshot.machineLabel, !machineLabel.isEmpty {
                return "Sidekick is creating the runtime on \(machineLabel) and checking for readiness."
            }
            return "Sidekick is creating the runtime and checking for readiness."
        case .waitingForEnvironment:
            return "Codex setup is still settling. Sidekick keeps checking and will pick up the environment automatically."
        case .ready:
            if let environmentLabel = snapshot.environmentLabel, !environmentLabel.isEmpty {
                return "Ready on \(environmentLabel)."
            }
            return "A usable Codex runtime is ready."
        }
    }

    @ViewBuilder
    private var setupStateGlyph: some View {
        switch snapshot.phase {
        case .connectGitHub:
            Image(systemName: "link.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(SidekickTheme.accent)
                .frame(width: 34, height: 34)
                .background(SidekickTheme.accent.opacity(0.12), in: Circle())
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
            ProgressView()
                .controlSize(.regular)
                .frame(width: 34, height: 34)
                .background(SidekickTheme.accent.opacity(0.12), in: Circle())
        case .ready:
            Image(systemName: "checkmark")
                .font(.headline.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(Color.green.opacity(0.12), in: Circle())
        }
    }
}

private enum OAuthSetupStepState {
    case pending
    case current
    case complete
}

private struct OAuthSetupStepRow: View {
    let title: String
    let detail: String
    let state: OAuthSetupStepState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            stepIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch state {
        case .pending:
            Circle()
                .stroke(SidekickTheme.edge, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
        case .current:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
        }
    }
}

// MARK: - Sign-In Gate

struct OnboardingView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var authError: String?

    var body: some View {
        ZStack {
            SidekickBackground()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(SidekickTheme.accent)

                    Text("Sidekick")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))

                    Text("Sign in with ChatGPT to get started.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    signIn()
                } label: {
                    HStack(spacing: 8) {
                        if auth.isSigningIn {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Sign in with ChatGPT")
                    }
                    .frame(maxWidth: 280)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(SidekickTheme.accent)
                .disabled(auth.isSigningIn)

                if let authError, !authError.isEmpty {
                    Text(authError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()
                Spacer()
            }
        }
        .sheet(isPresented: signInSheetBinding) {
            if let url = auth.signInURL {
                SafariBrowserView(url: url)
            }
        }
    }

    private func signIn() {
        authError = nil
        Task {
            do {
                try await auth.signIn()
            } catch is CancellationError {
            } catch {
                authError = error.localizedDescription
            }
        }
    }

    private var signInSheetBinding: Binding<Bool> {
        Binding(
            get: { auth.signInURL != nil },
            set: { isPresented in
                guard !isPresented else { return }
                auth.cancelSignIn()
            }
        )
    }
}

// MARK: - Main App

struct ContentView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @State private var selectedTab: AppTab = QAFlags.shouldOpenLatestPaper ? .papers : .notes

    var body: some View {
        if auth.isAuthenticated {
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
            OnboardingView()
        }
    }

    // MARK: - Ambient Status

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

// MARK: - Pulse Animation

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
