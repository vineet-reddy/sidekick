import Combine
import Foundation

struct GitHubWorkspaceContext: Codable, Equatable {
    let githubLogin: String
    let githubAccountID: Int
    let repositoryID: Int
    let repositoryName: String
    let repositoryFullName: String
    let repositoryHTMLURL: URL?
    let defaultBranch: String
    let connectorInstallURL: URL
    let connectorRepairURL: URL
    let bootstrapSessionID: String?
    let installLaunchTime: Date
    let provisionedAt: Date

    enum CodingKeys: String, CodingKey {
        case githubLogin = "github_login"
        case githubAccountID = "github_account_id"
        case repositoryID = "repository_id"
        case repositoryName = "repository_name"
        case repositoryFullName = "repository_full_name"
        case repositoryHTMLURL = "repository_html_url"
        case defaultBranch = "default_branch"
        case connectorInstallURL = "connector_install_url"
        case connectorRepairURL = "connector_repair_url"
        case bootstrapSessionID = "bootstrap_session_id"
        case installLaunchTime = "install_launch_time"
        case provisionedAt = "provisioned_at"
    }
}

struct ConnectorScopeAttestation: Codable, Equatable {
    let chatgptEmail: String
    let githubLogin: String
    let repositoryID: Int
    let repositoryFullName: String
    let bootstrapSessionID: String?
    let installLaunchTime: Date
    let attestedAt: Date
}

struct GitHubBootstrapSession: Codable, Equatable {
    let sessionID: String
    let status: String
    let chatgptEmail: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date
    let startURL: URL
    let statusURL: URL
    let workspace: GitHubWorkspaceContext?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case chatgptEmail = "chatgpt_email"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case startURL = "start_url"
        case statusURL = "status_url"
        case workspace
    }
}

@MainActor
final class GitHubService: ObservableObject {
    enum GitHubServiceError: LocalizedError {
        case bootstrapServiceNotConfigured
        case bootstrapServiceUnavailable(URL)
        case invalidResponse
        case missingWorkspaceContext
        case missingChatGPTEmail

        var errorDescription: String? {
            switch self {
            case .bootstrapServiceNotConfigured:
                return "Sidekick could not find its GitHub workspace service configuration."
            case let .bootstrapServiceUnavailable(url):
                return """
                Sidekick could not reach its GitHub workspace service at \(url.absoluteString). Try again in a moment.
                """
            case .invalidResponse:
                return "The GitHub bootstrap service returned an unexpected response."
            case .missingWorkspaceContext:
                return "Sidekick has not provisioned a workspace repository yet."
            case .missingChatGPTEmail:
                return "Sign in with ChatGPT before confirming connector scope."
            }
        }
    }

    @Published private(set) var workspaceContext: GitHubWorkspaceContext?
    @Published private(set) var activeBootstrapSession: GitHubBootstrapSession?
    @Published private(set) var bootstrapErrorMessage: String?

    private let session: URLSession
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let attestationMaximumAge: TimeInterval = 24 * 60 * 60
    private var signOutObserver: NSObjectProtocol?

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.defaults = defaults
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        workspaceContext = Self.loadValue(
            GitHubWorkspaceContext.self,
            defaults: defaults,
            key: sidekickGitHubWorkspaceContextDefaultsKey,
            decoder: decoder
        )
        activeBootstrapSession = Self.loadValue(
            GitHubBootstrapSession.self,
            defaults: defaults,
            key: sidekickGitHubBootstrapSessionDefaultsKey,
            decoder: decoder
        )

