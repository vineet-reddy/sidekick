import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var openAI: OpenAIService
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @State private var apiKeyDraft = ""
    @State private var apiKeyStatusMessage: String?
    @State private var apiKeyStatusIsError = false

    var body: some View {
        ZStack {
            SidekickBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // MARK: - Account
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Account")
                            .font(.headline)

                        if let email = auth.userEmail {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        StatusPill(title: "Connected", tint: .green)

                        Button("Sign out") {
                            auth.signOut()
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                    }
                    .glassCard(padding: 22)

                    if !openAI.hasUserAPIKeyOverride {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Codex Workspace")
                                .font(.headline)

                            StatusPill(
                                title: chatGPTQueueStatusTitle,
                                tint: chatGPTQueueStatusTint
                            )

                            Text(
                                openAI.oauthExecutionSetupMessage
                                    ?? "Your ChatGPT OAuth path has at least one usable repository-bound Codex environment."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            if openAI.oauthExecutionSetupMessage != nil {
                                Button("Open setup guide") {
                                    openAI.requestOAuthExecutionSetupSheet()
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.subheadline)
                            }
                        }
                        .glassCard(padding: 22)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("OpenAI API Key")
                            .font(.headline)

                        Text(
                            openAI.hasUserAPIKeyOverride
                                ? "API key mode takes priority over the repository-bound Codex workspace flow and can run multiple remote papers at once."
                                : "Optional override. If you add your own OpenAI API key, Sidekick will prefer it over the repository-bound ChatGPT Codex workspace flow."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        StatusPill(
                            title: openAI.hasUserAPIKeyOverride ? "API key active" : "Using Codex workspace",
                            tint: openAI.hasUserAPIKeyOverride ? .green : SidekickTheme.accent
                        )

                        if let hint = openAI.userAPIKeyHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        if let errorMessage = openAI.userAPIKeyErrorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        SecureField("sk-...", text: $apiKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        HStack(spacing: 12) {
                            Button(openAI.hasUserAPIKeyOverride ? "Update key" : "Save key") {
                                saveAPIKey()
                            }
                            .buttonStyle(.borderedProminent)

                            if openAI.hasUserAPIKeyOverride {
                                Button("Remove key", role: .destructive) {
                                    removeAPIKey()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .font(.subheadline)

                        if let apiKeyStatusMessage, !apiKeyStatusMessage.isEmpty {
                            Text(apiKeyStatusMessage)
                                .font(.caption)
                                .foregroundStyle(apiKeyStatusIsError ? .red : .secondary)
                        }
                    }
                    .glassCard(padding: 22)

                    // MARK: - Status
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

    private func saveAPIKey() {
        do {
            try openAI.saveUserAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            apiKeyStatusIsError = false
            apiKeyStatusMessage = "Stored securely in Keychain. New queued papers will prefer the API path."
        } catch {
            apiKeyStatusIsError = true
            apiKeyStatusMessage = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try openAI.clearUserAPIKey()
            apiKeyDraft = ""
            apiKeyStatusIsError = false
            apiKeyStatusMessage = "Removed from Keychain. Sidekick will return to the repository-bound Codex workspace flow."
        } catch {
            apiKeyStatusIsError = true
            apiKeyStatusMessage = error.localizedDescription
        }
    }

    private var chatGPTQueueStatusTitle: String {
        if openAI.oauthExecutionSetupMessage == nil {
            return "Ready"
        }

        switch openAI.oauthExecutionSetup.phase {
        case .connectGitHub:
            return "Workspace setup required"
        case .confirmRepositoryScope:
            return "Scope confirmation required"
        case .waitingForMachine, .waitingForEnvironment:
            return "Finishing setup"
        case .autoProvisioning:
            return "Auto-provisioning"
        case .manualFinish:
            return "Finish in ChatGPT"
        case .ready:
            return "Ready"
        }
    }

    private var chatGPTQueueStatusTint: Color {
        openAI.oauthExecutionSetupMessage == nil ? .green : .orange
    }
}
