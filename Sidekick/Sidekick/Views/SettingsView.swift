import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService

    @State private var authError: String?
    @State private var isSigningIn = false

    var body: some View {
        ZStack {
            SidekickBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(
                        eyebrow: "Settings",
                        title: "Quiet on the surface, serious under the hood",
                        subtitle: "Sign in with your ChatGPT account. Your subscription covers all usage."
                    )

                    // MARK: - Account
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Account")
                            .font(.headline)

                        if auth.isAuthenticated {
                            if let email = auth.userEmail {
                                Text(email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                StatusPill(title: "Connected", tint: .green)

                                if notifications.authorizationStatus == .authorized {
                                    StatusPill(title: "Notifications on", tint: SidekickTheme.accent)
                                }
                            }

                            Button("Sign out") {
                                auth.signOut()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("Sign in with your ChatGPT account to let Sidekick generate papers using your subscription.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button {
                                signIn()
                            } label: {
                                HStack {
                                    if isSigningIn {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(isSigningIn ? "Signing in..." : "Sign in with ChatGPT")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SidekickTheme.accent)
                            .disabled(isSigningIn)

                            HStack {
                                StatusPill(title: "Not signed in", tint: .orange)

                                if notifications.authorizationStatus == .authorized {
                                    StatusPill(title: "Notifications on", tint: SidekickTheme.accent)
                                }
                            }
                        }

                        if let authError, !authError.isEmpty {
                            Text(authError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .glassCard(padding: 22)

                    // MARK: - Heartbeat
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Heartbeat")
                            .font(.headline)

                        Text("Run the clustering and paper-generation loop on demand. Background refresh is also scheduled automatically.")
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                await heartbeat.run(modelContext: modelContext, force: true)
                            }
                        } label: {
                            HStack {
                                if heartbeat.isRunning {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(heartbeat.isRunning ? "Running..." : "Run Sidekick now")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SidekickTheme.accent)
                        .disabled(heartbeat.isRunning || !auth.isAuthenticated)

                        if let lastError = heartbeat.lastError, !lastError.isEmpty {
                            Text(lastError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .glassCard(padding: 22)
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() {
        isSigningIn = true
        authError = nil
        Task {
            do {
                try await auth.signIn()
            } catch {
                authError = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}
