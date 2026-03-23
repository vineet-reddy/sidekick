import Combine
import Foundation

struct SidekickBackendSession: Codable, Equatable {
    let installSessionID: String
    let sessionToken: String
    let createdAt: Date
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case installSessionID = "install_session_id"
        case sessionToken = "session_token"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct GitHubExportContext: Codable, Equatable {
    let id: String
    let githubLogin: String
    let repoOwner: String
    let repoName: String
    let repoFullName: String
    let repoURL: URL?
    let visibility: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case githubLogin = "github_login"
        case repoOwner = "repo_owner"
        case repoName = "repo_name"
        case repoFullName = "repo_full_name"
        case repoURL = "repo_url"
        case visibility
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GitHubConnectSession: Codable, Equatable {
    let sessionID: String
    let status: String
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date
    let browserURL: URL
    let connection: GitHubExportContext?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case browserURL = "browser_url"
        case connection
    }

    var isTerminal: Bool {
        status == "completed" || status == "failed"
    }
}

private struct DeviceSessionResponse: Codable {
    let installSessionID: String
    let sessionToken: String
    let createdAt: Date
    let lastSeenAt: Date
    let githubConnection: GitHubExportContext?

    enum CodingKeys: String, CodingKey {
        case installSessionID = "install_session_id"
        case sessionToken = "session_token"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case githubConnection = "github_connection"
    }

    var session: SidekickBackendSession {
        SidekickBackendSession(
            installSessionID: installSessionID,
            sessionToken: sessionToken,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt
        )
    }
}

@MainActor
final class GitHubService: ObservableObject {
    enum GitHubServiceError: LocalizedError {
        case backendNotConfigured
        case invalidResponse
        case missingDeviceSession
        case invalidSessionToken

        var errorDescription: String? {
            switch self {
            case .backendNotConfigured:
                return "Sidekick could not find its backend URL."
            case .invalidResponse:
                return "The Sidekick backend returned an unexpected response."
            case .missingDeviceSession:
                return "Sidekick could not create a device session."
            case .invalidSessionToken:
                return "invalid_session_token"
            }
        }
    }

    @Published private(set) var backendSession: SidekickBackendSession?
    @Published private(set) var exportContext: GitHubExportContext?
    @Published private(set) var activeConnectSession: GitHubConnectSession?
    @Published private(set) var connectionErrorMessage: String?

    private let session: URLSession
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let requestTimeout: TimeInterval = 12

    init(
        session: URLSession? = nil,
        defaults: UserDefaults = .standard
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        backendSession = Self.loadValue(
            SidekickBackendSession.self,
            defaults: defaults,
            key: sidekickBackendSessionDefaultsKey,
            decoder: decoder
        )
        exportContext = Self.loadValue(
            GitHubExportContext.self,
            defaults: defaults,
            key: sidekickGitHubExportContextDefaultsKey,
            decoder: decoder
        )
        activeConnectSession = Self.loadValue(
            GitHubConnectSession.self,
            defaults: defaults,
            key: sidekickGitHubConnectSessionDefaultsKey,
            decoder: decoder
        )
        if let activeConnectSession,
           activeConnectSession.browserURL.host?.lowercased() != "github.com" {
            self.activeConnectSession = nil
            defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
        }
    }

    var isConnected: Bool {
        exportContext != nil
    }

    var repositoryURL: URL? {
        exportContext?.repoURL
    }

    var repositoryDisplayName: String {
        exportContext?.repoFullName ?? "Connect GitHub"
    }

    func ensureDeviceSession(forceRefresh: Bool = false) async throws -> SidekickBackendSession {
        guard let baseURL = backendBaseURL else {
            throw GitHubServiceError.backendNotConfigured
        }
        invalidatePersistedStateIfBackendChanged(baseURL: baseURL)

        if !forceRefresh, let backendSession {
            return backendSession
        }

        let response = try await createOrResumeDeviceSession(baseURL: baseURL)

        backendSession = response.session
        exportContext = response.githubConnection
        connectionErrorMessage = nil
        persist(response.session, key: sidekickBackendSessionDefaultsKey)
        if let githubConnection = response.githubConnection {
            persist(githubConnection, key: sidekickGitHubExportContextDefaultsKey)
        } else {
            defaults.removeObject(forKey: sidekickGitHubExportContextDefaultsKey)
        }
        defaults.set(baseURL.absoluteString, forKey: sidekickBackendBaseURLDefaultsKey)
        NotificationCenter.default.post(name: .sidekickGitHubConnectionChanged, object: nil)
        return response.session
    }

    func beginGitHubConnection() async throws -> URL {
        _ = try await ensureDeviceSession(forceRefresh: true)
        guard let baseURL = backendBaseURL else {
            throw GitHubServiceError.backendNotConfigured
        }

        activeConnectSession = nil
        defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)

        let connectSession: GitHubConnectSession = try await performAuthorizedRequest(
            url: baseURL.appendingPathComponent("api/github/connect/start"),
            method: "POST"
        )
        activeConnectSession = connectSession
        persist(connectSession, key: sidekickGitHubConnectSessionDefaultsKey)
        connectionErrorMessage = nil
        if let connection = connectSession.connection {
            exportContext = connection
            persist(connection, key: sidekickGitHubExportContextDefaultsKey)
            NotificationCenter.default.post(name: .sidekickGitHubConnectionChanged, object: nil)
        }
        if connectSession.isTerminal {
            defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
        }
        return connectSession.browserURL
    }

