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
    private let notifications: NotificationService
    private let defaults: UserDefaults
    private var advancingResearchRunIDs = Set<String>()

    private let lastRunKey = "com.vineet.sidekick.lastHeartbeatAt"
    private let cooldown: TimeInterval = 20 * 60
    private let remoteRetryGracePeriod: TimeInterval = 8 * 60
    private let remoteNoSignalRetryGracePeriod: TimeInterval = 2 * 60
    private let bundledRemoteRetryGracePeriod: TimeInterval = 5 * 60
    private let failedPaperRetryCooldown: TimeInterval = 20 * 60
    private let deadBundledTaskGracePeriod: TimeInterval = 2 * 60
    private let stalledEventGracePeriod: TimeInterval = 4 * 60
    private let maxRemoteAttempts = 2
    private let maxResearchStageAttempts = 3
    private let maxNoSignalRemoteTaskRestartsPerStage = 1
    private let maxAnalysisRevisionCycles = 6
    private let maxNoteAssessmentPasses = 3
    private let maxConcurrentOAuthRemoteRuns = 1
    private let maxConcurrentAPIKeyRemoteRuns = 2
    private let analysisRevisionCycleAttemptKey = "analysis_revision_cycle"
    private let analysisRevisionCycleLimitMessage = "Analysis revision cycles exceeded the retry budget."
    private let noSignalRemoteRetryAttemptKeyPrefix = "no_signal_remote_retry"

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
            try await admitQueuedResearchRunsIfPossible(modelContext: modelContext)

            phase = .assessingNotes
            print("[Heartbeat] Phase: assessing notes...")
            let submitted = try await discoverNewPaperCandidates(modelContext: modelContext)
            try await admitQueuedResearchRunsIfPossible(modelContext: modelContext)

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
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let runsByPaperID = runs.latestRunsByPaperID()
        let recoverablePaperIDs = Set(
            runs.compactMap { run in
                isFailedResearchRunRecoverable(run) ? run.paperID : nil
            }
        )
        let inFlightPapers = papers.filter { paper in
            paper.status == .generating || (paper.status == .failed && recoverablePaperIDs.contains(paper.id))
        }
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        print("[Heartbeat] Found \(inFlightPapers.count) in-flight paper(s).")

        for paper in inFlightPapers {
            defer {
                persistModelChangesIfPossible(in: modelContext, context: "paper heartbeat state")
            }

            print("[Heartbeat]   Checking task \(paper.codexTaskID) for \"\(paper.title)\"...")

            if let run = runsByPaperID[paper.id] {
                if run.status == .queued {
                    continue
                }

                do {
                    try await resolveResearchRun(run, paper: paper, notesByID: notesByID)
                } catch {
                    print("[Heartbeat]   -> Research run error: \(error.localizedDescription)")
                }
                continue
            }

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

        persistModelChangesIfPossible(in: paper.modelContext, context: "paper artifacts")
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

        guard submission.attemptCount >= maxRemoteAttempts else {
            return false
        }

        return isStalled(snapshot: snapshot, submission: submission)
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

        guard force || shouldAttemptRecovery(snapshot: snapshot, submission: submission) else {
            return nil
        }

        guard submission.attemptCount < maxRemoteAttempts else {
            return nil
        }

        let notes = paper.sourceNoteIDs.compactMap { notesByID[$0] }
        guard !notes.isEmpty else {
            return nil
        }

        print("[Heartbeat]   -> Triggering remote retry. \(progressDescription(snapshot))")

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

        return .resubmitted(resubmission.taskID)
    }

    private func shouldAttemptRecovery(
        snapshot: PaperTaskProgressSnapshot,
        submission: PaperArtifactStore.PendingSubmissionSnapshot
    ) -> Bool {
        return submission.attemptCount < maxRemoteAttempts
            && isStalled(snapshot: snapshot, submission: submission)
    }

    private func isStalled(
        snapshot: PaperTaskProgressSnapshot,
        submission: PaperArtifactStore.PendingSubmissionSnapshot
    ) -> Bool {
        let now = Date()
        let taskStart = snapshot.taskCreatedAt ?? snapshot.assistantTurnCreatedAt ?? submission.createdAt
        let lastProgressAt = snapshot.latestEventAt ?? snapshot.assistantTurnCreatedAt ?? taskStart

        let taskAge = now.timeIntervalSince(taskStart)
        let progressAge = now.timeIntervalSince(lastProgressAt)
        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retryGracePeriod =
            snapshot.outputCharacterCount == 0 && latestEvent.isEmpty && snapshot.latestEventAt == nil
            ? remoteNoSignalRetryGracePeriod
            : remoteRetryGracePeriod

        return taskAge >= retryGracePeriod
            && (snapshot.outputCharacterCount == 0 || progressAge >= stalledEventGracePeriod)
    }

    private func progressDescription(_ snapshot: PaperTaskProgressSnapshot) -> String {
        let now = Date()
        let taskAgeSeconds = snapshot.taskCreatedAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        let progressAgeSeconds = snapshot.latestEventAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        let latestEvent = snapshot.latestEventText ?? "<none>"
        let environmentLabel = snapshot.environmentLabel ?? "<none>"
        let networkMode = snapshot.environmentNetworkMode ?? "<unknown>"

        return "status=\(snapshot.status) task_age_s=\(taskAgeSeconds) " +
            "latest_event_age_s=\(progressAgeSeconds) output_chars=\(snapshot.outputCharacterCount) " +
            "env=\"\(environmentLabel)\" network=\(networkMode) latest_event=\"\(latestEvent)\""
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
            print("[Heartbeat]   -> Failed to save \(context): \(error.localizedDescription)")
        }
    }

    private func withResearchRunAdvanceLock(
        _ run: ResearchRun,
        operation: () async throws -> Void
    ) async throws {
        guard advancingResearchRunIDs.insert(run.runID).inserted else {
            print("[Heartbeat]   -> Research run \(run.runID) is already advancing; skipping duplicate trigger.")
            return
        }

        defer {
            advancingResearchRunIDs.remove(run.runID)
        }

        try await operation()
    }

    private func scheduleResearchRunAdvance(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note]
    ) {
        guard !advancingResearchRunIDs.contains(run.runID) else {
            print("[Heartbeat]   -> Research run \(run.runID) is already advancing in the background.")
            return
        }

        Task { @MainActor in
            do {
                try await self.withResearchRunAdvanceLock(run) {
                    try await self.advanceResearchRun(run, paper: paper, notes: notes)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[Heartbeat]   -> Background advancement failed for \(run.runID): \(message)")
            }
        }
    }

    private func shouldRescueDeadBundledTask(
        run: ResearchRun,
        snapshot: PaperTaskProgressSnapshot
    ) -> Bool {
        let latestProgress = run.latestProgressMessage?.lowercased() ?? ""
        guard latestProgress.contains("bundled") else {
            return false
        }

        let normalizedStatus = snapshot.status.lowercased()
        guard ["pending", "queued", "in_progress", "incomplete"].contains(normalizedStatus) else {
            return false
        }

        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard latestEvent.isEmpty, snapshot.outputCharacterCount == 0 else {
            return false
        }

        let networkMode = snapshot.environmentNetworkMode?.lowercased() ?? ""
        guard networkMode == "off" else {
            return false
        }

        let taskStart = snapshot.taskCreatedAt
            ?? snapshot.assistantTurnCreatedAt
            ?? run.currentStageStartedAt
            ?? run.updatedAt

        return Date().timeIntervalSince(taskStart) >= deadBundledTaskGracePeriod
    }

    private func resolveResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        notesByID: [UUID: Note]
    ) async throws {
        if shouldRetryLatestVerification(for: run) {
            paper.status = .generating
            run.resetAttemptCount(for: .verify)
            run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
        } else if shouldRetryQueueRetryBudgetFailure(for: run) {
            paper.status = .generating
            run.resetAttemptCount(for: run.currentStage)
            run.status = .running
        } else if shouldRetryDirectFallbackStage(for: run) {
            paper.status = .generating
            run.resetAttemptCount(for: run.currentStage)
            run.status = .running
        } else if run.status == .failed, pendingAnalysisRevision(for: run.runID) != nil {
            guard run.attemptCount(forKey: analysisRevisionCycleAttemptKey) < maxAnalysisRevisionCycles else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: analysisRevisionCycleLimitMessage
                )
                return
            }

            paper.status = .generating
            run.resetAttemptCount(for: .verify)
            run.markRunning(stage: .analyze, message: "Revising analysis from verification feedback.")
        }

        let notes = run.sourceNoteIDs.compactMap { notesByID[$0] }
        guard !notes.isEmpty else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "The source notes for this research run could not be found."
            )
            return
        }

        try await withResearchRunAdvanceLock(run) {
            try await advanceResearchRun(run, paper: paper, notes: notes)
        }
    }

    private func isFailedResearchRunRecoverable(_ run: ResearchRun) -> Bool {
        pendingAnalysisRevision(for: run.runID) != nil
            || shouldRetryLatestVerification(for: run)
            || shouldRetryQueueRetryBudgetFailure(for: run)
            || shouldRetryDirectFallbackStage(for: run)
    }

    private func shouldRetryLatestVerification(for run: ResearchRun) -> Bool {
        guard run.status == .failed,
              run.currentStage == .verify,
              (run.lastError ?? "").localizedCaseInsensitiveContains("verification exceeded the retry budget."),
              PaperArtifactStore.stageArtifact(
                  ResearchAnalysisArtifact.self,
                  runID: run.runID,
                  stage: .analyze
              ) != nil,
              currentVerificationArtifact(for: run.runID) == nil else {
            return false
        }

        return true
    }

    private func shouldRetryDirectFallbackStage(for run: ResearchRun) -> Bool {
        guard run.status == .failed,
              run.activeTaskID == nil,
              run.currentStage == .inspect || run.currentStage == .analyze else {
            return false
        }

        return shouldRetryResponsesFallback(for: run)
    }

    private func shouldRetryQueueRetryBudgetFailure(for run: ResearchRun) -> Bool {
        guard run.status == .failed,
              run.activeTaskID == nil,
              run.currentStage == .inspect || run.currentStage == .analyze,
              (run.lastError ?? "").localizedCaseInsensitiveContains("exceeded the retry budget.") else {
            return false
        }

        switch run.currentStage {
        case .inspect:
            return PaperArtifactStore.stageArtifact(
                ResearchInspectionArtifact.self,
                runID: run.runID,
                stage: .inspect
            ) == nil
        case .analyze:
            return PaperArtifactStore.stageArtifact(
                ResearchAnalysisArtifact.self,
                runID: run.runID,
                stage: .analyze
            ) == nil
        default:
            return false
        }
    }

    private func advanceResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note]
    ) async throws {
        switch run.currentStage {
        case .plan:
            if PaperArtifactStore.stageArtifact(ResearchPlanArtifact.self, runID: run.runID, stage: .plan) != nil {
                run.markRunning(stage: .inspect, message: ResearchRunStage.inspect.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            try await executePlanStage(run, paper: paper, notes: notes)

        case .inspect:
            if let inspection = PaperArtifactStore.stageArtifact(
                ResearchInspectionArtifact.self,
                runID: run.runID,
                stage: .inspect
            ), !inspectionArtifactIndicatesTransportBlock(inspection) {
                run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let plan = PaperArtifactStore.stageArtifact(
                ResearchPlanArtifact.self,
                runID: run.runID,
                stage: .plan
            ) else {
                run.markRunning(stage: .plan, message: ResearchRunStage.plan.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard try await bindPlannedSourceFamiliesIfNeeded(
                run,
                paper: paper,
                notes: notes,
                plan: plan
            ) else {
                return
            }

            if run.activeTaskID == nil, shouldRetryResponsesFallback(for: run) {
                do {
                    try await performInspectResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        incrementAttempt: false
                    )
                } catch {
                    handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                }
                return
            }

            try await executeInspectStage(run, paper: paper, notes: notes, plan: plan)

        case .analyze:
            let revisionRequest = pendingAnalysisRevision(for: run.runID)

            if PaperArtifactStore.stageArtifact(ResearchAnalysisArtifact.self, runID: run.runID, stage: .analyze) != nil,
               revisionRequest == nil {
                run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let plan = PaperArtifactStore.stageArtifact(
                ResearchPlanArtifact.self,
                runID: run.runID,
                stage: .plan
            ) else {
                run.markRunning(stage: .plan, message: ResearchRunStage.plan.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let inspection = PaperArtifactStore.stageArtifact(
                ResearchInspectionArtifact.self,
                runID: run.runID,
                stage: .inspect
            ) else {
                run.markRunning(stage: .inspect, message: ResearchRunStage.inspect.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            if inspectionArtifactIndicatesTransportBlock(inspection) {
                run.markRunning(stage: .inspect, message: "Re-inspecting the dataset slice after incomplete source access.")
                try persistModelChanges(in: run.modelContext)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            if run.activeTaskID == nil, shouldRetryResponsesFallback(for: run) {
                do {
                    try await performAnalyzeResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        inspection: inspection,
                        revisionRequest: revisionRequest,
                        incrementAttempt: false
                    )
                } catch {
                    handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                }
                return
            }

            try await executeAnalyzeStage(
                run,
                paper: paper,
                notes: notes,
                plan: plan,
                inspection: inspection,
                revisionRequest: revisionRequest
            )

        case .verify:
            if let verification = currentVerificationArtifact(for: run.runID) {
                run.resetAttemptCount(for: .verify)

                if verification.decision == .reviseAnalysis {
                    guard run.attemptCount(forKey: analysisRevisionCycleAttemptKey) < maxAnalysisRevisionCycles else {
                        markResearchRunFailed(
                            run,
                            paper: paper,
                            message: analysisRevisionCycleLimitMessage
                        )
                        return
                    }

                    run.markRunning(stage: .analyze, message: "Revising analysis from verification feedback.")
                    try await advanceResearchRun(run, paper: paper, notes: notes)
                    return
                }

                run.resetAttemptCount(forKey: analysisRevisionCycleAttemptKey)

                guard verification.allowsWriting else {
                    markResearchRunFailed(run, paper: paper, message: verification.blockingMessage)
                    return
                }

                run.markRunning(stage: .write, message: ResearchRunStage.write.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let plan = PaperArtifactStore.stageArtifact(
                ResearchPlanArtifact.self,
                runID: run.runID,
                stage: .plan
            ) else {
                run.markRunning(stage: .plan, message: ResearchRunStage.plan.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let inspection = PaperArtifactStore.stageArtifact(
                ResearchInspectionArtifact.self,
                runID: run.runID,
                stage: .inspect
            ) else {
                run.markRunning(stage: .inspect, message: ResearchRunStage.inspect.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard let analysis = PaperArtifactStore.stageArtifact(
                ResearchAnalysisArtifact.self,
                runID: run.runID,
                stage: .analyze
            ) else {
                run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            try await executeVerifyStage(
                run,
                paper: paper,
                notes: notes,
                plan: plan,
                inspection: inspection,
                analysis: analysis
            )

        case .write:
            guard let verification = PaperArtifactStore.stageArtifact(
                ResearchVerificationArtifact.self,
                runID: run.runID,
                stage: .verify
            ) else {
                run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard verification.allowsWriting else {
                markResearchRunFailed(run, paper: paper, message: verification.blockingMessage)
                return
            }

            guard let analysis = PaperArtifactStore.stageArtifact(
                ResearchAnalysisArtifact.self,
                runID: run.runID,
                stage: .analyze
            ) else {
                run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            if let draft = PaperArtifactStore.stageArtifact(
                ResearchDraftArtifact.self,
                runID: run.runID,
                stage: .write
            ) {
                try await finalizeResearchRun(run, paper: paper, analysis: analysis, draft: draft)
                return
            }

            guard let plan = PaperArtifactStore.stageArtifact(
                ResearchPlanArtifact.self,
                runID: run.runID,
                stage: .plan
            ) else {
                run.markRunning(stage: .plan, message: ResearchRunStage.plan.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            try await executeWriteStage(
                run,
                paper: paper,
                notes: notes,
                plan: plan,
                analysis: analysis,
                verification: verification
            )

        case .typeset:
            guard let analysis = PaperArtifactStore.stageArtifact(
                ResearchAnalysisArtifact.self,
                runID: run.runID,
                stage: .analyze
            ), let draft = PaperArtifactStore.stageArtifact(
                ResearchDraftArtifact.self,
                runID: run.runID,
                stage: .write
            ) else {
                run.markRunning(stage: .write, message: ResearchRunStage.write.title)
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            try await finalizeResearchRun(run, paper: paper, analysis: analysis, draft: draft)
        }
    }

    private func executePlanStage(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note]
    ) async throws {
        guard run.attemptCount(for: .plan) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Planning exceeded the retry budget."
            )
            return
        }

        run.incrementAttempt(for: .plan)
        run.markRunning(stage: .plan, message: "Planning the study from notes and trusted datasets.")
        try persistModelChanges(in: run.modelContext)

        do {
            let artifact = try await openAI.createResearchPlan(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs
            )
            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .plan)
            print("[Heartbeat]   -> Plan stage completed for \(run.runID)")

            guard try await bindPlannedSourceFamiliesIfNeeded(
                run,
                paper: paper,
                notes: notes,
                plan: artifact
            ) else {
                print("[Heartbeat]   -> Holding \(run.runID) after bounded source discovery found no supported fit.")
                return
            }

            run.markRunning(stage: .inspect, message: ResearchRunStage.inspect.title)
            try persistModelChanges(in: run.modelContext)
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            handleResearchStageError(error, run: run, paper: paper, stage: .plan)
        }
    }

    private func bindPlannedSourceFamiliesIfNeeded(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact
    ) async throws -> Bool {
        let binding = await openAI.resolvePlanDatasetBinding(
            plan: plan,
            noteTexts: notes.map(\.content)
        )

        guard !binding.datasets.isEmpty else {
            run.schedulingDisposition = .hold
            paper.status = .generating
            run.markQueued(
                message: "Bounded source discovery could not find a strong source-family fit. Kept queued until a better fit is confirmed.",
                queueState: .held
            )
            try persistModelChanges(in: run.modelContext)
            return false
        }

        if binding.datasets.contains(where: { $0.resolvedSupportTier != .supported }) {
            let message: String
            let primaryTier = binding.datasets.first?.resolvedSupportTier

            switch primaryTier {
            case .supported:
                message = "Bounded source discovery still depends on experimental source families. Kept queued until a supported-only fit is confirmed."
            case .experimental:
                message = "Bounded source discovery selected an experimental source family. Kept queued until a supported fit is confirmed."
            case .disabled:
                message = "Bounded source discovery selected a disabled source family. Kept queued until a supported fit is confirmed."
            case nil:
                message = "Bounded source discovery could not confirm a supported source-family fit. Kept queued until a better fit is confirmed."
            }

            run.schedulingDisposition = .hold
            paper.status = .generating
            run.markQueued(message: message, queueState: .held)
            try persistModelChanges(in: run.modelContext)
            return false
        }

        let allowedDomains = TrustedDatasetRegistry.allowedDomains(for: binding.datasets)
        let sourceSupportTier = binding.datasets.first?.resolvedSupportTier ?? .supported
        var didChange = false

        if run.datasetIDs != binding.datasetIDs {
            run.datasetIDs = binding.datasetIDs
            didChange = true
        }

        if run.allowedDomains != allowedDomains {
            run.allowedDomains = allowedDomains
            didChange = true
        }

        if run.sourceSupportTier != sourceSupportTier {
            run.sourceSupportTier = sourceSupportTier
            didChange = true
        }

        if run.schedulingDisposition != .autoStart {
            run.schedulingDisposition = .autoStart
            didChange = true
        }

        if didChange {
            try persistModelChanges(in: run.modelContext)
        }

        return true
    }

    private func executeInspectStage(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact
    ) async throws {
        if let taskID = run.activeTaskID, !taskID.isEmpty {
            let result = try await openAI.checkResearchInspectionTask(taskID)

            switch result {
            case let .waiting(snapshot):
                persistTaskProgress(snapshot)
                let message = progressMessage(
                    for: snapshot,
                    stage: .inspect,
                    fallback: run.latestProgressMessage ?? ResearchRunStage.inspect.title
                )
                run.updateProgress(message: message, at: snapshot.latestEventAt ?? snapshot.observedAt)
                try persistModelChanges(in: run.modelContext)

                if await prefersBundledResearchFallback(run: run, notes: notes),
                   shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
                    print("[Heartbeat]   -> Inspect stage is attached to an incompatible repo environment; switching to responses fallback.")
                    run.activeTaskID = nil

                    do {
                        try await performInspectResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                if !(await prefersBundledResearchFallback(run: run, notes: notes)),
                   shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
                    print("[Heartbeat]   -> Inspect stage is attached to an incompatible repo environment; switching to direct Code Interpreter fallback.")
                    run.activeTaskID = nil

                    do {
                        try await performInspectNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                if shouldRescueDeadBundledTask(run: run, snapshot: snapshot) {
                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Inspect stage bundled task looks dead on \(environmentLabel); rerouting without spending another stage attempt.")
                    await openAI.quarantineSelfContainedBundleEnvironment(snapshot.environmentID)
                    run.activeTaskID = nil

                    do {
                        try await performInspectResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                if shouldRestartResearchTask(run: run, snapshot: snapshot, stage: .inspect) {
                    let noSignalTask = isNoSignalRemoteTask(snapshot)
                    if noSignalTask {
                        let restartCount = incrementNoSignalRestartCount(for: run, stage: .inspect)
                        await quarantineEnvironmentForSilentTask(snapshot)
                        guard restartCount <= maxNoSignalRemoteTaskRestartsPerStage else {
                            print("[Heartbeat]   -> Inspect stage for \(run.runID) exhausted the silent-worker budget; moving on.")
                            markResearchRunFailed(
                                run,
                                paper: paper,
                                message: noSignalFailureMessage(for: .inspect)
                            )
                            return
                        }

                        print("[Heartbeat]   -> Inspect stage for \(run.runID) never emitted progress; retrying on a fresh worker.")
                    } else {
                        resetNoSignalRestartCount(for: run, stage: .inspect)
                        print("[Heartbeat]   -> Inspect stage stalled for \(run.runID); restarting from checkpoint.")
                    }

                    run.activeTaskID = nil
                    refundRetryBudgetIfNeeded(run: run, stage: .inspect, snapshot: snapshot)

                    if await prefersBundledResearchFallback(run: run, notes: notes),
                       shouldUseResponsesFallback(for: snapshot) {
                        do {
                            try await performInspectResponsesFallback(
                                run,
                                paper: paper,
                                notes: notes,
                                plan: plan,
                                incrementAttempt: true
                            )
                        } catch {
                            handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                        }
                        return
                    }

                    try await startResearchInspectionTask(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        preserveNoSignalRestartBudget: noSignalTask
                    )
                }

            case let .completed(snapshot, artifact):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

                if await shouldRerouteInspectionArtifactToBundledFallback(
                    artifact,
                    run: run,
                    notes: notes
                ) {
                    print("[Heartbeat]   -> Inspect task for \(run.runID) only returned transport-block diagnostics; rerouting to bundled fallback.")
                    do {
                        try await performInspectResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                if inspectionArtifactIndicatesTransportBlock(artifact) {
                    guard run.attemptCount(for: .inspect) < maxResearchStageAttempts else {
                        print("[Heartbeat]   -> Inspect stage for \(run.runID) exhausted remote task retries; switching to direct Code Interpreter fallback.")
                        do {
                            try await performInspectNetworkedResponsesFallback(
                                run,
                                paper: paper,
                                notes: notes,
                                plan: plan,
                                incrementAttempt: false
                            )
                        } catch {
                            markResearchRunFailed(
                                run,
                                paper: paper,
                                message: error.localizedDescription
                            )
                        }
                        return
                    }

                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Inspect stage for \(run.runID) hit approved-domain access blockers on \(environmentLabel); retrying on a different environment.")
                    await openAI.quarantineNetworkedSelfContainedEnvironment(snapshot.environmentID)

                    do {
                        try await startResearchInspectionTask(run, paper: paper, notes: notes, plan: plan)
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .inspect)
                run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
                try persistModelChanges(in: run.modelContext)
                print("[Heartbeat]   -> Inspect stage completed for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)

            case let .failed(snapshot, message):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

                if shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot),
                   !(await prefersBundledResearchFallback(run: run, notes: notes)) {
                    do {
                        try await performInspectNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                    }
                    return
                }

                if run.attemptCount(for: .inspect) < maxResearchStageAttempts {
                    print("[Heartbeat]   -> Inspect stage failed for \(run.runID); retrying same stage.")
                    try await startResearchInspectionTask(run, paper: paper, notes: notes, plan: plan)
                } else {
                    markResearchRunFailed(run, paper: paper, message: message)
                }
            }

            return
        }

        try await startResearchInspectionTask(run, paper: paper, notes: notes, plan: plan)
    }

    private func startResearchInspectionTask(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        preserveNoSignalRestartBudget: Bool = false
    ) async throws {
        guard run.attemptCount(for: .inspect) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Dataset inspection exceeded the retry budget."
            )
            return
        }

        if !preserveNoSignalRestartBudget {
            resetNoSignalRestartCount(for: run, stage: .inspect)
        }

        let shouldUseBundledFallback = await prefersBundledResearchFallback(run: run, notes: notes)
        run.incrementAttempt(for: .inspect)

        if resolvedExecutionBackend(for: run) == .openAIAPIKey {
            do {
                if shouldUseBundledFallback {
                    try await performInspectResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        incrementAttempt: false
                    )
                } else {
                    try await performInspectNetworkedResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        incrementAttempt: false
                    )
                }
            } catch {
                handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
            }
            return
        }

        if shouldUseBundledFallback {
            print("[Heartbeat]   -> Inspect stage for \(run.runID) is supported by a bundled cohort fallback; skipping the live remote path.")
            do {
                try await performInspectResponsesFallback(
                    run,
                    paper: paper,
                    notes: notes,
                    plan: plan,
                    incrementAttempt: false
                )
            } catch {
                handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
            }
            return
        }

        run.markRunning(stage: .inspect, message: "Resolving and inspecting the dataset slice.")
        try persistModelChanges(in: run.modelContext)

        do {
            let taskID = try await openAI.startResearchInspectionTask(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                allowedDomains: run.allowedDomains,
                plan: plan
            )
            run.activeTaskID = taskID
            run.updateProgress(message: "Remote dataset inspection is running.", at: .now)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Inspect task started as \(taskID)")
        } catch {
            if shouldUseResponsesFallback(after: error) {
                do {
                    if shouldUseBundledFallback {
                        try await performInspectResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    } else {
                        try await performInspectNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            incrementAttempt: false
                        )
                    }
                } catch {
                    handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
                }
                return
            }

            handleResearchStageError(error, run: run, paper: paper, stage: .inspect)
        }
    }

    private func executeAnalyzeStage(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact?
    ) async throws {
        if let taskID = run.activeTaskID, !taskID.isEmpty {
            let result = try await openAI.checkResearchAnalysisTask(taskID)

            switch result {
            case let .waiting(snapshot):
                persistTaskProgress(snapshot)
                let message = progressMessage(
                    for: snapshot,
                    stage: .analyze,
                    fallback: run.latestProgressMessage ?? ResearchRunStage.analyze.title
                )
                run.updateProgress(message: message, at: snapshot.latestEventAt ?? snapshot.observedAt)
                try persistModelChanges(in: run.modelContext)

                if await prefersBundledResearchFallback(run: run, notes: notes),
                   shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
                    print("[Heartbeat]   -> Analysis stage is attached to an incompatible repo environment; switching to responses fallback.")
                    run.activeTaskID = nil

                    do {
                        try await performAnalyzeResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                if !(await prefersBundledResearchFallback(run: run, notes: notes)),
                   shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
                    print("[Heartbeat]   -> Analysis stage is attached to an incompatible repo environment; switching to direct Code Interpreter fallback.")
                    run.activeTaskID = nil

                    do {
                        try await performAnalyzeNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                if shouldRescueDeadBundledTask(run: run, snapshot: snapshot) {
                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Analysis stage bundled task looks dead on \(environmentLabel); rerouting without spending another stage attempt.")
                    await openAI.quarantineSelfContainedBundleEnvironment(snapshot.environmentID)
                    run.activeTaskID = nil

                    do {
                        try await performAnalyzeResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                if shouldRestartResearchTask(run: run, snapshot: snapshot, stage: .analyze) {
                    let noSignalTask = isNoSignalRemoteTask(snapshot)
                    if noSignalTask {
                        let restartCount = incrementNoSignalRestartCount(for: run, stage: .analyze)
                        await quarantineEnvironmentForSilentTask(snapshot)
                        guard restartCount <= maxNoSignalRemoteTaskRestartsPerStage else {
                            print("[Heartbeat]   -> Analysis stage for \(run.runID) exhausted the silent-worker budget; moving on.")
                            markResearchRunFailed(
                                run,
                                paper: paper,
                                message: noSignalFailureMessage(for: .analyze)
                            )
                            return
                        }

                        print("[Heartbeat]   -> Analysis stage for \(run.runID) never emitted progress; retrying on a fresh worker.")
                    } else {
                        resetNoSignalRestartCount(for: run, stage: .analyze)
                        print("[Heartbeat]   -> Analysis stage stalled for \(run.runID); restarting from checkpoint.")
                    }

                    run.activeTaskID = nil
                    refundRetryBudgetIfNeeded(run: run, stage: .analyze, snapshot: snapshot)

                    if revisionRequest != nil,
                       await prefersBundledResearchFallback(run: run, notes: notes) {
                        do {
                            try await performAnalyzeResponsesFallback(
                                run,
                                paper: paper,
                                notes: notes,
                                plan: plan,
                                inspection: inspection,
                                revisionRequest: revisionRequest,
                                incrementAttempt: false
                            )
                        } catch {
                            handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                        }
                        return
                    }

                    if await prefersBundledResearchFallback(run: run, notes: notes),
                       shouldUseResponsesFallback(for: snapshot) {
                        do {
                            try await performAnalyzeResponsesFallback(
                                run,
                                paper: paper,
                                notes: notes,
                                plan: plan,
                                inspection: inspection,
                                revisionRequest: revisionRequest,
                                incrementAttempt: true
                            )
                        } catch {
                            handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                        }
                        return
                    }

                    try await startResearchAnalysisTask(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        inspection: inspection,
                        revisionRequest: revisionRequest,
                        preserveNoSignalRestartBudget: noSignalTask
                    )
                }

            case let .completed(snapshot, artifact):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

                if await shouldRerouteAnalysisArtifactToBundledFallback(
                    artifact,
                    run: run,
                    notes: notes
                ) {
                    print("[Heartbeat]   -> Analysis task for \(run.runID) only returned transport-block diagnostics; rerouting to bundled fallback.")
                    do {
                        try await performAnalyzeResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                if analysisArtifactIndicatesTransportBlock(artifact) {
                    if revisionRequest != nil {
                        guard run.attemptCount(for: .analyze) < maxResearchStageAttempts else {
                            print("[Heartbeat]   -> Analysis stage for \(run.runID) exhausted remote revision retries; switching to direct Code Interpreter fallback.")
                            do {
                                try await performAnalyzeNetworkedResponsesFallback(
                                    run,
                                    paper: paper,
                                    notes: notes,
                                    plan: plan,
                                    inspection: inspection,
                                    revisionRequest: revisionRequest,
                                    incrementAttempt: false
                                )
                            } catch {
                                markResearchRunFailed(
                                    run,
                                    paper: paper,
                                    message: error.localizedDescription
                                )
                            }
                            return
                        }
                        run.incrementAttempt(for: .analyze)
                    } else if run.attemptCount(for: .analyze) >= maxResearchStageAttempts {
                        print("[Heartbeat]   -> Analysis stage for \(run.runID) exhausted remote task retries; switching to direct Code Interpreter fallback.")
                        do {
                            try await performAnalyzeNetworkedResponsesFallback(
                                run,
                                paper: paper,
                                notes: notes,
                                plan: plan,
                                inspection: inspection,
                                revisionRequest: revisionRequest,
                                incrementAttempt: false
                            )
                        } catch {
                            markResearchRunFailed(
                                run,
                                paper: paper,
                                message: error.localizedDescription
                            )
                        }
                        return
                    }

                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Analysis stage for \(run.runID) hit approved-domain access blockers on \(environmentLabel); retrying on a different environment.")
                    await openAI.quarantineNetworkedSelfContainedEnvironment(snapshot.environmentID)

                    do {
                        try await startResearchAnalysisTask(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .analyze)
                run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
                try persistModelChanges(in: run.modelContext)
                print("[Heartbeat]   -> Analysis stage completed for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)

            case let .failed(snapshot, message):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

                if shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot),
                   !(await prefersBundledResearchFallback(run: run, notes: notes)) {
                    do {
                        try await performAnalyzeNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                    return
                }

                if revisionRequest != nil,
                   await prefersBundledResearchFallback(run: run, notes: notes) {
                    print("[Heartbeat]   -> Analysis revision stage failed for \(run.runID); retrying checkpointed analysis.")
                    do {
                        try await performAnalyzeResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } catch {
                        handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                    }
                } else if revisionRequest != nil || run.attemptCount(for: .analyze) < maxResearchStageAttempts {
                    print("[Heartbeat]   -> Analysis stage failed for \(run.runID); retrying same stage.")
                    try await startResearchAnalysisTask(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        inspection: inspection,
                        revisionRequest: revisionRequest
                    )
                } else {
                    markResearchRunFailed(run, paper: paper, message: message)
                }
            }

            return
        }

        if revisionRequest != nil,
           await prefersBundledResearchFallback(run: run, notes: notes) {
            do {
                try await performAnalyzeResponsesFallback(
                    run,
                    paper: paper,
                    notes: notes,
                    plan: plan,
                    inspection: inspection,
                    revisionRequest: revisionRequest,
                    incrementAttempt: false
                )
            } catch {
                handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
            }
            return
        }

        try await startResearchAnalysisTask(
            run,
            paper: paper,
            notes: notes,
            plan: plan,
            inspection: inspection,
            revisionRequest: revisionRequest
        )
    }

    private func startResearchAnalysisTask(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact?,
        preserveNoSignalRestartBudget: Bool = false
    ) async throws {
        let isRevisionRetry = revisionRequest != nil

        guard isRevisionRetry || run.attemptCount(for: .analyze) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Analysis exceeded the retry budget."
            )
            return
        }

        if !preserveNoSignalRestartBudget {
            resetNoSignalRestartCount(for: run, stage: .analyze)
        }

        let shouldUseBundledFallback: Bool
        if isRevisionRetry {
            shouldUseBundledFallback = false
        } else {
            shouldUseBundledFallback = await prefersBundledResearchFallback(run: run, notes: notes)
        }

        if !isRevisionRetry {
            run.incrementAttempt(for: .analyze)
        }

        if resolvedExecutionBackend(for: run) == .openAIAPIKey {
            let shouldUseBundledAPIExecution = await prefersBundledResearchFallback(run: run, notes: notes)

            do {
                if shouldUseBundledAPIExecution {
                    try await performAnalyzeResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        inspection: inspection,
                        revisionRequest: revisionRequest,
                        incrementAttempt: false
                    )
                } else {
                    try await performAnalyzeNetworkedResponsesFallback(
                        run,
                        paper: paper,
                        notes: notes,
                        plan: plan,
                        inspection: inspection,
                        revisionRequest: revisionRequest,
                        incrementAttempt: false
                    )
                }
            } catch {
                handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
            }
            return
        }

        if shouldUseBundledFallback {
            print("[Heartbeat]   -> Analysis stage for \(run.runID) is supported by a bundled cohort fallback; skipping the live remote path.")
            do {
                try await performAnalyzeResponsesFallback(
                    run,
                    paper: paper,
                    notes: notes,
                    plan: plan,
                    inspection: inspection,
                    revisionRequest: revisionRequest,
                    incrementAttempt: false
                )
            } catch {
                handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
            }
            return
        }

        run.markRunning(
            stage: .analyze,
            message: isRevisionRetry
                ? "Re-running analysis with verification revisions."
                : "Starting remote analysis task."
        )
        try persistModelChanges(in: run.modelContext)

        do {
            let taskID = try await openAI.startResearchAnalysisTask(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                allowedDomains: run.allowedDomains,
                plan: plan,
                inspection: inspection,
                revisionRequest: revisionRequest
            )
            run.activeTaskID = taskID
            run.updateProgress(message: "Remote analysis is running.", at: .now)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Analysis task started as \(taskID)")
        } catch {
            let shouldUseBundledFallback = await prefersBundledResearchFallback(run: run, notes: notes)

            if shouldUseResponsesFallback(after: error) {
                do {
                    if shouldUseBundledFallback {
                        try await performAnalyzeResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    } else {
                        try await performAnalyzeNetworkedResponsesFallback(
                            run,
                            paper: paper,
                            notes: notes,
                            plan: plan,
                            inspection: inspection,
                            revisionRequest: revisionRequest,
                            incrementAttempt: false
                        )
                    }
                } catch {
                    handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
                }
                return
            }

            handleResearchStageError(error, run: run, paper: paper, stage: .analyze)
        }
    }

    private func executeVerifyStage(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        analysis: ResearchAnalysisArtifact
    ) async throws {
        guard run.attemptCount(for: .verify) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Verification exceeded the retry budget."
            )
            return
        }

        run.incrementAttempt(for: .verify)
        run.markRunning(stage: .verify, message: "Verifying that the saved artifacts support a publishable paper.")
        try persistModelChanges(in: run.modelContext)

        do {
            let verification = try await openAI.verifyResearchAnalysis(
                notes: notes,
                title: run.title,
                theme: run.theme,
                plan: plan,
                inspection: inspection,
                analysis: analysis
            )
            let normalizedVerification = normalizedVerificationArtifact(
                verification,
                analysis: analysis
            )
            try PaperArtifactStore.persistStageArtifact(normalizedVerification, runID: run.runID, stage: .verify)
            run.resetAttemptCount(for: .verify)

            if normalizedVerification.decision == .reviseAnalysis {
                guard run.attemptCount(forKey: analysisRevisionCycleAttemptKey) < maxAnalysisRevisionCycles else {
                    markResearchRunFailed(
                        run,
                        paper: paper,
                        message: analysisRevisionCycleLimitMessage
                    )
                    return
                }

                run.incrementAttempt(forKey: analysisRevisionCycleAttemptKey)
                run.markRunning(stage: .analyze, message: "Revising analysis from verification feedback.")
                try persistModelChanges(in: run.modelContext)
                print("[Heartbeat]   -> Verification requested analysis revisions for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            run.resetAttemptCount(forKey: analysisRevisionCycleAttemptKey)

            guard normalizedVerification.allowsWriting else {
                print("[Heartbeat]   -> Verification blocked drafting for \(run.runID)")
                markResearchRunFailed(run, paper: paper, message: normalizedVerification.blockingMessage)
                return
            }

            run.markRunning(stage: .write, message: ResearchRunStage.write.title)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Verify stage completed for \(run.runID)")
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            handleResearchStageError(error, run: run, paper: paper, stage: .verify)
        }
    }

    private func executeWriteStage(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        analysis: ResearchAnalysisArtifact,
        verification: ResearchVerificationArtifact
    ) async throws {
        guard run.attemptCount(for: .write) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Paper drafting exceeded the retry budget."
            )
            return
        }

        run.incrementAttempt(for: .write)
        run.markRunning(stage: .write, message: "Drafting the paper from checkpointed analysis.")
        try persistModelChanges(in: run.modelContext)

        do {
            let draft = try await openAI.writeResearchPaper(
                notes: notes,
                title: run.title,
                theme: run.theme,
                plan: plan,
                analysis: analysis,
                verification: verification
            )
            try PaperArtifactStore.persistStageArtifact(draft, runID: run.runID, stage: .write)
            run.markRunning(stage: .typeset, message: ResearchRunStage.typeset.title)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Write stage completed for \(run.runID)")
            try await finalizeResearchRun(run, paper: paper, analysis: analysis, draft: draft)
        } catch {
            handleResearchStageError(error, run: run, paper: paper, stage: .write)
        }
    }

    private func finalizeResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        analysis: ResearchAnalysisArtifact,
        draft: ResearchDraftArtifact
    ) async throws {
        run.markRunning(stage: .typeset, message: "Preparing the final PDF bundle.")
        paper.title = draft.title
        paper.markdown = draft.markdown
        paper.figureData = analysis.figureData
        paper.codexTaskID = run.runID
        paper.status = .ready
        run.title = draft.title

        do {
            try PaperArtifactStore.finalizeProvenance(
                taskID: run.runID,
                title: draft.title,
                modelProvenance: analysis.provenance
            )
        } catch {
            print("[Heartbeat]   -> Failed to persist staged provenance: \(error.localizedDescription)")
        }

        await PaperDocumentService.precomputeIfNeeded(for: paper)

        if paper.lastNotifiedAt == nil {
            notifications.notify(paper: paper)
            paper.lastNotifiedAt = .now
        }

        run.markCompleted(message: "Paper ready.")
        try persistModelChanges(in: run.modelContext)
        print("[Heartbeat]   -> Research run complete for \(run.runID)")
    }

    private func performInspectNetworkedResponsesFallback(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        incrementAttempt: Bool
    ) async throws {
        resetNoSignalRestartCount(for: run, stage: .inspect)

        if incrementAttempt {
            guard run.attemptCount(for: .inspect) < maxResearchStageAttempts else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: "Dataset inspection exceeded the retry budget."
                )
                return
            }
            run.incrementAttempt(for: .inspect)
        }

        run.activeTaskID = nil
        let isAPIKeyExecution = resolvedExecutionBackend(for: run) == .openAIAPIKey
        run.markRunning(
            stage: .inspect,
            message: isAPIKeyExecution
                ? "Inspecting the dataset with your OpenAI API key."
                : "Inspecting the dataset via direct Code Interpreter fallback."
        )
        try persistModelChanges(in: run.modelContext)

        let artifact = try await openAI.runNetworkedResearchInspectionResponse(
            notes: notes,
            title: run.title,
            theme: run.theme,
            datasetIDs: run.datasetIDs,
            allowedDomains: run.allowedDomains,
            plan: plan
        )

        guard !inspectionArtifactIndicatesTransportBlock(artifact) else {
            throw NSError(
                domain: "com.vineet.Sidekick.HeartbeatManager",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Approved-domain access remained blocked in the direct Code Interpreter inspection fallback."
                ]
            )
        }

        try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .inspect)
        run.activeTaskID = nil
        run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
        try persistModelChanges(in: run.modelContext)
        print("[Heartbeat]   -> Inspect direct fallback completed for \(run.runID)")
        try await advanceResearchRun(run, paper: paper, notes: notes)
    }

    private func performInspectResponsesFallback(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        incrementAttempt: Bool
    ) async throws {
        resetNoSignalRestartCount(for: run, stage: .inspect)

        if incrementAttempt {
            guard run.attemptCount(for: .inspect) < maxResearchStageAttempts else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: "Dataset inspection exceeded the retry budget."
                )
                return
            }
            run.incrementAttempt(for: .inspect)
        }

        run.activeTaskID = nil
        let isAPIKeyExecution = resolvedExecutionBackend(for: run) == .openAIAPIKey
        run.markRunning(
            stage: .inspect,
            message: isAPIKeyExecution
                ? "Inspecting the bundled dataset slice with your OpenAI API key."
                : "Inspecting the dataset via bundled Code Interpreter fallback."
        )
        try persistModelChanges(in: run.modelContext)

        do {
            let artifact = try await openAI.runResearchInspectionFallback(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                plan: plan
            )

            guard !inspectionArtifactIndicatesTransportBlock(artifact) else {
                throw NSError(
                    domain: "com.vineet.Sidekick.HeartbeatManager",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Bundled Code Interpreter inspection fallback returned only transport-block diagnostics."
                    ]
                )
            }

            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .inspect)
            run.activeTaskID = nil
            run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Inspect bundled Code Interpreter fallback completed for \(run.runID)")
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            guard !isAPIKeyExecution,
                  shouldUseBundledResearchTaskFallback(after: error) else {
                throw error
            }

            let taskID = try await openAI.startBundledResearchInspectionTask(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                plan: plan
            )
            run.activeTaskID = taskID
            run.updateProgress(message: "Remote bundled inspection is running.", at: .now)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Inspect bundled fallback task started as \(taskID)")
        }
    }

    private func performAnalyzeNetworkedResponsesFallback(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact?,
        incrementAttempt: Bool
    ) async throws {
        resetNoSignalRestartCount(for: run, stage: .analyze)

        if incrementAttempt {
            guard run.attemptCount(for: .analyze) < maxResearchStageAttempts else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: "Analysis exceeded the retry budget."
                )
                return
            }
            run.incrementAttempt(for: .analyze)
        }

        run.activeTaskID = nil
        let isAPIKeyExecution = resolvedExecutionBackend(for: run) == .openAIAPIKey
        run.markRunning(
            stage: .analyze,
            message: isAPIKeyExecution
                ? "Running the analysis with your OpenAI API key."
                : "Running analysis via direct Code Interpreter fallback."
        )
        try persistModelChanges(in: run.modelContext)

        let artifact = try await openAI.runNetworkedResearchAnalysisResponse(
            notes: notes,
            title: run.title,
            theme: run.theme,
            datasetIDs: run.datasetIDs,
            allowedDomains: run.allowedDomains,
            plan: plan,
            inspection: inspection,
            revisionRequest: revisionRequest
        )

        guard !analysisArtifactIndicatesTransportBlock(artifact) else {
            throw NSError(
                domain: "com.vineet.Sidekick.HeartbeatManager",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Approved-domain access remained blocked in the direct Code Interpreter analysis fallback."
                ]
            )
        }

        try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .analyze)
        run.activeTaskID = nil
        run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
        try persistModelChanges(in: run.modelContext)
        print("[Heartbeat]   -> Analysis direct fallback completed for \(run.runID)")
        try await advanceResearchRun(run, paper: paper, notes: notes)
    }

    private func performAnalyzeResponsesFallback(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        inspection: ResearchInspectionArtifact,
        revisionRequest: ResearchVerificationArtifact?,
        incrementAttempt: Bool
    ) async throws {
        resetNoSignalRestartCount(for: run, stage: .analyze)

        if incrementAttempt {
            guard run.attemptCount(for: .analyze) < maxResearchStageAttempts else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: "Analysis exceeded the retry budget."
                )
                return
            }
            run.incrementAttempt(for: .analyze)
        }

        run.activeTaskID = nil
        let isAPIKeyExecution = resolvedExecutionBackend(for: run) == .openAIAPIKey
        run.markRunning(
            stage: .analyze,
            message: isAPIKeyExecution
                ? "Running bundled analysis with your OpenAI API key."
                : "Running analysis via bundled Code Interpreter fallback."
        )
        try persistModelChanges(in: run.modelContext)

        do {
            let artifact = try await openAI.runResearchAnalysisFallback(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                plan: plan,
                inspection: inspection,
                revisionRequest: revisionRequest
            )

            guard !analysisArtifactIndicatesTransportBlock(artifact) else {
                throw NSError(
                    domain: "com.vineet.Sidekick.HeartbeatManager",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Bundled Code Interpreter analysis fallback returned only transport-block diagnostics."
                    ]
                )
            }

            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .analyze)
            run.activeTaskID = nil
            run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Analysis bundled Code Interpreter fallback completed for \(run.runID)")
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            guard !isAPIKeyExecution,
                  shouldUseBundledResearchTaskFallback(after: error) else {
                throw error
            }

            let taskID = try await openAI.startBundledResearchAnalysisTask(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                plan: plan,
                inspection: inspection,
                revisionRequest: revisionRequest
            )
            run.activeTaskID = taskID
            run.updateProgress(message: "Remote bundled analysis is running.", at: .now)
            try persistModelChanges(in: run.modelContext)
            print("[Heartbeat]   -> Analysis bundled fallback task started as \(taskID)")
        }
    }

    private func shouldRestartResearchTask(
        run: ResearchRun,
        snapshot: PaperTaskProgressSnapshot,
        stage: ResearchRunStage
    ) -> Bool {
        guard run.attemptCount(for: stage) < maxResearchStageAttempts else {
            return false
        }

        let now = Date()
        let taskStart = snapshot.taskCreatedAt
            ?? snapshot.assistantTurnCreatedAt
            ?? run.currentStageStartedAt
            ?? run.updatedAt
        let lastProgress = snapshot.latestEventAt
            ?? snapshot.assistantTurnCreatedAt
            ?? taskStart

        let taskAge = now.timeIntervalSince(taskStart)
        let progressAge = now.timeIntervalSince(lastProgress)
        let latestProgress = run.latestProgressMessage?.lowercased() ?? ""
        let networkMode = snapshot.environmentNetworkMode?.lowercased() ?? ""
        let noSignalRemoteTask = isNoSignalRemoteTask(snapshot)
        let retryGracePeriod =
            latestProgress.contains("bundled") && networkMode == "on"
            ? bundledRemoteRetryGracePeriod
            : (noSignalRemoteTask ? remoteNoSignalRetryGracePeriod : remoteRetryGracePeriod)

        return taskAge >= retryGracePeriod
            && (snapshot.outputCharacterCount == 0 || progressAge >= stalledEventGracePeriod)
    }

    private func refundRetryBudgetIfNeeded(
        run: ResearchRun,
        stage: ResearchRunStage,
        snapshot: PaperTaskProgressSnapshot
    ) {
        guard isNoSignalRemoteTask(snapshot) else {
            return
        }

        run.decrementAttempt(for: stage)
    }

    private func noSignalRetryAttemptKey(for stage: ResearchRunStage) -> String {
        "\(noSignalRemoteRetryAttemptKeyPrefix):\(stage.rawValue)"
    }

    private func incrementNoSignalRestartCount(
        for run: ResearchRun,
        stage: ResearchRunStage
    ) -> Int {
        let key = noSignalRetryAttemptKey(for: stage)
        run.incrementAttempt(forKey: key)
        return run.attemptCount(forKey: key)
    }

    private func resetNoSignalRestartCount(
        for run: ResearchRun,
        stage: ResearchRunStage
    ) {
        run.resetAttemptCount(forKey: noSignalRetryAttemptKey(for: stage))
    }

    private func noSignalFailureMessage(for stage: ResearchRunStage) -> String {
        "The ChatGPT remote worker stayed silent while \(stage.title.lowercased()) on two fresh attempts, so Sidekick moved on to the next queued paper. Retry this paper later."
    }

    private func quarantineEnvironmentForSilentTask(_ snapshot: PaperTaskProgressSnapshot) async {
        let networkMode = snapshot.environmentNetworkMode?.lowercased() ?? ""
        if networkMode == "off" {
            await openAI.quarantineSelfContainedBundleEnvironment(snapshot.environmentID)
        } else {
            await openAI.quarantineRepositoryBoundEnvironment(snapshot.environmentID)
        }
    }

    private func isNoSignalRemoteTask(_ snapshot: PaperTaskProgressSnapshot) -> Bool {
        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return snapshot.outputCharacterCount == 0
            && latestEvent.isEmpty
            && snapshot.latestEventAt == nil
    }

    private func progressMessage(
        for snapshot: PaperTaskProgressSnapshot,
        stage: ResearchRunStage,
        fallback: String
    ) -> String {
        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !latestEvent.isEmpty {
            return latestEvent
        }

        let status = snapshot.status.lowercased()
        let environmentLabel = snapshot.environmentLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = environmentLabel?.isEmpty == false
            ? environmentLabel!
            : (snapshot.environmentID ?? "the remote worker")

        let taskStart = snapshot.taskCreatedAt ?? snapshot.assistantTurnCreatedAt ?? snapshot.observedAt
        let ageText = conciseElapsedTime(since: taskStart, now: snapshot.observedAt)

        switch status {
        case "pending", "queued":
            return "Queued on \(environment) \(ageText). Waiting for the remote worker to start \(stage.title.lowercased())."
        case "in_progress", "incomplete":
            return "Running on \(environment) \(ageText). Waiting for the first research update."
        default:
            return fallback
        }
    }

    private func conciseElapsedTime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 {
            return "for \(seconds)s"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "for \(minutes)m"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        if remainderMinutes == 0 {
            return "for \(hours)h"
        }

        return "for \(hours)h \(remainderMinutes)m"
    }

    private func shouldUseResponsesFallback(for snapshot: PaperTaskProgressSnapshot) -> Bool {
        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedStatus = snapshot.status.lowercased()

        return ["pending", "queued", "in_progress", "incomplete"].contains(normalizedStatus)
            && snapshot.outputCharacterCount == 0
            && latestEvent.isEmpty
    }

    private func shouldUseResponsesFallbackImmediately(
        run: ResearchRun,
        snapshot: PaperTaskProgressSnapshot
    ) -> Bool {
        let latestEvent = snapshot.latestEventText?.lowercased() ?? ""
        let latestProgress = run.latestProgressMessage?.lowercased() ?? ""
        let indicators = [
            "repo_not_accessible",
            "repository is not accessible",
            "no usable codex cloud environment"
        ]

        return indicators.contains(where: latestEvent.contains)
            || indicators.contains(where: latestProgress.contains)
    }

    private func shouldUseResponsesFallback(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let indicators = [
            "no usable codex cloud environment",
            "repo_not_accessible",
            "repository is not accessible"
        ]

        return indicators.contains(where: message.contains)
    }

    private func shouldRetryResponsesFallback(for run: ResearchRun) -> Bool {
        let message = run.lastError?.lowercased() ?? ""
        let indicators = [
            "unsupported tool type: code_interpreter",
            "not found",
            "missing scopes: api.responses.write",
            "insufficient permissions",
            "prompt exceeds 100000 characters"
        ]

        return indicators.contains(where: message.contains)
    }

    private func shouldUseBundledResearchTaskFallback(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let indicators = [
            "unsupported tool type: code_interpreter",
            "missing scopes: api.responses.write",
            "insufficient permissions",
            "not found"
        ]

        return indicators.contains(where: message.contains)
    }

    private func prefersBundledResearchFallback(
        run: ResearchRun,
        notes: [Note]
    ) async -> Bool {
        await openAI.prefersBundledResearchFallback(
            datasetIDs: run.datasetIDs,
            noteTexts: notes.map(\.content),
            theme: run.theme
        )
    }

    private func supportsBundledResearchFallback(
        run: ResearchRun,
        notes: [Note]
    ) async -> Bool {
        await openAI.supportsBundledResearchFallback(
            datasetIDs: run.datasetIDs,
            noteTexts: notes.map(\.content),
            theme: run.theme
        )
    }

    private func shouldRerouteInspectionArtifactToBundledFallback(
        _ artifact: ResearchInspectionArtifact,
        run: ResearchRun,
        notes: [Note]
    ) async -> Bool {
        guard await supportsBundledResearchFallback(run: run, notes: notes) else {
            return false
        }

        return inspectionArtifactIndicatesTransportBlock(artifact)
    }

    private func inspectionArtifactIndicatesTransportBlock(
        _ artifact: ResearchInspectionArtifact
    ) -> Bool {
        let evidence = [
            artifact.accessNotes,
            artifact.datasetManifest.sampleDescription
        ] + artifact.qualityChecks
            + artifact.analysisChecklist
            + artifact.datasetManifest.qualityNotes
            + artifact.datasetManifest.dataSources
            + artifact.datasetManifest.selectedVariables

        if artifactTextIndicatesTransportBlock(evidence) {
            return true
        }

        let selectedVariableSet = Set(artifact.datasetManifest.selectedVariables.map { $0.lowercased() })
        let looksLikeCardMetadataOnly = [
            "id",
            "disciplines",
            "use",
            "avoid",
            "access",
            "sample",
            "domains",
            "example"
        ].allSatisfy(selectedVariableSet.contains)

        let cardOnlyIndicators = [
            "trusted dataset card:",
            "trusted dataset card metadata",
            "vetted in-prompt card metadata only",
            "card metadata only",
            "no live collection_id",
            "no live dataset_id",
            "no live study_id",
            "could not be inspected from live source"
        ]
        let combinedEvidence = evidence.joined(separator: " ").lowercased()

        return looksLikeCardMetadataOnly
            || cardOnlyIndicators.contains(where: combinedEvidence.contains)
    }

    private func shouldRerouteAnalysisArtifactToBundledFallback(
        _ artifact: ResearchAnalysisArtifact,
        run: ResearchRun,
        notes: [Note]
    ) async -> Bool {
        guard await supportsBundledResearchFallback(run: run, notes: notes) else {
            return false
        }

        return analysisArtifactIndicatesTransportBlock(artifact)
    }

    private func analysisArtifactIndicatesTransportBlock(
        _ artifact: ResearchAnalysisArtifact
    ) -> Bool {
        let findingEvidence = artifact.findings.flatMap { finding in
            [finding.claim, finding.estimate, finding.uncertainty, finding.evidence]
        }
        let evidence = [
            artifact.narrativeSummary,
            artifact.datasetManifest.sampleDescription,
            artifact.provenance.notes
        ]
        + artifact.limitations
        + artifact.datasetManifest.qualityNotes
        + artifact.datasetManifest.dataSources
        + artifact.datasetManifest.selectedVariables
        + findingEvidence

        if (artifact.datasetManifest.rowCount ?? 0) == 0,
           artifact.figures.isEmpty,
           artifactTextIndicatesTransportBlock(evidence) {
            return true
        }

        let selectedVariableSet = Set(artifact.datasetManifest.selectedVariables.map { $0.lowercased() })
        let looksLikeCardMetadataOnly = [
            "id",
            "disciplines",
            "use",
            "avoid",
            "access",
            "sample",
            "domains",
            "example"
        ].allSatisfy(selectedVariableSet.contains)
        let cardOnlyIndicators = [
            "trusted dataset card:",
            "trusted dataset card metadata",
            "vetted in-prompt card metadata only",
            "card metadata only",
            "no live collection_id",
            "no live dataset_id",
            "no live study_id",
            "could not be inspected from live source"
        ]
        let combinedEvidence = evidence.joined(separator: " ").lowercased()

        return artifact.figures.isEmpty
            && (looksLikeCardMetadataOnly
                || cardOnlyIndicators.contains(where: combinedEvidence.contains))
    }

    private func artifactTextIndicatesTransportBlock(_ parts: [String]) -> Bool {
        let combined = parts.joined(separator: " ").lowercased()
        let indicators = [
            "connect tunnel",
            "tunnel connection failed",
            "response 403",
            "403 forbidden",
            "approved domains were probed",
            "approved-domain",
            "outbound https",
            "outbound access",
            "network egress",
            "transport-layer block",
            "transport blockage",
            "restore outbound access",
            "all approved endpoint probes failed"
        ]

        return indicators.contains(where: combined.contains)
    }

    private func normalizedVerificationArtifact(
        _ verification: ResearchVerificationArtifact,
        analysis: ResearchAnalysisArtifact
    ) -> ResearchVerificationArtifact {
        guard verification.decision != .blocked,
              !analysis.figures.isEmpty else {
            return verification
        }

        var reasons: [String] = []
        var figureChecks = verification.figureSanityChecks
        var requiredRevisions = verification.requiredRevisions
        let existingCheckFilenames = Set(
            figureChecks.map { $0.filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        let unusableFigures = analysis.figures.filter { $0.imageData == nil }

        if !unusableFigures.isEmpty {
            reasons.append("At least one required figure asset was missing or unusable after local validation.")
            requiredRevisions.append(
                "Regenerate every required figure asset as a real PNG and ensure the saved analysis artifact includes it."
            )

            for figure in unusableFigures {
                let normalizedFilename = figure.filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !existingCheckFilenames.contains(normalizedFilename) else {
                    continue
                }

                figureChecks.append(
                    ResearchFigureSanityCheck(
                        filename: figure.filename,
                        status: "missing",
                        issue: "This figure asset was missing or unusable after local validation. Regenerate it as a real PNG."
                    )
                )
            }
        }

        if verification.figureSanityChecks.contains(where: {
            $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missing"
        }) {
            reasons.append("Verification reported at least one required figure as missing.")
            requiredRevisions.append("Regenerate or reattach the missing figure asset before drafting.")
        }

        guard !reasons.isEmpty else {
            return verification
        }

        let baseSummary = verification.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarySuffix = uniquePreservingOrder(reasons).joined(separator: " ")
        let summary = baseSummary.isEmpty ? summarySuffix : "\(baseSummary) \(summarySuffix)"

        return ResearchVerificationArtifact(
            decision: .reviseAnalysis,
            summary: summary,
            supportedClaims: verification.supportedClaims,
            weakOrUnsupportedClaims: verification.weakOrUnsupportedClaims,
            figureSanityChecks: figureChecks,
            modelWarnings: verification.modelWarnings,
            sampleWarnings: verification.sampleWarnings,
            requiredRevisions: uniquePreservingOrder(requiredRevisions)
        )
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }

            result.append(normalized)
        }

        return result
    }

    private func pendingAnalysisRevision(for runID: String) -> ResearchVerificationArtifact? {
        guard let verification = PaperArtifactStore.stageArtifact(
            ResearchVerificationArtifact.self,
            runID: runID,
            stage: .verify
        ), verification.decision == .reviseAnalysis else {
            return nil
        }

        let verifyModifiedAt = PaperArtifactStore.stageArtifactModifiedAt(runID: runID, stage: .verify)
        let analyzeModifiedAt = PaperArtifactStore.stageArtifactModifiedAt(runID: runID, stage: .analyze)

        if let verifyModifiedAt, let analyzeModifiedAt, verifyModifiedAt <= analyzeModifiedAt {
            return nil
        }

        return verification
    }

    private func currentVerificationArtifact(for runID: String) -> ResearchVerificationArtifact? {
        guard let verification = PaperArtifactStore.stageArtifact(
            ResearchVerificationArtifact.self,
            runID: runID,
            stage: .verify
        ) else {
            return nil
        }

        let verifyModifiedAt = PaperArtifactStore.stageArtifactModifiedAt(runID: runID, stage: .verify)
        let analyzeModifiedAt = PaperArtifactStore.stageArtifactModifiedAt(runID: runID, stage: .analyze)

        if let verifyModifiedAt, let analyzeModifiedAt, verifyModifiedAt < analyzeModifiedAt {
            return nil
        }

        return verification
    }

    private func handleResearchStageError(
        _ error: Error,
        run: ResearchRun,
        paper: Paper,
        stage: ResearchRunStage
    ) {
        let message = error.localizedDescription

        if let blockingAPIKeyMessage = blockingAPIKeyFailureMessage(for: error, run: run) {
            openAI.recordUserAPIKeyFailure(blockingAPIKeyMessage)
            markResearchRunFailed(run, paper: paper, message: blockingAPIKeyMessage)
            return
        }

        if run.attemptCount(for: stage) >= maxResearchStageAttempts {
            markResearchRunFailed(run, paper: paper, message: message)
            return
        }

        run.status = .running
        run.activeTaskID = nil
        run.lastError = message
        run.updateProgress(message: "Retrying \(stage.title.lowercased()) soon: \(message)")
        persistModelChangesIfPossible(in: run.modelContext, context: "research stage error")
        print("[Heartbeat]   -> Stage \(stage.rawValue) failed for \(run.runID): \(message)")
    }

    private func markResearchRunFailed(
        _ run: ResearchRun,
        paper: Paper,
        message: String
    ) {
        run.markFailed(message: message)
        paper.status = .failed
        persistModelChangesIfPossible(in: run.modelContext, context: "research failure")
        print("[Heartbeat]   -> Research run failed for \(run.runID): \(message)")
    }

    private func applyRecovery(_ recovery: RecoveryResult, to paper: Paper) async throws {
        switch recovery {
        case let .resubmitted(taskID):
            print("[Heartbeat]   -> Resubmitted task as \(taskID)")
        }
    }

    private func blockingAPIKeyFailureMessage(
        for error: Error,
        run: ResearchRun
    ) -> String? {
        guard resolvedExecutionBackend(for: run) == .openAIAPIKey else {
            return nil
        }

        let normalized = error.localizedDescription.lowercased()
        let indicators = [
            "incorrect api key",
            "invalid api key",
            "api key provided",
            "missing scopes",
            "insufficient permissions",
            "insufficient_quota",
            "billing",
            "account is not active",
            "organization",
            "project",
            "authentication"
        ]

        guard indicators.contains(where: normalized.contains) else {
            return nil
        }

        return "The configured OpenAI API key was rejected. Update or remove it in Settings before retrying queued papers. \(error.localizedDescription)"
    }

    private func admitQueuedResearchRunsIfPossible(modelContext: ModelContext) async throws {
        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        guard !runs.isEmpty else {
            return
        }

        let papers = try modelContext.fetch(FetchDescriptor<Paper>())
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let papersByID = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var activeCounts = backendActiveCounts(for: runs)

        let queuedRuns = runs.filter(\.isSchedulerEligible).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }

            return lhs.runID < rhs.runID
        }

        for run in queuedRuns {
            let backend = resolvedExecutionBackend(for: run)
            if backend == .openAIAPIKey, openAI.hasBlockingUserAPIKeyError {
                continue
            }

            guard activeCounts[backend, default: 0] < maxConcurrentRemoteRuns(for: backend) else {
                continue
            }

            guard let paper = papersByID[run.paperID] else {
                continue
            }

            let sourceNotes = run.sourceNoteIDs.compactMap { notesByID[$0] }
            guard !sourceNotes.isEmpty else {
                markResearchRunFailed(
                    run,
                    paper: paper,
                    message: "The source notes for this queued paper could not be found."
                )
                continue
            }

            try startQueuedResearchRun(
                run,
                paper: paper,
                notes: sourceNotes,
                backend: backend
            )
            activeCounts[backend, default: 0] += 1
        }

        refreshQueuedRunPresentation(runs, activeCounts: activeCounts)
        try persistModelChanges(in: modelContext)
    }

    private func startQueuedResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        backend: ResearchExecutionBackend
    ) throws {
        run.executionBackend = backend
        paper.status = .generating
        run.markRunning(
            stage: run.currentStage,
            message: backendStartMessage(for: run, backend: backend)
        )
        try persistModelChanges(in: run.modelContext)
        scheduleResearchRunAdvance(run, paper: paper, notes: notes)
    }

    private func refreshQueuedRunPresentation(
        _ runs: [ResearchRun],
        activeCounts: [ResearchExecutionBackend: Int]
    ) {
        let groupedQueuedRuns = Dictionary(grouping: runs.filter { $0.status == .queued }) { run in
            resolvedExecutionBackend(for: run)
        }

        for run in runs where run.status == .queued && run.schedulingDisposition == .hold {
            run.markQueued(
                message: heldQueueMessage(for: run),
                queueState: .held
            )
        }

        for (backend, queuedRuns) in groupedQueuedRuns {
            let eligibleQueuedRuns = queuedRuns
                .filter(\.isSchedulerEligible)
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }

                    return lhs.runID < rhs.runID
                }

            if backend == .openAIAPIKey,
               let blockingMessage = openAI.userAPIKeyErrorMessage,
               openAI.hasBlockingUserAPIKeyError {
                for run in eligibleQueuedRuns {
                    run.markQueued(
                        message: blockingMessage,
                        queueState: .held
                    )
                }
                continue
            }

            for (index, run) in eligibleQueuedRuns.enumerated() {
                let queueState: ResearchRunQueueState
                let message: String

                if activeCounts[backend, default: 0] >= maxConcurrentRemoteRuns(for: backend) {
                    if index == 0 {
                        queueState = .nextInLine
                        message = nextInLineMessage(for: backend)
                    } else {
                        queueState = .waitingForCurrentPaper
                        message = waitingQueueMessage(for: backend)
                    }
                } else {
                    queueState = .queued
                    message = "Research queued."
                }

                run.markQueued(message: message, queueState: queueState)
            }
        }
    }

    private func backendActiveCounts(for runs: [ResearchRun]) -> [ResearchExecutionBackend: Int] {
        runs.reduce(into: [ResearchExecutionBackend: Int]()) { result, run in
            guard run.status == .running else {
                return
            }

            result[resolvedExecutionBackend(for: run), default: 0] += 1
        }
    }

    private func resolvedExecutionBackend(for run: ResearchRun) -> ResearchExecutionBackend {
        switch run.executionBackend {
        case .automatic:
            return openAI.hasUserAPIKeyOverride ? .openAIAPIKey : .chatGPTOAuth
        case let backend:
            return backend
        }
    }

    private func maxConcurrentRemoteRuns(for backend: ResearchExecutionBackend) -> Int {
        switch backend {
        case .automatic, .chatGPTOAuth:
            return maxConcurrentOAuthRemoteRuns
        case .openAIAPIKey:
            return maxConcurrentAPIKeyRemoteRuns
        }
    }

    private func backendStartMessage(
        for run: ResearchRun,
        backend: ResearchExecutionBackend
    ) -> String {
        switch backend {
        case .automatic, .chatGPTOAuth:
            return "Starting queued research with the ChatGPT remote queue."
        case .openAIAPIKey:
            return "Starting queued research with your OpenAI API key."
        }
    }

    private func heldQueueMessage(for run: ResearchRun) -> String {
        let existing = run.latestProgressMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty {
            return existing
        }

        switch run.sourceSupportTier {
        case .supported:
            return "Research queued."
        case .experimental:
            return "Experimental source selection. Kept queued until a more reliable source is confirmed."
        case .disabled:
            return "This source family is disabled for automatic paper generation."
        }
    }

    private func nextInLineMessage(for backend: ResearchExecutionBackend) -> String {
        switch backend {
        case .automatic, .chatGPTOAuth:
            return "Waiting for the current paper to finish. This one is next in line."
        case .openAIAPIKey:
            return "Waiting for an API-key research slot. This paper is next in line."
        }
    }

    private func waitingQueueMessage(for backend: ResearchExecutionBackend) -> String {
        switch backend {
        case .automatic, .chatGPTOAuth:
            return "Waiting for the current paper to finish. Sidekick runs one ChatGPT-backed paper at a time."
        case .openAIAPIKey:
            return "Waiting for currently running API-key papers to finish."
        }
    }

    private func isPromotableTrustedPartialCluster(_ cluster: NoteCluster) -> Bool {
        guard cluster.readinessMode == .trustedPartial,
              !cluster.datasetIDs.isEmpty else {
            return false
        }

        return Set(cluster.noteIDs).count >= 2
    }

    private func isPromotableExploratoryCluster(_ cluster: NoteCluster) -> Bool {
        guard cluster.readinessMode == .exploratoryReady,
              !cluster.datasetIDs.isEmpty else {
            return false
        }

        return Set(cluster.noteIDs).count >= 2
    }

    private func isSubmissionCandidate(_ cluster: NoteCluster) -> Bool {
        cluster.isAutomaticallyRunnable
            || isPromotableTrustedPartialCluster(cluster)
            || isPromotableExploratoryCluster(cluster)
    }

    private func selectedSubmissionClusters(from clusters: [NoteCluster]) -> [NoteCluster] {
        let candidates = clusters
            .filter(isSubmissionCandidate)
            .sorted { lhs, rhs in
                let lhsPriority = submissionPriorityScore(for: lhs)
                let rhsPriority = submissionPriorityScore(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                let lhsNoteCount = Set(lhs.noteIDs).count
                let rhsNoteCount = Set(rhs.noteIDs).count
                if lhsNoteCount != rhsNoteCount {
                    return lhsNoteCount > rhsNoteCount
                }

                if lhs.isAutomaticallyRunnable != rhs.isAutomaticallyRunnable {
                    return lhs.isAutomaticallyRunnable && !rhs.isAutomaticallyRunnable
                }

                let lhsDatasetCount = Set(lhs.datasetIDs).count
                let rhsDatasetCount = Set(rhs.datasetIDs).count
                if lhsDatasetCount != rhsDatasetCount {
                    return lhsDatasetCount < rhsDatasetCount
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
                print("[Heartbeat]   Skipping overlapping cluster \"\(cluster.suggestedTitle)\" to avoid duplicate auto-runs.")
                continue
            }

            if isPromotableTrustedPartialCluster(cluster) && !cluster.isAutomaticallyRunnable {
                print("[Heartbeat]   Promoting trusted-partial cluster \"\(cluster.suggestedTitle)\" for a first-pass run.")
            }

            selected.append(cluster)
        }

        return selected
    }

    private func submissionPriorityScore(for cluster: NoteCluster) -> Double {
        let noteCount = Double(Set(cluster.noteIDs).count)
        let datasetCount = Double(Set(cluster.datasetIDs).count)
        let readinessBonus: Double = cluster.isAutomaticallyRunnable ? 40 : 30
        let noteCoverageBonus = min(noteCount, 4.0) * 12
        let datasetPenalty = max(0, datasetCount - 1) * 2

        return readinessBonus + noteCoverageBonus - datasetPenalty
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

        let existingPapers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )

        guard shouldAssessNotes(notes: notes, existingPapers: existingPapers) else {
            print("[Heartbeat] All current notes are already covered by non-failed papers; skipping reassessment.")
            return 0
        }

        let clusters = try await assessNotesWithRescue(notes)
        let runnableClusters = selectedSubmissionClusters(from: clusters)
        let promotedClusters = runnableClusters.filter { isPromotableTrustedPartialCluster($0) && !$0.isAutomaticallyRunnable }
        print(
            "[Heartbeat] Got \(clusters.count) cluster(s). " +
                "Submission candidates: \(runnableClusters.count). " +
                "Promoted partial clusters: \(promotedClusters.count)"
        )

        var submitted = 0
        for cluster in runnableClusters {
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
            if let latestPaper = matchingPapers.max(by: { $0.updatedAt < $1.updatedAt }) {
                if latestPaper.status == .failed {
                    let failureAge = Date().timeIntervalSince(latestPaper.updatedAt)
                    guard failureAge >= failedPaperRetryCooldown else {
                        let retryDelayMinutes = max(
                            1,
                            Int(ceil((failedPaperRetryCooldown - failureAge) / 60))
                        )
                        print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" failed recently; retrying in about \(retryDelayMinutes) minute(s).")
                        continue
                    }

                    print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" failed previously; retrying the cluster.")
                } else if latestPaper.updatedAt >= latestNoteUpdate {
                    print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" already tracked, skipping.")
                    continue
                }
            }

            if !matchingPapers.isEmpty {
                print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" changed since the latest paper, generating a revision.")
            }

            phase = .submittingPaper(cluster.suggestedTitle)
            print("[Heartbeat]   Starting staged research run: \"\(cluster.suggestedTitle)\"...")
            try await beginResearchRun(
                cluster: cluster,
                notes: clusterNotes,
                modelContext: modelContext
            )

            submitted += 1
        }

        return submitted
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

        for pass in 1 ... maxNoteAssessmentPasses {
            guard !remainingNotes.isEmpty else {
                break
            }

            let isRescuePass = pass > 1
            if isRescuePass {
                print("[Heartbeat] Calling OpenAI assessNotes API for rescue pass \(pass - 1) on \(remainingNotes.count) leftover note(s)...")
            } else {
                print("[Heartbeat] Calling OpenAI assessNotes API...")
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
                if isRescuePass {
                    print("[Heartbeat] Rescue pass \(pass - 1) found no additional runnable or promotable clusters.")
                }
                break
            }

            let nextRemainingNotes = notes.filter { !coveredNoteIDs.contains($0.id) }
            if nextRemainingNotes.count == remainingNotes.count {
                break
            }

            if !nextRemainingNotes.isEmpty {
                print("[Heartbeat] \(nextRemainingNotes.count) note(s) still uncovered after pass \(pass); keeping them for another clustering pass.")
            }

            remainingNotes = nextRemainingNotes
        }

        return allClusters
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
        let runIDPrefix = preparation.draftArtifact == nil ? "run" : "local"
        let runID = "\(runIDPrefix)-\(UUID().uuidString)"
        let paper = Paper(
            title: cluster.suggestedTitle,
            status: .generating,
            codexTaskID: runID,
            sourceNoteIDs: cluster.noteIDs
        )
        let initialStage: ResearchRunStage = preparation.draftArtifact == nil ? .plan : .write
        let run = ResearchRun(
            runID: runID,
            paperID: paper.id,
            title: cluster.suggestedTitle,
            theme: cluster.theme,
            sourceNoteIDs: cluster.noteIDs,
            datasetIDs: preparation.selectedDatasetIDs,
            allowedDomains: preparation.allowedDomains,
            registryVersion: preparation.registryVersion,
            currentStage: initialStage,
            status: .queued,
            executionBackend: .automatic,
            queueState: preparation.schedulingDisposition == .autoStart ? .queued : .held,
            schedulingDisposition: preparation.schedulingDisposition,
            sourceSupportTier: preparation.sourceSupportTier
        )

        modelContext.insert(paper)
        modelContext.insert(run)
        run.markQueued(
            message: preparation.initialStatusMessage,
            queueState: preparation.schedulingDisposition == .autoStart ? .queued : .held
        )
        try persistModelChanges(in: modelContext)

        if let plan = preparation.planArtifact {
            try PaperArtifactStore.persistStageArtifact(plan, runID: runID, stage: .plan)
        }

        if let inspection = preparation.inspectionArtifact {
            try PaperArtifactStore.persistStageArtifact(inspection, runID: runID, stage: .inspect)
        }

        if let analysis = preparation.analysisArtifact {
            try PaperArtifactStore.persistStageArtifact(analysis, runID: runID, stage: .analyze)
        }

        if let verification = preparation.verificationArtifact {
            try PaperArtifactStore.persistStageArtifact(verification, runID: runID, stage: .verify)
        }

        if let draft = preparation.draftArtifact {
            try PaperArtifactStore.persistStageArtifact(draft, runID: runID, stage: .write)
        }

        print("[Heartbeat]   -> Research run ID: \(runID)")
    }
}

private enum RecoveryResult {
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
