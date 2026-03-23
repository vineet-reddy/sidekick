import BackgroundTasks
import Combine
import Foundation
import SwiftData

enum HeartbeatPhase: Equatable {
    case idle
    case checkingPapers
    case assessingNotes
    case submittingPaper(String)
    case done(Int)

    var label: String {
        switch self {
        case .idle:
            return ""
        case .checkingPapers:
            return "Checking papers..."
        case .assessingNotes:
            return "Reading your notes..."
        case let .submittingPaper(title):
            return "Planning \"\(title)\"..."
        case let .done(count):
            if count == 0 {
                return "All caught up."
            }

            return count == 1 ? "1 new paper queued." : "\(count) new papers queued."
        }
    }
}

@MainActor
final class HeartbeatManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase: HeartbeatPhase = .idle
    @Published var lastError: String?

    private let openAI: OpenAIService
    private let github: GitHubService
    private let notifications: NotificationService
    private let defaults: UserDefaults

    private let lastRunKey = "com.vineet.sidekick.lastHeartbeatAt"
    private let cooldown: TimeInterval = 20 * 60
    private let failedPaperRetryCooldown: TimeInterval = 20 * 60
    private let maxConcurrentRuns = 1
    private let maxNoteAssessmentPasses = 3

    init(
        openAI: OpenAIService,
        github: GitHubService,
        notifications: NotificationService,
        defaults: UserDefaults = .standard
    ) {
        self.openAI = openAI
        self.github = github
        self.notifications = notifications
        self.defaults = defaults
    }

    func scheduleBackgroundRefresh() {
        BackgroundHeartbeatScheduler.shared.schedule()
    }

    func runIfNeeded(modelContext: ModelContext) async {
        let lastRun = defaults.object(forKey: lastRunKey) as? Date
        let shouldRun = lastRun.map { Date().timeIntervalSince($0) > cooldown } ?? true

        if shouldRun {
            await run(modelContext: modelContext, force: false)
        }
    }

    func run(modelContext: ModelContext, force: Bool) async {
        if isRunning {
            return
        }

        if !force {
            let lastRun = defaults.object(forKey: lastRunKey) as? Date
            let shouldRun = lastRun.map { Date().timeIntervalSince($0) > cooldown } ?? true
            guard shouldRun else {
                return
            }
        }

        isRunning = true
        defer {
            isRunning = false
            defaults.set(Date(), forKey: lastRunKey)
            scheduleBackgroundRefresh()
        }

        do {
            phase = .checkingPapers
            try await resolveInFlightPapers(modelContext: modelContext)
            try await reconsiderHeldResearchRunsIfNeeded(modelContext: modelContext)
            try await admitQueuedResearchRunsIfPossible(modelContext: modelContext)

            phase = .assessingNotes
            let submitted = try await discoverNewPaperCandidates(modelContext: modelContext)
            try await admitQueuedResearchRunsIfPossible(modelContext: modelContext)
            try modelContext.save()
            lastError = nil
            phase = .done(submitted)

            Task {
                try? await Task.sleep(for: .seconds(4))
                if case .done = phase {
                    phase = .idle
                }
            }
        } catch {
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    private func resolveInFlightPapers(modelContext: ModelContext) async throws {
        let papers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let runsByPaperID = runs.latestRunsByPaperID()

        for paper in papers where paper.status == .generating {
            guard let run = runsByPaperID[paper.id] else {
                continue
            }

            if run.status == .queued {
                continue
            }

            let result = try await openAI.checkTask(run.runID)
            switch result {
            case let .waiting(snapshot):
                persistTaskProgress(snapshot)
                apply(snapshot: snapshot, to: run)
            case let .completed(snapshot, artifacts):
                persistTaskProgress(snapshot)
                apply(snapshot: snapshot, to: run)
                try await applyCompletedArtifacts(artifacts, to: paper, run: run)
            case let .failed(snapshot, message):
                persistTaskProgress(snapshot)
                apply(snapshot: snapshot, to: run)
                markResearchRunFailed(run, paper: paper, message: message)
            }
        }

        for paper in papers where paper.status != .ready {
            guard let run = runsByPaperID[paper.id] else {
                continue
            }

            guard run.status == .completed,
                  !run.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if await repairCompletedPaperFromLocalArtifactsIfPossible(paper, run: run) {
                continue
            }

            let result = try await openAI.checkTask(run.runID)
            switch result {
            case .waiting:
                continue
            case let .completed(snapshot, artifacts):
                persistTaskProgress(snapshot)
                apply(snapshot: snapshot, to: run)
                try await applyCompletedArtifacts(artifacts, to: paper, run: run)
            case .failed:
                continue
            }
        }
    }

    private func apply(snapshot: PaperTaskProgressSnapshot, to run: ResearchRun) {
        if snapshot.status == "queued" {
            run.markQueued(message: snapshot.latestEventText, queueState: .queued)
            return
        }

        run.markRunning(
            stage: stage(
                from: run.currentStage,
                backendStageRaw: snapshot.backendStage,
                backendMessage: snapshot.latestEventText
            ),
            message: snapshot.latestEventText
        )
    }

    private func stage(
        from current: ResearchRunStage,
        backendStageRaw: String?,
        backendMessage: String?
    ) -> ResearchRunStage {
        let normalized = backendStageRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch normalized {
        case let value where value.contains("plan"):
            return .plan
        case let value where value.contains("inspect"):
            return .inspect
        case let value where value.contains("analy"):
            return .analyze
        case let value where value.contains("verify"):
            return .verify
        case let value where value.contains("draft"),
             let value where value.contains("publish"),
             let value where value.contains("write"):
            return .write
        default:
            break
        }

        let fallback = backendMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !fallback.isEmpty else {
            return current
        }

        switch fallback {
        case let value where value.contains("plan"):
            return .plan
        case let value where value.contains("inspect"):
            return .inspect
        case let value where value.contains("analy"):
            return .analyze
        case let value where value.contains("verify"):
            return .verify
        case let value where value.contains("draft"),
             let value where value.contains("publish"),
             let value where value.contains("write"):
            return .write
        default:
            return current
        }
    }

    private func applyCompletedArtifacts(
        _ artifacts: PaperArtifacts,
        to paper: Paper,
        run: ResearchRun
    ) async throws {
        if let plan = artifacts.plan {
            try? PaperArtifactStore.persistStageArtifact(plan, runID: run.runID, stage: .plan)
        }
        if let inspection = artifacts.inspection {
            try? PaperArtifactStore.persistStageArtifact(inspection, runID: run.runID, stage: .inspect)
        }
        if let analysis = artifacts.analysis {
            try? PaperArtifactStore.persistStageArtifact(analysis, runID: run.runID, stage: .analyze)
        }
        if let verification = artifacts.verification {
            try? PaperArtifactStore.persistStageArtifact(verification, runID: run.runID, stage: .verify)
        }
        let draftArtifact = artifacts.draft ?? ResearchDraftArtifact(
            title: artifacts.title,
            markdown: artifacts.markdown
        )
        try? PaperArtifactStore.persistStageArtifact(draftArtifact, runID: run.runID, stage: .write)
        if let export = artifacts.exportMetadata {
            try? PaperArtifactStore.persistExportMetadata(
                taskID: run.runID,
                repoURL: export.repoURL,
                commitSHA: export.commitSHA,
                repoPath: export.repoPath,
                publishedAt: export.publishedAt ?? .now
            )
        }

        if let provenance = artifacts.provenance {
            try? PaperArtifactStore.finalizeProvenance(
                taskID: run.runID,
                title: artifacts.title,
                modelProvenance: provenance
            )
        }

        run.markRunning(stage: .typeset, message: ResearchRunStage.typeset.title)
        paper.title = artifacts.title
        paper.markdown = artifacts.markdown
        paper.figureData = artifacts.figures
        paper.codexTaskID = run.runID
        paper.figureData = artifacts.figures.isEmpty ? (artifacts.analysis?.figureData ?? []) : artifacts.figures
        paper.status = .ready

        await PaperDocumentService.precomputeIfNeeded(for: paper)

        if paper.lastNotifiedAt == nil {
            notifications.notify(paper: paper)
            paper.lastNotifiedAt = .now
        }

        run.markCompleted(message: "Paper ready.")
        try persistModelChanges(in: run.modelContext)
    }

    private func repairCompletedPaperFromLocalArtifactsIfPossible(
        _ paper: Paper,
        run: ResearchRun
    ) async -> Bool {
        let taskID = run.runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            return false
        }

        let draft = PaperArtifactStore.stageArtifact(
            ResearchDraftArtifact.self,
            runID: taskID,
            stage: .write
        )
        let analysis = PaperArtifactStore.stageArtifact(
            ResearchAnalysisArtifact.self,
            runID: taskID,
            stage: .analyze
        )

        let recoveredTitle = (draft?.title ?? paper.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredMarkdown = (draft?.markdown ?? paper.markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredFigures = paper.figureData.isEmpty ? (analysis?.figureData ?? []) : paper.figureData

        guard !recoveredMarkdown.isEmpty else {
            return false
        }

        if !recoveredTitle.isEmpty {
            paper.title = recoveredTitle
        }
        paper.markdown = recoveredMarkdown
        paper.figureData = recoveredFigures
        paper.codexTaskID = taskID
        paper.status = .ready
        run.markRunning(stage: .typeset, message: ResearchRunStage.typeset.title)

        await PaperDocumentService.precomputeIfNeeded(for: paper)
        guard paper.status == .ready else {
            persistModelChangesIfPossible(in: run.modelContext, context: "repair completed paper")
            return false
        }

        if paper.lastNotifiedAt == nil {
            notifications.notify(paper: paper)
            paper.lastNotifiedAt = .now
        }

        run.markCompleted(message: "Paper ready.")
        persistModelChangesIfPossible(in: run.modelContext, context: "repair completed paper")
        return true
    }

    private func persistTaskProgress(_ snapshot: PaperTaskProgressSnapshot) {
        try? PaperArtifactStore.recordTaskProgress(snapshot)
    }

    private func reconsiderHeldResearchRunsIfNeeded(modelContext: ModelContext) async throws {
        guard github.isConnected else {
            return
        }

        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )

        for run in runs where run.status == .queued && run.queueState == .held {
            run.schedulingDisposition = .autoStart
            run.markQueued(
                message: "GitHub connected. Research queued on Sidekick-hosted compute.",
                queueState: .queued
            )
        }
    }

    private func admitQueuedResearchRunsIfPossible(modelContext: ModelContext) async throws {
        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        let papers = try modelContext.fetch(FetchDescriptor<Paper>())
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let papersByID = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        let activeCount = runs.filter { $0.status == .running }.count
        var availableSlots = max(0, maxConcurrentRuns - activeCount)

        for run in runs where run.status == .queued && run.queueState == .held {
            run.markQueued(
                message: "Connect GitHub to start this paper. Sidekick requires a public user-owned repo for every run.",
                queueState: .held
            )
        }

        let queuedRuns = runs.filter(\.isSchedulerEligible).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }

            return $0.runID < $1.runID
        }

        for (index, run) in queuedRuns.enumerated() {
            guard let paper = papersByID[run.paperID] else {
                continue
            }

            let sourceNotes = run.sourceNoteIDs.compactMap { notesByID[$0] }
            guard !sourceNotes.isEmpty else {
                markResearchRunFailed(run, paper: paper, message: "The source notes for this paper could not be found.")
                continue
            }

            guard github.isConnected else {
                run.schedulingDisposition = .hold
                run.markQueued(
                    message: "Connect GitHub to start this paper. Sidekick requires a public user-owned repo for every run.",
                    queueState: .held
                )
                continue
            }

            guard availableSlots > 0 else {
                let queueState: ResearchRunQueueState = index == 0 ? .nextInLine : .waitingForCurrentPaper
                run.markQueued(
                    message: index == 0
                        ? "Waiting for the current paper to finish. This paper is next in line."
                        : "Waiting for the current paper to finish. Sidekick runs one paper at a time per install.",
                    queueState: queueState
                )
                continue
            }

            try await startQueuedResearchRun(run, paper: paper, notes: sourceNotes)
            availableSlots -= 1
        }
    }

    private func startQueuedResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note]
    ) async throws {
        run.executionBackend = .sidekickHosted
        paper.status = .generating
        run.markRunning(stage: .plan, message: "Submitting the paper job to Sidekick-hosted compute.")
        try persistModelChanges(in: run.modelContext)

        do {
            let submission = try await openAI.submitPaperTask(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs
            )
            run.runID = submission.taskID
            run.activeTaskID = submission.taskID
            run.datasetIDs = submission.selectedDatasetIDs
            run.allowedDomains = submission.allowedDomains
            paper.codexTaskID = submission.taskID
            run.markRunning(stage: .plan, message: ResearchRunStage.plan.title)
            try PaperArtifactStore.persistPendingSubmission(
                submission,
                title: run.title,
                theme: run.theme
            )
            try persistModelChanges(in: run.modelContext)
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("github") {
                run.schedulingDisposition = .hold
                run.markQueued(message: message, queueState: .held)
                paper.status = .generating
            } else {
                markResearchRunFailed(run, paper: paper, message: message)
            }
        }
    }

    @discardableResult
    private func discoverNewPaperCandidates(modelContext: ModelContext) async throws -> Int {
        let notes = try modelContext.fetch(
            FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        guard !notes.isEmpty else {
            return 0
        }

        let existingPapers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        guard shouldAssessNotes(notes: notes, existingPapers: existingPapers) else {
            return 0
        }

        let clusters = try await assessNotesWithRescue(notes)
        let surfacedClusters = selectedPresentationClusters(from: clusters)
        var submitted = 0

        for cluster in surfacedClusters {
            let clusterNotes = notes.filter { cluster.noteIDs.contains($0.id) }
            guard !clusterNotes.isEmpty else {
                continue
            }

            let matchingPapers = existingPapers.filter { $0.matches(noteIDs: cluster.noteIDs) }
            if matchingPapers.contains(where: { $0.status == .generating }) {
                continue
            }

            let latestNoteUpdate = clusterNotes.map(\.updatedAt).max() ?? .distantPast
            if let latestPaper = matchingPapers.max(by: { $0.updatedAt < $1.updatedAt }) {
                if latestPaper.status == .failed {
                    let failureAge = Date().timeIntervalSince(latestPaper.updatedAt)
                    guard failureAge >= failedPaperRetryCooldown else {
                        continue
                    }
                } else if latestPaper.updatedAt >= latestNoteUpdate {
                    continue
                }
            }

            phase = .submittingPaper(cluster.suggestedTitle)
            try await beginResearchRun(
                cluster: cluster,
                notes: clusterNotes,
                modelContext: modelContext
            )
            submitted += 1
        }

        return submitted
    }

    private func beginResearchRun(
        cluster: NoteCluster,
        notes: [Note],
        modelContext: ModelContext
    ) async throws {
        let preparation = try await openAI.prepareResearchRun(
            notes: notes,
            title: cluster.suggestedTitle,
            theme: cluster.theme,
            datasetIDs: cluster.datasetIDs
        )
        let runID = "queued-\(UUID().uuidString)"
        let paper = Paper(
            title: cluster.suggestedTitle,
            status: .generating,
            codexTaskID: runID,
            sourceNoteIDs: cluster.noteIDs
        )
        let queueState: ResearchRunQueueState = preparation.schedulingDisposition == .autoStart ? .queued : .held
        let run = ResearchRun(
            runID: runID,
            paperID: paper.id,
            title: cluster.suggestedTitle,
            theme: cluster.theme,
            sourceNoteIDs: cluster.noteIDs,
            datasetIDs: preparation.selectedDatasetIDs,
            allowedDomains: preparation.allowedDomains,
            registryVersion: preparation.registryVersion,
            currentStage: .plan,
            status: .queued,
            executionBackend: .sidekickHosted,
            queueState: queueState,
            schedulingDisposition: preparation.schedulingDisposition,
            sourceSupportTier: preparation.sourceSupportTier
        )

        modelContext.insert(paper)
        modelContext.insert(run)
        run.markQueued(
            message: preparation.initialStatusMessage,
            queueState: queueState
        )
        try persistModelChanges(in: modelContext)
    }

    private func shouldAssessNotes(notes: [Note], existingPapers: [Paper]) -> Bool {
        let trackedPapers = existingPapers.filter { $0.status != .failed }
        guard !trackedPapers.isEmpty else {
            return true
        }

        for note in notes {
            let coveringPapers = trackedPapers.filter { $0.sourceNoteIDs.contains(note.id) }
            guard let latestCoverageAt = coveringPapers.map(\.updatedAt).max() else {
                return true
            }

            if latestCoverageAt < note.updatedAt {
                return true
            }
        }

        return false
    }

    private func assessNotesWithRescue(_ notes: [Note]) async throws -> [NoteCluster] {
        var allClusters: [NoteCluster] = []
        var remainingNotes = notes
        var coveredNoteIDs = Set<UUID>()

        for _ in 1 ... maxNoteAssessmentPasses {
            guard !remainingNotes.isEmpty else {
                break
            }

            let passClusters = try await openAI.assessNotes(remainingNotes)
            allClusters.append(contentsOf: passClusters)

            let newlyCoveredNoteIDs = Set(
                selectedSubmissionClusters(from: passClusters)
                    .flatMap(\.noteIDs)
            )
            let previousCoverageCount = coveredNoteIDs.count
            coveredNoteIDs.formUnion(newlyCoveredNoteIDs)

            if coveredNoteIDs.count == previousCoverageCount {
                break
            }

            let nextRemainingNotes = notes.filter { !coveredNoteIDs.contains($0.id) }
            if nextRemainingNotes.count == remainingNotes.count {
                break
            }

            remainingNotes = nextRemainingNotes
        }

        return allClusters
    }

    private func selectedPresentationClusters(from clusters: [NoteCluster]) -> [NoteCluster] {
        deduplicatedClusters(
            from: clusters.filter { !$0.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    private func selectedSubmissionClusters(from clusters: [NoteCluster]) -> [NoteCluster] {
        deduplicatedClusters(
            from: clusters.filter(isSubmissionCandidate)
        )
    }

    private func deduplicatedClusters(from clusters: [NoteCluster]) -> [NoteCluster] {
        let candidates = clusters.sorted { lhs, rhs in
            let lhsPriority = clusterPriorityScore(for: lhs)
            let rhsPriority = clusterPriorityScore(for: rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }

            let lhsNoteCount = Set(lhs.noteIDs).count
            let rhsNoteCount = Set(rhs.noteIDs).count
            if lhsNoteCount != rhsNoteCount {
                return lhsNoteCount > rhsNoteCount
            }

            return lhs.suggestedTitle < rhs.suggestedTitle
        }

        var selected: [NoteCluster] = []

        for cluster in candidates {
            let noteSet = Set(cluster.noteIDs)
            guard !noteSet.isEmpty else {
                continue
            }

            let overlapsExistingSelection = selected.contains { existing in
                let existingNoteSet = Set(existing.noteIDs)
                let sharedCount = noteSet.intersection(existingNoteSet).count
                guard sharedCount > 0 else {
                    return false
                }

                let smallerClusterSize = min(noteSet.count, existingNoteSet.count)
                let overlapRatio = Double(sharedCount) / Double(smallerClusterSize)
                let sharesDatasetFamily = !Set(cluster.datasetIDs).isDisjoint(with: Set(existing.datasetIDs))

                return overlapRatio >= 0.75 || (sharesDatasetFamily && overlapRatio >= 0.5)
            }

            guard !overlapsExistingSelection else {
                continue
            }

            selected.append(cluster)
        }

        return selected
    }

    private func clusterPriorityScore(for cluster: NoteCluster) -> Double {
        let noteCount = Double(Set(cluster.noteIDs).count)
        let datasetCount = Double(Set(cluster.datasetIDs).count)
        let readinessBonus: Double

        if cluster.isAutomaticallyRunnable {
            readinessBonus = 48
        } else if isPromotableTrustedPartialCluster(cluster) {
            readinessBonus = 38
        } else if isPromotableExploratoryCluster(cluster) {
            readinessBonus = 34
        } else {
            switch cluster.readinessMode {
            case .trustedReady:
                readinessBonus = 32
            case .trustedPartial:
                readinessBonus = 24
            case .exploratoryReady:
                readinessBonus = 18
            }
        }

        let noteCoverageBonus = min(noteCount, 4.0) * 12
        let datasetPenalty = max(0, datasetCount - 1) * 2
        return readinessBonus + noteCoverageBonus - datasetPenalty
    }

    private func isPromotableTrustedPartialCluster(_ cluster: NoteCluster) -> Bool {
        guard cluster.readinessMode == .trustedPartial else {
            return false
        }

        let noteCount = Set(cluster.noteIDs).count
        return noteCount >= 2 || (noteCount == 1 && Set(cluster.datasetIDs).count <= 1)
    }

    private func isPromotableExploratoryCluster(_ cluster: NoteCluster) -> Bool {
        guard cluster.readinessMode == .exploratoryReady else {
            return false
        }

        return Set(cluster.noteIDs).count >= 2
    }

    private func isSubmissionCandidate(_ cluster: NoteCluster) -> Bool {
        cluster.isAutomaticallyRunnable
            || isPromotableTrustedPartialCluster(cluster)
            || isPromotableExploratoryCluster(cluster)
    }

    private func markResearchRunFailed(
        _ run: ResearchRun,
        paper: Paper,
        message: String
    ) {
        run.markFailed(message: message)
        paper.status = .failed
        persistModelChangesIfPossible(in: run.modelContext, context: "mark failed")
    }

    private func persistModelChanges(in modelContext: ModelContext?) throws {
        guard let modelContext else {
            return
        }

        try modelContext.save()
    }

    private func persistModelChangesIfPossible(in modelContext: ModelContext?, context: String) {
        do {
            try persistModelChanges(in: modelContext)
        } catch {
            print("[Heartbeat] Failed to persist \(context): \(error.localizedDescription)")
        }
    }
}

final class BackgroundHeartbeatScheduler {
    static let shared = BackgroundHeartbeatScheduler()
    static let identifier = "com.vineet.sidekick.heartbeat"

    var runner: (@MainActor @Sendable () async -> Void)?

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
        ) { task in
            Task { @MainActor in
                self.handle(task: task as? BGAppRefreshTask)
            }
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(task: BGAppRefreshTask?) {
        guard let task else {
            return
        }

        schedule()

        let work = Task { @MainActor in
            await runner?()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