    @discardableResult
    func refreshConnectionSessionIfNeeded() async throws -> GitHubConnectSession? {
        guard let activeConnectSession,
              let baseURL = backendBaseURL else {
            return nil
        }

        do {
            let refreshed: GitHubConnectSession = try await performAuthorizedRequest(
                url: baseURL.appendingPathComponent("api/github/connect/sessions/\(activeConnectSession.sessionID)"),
                method: "GET"
            )
            self.activeConnectSession = refreshed
            persist(refreshed, key: sidekickGitHubConnectSessionDefaultsKey)
            connectionErrorMessage = refreshed.errorMessage

            if let connection = refreshed.connection {
                exportContext = connection
                persist(connection, key: sidekickGitHubExportContextDefaultsKey)
                NotificationCenter.default.post(name: .sidekickGitHubConnectionChanged, object: nil)
            }

            if refreshed.isTerminal {
                defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
            }

            return refreshed
        } catch {
            if let nsError = error as NSError?,
               nsError.localizedDescription == "unknown_session" {
                self.activeConnectSession = nil
                defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
                return nil
            }
            throw error
        }
    }

    func clearConnectionState() {
        exportContext = nil
        activeConnectSession = nil
        connectionErrorMessage = nil
        defaults.removeObject(forKey: sidekickGitHubExportContextDefaultsKey)
        defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
        NotificationCenter.default.post(name: .sidekickGitHubConnectionChanged, object: nil)
    }

    private func createOrResumeDeviceSession(baseURL: URL) async throws -> DeviceSessionResponse {
        let payload = [
            "device_id": deviceID
        ]
        return try await performRequest(
            url: baseURL.appendingPathComponent("api/device/session"),
            method: "POST",
            body: payload,
            authorized: false
        )
    }

    private func performAuthorizedRequest<Response: Decodable>(
        url: URL,
        method: String,
        body: [String: Any]? = nil
    ) async throws -> Response {
        _ = try await ensureDeviceSession()

        do {
            return try await performRequest(
                url: url,
                method: method,
                body: body,
                authorized: true
            )
        } catch GitHubServiceError.invalidSessionToken {
            _ = try await ensureDeviceSession(forceRefresh: true)
            return try await performRequest(
                url: url,
                method: method,
                body: body,
                authorized: true
            )
        } catch {
            throw error
        }
    }

    private var backendBaseURL: URL? {
        let environmentValue = ProcessInfo.processInfo.environment["SIDEKICK_BACKEND_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return URL(string: environmentValue)
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

    private var deviceID: String {
        if let stored = defaults.string(forKey: sidekickBackendDeviceIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: sidekickBackendDeviceIDDefaultsKey)
        return generated
    }

    private func performRequest<Response: Decodable>(
        url: URL,
        method: String,
        body: [String: Any]? = nil,
        authorized: Bool
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if authorized {
            guard let token = backendSession?.sessionToken else {
                throw GitHubServiceError.missingDeviceSession
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard let httpResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            if httpResponse?.statusCode == 401,
               let error = decodeErrorMessage(data: data) as NSError?,
               error.localizedDescription == GitHubServiceError.invalidSessionToken.localizedDescription {
                backendSession = nil
                exportContext = nil
                activeConnectSession = nil
                defaults.removeObject(forKey: sidekickBackendSessionDefaultsKey)
                defaults.removeObject(forKey: sidekickGitHubExportContextDefaultsKey)
                defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
                NotificationCenter.default.post(name: .sidekickGitHubConnectionChanged, object: nil)
                throw GitHubServiceError.invalidSessionToken
            }
            throw decodeErrorMessage(data: data) ?? GitHubServiceError.invalidResponse
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw GitHubServiceError.invalidResponse
        }
    }

    private func decodeErrorMessage(data: Data) -> Error? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = object["message"] as? String {
            return NSError(
                domain: "com.vineet.sidekick.github",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        if let error = object["error"] as? String {
            if error == GitHubServiceError.invalidSessionToken.localizedDescription {
                return GitHubServiceError.invalidSessionToken
            }
            return NSError(domain: "com.vineet.sidekick.github", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return nil
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func invalidatePersistedStateIfBackendChanged(baseURL: URL) {
        let normalized = baseURL.absoluteString
        let stored = defaults.string(forKey: sidekickBackendBaseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let stored, !stored.isEmpty else {
            if backendSession != nil || exportContext != nil || activeConnectSession != nil {
                backendSession = nil
                exportContext = nil
                activeConnectSession = nil
                connectionErrorMessage = nil
                defaults.removeObject(forKey: sidekickBackendSessionDefaultsKey)
                defaults.removeObject(forKey: sidekickGitHubExportContextDefaultsKey)
                defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
            }
            defaults.set(normalized, forKey: sidekickBackendBaseURLDefaultsKey)
            return
        }

        guard stored != normalized else {
            return
        }

        backendSession = nil
        exportContext = nil
        activeConnectSession = nil
        connectionErrorMessage = nil
        defaults.removeObject(forKey: sidekickBackendSessionDefaultsKey)
        defaults.removeObject(forKey: sidekickGitHubExportContextDefaultsKey)
        defaults.removeObject(forKey: sidekickGitHubConnectSessionDefaultsKey)
        defaults.set(normalized, forKey: sidekickBackendBaseURLDefaultsKey)
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
