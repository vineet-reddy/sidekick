import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var github: GitHubService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @State private var connectError: String?

    var body: some View {
        ZStack {
            SidekickBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("GitHub Publishing")
                            .font(.headline)

                        StatusPill(
                            title: github.isConnected ? "Connected" : "Required",
                            tint: github.isConnected ? .green : .orange
                        )

                        Text(
                            github.isConnected
                                ? "Sidekick publishes every completed paper into your public GitHub repo as LaTeX plus reproducibility code."
                                : "GitHub is required before Sidekick starts a paper. Every run publishes to a public repo in the user’s account."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        if let context = github.exportContext {
                            Text(context.repoFullName)
                                .font(.subheadline.weight(.semibold))

                            if let repoURL = context.repoURL {
                                Link(repoURL.absoluteString, destination: repoURL)
                                    .font(.caption)
                            }
                        }

                        Button(github.isConnected ? "Reconnect GitHub" : "Connect GitHub") {
                            connectGitHub()
                        }
                        .buttonStyle(.borderedProminent)

                        if let connectError, !connectError.isEmpty {
                            Text(connectError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let backendError = github.connectionErrorMessage, !backendError.isEmpty {
                            Text(backendError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .glassCard(padding: 22)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Execution")
                            .font(.headline)

                        Text("Sidekick runs planning, data inspection, analysis, verification, and drafting on Sidekick-hosted OpenAI compute. The app keeps notes, cached artifacts, and local PDF rendering on device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        StatusPill(title: "Sidekick hosted", tint: SidekickTheme.accent)
                    }
                    .glassCard(padding: 22)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Usage Guardrails")
                            .font(.headline)

                        Text("One paper runs at a time per install. GitHub must be connected before compute spend starts. Large artifacts stay temporary on the backend and durable reproducibility storage lives in the user’s public repo.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .glassCard(padding: 22)

                    if let lastError = heartbeat.lastError, !lastError.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Last sync encountered an issue.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(lastError)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text("Sidekick will retry automatically.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .glassCard(padding: 22)
                    }

                    Spacer()

                    Text("Sidekick v1.0")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.view")
    }

    private func connectGitHub() {
        connectError = nil
        Task {
            do {
                let url = try await github.beginGitHubConnection()
                await MainActor.run {
                    if !github.isConnected {
                        openURL(url)
                    }
                }
            } catch {
                await MainActor.run {
                    connectError = error.localizedDescription
                }
            }
        }
    }
}
