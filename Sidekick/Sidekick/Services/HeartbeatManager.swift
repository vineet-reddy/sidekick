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
            return "Writing \"\(title)\"..."
        case let .done(count):
            if count == 0 {
                return "All caught up."
            }

            return count == 1 ? "1 new paper started." : "\(count) new papers started."
        }
    }
}

@MainActor
final class HeartbeatManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase: HeartbeatPhase = .idle
    @Published var lastError: String?

    private let openAI: OpenAIService
    private let notifications: NotificationService
    private let defaults: UserDefaults

    private let lastRunKey = "com.vineet.sidekick.lastHeartbeatAt"
    private let cooldown: TimeInterval = 20 * 60
    private let supportedLocalRecoveryGracePeriod: TimeInterval = 3 * 60
    private let remoteRetryGracePeriod: TimeInterval = 8 * 60
    private let stalledEventGracePeriod: TimeInterval = 4 * 60
    private let maxRemoteAttempts = 2

    init(
        openAI: OpenAIService,
        notifications: NotificationService,
        defaults: UserDefaults = .standard
    ) {
        self.openAI = openAI
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
            print("[Heartbeat] Already running, skipping.")
            return
        }

        if !force {
            let lastRun = defaults.object(forKey: lastRunKey) as? Date
            let shouldRun = lastRun.map { Date().timeIntervalSince($0) > cooldown } ?? true
            guard shouldRun else {
                print("[Heartbeat] Cooldown active, skipping.")
                return
            }
        }

        print("[Heartbeat] Starting run (force=\(force))")
        isRunning = true
        defer {
            isRunning = false
            defaults.set(Date(), forKey: lastRunKey)
            scheduleBackgroundRefresh()
            print("[Heartbeat] Run complete.")
        }

        do {
            phase = .checkingPapers
            print("[Heartbeat] Phase: checking in-flight papers...")
            try await resolveInFlightPapers(modelContext: modelContext)

            phase = .assessingNotes
            print("[Heartbeat] Phase: assessing notes...")
            let submitted = try await discoverNewPaperCandidates(modelContext: modelContext)

            try modelContext.save()
            lastError = nil
            phase = .done(submitted)
            print("[Heartbeat] Done. Submitted \(submitted) new paper(s).")

            Task {
                try? await Task.sleep(for: .seconds(4))
                if case .done = phase {
                    phase = .idle
                }
            }
        } catch {
            print("[Heartbeat] ERROR: \(error.localizedDescription)")
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    private func resolveInFlightPapers(modelContext: ModelContext) async throws {
        let papers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        .filter { $0.status == .generating }
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        print("[Heartbeat] Found \(papers.count) in-flight paper(s).")

        for paper in papers {
            print("[Heartbeat]   Checking task \(paper.codexTaskID) for \"\(paper.title)\"...")

            do {
                let result = try await openAI.checkTask(paper.codexTaskID)

                switch result {
                case let .waiting(snapshot):
                    persistTaskProgress(snapshot)

                    if let recovery = try await recoverStalledPaperIfNeeded(
                        for: paper,
                        notesByID: notesByID,
                        snapshot: snapshot,
                        force: false
                    ) {
                        try await applyRecovery(recovery, to: paper)
                    } else if shouldFailStalledRemote(for: paper, snapshot: snapshot) {
                        paper.status = .failed
                        print("[Heartbeat]   -> Marked failed after repeated stalled attempts.")
                    } else {
                        print("[Heartbeat]   -> Still in progress. \(progressDescription(snapshot))")
                    }

                case let .completed(snapshot, artifacts):
                    persistTaskProgress(snapshot)
                    applyArtifacts(artifacts, to: paper)
                    await PaperDocumentService.precomputeIfNeeded(for: paper)
                    print("[Heartbeat]   -> Paper ready: \"\(artifacts.title)\"")

                case let .failed(snapshot, message):
                    persistTaskProgress(snapshot)

                    if let recovery = try await recoverStalledPaperIfNeeded(
                        for: paper,
                        notesByID: notesByID,
                        snapshot: snapshot,
                        force: true
                    ) {
                        try await applyRecovery(recovery, to: paper)
                    } else {
                        paper.status = .failed
                        print("[Heartbeat]   -> Failed: \(message)")
                    }
                }
            } catch {
                print("[Heartbeat]   -> Poll error: \(error.localizedDescription)")
            }
        }
    }

    private func applyArtifacts(_ artifacts: PaperArtifacts, to paper: Paper) {
        do {
            try PaperArtifactStore.finalizeProvenance(
                taskID: paper.codexTaskID,
                title: artifacts.title,
                modelProvenance: artifacts.provenance
            )
        } catch {
            print("[Heartbeat]   -> Failed to persist provenance: \(error.localizedDescription)")
        }

        paper.title = artifacts.title
        paper.markdown = artifacts.markdown
        paper.figureData = artifacts.figures
        paper.status = .ready

        if paper.lastNotifiedAt == nil {
            notifications.notify(paper: paper)
            paper.lastNotifiedAt = .now
        }
    }

    private func persistTaskProgress(_ snapshot: PaperTaskProgressSnapshot) {
        do {
            try PaperArtifactStore.recordTaskProgress(snapshot)
        } catch {
            print("[Heartbeat]   -> Failed to persist task progress: \(error.localizedDescription)")
        }
    }

    private func shouldFailStalledRemote(for paper: Paper, snapshot: PaperTaskProgressSnapshot) -> Bool {
        guard let submission = PaperArtifactStore.pendingSubmission(for: paper.codexTaskID) else {
            return false
        }

        let supportsLocal = LocalPaperGenerationService.supports(datasetIDs: submission.selectedDatasetIDs)
        guard !supportsLocal, submission.attemptCount >= maxRemoteAttempts else {
            return false
        }

        return isStalled(snapshot: snapshot, submission: submission, supportsLocal: false)
    }

    private func recoverStalledPaperIfNeeded(
        for paper: Paper,
        notesByID: [UUID: Note],
        snapshot: PaperTaskProgressSnapshot,
        force: Bool
    ) async throws -> RecoveryResult? {
        guard let submission = PaperArtifactStore.pendingSubmission(for: paper.codexTaskID) else {
            return nil
        }

        let supportsLocal = LocalPaperGenerationService.supports(datasetIDs: submission.selectedDatasetIDs)
        guard force || shouldAttemptRecovery(snapshot: snapshot, submission: submission, supportsLocal: supportsLocal) else {
            return nil
        }

        guard supportsLocal || submission.attemptCount < maxRemoteAttempts else {
            return nil
        }

        let notes = paper.sourceNoteIDs.compactMap { notesByID[$0] }
        guard !notes.isEmpty else {
            return nil
        }

        let recoveryMode = supportsLocal ? "local recovery" : "remote retry"
        print("[Heartbeat]   -> Triggering \(recoveryMode). \(progressDescription(snapshot))")

        let resubmission = try await openAI.submitPaperTask(
            notes: notes,
            title: paper.title,
            theme: submission.theme,
            datasetIDs: submission.selectedDatasetIDs
        )

        let nextAttemptCount = submission.attemptCount + 1

        do {
            try PaperArtifactStore.persistPendingSubmission(
                resubmission,
                title: paper.title,
                theme: submission.theme,
                attemptCount: nextAttemptCount
            )
        } catch {
            print("[Heartbeat]   -> Failed to persist recovery submission: \(error.localizedDescription)")
        }

        paper.codexTaskID = resubmission.taskID

        if let artifacts = resubmission.precomputedArtifacts {
            return .artifacts(artifacts, source: "local recovery")
        }

        return .resubmitted(resubmission.taskID)
    }

    private func shouldAttemptRecovery(
        snapshot: PaperTaskProgressSnapshot,
        submission: PaperArtifactStore.PendingSubmissionSnapshot,
        supportsLocal: Bool
    ) -> Bool {
        if supportsLocal {
            return isStalled(snapshot: snapshot, submission: submission, supportsLocal: true)
        }

        return submission.attemptCount < maxRemoteAttempts
            && isStalled(snapshot: snapshot, submission: submission, supportsLocal: false)
    }

    private func isStalled(
        snapshot: PaperTaskProgressSnapshot,
        submission: PaperArtifactStore.PendingSubmissionSnapshot,
        supportsLocal: Bool
    ) -> Bool {
        let now = Date()
        let taskStart = snapshot.taskCreatedAt ?? snapshot.assistantTurnCreatedAt ?? submission.createdAt
        let lastProgressAt = snapshot.latestEventAt ?? snapshot.assistantTurnCreatedAt ?? taskStart

        let taskAge = now.timeIntervalSince(taskStart)
        let progressAge = now.timeIntervalSince(lastProgressAt)

        if supportsLocal {
            return taskAge >= supportedLocalRecoveryGracePeriod
        }

        return taskAge >= remoteRetryGracePeriod
            && (snapshot.outputCharacterCount == 0 || progressAge >= stalledEventGracePeriod)
    }

    private func progressDescription(_ snapshot: PaperTaskProgressSnapshot) -> String {
        let now = Date()
        let taskAgeSeconds = snapshot.taskCreatedAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        let progressAgeSeconds = snapshot.latestEventAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        let latestEvent = snapshot.latestEventText ?? "<none>"

        return "status=\(snapshot.status) task_age_s=\(taskAgeSeconds) " +
            "latest_event_age_s=\(progressAgeSeconds) output_chars=\(snapshot.outputCharacterCount) " +
            "latest_event=\"\(latestEvent)\""
    }

    private func applyRecovery(_ recovery: RecoveryResult, to paper: Paper) async throws {
        switch recovery {
        case let .artifacts(artifacts, source):
            applyArtifacts(artifacts, to: paper)
            await PaperDocumentService.precomputeIfNeeded(for: paper)
            print("[Heartbeat]   -> Recovered via \(source): \"\(artifacts.title)\"")

        case let .resubmitted(taskID):
            print("[Heartbeat]   -> Resubmitted task as \(taskID)")
        }
    }

    @discardableResult
    private func discoverNewPaperCandidates(modelContext: ModelContext) async throws -> Int {
        let notes = try modelContext.fetch(
            FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )

        print("[Heartbeat] Found \(notes.count) note(s) to assess.")
        guard !notes.isEmpty else {
            print("[Heartbeat] No notes — nothing to do.")
            return 0
        }

        print("[Heartbeat] Calling OpenAI assessNotes API...")
        let clusters = try await openAI.assessNotes(notes)
        print("[Heartbeat] Got \(clusters.count) cluster(s). Auto-runnable: \(clusters.filter(\.isAutomaticallyRunnable).count)")

        let existingPapers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )

        var submitted = 0
        for cluster in clusters where cluster.isAutomaticallyRunnable {
            let clusterNotes = notes.filter { cluster.noteIDs.contains($0.id) }
            guard !clusterNotes.isEmpty else {
                continue
            }

            let matchingPapers = existingPapers.filter { $0.matches(noteIDs: cluster.noteIDs) }
            if let inFlightPaper = matchingPapers.first(where: { $0.status == .generating }) {
                print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" still in flight as \(inFlightPaper.codexTaskID), skipping.")
                continue
            }

            let latestNoteUpdate = clusterNotes.map(\.updatedAt).max() ?? .distantPast
            if let latestPaper = matchingPapers.max(by: { $0.updatedAt < $1.updatedAt }),
               latestPaper.updatedAt >= latestNoteUpdate {
                print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" already tracked, skipping.")
                continue
            }

            if !matchingPapers.isEmpty {
                print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" changed since the latest paper, generating a revision.")
            }

            phase = .submittingPaper(cluster.suggestedTitle)
            print("[Heartbeat]   Submitting paper task: \"\(cluster.suggestedTitle)\"...")

            let submission = try await openAI.submitPaperTask(
                notes: clusterNotes,
                title: cluster.suggestedTitle,
                theme: cluster.theme,
                datasetIDs: cluster.datasetIDs
            )
            print("[Heartbeat]   -> Task ID: \(submission.taskID)")

            do {
                try PaperArtifactStore.persistPendingSubmission(
                    submission,
                    title: cluster.suggestedTitle,
                    theme: cluster.theme
                )
            } catch {
                print("[Heartbeat]   -> Failed to persist submission metadata: \(error.localizedDescription)")
            }

            if let artifacts = submission.precomputedArtifacts {
                let paper = Paper(
                    title: artifacts.title,
                    markdown: artifacts.markdown,
                    status: .ready,
                    codexTaskID: submission.taskID,
                    sourceNoteIDs: cluster.noteIDs,
                    figureData: artifacts.figures,
                    lastNotifiedAt: .now
                )
                modelContext.insert(paper)

                do {
                    try PaperArtifactStore.finalizeProvenance(
                        taskID: submission.taskID,
                        title: artifacts.title,
                        modelProvenance: artifacts.provenance
                    )
                } catch {
                    print("[Heartbeat]   -> Failed to finalize local provenance: \(error.localizedDescription)")
                }

                await PaperDocumentService.precomputeIfNeeded(for: paper)
                notifications.notify(paper: paper)
            } else {
                let paper = Paper(
                    title: cluster.suggestedTitle,
                    status: .generating,
                    codexTaskID: submission.taskID,
                    sourceNoteIDs: cluster.noteIDs
                )
                modelContext.insert(paper)
            }

            submitted += 1
        }

        return submitted
    }
}

private enum RecoveryResult {
    case artifacts(PaperArtifacts, source: String)
    case resubmitted(String)
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
