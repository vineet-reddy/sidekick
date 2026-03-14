import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @EnvironmentObject private var notifications: NotificationService

    @State private var authError: String?

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
                                    if auth.isSigningIn {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(auth.signInURL == nil ? "Sign in with ChatGPT" : "Continue in Sidekick")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SidekickTheme.accent)
                            .disabled(auth.isSigningIn)

                            HStack {
                                StatusPill(
                                    title: auth.signInURL == nil ? "Not signed in" : "Waiting for browser",
                                    tint: auth.signInURL == nil ? .orange : SidekickTheme.accent
                                )

                                if notifications.authorizationStatus == .authorized {
                                    StatusPill(title: "Notifications on", tint: SidekickTheme.accent)
                                }
                            }

                            if auth.signInURL != nil {
                                Text("Finish the secure ChatGPT sign-in in the browser sheet, then Sidekick will close it automatically.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
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
