import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var heartbeat: HeartbeatManager

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
}
