import BackgroundTasks
import Combine
import Foundation
import SwiftData

@MainActor
final class HeartbeatManager: ObservableObject {
    @Published private(set) var isRunning = false
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
            try await resolveInFlightPapers(modelContext: modelContext)
            try await discoverNewPaperCandidates(modelContext: modelContext)
            try modelContext.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolveInFlightPapers(modelContext: ModelContext) async throws {
        let papers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )
            .filter { $0.status == .generating }

        for paper in papers {
            guard let artifacts = try await openAI.checkTask(paper.codexTaskID) else {
                continue
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
    }

    private func discoverNewPaperCandidates(modelContext: ModelContext) async throws {
        let notes = try modelContext.fetch(
            FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )

        guard !notes.isEmpty else {
            return
        }

        let clusters = try await openAI.assessNotes(notes)
        let existingPapers = try modelContext.fetch(
            FetchDescriptor<Paper>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )

        for cluster in clusters where cluster.isReady {
            let alreadyTracked = existingPapers.contains { $0.matches(noteIDs: cluster.noteIDs) }
            if alreadyTracked {
                continue
            }

            let clusterNotes = notes.filter { cluster.noteIDs.contains($0.id) }
            guard !clusterNotes.isEmpty else {
                continue
            }

            let taskID = try await openAI.submitPaperTask(
                notes: clusterNotes,
                title: cluster.suggestedTitle,
                theme: cluster.theme
            )

            let paper = Paper(
                title: cluster.suggestedTitle,
                status: .generating,
                codexTaskID: taskID,
                sourceNoteIDs: cluster.noteIDs
            )
            modelContext.insert(paper)
        }
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
