import Foundation

let sidekickBackendSessionDefaultsKey = "com.vineet.sidekick.backend-session"
let sidekickBackendDeviceIDDefaultsKey = "com.vineet.sidekick.backend-device-id"
let sidekickGitHubExportContextDefaultsKey = "com.vineet.sidekick.github-export-context"
let sidekickGitHubConnectSessionDefaultsKey = "com.vineet.sidekick.github-connect-session"
let sidekickOpenAIEnvironmentRouterDefaultsKey = "com.vineet.sidekick.openai-environment-router"
let sidekickGitHubWorkspaceContextDefaultsKey = "com.vineet.sidekick.github-workspace-context"
let sidekickGitHubBootstrapSessionDefaultsKey = "com.vineet.sidekick.github-bootstrap-session"
let sidekickConnectorScopeAttestationDefaultsKey = "com.vineet.sidekick.connector-scope-attestation"

extension Notification.Name {
    static let sidekickGitHubConnectionChanged = Notification.Name("com.vineet.sidekick.github-connection-changed")
    static let sidekickDidSignOut = Notification.Name("com.vineet.sidekick.did-sign-out")
}
