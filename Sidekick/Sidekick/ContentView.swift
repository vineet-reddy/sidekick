import SwiftData
import SwiftUI

private enum AppTab: Hashable {
    case notes
    case papers
    case settings
}

enum QAFlags {
    static var shouldOpenLatestPaper: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--qa-open-latest-paper") {
            return true
        }

        return ProcessInfo.processInfo.environment["SIDEKICK_QA_OPEN_LATEST_PAPER"] == "1"
    }
}

struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService

    var body: some View {
        ContentView()
            .task {
                Task {
                    await notifications.requestAuthorization()
                }
                heartbeat.scheduleBackgroundRefresh()
                Task {
                    await preloadRecentReadyPapers(modelContext: modelContext)
                }
                await heartbeat.runIfNeeded(modelContext: modelContext)
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
                    await heartbeat.runIfNeeded(modelContext: modelContext)
                }
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
