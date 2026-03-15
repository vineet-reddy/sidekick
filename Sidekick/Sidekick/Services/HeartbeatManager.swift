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
    private let maxResearchStageAttempts = 3

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
        let runs = try modelContext.fetch(
            FetchDescriptor<ResearchRun>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
        let runsByPaperID = Dictionary(uniqueKeysWithValues: runs.map { ($0.paperID, $0) })
        let recoverablePaperIDs = Set(
            runs.compactMap { run in
                pendingAnalysisRevision(for: run.runID) == nil ? nil : run.paperID
            }
        )
        let inFlightPapers = papers.filter { paper in
            paper.status == .generating || (paper.status == .failed && recoverablePaperIDs.contains(paper.id))
        }
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        print("[Heartbeat] Found \(inFlightPapers.count) in-flight paper(s).")

        for paper in inFlightPapers {
            print("[Heartbeat]   Checking task \(paper.codexTaskID) for \"\(paper.title)\"...")

            if let run = runsByPaperID[paper.id] {
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
        let environmentLabel = snapshot.environmentLabel ?? "<none>"
        let networkMode = snapshot.environmentNetworkMode ?? "<unknown>"

        return "status=\(snapshot.status) task_age_s=\(taskAgeSeconds) " +
            "latest_event_age_s=\(progressAgeSeconds) output_chars=\(snapshot.outputCharacterCount) " +
            "env=\"\(environmentLabel)\" network=\(networkMode) latest_event=\"\(latestEvent)\""
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

        return Date().timeIntervalSince(taskStart) >= remoteRetryGracePeriod
    }

    private func resolveResearchRun(
        _ run: ResearchRun,
        paper: Paper,
        notesByID: [UUID: Note]
    ) async throws {
        if run.status == .failed, pendingAnalysisRevision(for: run.runID) != nil {
            paper.status = .generating
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

        try await advanceResearchRun(run, paper: paper, notes: notes)
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
            if PaperArtifactStore.stageArtifact(ResearchInspectionArtifact.self, runID: run.runID, stage: .inspect) != nil {
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
                if verification.decision == .reviseAnalysis {
                    run.markRunning(stage: .analyze, message: "Revising analysis from verification feedback.")
                    try await advanceResearchRun(run, paper: paper, notes: notes)
                    return
                }

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

        do {
            let artifact = try await openAI.createResearchPlan(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs
            )
            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .plan)
            print("[Heartbeat]   -> Plan stage completed for \(run.runID)")
            run.markRunning(stage: .inspect, message: ResearchRunStage.inspect.title)
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            handleResearchStageError(error, run: run, paper: paper, stage: .plan)
        }
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
                let message = snapshot.latestEventText
                    ?? run.latestProgressMessage
                    ?? ResearchRunStage.inspect.title
                run.updateProgress(message: message, at: snapshot.latestEventAt ?? snapshot.observedAt)

                if shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
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

                if shouldRescueDeadBundledTask(run: run, snapshot: snapshot) {
                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Inspect stage bundled task looks dead on \(environmentLabel); rerouting without spending another stage attempt.")
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
                    print("[Heartbeat]   -> Inspect stage stalled for \(run.runID); restarting from checkpoint.")
                    run.activeTaskID = nil

                    if shouldUseResponsesFallback(for: snapshot) {
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

                    try await startResearchInspectionTask(run, paper: paper, notes: notes, plan: plan)
                }

            case let .completed(snapshot, artifact):
                persistTaskProgress(snapshot)
                try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .inspect)
                run.activeTaskID = nil
                run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
                print("[Heartbeat]   -> Inspect stage completed for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)

            case let .failed(snapshot, message):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

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
        plan: ResearchPlanArtifact
    ) async throws {
        guard run.attemptCount(for: .inspect) < maxResearchStageAttempts else {
            markResearchRunFailed(
                run,
                paper: paper,
                message: "Dataset inspection exceeded the retry budget."
            )
            return
        }

        run.incrementAttempt(for: .inspect)
        run.markRunning(stage: .inspect, message: "Resolving and inspecting the dataset slice.")

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
            print("[Heartbeat]   -> Inspect task started as \(taskID)")
        } catch {
            if shouldUseResponsesFallback(after: error) {
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
                let message = snapshot.latestEventText
                    ?? run.latestProgressMessage
                    ?? ResearchRunStage.analyze.title
                run.updateProgress(message: message, at: snapshot.latestEventAt ?? snapshot.observedAt)

                if shouldUseResponsesFallbackImmediately(run: run, snapshot: snapshot) {
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

                if shouldRescueDeadBundledTask(run: run, snapshot: snapshot) {
                    let environmentLabel = snapshot.environmentLabel ?? snapshot.environmentID ?? "<unknown>"
                    print("[Heartbeat]   -> Analysis stage bundled task looks dead on \(environmentLabel); rerouting without spending another stage attempt.")
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
                    print("[Heartbeat]   -> Analysis stage stalled for \(run.runID); restarting from checkpoint.")
                    run.activeTaskID = nil

                    if shouldUseResponsesFallback(for: snapshot) {
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
                        revisionRequest: revisionRequest
                    )
                }

            case let .completed(snapshot, artifact):
                persistTaskProgress(snapshot)
                try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .analyze)
                run.activeTaskID = nil
                run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
                print("[Heartbeat]   -> Analysis stage completed for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)

            case let .failed(snapshot, message):
                persistTaskProgress(snapshot)
                run.activeTaskID = nil

                if revisionRequest != nil || run.attemptCount(for: .analyze) < maxResearchStageAttempts {
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
        revisionRequest: ResearchVerificationArtifact?
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

        if !isRevisionRetry {
            run.incrementAttempt(for: .analyze)
        }
        run.markRunning(
            stage: .analyze,
            message: isRevisionRetry
                ? "Re-running analysis with verification revisions."
                : "Starting remote analysis task."
        )

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
            print("[Heartbeat]   -> Analysis task started as \(taskID)")
        } catch {
            if shouldUseResponsesFallback(after: error) {
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

        do {
            let verification = try await openAI.verifyResearchAnalysis(
                notes: notes,
                title: run.title,
                theme: run.theme,
                plan: plan,
                inspection: inspection,
                analysis: analysis
            )
            try PaperArtifactStore.persistStageArtifact(verification, runID: run.runID, stage: .verify)

            if verification.decision == .reviseAnalysis {
                run.markRunning(stage: .analyze, message: "Revising analysis from verification feedback.")
                print("[Heartbeat]   -> Verification requested analysis revisions for \(run.runID)")
                try await advanceResearchRun(run, paper: paper, notes: notes)
                return
            }

            guard verification.allowsWriting else {
                print("[Heartbeat]   -> Verification blocked drafting for \(run.runID)")
                markResearchRunFailed(run, paper: paper, message: verification.blockingMessage)
                return
            }

            run.markRunning(stage: .write, message: ResearchRunStage.write.title)
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
        print("[Heartbeat]   -> Research run complete for \(run.runID)")
    }

    private func performInspectResponsesFallback(
        _ run: ResearchRun,
        paper: Paper,
        notes: [Note],
        plan: ResearchPlanArtifact,
        incrementAttempt: Bool
    ) async throws {
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
        run.markRunning(stage: .inspect, message: "Inspecting the cohort via staged responses fallback.")

        do {
            let artifact = try await openAI.runResearchInspectionFallback(
                notes: notes,
                title: run.title,
                theme: run.theme,
                datasetIDs: run.datasetIDs,
                plan: plan
            )

            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .inspect)
            run.activeTaskID = nil
            run.markRunning(stage: .analyze, message: ResearchRunStage.analyze.title)
            print("[Heartbeat]   -> Inspect fallback completed for \(run.runID)")
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            guard shouldUseBundledResearchTaskFallback(after: error) else {
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
            print("[Heartbeat]   -> Inspect bundled fallback task started as \(taskID)")
        }
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
        run.markRunning(stage: .analyze, message: "Running analysis via staged responses fallback.")

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

            try PaperArtifactStore.persistStageArtifact(artifact, runID: run.runID, stage: .analyze)
            run.activeTaskID = nil
            run.markRunning(stage: .verify, message: ResearchRunStage.verify.title)
            print("[Heartbeat]   -> Analysis fallback completed for \(run.runID)")
            try await advanceResearchRun(run, paper: paper, notes: notes)
        } catch {
            guard shouldUseBundledResearchTaskFallback(after: error) else {
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

        return taskAge >= remoteRetryGracePeriod
            && (snapshot.outputCharacterCount == 0 || progressAge >= stalledEventGracePeriod)
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
        let latestEvent = snapshot.latestEventText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedLabel = snapshot.environmentLabel?.lowercased() ?? ""
        let normalizedStatus = snapshot.status.lowercased()
        let latestProgress = run.latestProgressMessage?.lowercased() ?? ""

        return ["pending", "queued", "in_progress", "incomplete"].contains(normalizedStatus)
            && snapshot.outputCharacterCount == 0
            && latestEvent.isEmpty
            && normalizedLabel.contains("/")
            && !normalizedLabel.contains("sidekick")
            && !latestProgress.contains("bundled")
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

        if run.attemptCount(for: stage) >= maxResearchStageAttempts {
            markResearchRunFailed(run, paper: paper, message: message)
            return
        }

        run.status = .running
        run.activeTaskID = nil
        run.lastError = message
        run.updateProgress(message: "Retrying \(stage.title.lowercased()) soon: \(message)")
        print("[Heartbeat]   -> Stage \(stage.rawValue) failed for \(run.runID): \(message)")
    }

    private func markResearchRunFailed(
        _ run: ResearchRun,
        paper: Paper,
        message: String
    ) {
        run.markFailed(message: message)
        paper.status = .failed
        print("[Heartbeat]   -> Research run failed for \(run.runID): \(message)")
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
            status: .running
        )

        modelContext.insert(paper)
        modelContext.insert(run)

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

        run.markRunning(stage: initialStage, message: initialStage.title)
        print("[Heartbeat]   -> Research run ID: \(runID)")
        try await advanceResearchRun(run, paper: paper, notes: notes)
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