        signOutObserver = NotificationCenter.default.addObserver(
            forName: .sidekickDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearSessionState()
            }
        }
    }

    deinit {
        if let signOutObserver {
            NotificationCenter.default.removeObserver(signOutObserver)
        }
    }

    func beginWorkspaceBootstrap(chatGPTEmail: String?) async throws -> URL {
        guard let baseURL = bootstrapServiceBaseURL else {
            throw GitHubServiceError.bootstrapServiceNotConfigured
        }

        try await verifyBootstrapServiceReachability(baseURL: baseURL)

        var request = URLRequest(url: baseURL.appendingPathComponent("api/bootstrap/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "chatgpt_email": (chatGPTEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            ]
        )

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw normalizeBootstrapTransportError(error, baseURL: baseURL)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        let bootstrapSession = try decoder.decode(GitHubBootstrapSession.self, from: data)
        activeBootstrapSession = bootstrapSession
        persist(bootstrapSession, key: sidekickGitHubBootstrapSessionDefaultsKey)
        bootstrapErrorMessage = nil
        return bootstrapSession.startURL
    }

    func refreshBootstrapSessionIfNeeded() async throws -> GitHubBootstrapSession? {
        guard let activeBootstrapSession else {
            return nil
        }

        let (data, response) = try await session.data(from: activeBootstrapSession.statusURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw GitHubServiceError.invalidResponse
        }

        let refreshed = try decoder.decode(GitHubBootstrapSession.self, from: data)
        self.activeBootstrapSession = refreshed
        persist(refreshed, key: sidekickGitHubBootstrapSessionDefaultsKey)

        if let workspace = refreshed.workspace {
            workspaceContext = workspace
            persist(workspace, key: sidekickGitHubWorkspaceContextDefaultsKey)
        }

        bootstrapErrorMessage = refreshed.errorMessage
        return refreshed
    }

    func markConnectorScopeAttested(chatgptEmail: String?) throws {
        guard let workspaceContext else {
            throw GitHubServiceError.missingWorkspaceContext
        }

        let normalizedEmail = (chatgptEmail ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedEmail.isEmpty else {
            throw GitHubServiceError.missingChatGPTEmail
        }

        let attestation = ConnectorScopeAttestation(
            chatgptEmail: normalizedEmail,
            githubLogin: workspaceContext.githubLogin,
            repositoryID: workspaceContext.repositoryID,
            repositoryFullName: workspaceContext.repositoryFullName,
            bootstrapSessionID: workspaceContext.bootstrapSessionID,
            installLaunchTime: workspaceContext.installLaunchTime,
            attestedAt: .now
        )
        persist(attestation, key: sidekickConnectorScopeAttestationDefaultsKey)
        bootstrapErrorMessage = nil
    }

    func hasRecentConnectorScopeAttestation(
        for workspaceContext: GitHubWorkspaceContext,
        chatgptEmail: String?
    ) -> Bool {
        let normalizedEmail = (chatgptEmail ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedEmail.isEmpty,
              let attestation = loadAttestation() else {
            return false
        }

        guard attestation.chatgptEmail == normalizedEmail,
              attestation.githubLogin == workspaceContext.githubLogin,
              attestation.repositoryID == workspaceContext.repositoryID,
              attestation.repositoryFullName == workspaceContext.repositoryFullName,
              attestation.bootstrapSessionID == workspaceContext.bootstrapSessionID,
              attestation.installLaunchTime == workspaceContext.installLaunchTime else {
            return false
        }

        return Date().timeIntervalSince(attestation.attestedAt) <= attestationMaximumAge
    }

    func connectorReviewURL() -> URL? {
        workspaceContext?.connectorRepairURL ?? activeBootstrapSession?.workspace?.connectorRepairURL
    }

    func recordBootstrapErrorMessage(_ message: String?) {
        bootstrapErrorMessage = message
    }

    func clearSessionState() {
        workspaceContext = nil
        activeBootstrapSession = nil
        bootstrapErrorMessage = nil
        defaults.removeObject(forKey: sidekickGitHubWorkspaceContextDefaultsKey)
        defaults.removeObject(forKey: sidekickGitHubBootstrapSessionDefaultsKey)
        defaults.removeObject(forKey: sidekickConnectorScopeAttestationDefaultsKey)
    }

    private var bootstrapServiceBaseURL: URL? {
        let rawValue = ProcessInfo.processInfo.environment["SIDEKICK_GITHUB_BOOTSTRAP_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawValue, !rawValue.isEmpty {
            return URL(string: rawValue)
        }

        let infoValue = (Bundle.main.object(forInfoDictionaryKey: "SidekickGitHubBootstrapBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let infoValue,
              !infoValue.isEmpty,
              !infoValue.contains("$(") else {
            return nil
        }

        return URL(string: infoValue)
    }

    private func verifyBootstrapServiceReachability(baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode) else {
                throw GitHubServiceError.bootstrapServiceUnavailable(baseURL)
            }
        } catch {
            throw normalizeBootstrapTransportError(error, baseURL: baseURL)
        }
    }

    private func normalizeBootstrapTransportError(_ error: Error, baseURL: URL) -> Error {
        if error is GitHubServiceError {
            return error
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return GitHubServiceError.bootstrapServiceUnavailable(baseURL)
            default:
                break
            }
        }

        return error
    }

    private func loadAttestation() -> ConnectorScopeAttestation? {
        Self.loadValue(
            ConnectorScopeAttestation.self,
            defaults: defaults,
            key: sidekickConnectorScopeAttestationDefaultsKey,
            decoder: decoder
        )
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func loadValue<T: Decodable>(
        _ type: T.Type,
        defaults: UserDefaults,
        key: String,
        decoder: JSONDecoder
    ) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }
}
