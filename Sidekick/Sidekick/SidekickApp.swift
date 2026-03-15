import SwiftData
import SwiftUI

@main
@MainActor
struct SidekickApp: App {
    @StateObject private var authService: AuthService
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

        let auth = AuthService()
        let notifications = NotificationService()
        let openAI = OpenAIService(auth: auth)
        let heartbeat = HeartbeatManager(openAI: openAI, notifications: notifications)

        _authService = StateObject(wrappedValue: auth)
        _notificationService = StateObject(wrappedValue: notifications)
        _openAIService = StateObject(wrappedValue: openAI)
        _heartbeatManager = StateObject(wrappedValue: heartbeat)

        BackgroundHeartbeatScheduler.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(authService)
                .environmentObject(openAIService)
                .environmentObject(notificationService)
                .environmentObject(heartbeatManager)
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
