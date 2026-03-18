import Combine
import CryptoKit
import Foundation
import Network
import Security
import UIKit

private let defaultAuthScopes = "openid profile email offline_access"

@MainActor
final class AuthService: ObservableObject {
    enum AuthError: LocalizedError {
        case notAuthenticated
        case tokenExpired
        case refreshFailed(String)
        case keychainFailure(OSStatus)
        case oauthError(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Sign in with ChatGPT to use Sidekick."
            case .tokenExpired:
                return "Your session expired. Please sign in again."
            case .refreshFailed(let msg):
                return "Could not refresh session: \(msg)"
            case .keychainFailure:
                return "Sidekick could not update the secure credential store."
            case .oauthError(let msg):
                return msg
            case .timedOut:
                return "Sign-in timed out. Please try again."
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var userEmail: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInURL: URL?

    // MARK: - Constants

    private let clientID: String
    private let issuer: String
    private let callbackPort: UInt16
    private let originator = "codex_cli_rs"
    private var redirectURI: String { "http://localhost:\(callbackPort)/auth/callback" }
    private let scopes: String

    private let keychain = KeychainStore(service: "com.vineet.sidekick.oauth")
    private let accessTokenAccount = "access-token"
    private let refreshTokenAccount = "refresh-token"
    private let expiryAccount = "token-expiry"
    private let emailAccount = "user-email"
    private var callbackServer: OAuthCallbackServer?

    init(
        clientID: String = ProcessInfo.processInfo.environment["SIDEKICK_AUTH_CLIENT_ID"] ?? "app_EMoamEEZ73f0CkXaXp7hrann",
        issuer: String = ProcessInfo.processInfo.environment["SIDEKICK_AUTH_ISSUER"] ?? "https://auth.openai.com",
        callbackPort: UInt16 = UInt16(ProcessInfo.processInfo.environment["SIDEKICK_AUTH_CALLBACK_PORT"] ?? "") ?? 1455,
        scopes: String = ProcessInfo.processInfo.environment["SIDEKICK_AUTH_SCOPE"] ?? defaultAuthScopes
    ) {
        self.clientID = clientID
        self.issuer = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.callbackPort = callbackPort
        self.scopes = scopes

        let hasRefresh = ((try? keychain.load(account: refreshTokenAccount)) ?? "").isEmpty == false
        isAuthenticated = hasRefresh
        userEmail = try? keychain.load(account: emailAccount)
        if userEmail?.isEmpty == true { userEmail = nil }
    }

    // MARK: - Browser PKCE Sign In

    func signIn() async throws {
        if isSigningIn {
            return
        }

        isSigningIn = true
        defer {
            callbackServer?.stop()
            callbackServer = nil
            signInURL = nil
            isSigningIn = false
        }

        // Generate PKCE pair
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        // Build auth URL
        var components = URLComponents(string: "\(issuer)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator),
        ]

        guard let authURL = components.url else {
            throw AuthError.oauthError("Failed to build authorization URL.")
        }

        let server = OAuthCallbackServer(port: callbackPort)
        callbackServer = server
        try await server.start()
        signInURL = authURL
        let callbackURL = try await server.waitForCallback(timeout: 300)
        try Task.checkCancellation()

        guard let cbComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.oauthError("Invalid authorization callback.")
        }

        if let oauthError = cbComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = cbComponents.queryItems?.first(where: { $0.name == "error_description" })?.value
            let fallback = oauthError.replacingOccurrences(of: "_", with: " ")
            throw AuthError.oauthError(normalizeOAuthMessage(description ?? fallback))
        }

        guard let code = cbComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.oauthError("No authorization code in callback.")
        }

