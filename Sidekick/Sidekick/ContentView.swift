import SwiftData
import SwiftUI

struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService

    var body: some View {
        ContentView()
            .task {
                await notifications.requestAuthorization()
                heartbeat.scheduleBackgroundRefresh()
                await heartbeat.runIfNeeded(modelContext: modelContext)
                BackgroundHeartbeatScheduler.shared.runner = {
                    await heartbeat.run(modelContext: modelContext, force: true)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    return
                }

                Task {
                    await heartbeat.runIfNeeded(modelContext: modelContext)
                }
            }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                NoteListView()
            }
            .tabItem {
                Label("Notes", systemImage: "square.and.pencil")
            }

            NavigationStack {
                PaperListView()
            }
            .tabItem {
                Label("Papers", systemImage: "doc.text.magnifyingglass")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
