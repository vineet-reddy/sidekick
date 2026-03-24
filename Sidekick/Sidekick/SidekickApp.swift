import SwiftData
import SwiftUI

@main
@MainActor
struct SidekickApp: App {
    @StateObject private var githubService: GitHubService
    @StateObject private var researchInputStore: ResearchInputStore
    @StateObject private var openAIService: OpenAIService
    @StateObject private var notificationService: NotificationService
    @StateObject private var heartbeatManager: HeartbeatManager

    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([Note.self, Paper.self, ResearchRun.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("SwiftData failed to initialize: \(error.localizedDescription)")
        }

        let github = GitHubService()
        let researchInputs = ResearchInputStore()
        let notifications = NotificationService()
        let openAI = OpenAIService(github: github, researchInputStore: researchInputs)
        let heartbeat = HeartbeatManager(openAI: openAI, github: github, notifications: notifications)

        _githubService = StateObject(wrappedValue: github)
        _researchInputStore = StateObject(wrappedValue: researchInputs)
        _notificationService = StateObject(wrappedValue: notifications)
        _openAIService = StateObject(wrappedValue: openAI)
        _heartbeatManager = StateObject(wrappedValue: heartbeat)

        BackgroundHeartbeatScheduler.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(githubService)
                .environmentObject(researchInputStore)
                .environmentObject(openAIService)
                .environmentObject(notificationService)
                .environmentObject(heartbeatManager)
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