        let returnedState = cbComponents.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            throw AuthError.oauthError("OAuth state mismatch.")
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
    }

    func cancelSignIn() {
        guard isSigningIn else { return }
        callbackServer?.cancel()
        signInURL = nil
    }

    // MARK: - Sign Out

    func signOut() {
        cancelSignIn()
        try? keychain.delete(account: accessTokenAccount)
        try? keychain.delete(account: refreshTokenAccount)
        try? keychain.delete(account: expiryAccount)
        try? keychain.delete(account: emailAccount)
        isAuthenticated = false
        userEmail = nil
    }

    // MARK: - Get Valid Token

    func validToken() async throws -> String {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }

        if let expiry = tokenExpiry(), expiry > Date().addingTimeInterval(5 * 60),
           let token = try? keychain.load(account: accessTokenAccount), !token.isEmpty {
            return token
        }

        try await refreshAccessToken()

        guard let token = try? keychain.load(account: accessTokenAccount), !token.isEmpty else {
            throw AuthError.tokenExpired
        }

        return token
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        let url = URL(string: "\(issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        request.httpBody = body.urlEncodedFormData()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Token exchange failed."
            throw AuthError.oauthError(msg)
        }

        try processTokenResponse(data: data)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws {
        guard let refreshToken = try? keychain.load(account: refreshTokenAccount),
              !refreshToken.isEmpty else {
            signOut()
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Refresh failed."
            signOut()
            throw AuthError.refreshFailed(msg)
        }

        try processTokenResponse(data: data)
    }

    // MARK: - Process Token Response

    private func processTokenResponse(data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AuthError.oauthError("Invalid token response.")
        }

        try keychain.save(accessToken, account: accessTokenAccount)

        if let refreshToken = json["refresh_token"] as? String {
            try keychain.save(refreshToken, account: refreshTokenAccount)
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiry = Date().addingTimeInterval(expiresIn)
        try keychain.save(String(expiry.timeIntervalSince1970), account: expiryAccount)

        if let idToken = json["id_token"] as? String {
            if let email = extractEmail(from: idToken) {
                try? keychain.save(email, account: emailAccount)
                userEmail = email
            }
        }

        isAuthenticated = true
    }

    private func normalizeOAuthMessage(_ raw: String) -> String {
        let plusDecoded = raw.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func tokenExpiry() -> Date? {
        guard let raw = try? keychain.load(account: expiryAccount),
              let interval = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func extractEmail(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload.append("=") }
        let padded = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }
}

// MARK: - Local OAuth Callback Server

private final class OAuthCallbackServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.vineet.sidekick.oauth-callback")
    private var listener: NWListener?
    private var listenerReadyContinuation: CheckedContinuation<Void, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(port: UInt16) {
        self.port = port
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.listener == nil else {
                    continuation.resume(returning: ())
                    return
                }

                do {
                    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: self.port)!)
                    self.listenerReadyContinuation = continuation
                    self.listener = listener

                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handleConnection(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func cancel() {
        queue.async {
            self.finishCallback(with: .failure(CancellationError()))
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.continuation = cont
                let workItem = DispatchWorkItem { [weak self] in
                    self?.finishCallback(with: .failure(AuthService.AuthError.timedOut))
                }
                self.timeoutWorkItem = workItem
                self.queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerReadyContinuation?.resume(returning: ())
            listenerReadyContinuation = nil
        case .failed(let error):
            listenerReadyContinuation?.resume(throwing: error)
            listenerReadyContinuation = nil
            finishCallback(with: .failure(error))
            listener?.cancel()
            listener = nil
        case .cancelled:
            listenerReadyContinuation?.resume(throwing: CancellationError())
            listenerReadyContinuation = nil
        default:
            break
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            guard let firstLine = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let target = String(parts[1])

            let path = URL(string: "http://localhost:\(self.port)\(target)")?.path ?? target
            let isCallback = path == "/auth/callback"
            let html = isCallback ? Self.successHTML : Self.notFoundHTML
            let statusLine = isCallback ? "HTTP/1.1 200 OK" : "HTTP/1.1 404 Not Found"
            let response = "\(statusLine)\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if isCallback, let url = URL(string: "http://localhost:\(self.port)\(target)") {
                self.finishCallback(with: .success(url))
            }
        }
    }

    private func finishCallback(with result: Result<URL, Error>) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static let successHTML = """
    <html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;\
    align-items:center;height:100vh;margin:0;background:#f7fbfe;color:#102230">\
    <div style="max-width:320px;text-align:center"><h1>Signed in</h1>\
    <p>You can close this page and return to Sidekick.</p></div>\
    </body></html>
    """

    private static let notFoundHTML = """
    <html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;\
    align-items:center;height:100vh;margin:0;background:#f7fbfe;color:#102230">\
    <div style="max-width:320px;text-align:center"><h1>Not found</h1>\
    <p>This page is only used for Sidekick sign-in callbacks.</p></div>\
    </body></html>
    """
}

// MARK: - Extensions

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Dictionary where Key == String, Value == String {
    func urlEncodedFormData() -> Data {
        let encoded = map { key, value in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

// MARK: - Keychain Store

struct KeychainStore {
    let service: String

    func save(_ value: String, account: String) throws {
        try delete(account: account)

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthService.AuthError.keychainFailure(status)
        }
    }

    func load(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            return ""
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AuthService.AuthError.keychainFailure(status)
        }

        return value
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthService.AuthError.keychainFailure(status)
        }
    }
}
