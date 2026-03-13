import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class AuthService: ObservableObject {
    enum AuthError: LocalizedError {
        case notAuthenticated
        case tokenExpired
        case refreshFailed(String)
        case keychainFailure(OSStatus)
        case oauthError(String)

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
            }
        }
    }

    @Published private(set) var isAuthenticated = false
    @Published private(set) var userEmail: String?

    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let authBaseURL = "https://auth.openai.com"
    private let scopes = "openid profile email offline_access"
    private let callbackScheme = "sidekick"
    private let redirectURI = "sidekick://oauth/callback"

    private let keychain = KeychainStore(service: "com.vineet.sidekick.oauth")
    private let accessTokenAccount = "access-token"
    private let refreshTokenAccount = "refresh-token"
    private let expiryAccount = "token-expiry"
    private let emailAccount = "user-email"

    private var codeVerifier: String?

    init() {
        let hasRefresh = ((try? keychain.load(account: refreshTokenAccount)) ?? "").isEmpty == false
        isAuthenticated = hasRefresh
        userEmail = try? keychain.load(account: emailAccount)
        if userEmail?.isEmpty == true { userEmail = nil }
    }

    // MARK: - Sign In

    func signIn() async throws {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        var components = URLComponents(string: "\(authBaseURL)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
        ]

        guard let authURL = components.url else {
            throw AuthError.oauthError("Failed to build authorization URL.")
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error {
                    continuation.resume(throwing: AuthError.oauthError(error.localizedDescription))
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.oauthError("No callback received."))
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = OAuthPresentationContext.shared
            session.start()
        }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.oauthError("No authorization code in callback.")
        }

        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            throw AuthError.oauthError("OAuth state mismatch.")
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
    }

    // MARK: - Sign Out

    func signOut() {
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

        // Check if current access token is still valid
        if let expiry = tokenExpiry(), expiry > Date().addingTimeInterval(5 * 60),
           let token = try? keychain.load(account: accessTokenAccount), !token.isEmpty {
            return token
        }

        // Refresh
        try await refreshAccessToken()

        guard let token = try? keychain.load(account: accessTokenAccount), !token.isEmpty else {
            throw AuthError.tokenExpired
        }

        return token
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        let url = URL(string: "\(authBaseURL)/oauth/token")!
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

        let url = URL(string: "\(authBaseURL)/oauth/token")!
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

    private func processTokenResponse(data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AuthError.oauthError("Invalid token response.")
        }

        try keychain.save(accessToken, account: accessTokenAccount)

        if let refreshToken = json["refresh_token"] as? String {
            try keychain.save(refreshToken, account: refreshTokenAccount)
        }

        // Parse expiry (default 1 hour)
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiry = Date().addingTimeInterval(expiresIn)
        try keychain.save(String(expiry.timeIntervalSince1970), account: expiryAccount)

        // Extract email from id_token if present
        if let idToken = json["id_token"] as? String {
            let email = extractEmail(from: idToken)
            if let email {
                try? keychain.save(email, account: emailAccount)
                userEmail = email
            }
        }

        isAuthenticated = true
    }

    // MARK: - Helpers

    private func tokenExpiry() -> Date? {
        guard let raw = try? keychain.load(account: expiryAccount),
              let interval = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

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

    private func extractEmail(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // Pad base64 if needed
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

// MARK: - ASWebAuthenticationSession Presentation

private class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Data Extension

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
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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
