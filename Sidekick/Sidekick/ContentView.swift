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

    var body: some View {
        if auth.isAuthenticated {
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
