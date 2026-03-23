import Foundation

let sidekickOpenAIEnvironmentRouterDefaultsKey = "com.vineet.sidekick.openai-environment-router"
let sidekickGitHubWorkspaceContextDefaultsKey = "com.vineet.sidekick.github-workspace-context"
let sidekickGitHubBootstrapSessionDefaultsKey = "com.vineet.sidekick.github-bootstrap-session"
let sidekickConnectorScopeAttestationDefaultsKey = "com.vineet.sidekick.connector-scope-attestation"

extension Notification.Name {
    static let sidekickDidSignOut = Notification.Name("com.vineet.sidekick.did-sign-out")
}
