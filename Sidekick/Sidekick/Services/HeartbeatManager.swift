import BackgroundTasks
import Combine
import Foundation
import SwiftData

enum HeartbeatPhase: Equatable {
    case idle
    case checkingPapers
    case assessingNotes
    case submittingPaper(String)  // cluster title
    case done(Int)               // number of papers submitted

    var label: String {
        switch self {
        case .idle: return ""
        case .checkingPapers: return "Checking papers..."
        case .assessingNotes: return "Reading your notes..."
        case .submittingPaper(let title): return "Drafting \"\(title)\"..."
        case .done(let count):
            if count == 0 { return "All caught up." }
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

            // Clear the "done" message after a few seconds
            Task {
                try? await Task.sleep(for: .seconds(4))
                if case .done = phase { phase = .idle }
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

        print("[Heartbeat] Found \(papers.count) in-flight paper(s).")

        for paper in papers {
            print("[Heartbeat]   Checking task \(paper.codexTaskID) for \"\(paper.title)\"...")
            guard let artifacts = try await openAI.checkTask(paper.codexTaskID) else {
                print("[Heartbeat]   -> Still in progress.")
                continue
            }

            paper.title = artifacts.title
            paper.markdown = artifacts.markdown
            paper.figureData = artifacts.figures
            paper.status = .ready
            print("[Heartbeat]   -> Paper ready: \"\(artifacts.title)\"")

            if paper.lastNotifiedAt == nil {
                notifications.notify(paper: paper)
                paper.lastNotifiedAt = .now
            }
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
            let alreadyTracked = existingPapers.contains { $0.matches(noteIDs: cluster.noteIDs) }
            if alreadyTracked {
                print("[Heartbeat]   Cluster \"\(cluster.suggestedTitle)\" already tracked, skipping.")
                continue
            }

            let clusterNotes = notes.filter { cluster.noteIDs.contains($0.id) }
            guard !clusterNotes.isEmpty else {
                continue
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

            let paper = Paper(
                title: cluster.suggestedTitle,
                status: .generating,
                codexTaskID: submission.taskID,
                sourceNoteIDs: cluster.noteIDs
            )
            modelContext.insert(paper)
            submitted += 1
        }

        return submitted
    }
}

final class BackgroundHeartbeatScheduler {
    static let shared = BackgroundHeartbeatScheduler()
    static let identifier = "com.vineet.sidekick.heartbeat"

    var runner: (@Sendable () async -> Void)?

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

        let work = Task {
            await runner?()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
