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

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var github: GitHubService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var openAI: OpenAIService
    @State private var hasDismissedOAuthSetupSheet = false
    @State private var oauthSetupBrowserTarget: BrowserTarget?

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
                guard oauthSetupBrowserTarget == nil else {
                    return
                }
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
                    performPrimaryAction: {
                        handleOAuthSetupPrimaryAction()
                    },
                    performSecondaryAction: {
                        handleOAuthSetupSecondaryAction()
                    },
                    dismiss: {
                        hasDismissedOAuthSetupSheet = true
                    }
                )
            }
            .sheet(item: $oauthSetupBrowserTarget) { target in
                SafariBrowserView(url: target.url)
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
        return "\(scenePhase == .active)-\(oauthSetupBrowserTarget != nil)-\(hasMessage)-\(phase)"
    }

    private var oauthSetupSheetBinding: Binding<Bool> {
        Binding(
            get: {
                guard !openAI.hasUserAPIKeyOverride,
                      oauthSetupBrowserTarget == nil,
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
              openAI.oauthExecutionSetupMessage != nil || oauthSetupBrowserTarget != nil else {
            return
        }

        while !Task.isCancelled,
              scenePhase == .active,
              !openAI.hasUserAPIKeyOverride,
              openAI.oauthExecutionSetupMessage != nil || oauthSetupBrowserTarget != nil {
            let phase = openAI.oauthExecutionSetup.phase
            let shouldAutoPoll: Bool

            switch phase {
            case .connectGitHub, .confirmRepositoryScope, .manualFinish:
                shouldAutoPoll = oauthSetupBrowserTarget != nil
            case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
                shouldAutoPoll = true
            case .ready:
                return
            }

            guard shouldAutoPoll else {
                break
            }

            let setupMessage = await openAI.refreshOAuthExecutionSetupStateIfNeeded()

            if setupMessage == nil {
                hasDismissedOAuthSetupSheet = false
                oauthSetupBrowserTarget = nil

                if heldRunCount > 0 {
                    await heartbeat.run(modelContext: modelContext, force: true)
                }
                break
            }

            let interval: Duration
            switch openAI.oauthExecutionSetup.phase {
            case .connectGitHub, .confirmRepositoryScope, .manualFinish:
                interval = oauthSetupBrowserTarget != nil ? .seconds(4) : .seconds(15)
            case .waitingForMachine, .waitingForEnvironment:
                interval = oauthSetupBrowserTarget != nil ? .seconds(4) : .seconds(10)
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

    private func handleOAuthSetupPrimaryAction() {
        switch openAI.oauthExecutionSetup.phase {
        case .connectGitHub:
            Task {
                do {
                    let url = try await github.beginWorkspaceBootstrap(chatGPTEmail: auth.userEmail)
                    await MainActor.run {
                        oauthSetupBrowserTarget = BrowserTarget(url: url)
                    }
                } catch {
                    await MainActor.run {
                        github.recordBootstrapErrorMessage(error.localizedDescription)
                    }
                }
            }
        case .confirmRepositoryScope:
            do {
                try github.markConnectorScopeAttested(chatgptEmail: auth.userEmail)
                Task {
                    _ = await openAI.refreshOAuthExecutionSetupStateIfNeeded()
                    if openAI.oauthExecutionSetupMessage == nil, heldRunCount > 0 {
                        await heartbeat.run(modelContext: modelContext, force: true)
                    }
                }
            } catch {
                github.recordBootstrapErrorMessage(error.localizedDescription)
            }
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            oauthSetupBrowserTarget = BrowserTarget(
                url: URL(string: "https://chatgpt.com/codex/settings/environments")!
            )
        }
    }

    private func handleOAuthSetupSecondaryAction() {
        switch openAI.oauthExecutionSetup.phase {
        case .confirmRepositoryScope:
            if let reviewURL = github.connectorReviewURL() {
                oauthSetupBrowserTarget = BrowserTarget(url: reviewURL)
            }
        case .connectGitHub, .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            Task {
                _ = await openAI.refreshOAuthExecutionSetupStateIfNeeded()
                if openAI.oauthExecutionSetupMessage == nil, heldRunCount > 0 {
                    await heartbeat.run(modelContext: modelContext, force: true)
                }
            }
        }
    }
}

private struct BrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
}

private struct OAuthCloudSetupView: View {
    @EnvironmentObject private var github: GitHubService
    let snapshot: OAuthExecutionSetupSnapshot
    let performPrimaryAction: () -> Void
    let performSecondaryAction: () -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SidekickBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeader(
                            eyebrow: "Codex Workspace",
                            title: "Finish setup once",
                            subtitle: "Sidekick creates one secure workspace repo, opens the ChatGPT Codex Connector already scoped to that repo, and then finishes the repository-bound environment."
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

                                    if let bootstrapErrorMessage = github.bootstrapErrorMessage,
                                       !bootstrapErrorMessage.isEmpty {
                                        Text(bootstrapErrorMessage)
                                            .font(.footnote)
                                            .foregroundStyle(.red)
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
                                title: "Create secure workspace repo",
                                detail: workspaceStepDetail,
                                state: githubStepState
                            )

                            OAuthSetupStepRow(
                                title: "Install Codex on one repo",
                                detail: connectorStepDetail,
                                state: connectorStepState
                            )

                            OAuthSetupStepRow(
                                title: "Finish Codex environment",
                                detail: runtimeStepDetail,
                                state: runtimeStepState
                            )
                        }
                        .glassCard(padding: 22)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Alternative")
                                .font(.headline)

                            Text("If you do not want to use the repository-bound ChatGPT Codex flow, add your own OpenAI API key in Settings and Sidekick will use that path instead.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .glassCard(padding: 22)
                    }
                    .padding(20)
                    .padding(.bottom, 140)
                }
            }
            .navigationTitle("Codex Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button(primaryActionTitle) {
                        performPrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(secondaryActionTitle) {
                        performSecondaryAction()
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
            return "Create Workspace In GitHub"
        case .confirmRepositoryScope:
            return "I Confirmed It"
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish:
            return "Open Codex Environments"
        case .ready:
            return "Open Codex Environments"
        }
    }

    private var secondaryActionTitle: String {
        switch snapshot.phase {
        case .confirmRepositoryScope:
            return "Review GitHub Access Again"
        case .connectGitHub, .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            return "Check Again Now"
        }
    }

    private var setupHeadline: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "Create the secure workspace repo"
        case .confirmRepositoryScope:
            return "Confirm the connector stayed on one repo"
        case .waitingForMachine:
            return "Waiting for a Codex machine"
        case .autoProvisioning:
            return "Sidekick is finishing setup"
        case .waitingForEnvironment:
            return "Waiting for the environment to appear"
        case .manualFinish:
            return "Finish the environment in ChatGPT"
        case .ready:
            return "Codex workspace is ready"
        }
    }

    private var githubStepState: OAuthSetupStepState {
        switch snapshot.phase {
        case .connectGitHub:
            return .current
        case .confirmRepositoryScope, .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            return .complete
        }
    }

    private var connectorStepState: OAuthSetupStepState {
        switch snapshot.phase {
        case .connectGitHub:
            return .pending
        case .confirmRepositoryScope:
            return .current
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            return .complete
        }
    }

    private var runtimeStepState: OAuthSetupStepState {
        switch snapshot.phase {
        case .connectGitHub, .confirmRepositoryScope:
            return .pending
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
            return .current
        case .manualFinish:
            return .actionRequired
        case .ready:
            return .complete
        }
    }

    private var workspaceStepDetail: String {
        if let repo = snapshot.workspaceRepositoryFullName, !repo.isEmpty {
            return "Sidekick created or reused \(repo) as the only permanent Codex workspace repo for this ChatGPT account."
        }
        return "Sidekick will create or reuse one private workspace repo and keep all papers, experiments, and artifacts inside it."
    }

    private var connectorStepDetail: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "GitHub opens with only the Sidekick workspace repo preselected for the ChatGPT Codex Connector."
        case .confirmRepositoryScope:
            return "Confirm that GitHub stayed on Only selected repositories and that the Sidekick workspace repo was the only selected repo."
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment, .manualFinish, .ready:
            if let repo = snapshot.workspaceRepositoryFullName, !repo.isEmpty {
                return "The connector is installed for \(repo) and Sidekick is using that repo-bound setup."
            }
            return "The connector install completed and Sidekick is using the repo-bound setup."
        }
    }

    private var runtimeStepDetail: String {
        switch snapshot.phase {
        case .connectGitHub:
            return "Once the connector is installed on one repo, Sidekick will provision the repository-bound environment automatically."
        case .confirmRepositoryScope:
            return "After you confirm the scope, Sidekick will finish the repository-bound environment automatically."
        case .waitingForMachine:
            return "GitHub is linked. Sidekick is waiting for Codex to expose a usable machine template."
        case .autoProvisioning:
            if let machineLabel = snapshot.machineLabel, !machineLabel.isEmpty {
                return "Sidekick is creating the repository-bound environment on \(machineLabel) and checking for readiness."
            }
            return "Sidekick is creating the repository-bound environment and checking for readiness."
        case .waitingForEnvironment:
            return "Codex is still finishing the workspace environment. Sidekick keeps checking and will pick it up automatically."
        case .manualFinish:
            return "Automatic provisioning stalled. Open Codex Environments to finish or verify the repository-bound environment, then come back and check again."
        case .ready:
            if let environmentLabel = snapshot.environmentLabel, !environmentLabel.isEmpty {
                return "Ready on \(environmentLabel)."
            }
            return "A usable repository-bound Codex environment is ready."
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
        case .confirmRepositoryScope:
            Image(systemName: "checkmark.shield")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.14), in: Circle())
        case .waitingForMachine, .autoProvisioning, .waitingForEnvironment:
            ProgressView()
                .controlSize(.regular)
                .frame(width: 34, height: 34)
                .background(SidekickTheme.accent.opacity(0.12), in: Circle())
        case .manualFinish:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.14), in: Circle())
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
    case actionRequired
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
        case .actionRequired:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
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
