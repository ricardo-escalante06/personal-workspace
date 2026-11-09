import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Google sign-in for a native app: OAuth 2.0 authorization code + PKCE in the
/// system's web-auth sheet. No client secret (iOS-type OAuth client), no server.
/// Refresh tokens live in the Keychain; access tokens only in memory.
@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Tokens {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String?
        var email: String?
    }

    enum AuthError: LocalizedError {
        case cancelled, badResponse(String), noRefreshToken
        var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .badResponse(let msg): "Google sign-in failed: \(msg)"
            case .noRefreshToken: "Google didn't return a refresh token. Remove the app at myaccount.google.com › Security › Third-party access, then connect again."
            }
        }
    }

    static let scopes = ["openid", "email", "https://www.googleapis.com/auth/calendar"]

    let clientId: String

    init(clientId: String) {
        self.clientId = clientId
    }

    /// "com.googleusercontent.apps.<id>" — Google's redirect scheme for iOS-type clients.
    var redirectScheme: String {
        "com.googleusercontent.apps." + clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    var redirectURI: String { "\(redirectScheme):/oauthredirect" }

    // MARK: Sign in

    func signIn(loginHint: String? = nil) async throws -> Tokens {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // offline + consent: always get a refresh token.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            // @Sendable: AuthenticationServices calls this on a background XPC queue, so it
            // must not be main-actor isolated (that crashed with a dispatch_assert_queue trap).
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: redirectScheme) { @Sendable url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.badResponse(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw AuthError.badResponse("missing code") }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "client_id": clientId,
        ])
        guard tokens.refreshToken != nil else { throw AuthError.noRefreshToken }
        return tokens
    }

    func refresh(refreshToken: String) async throws -> Tokens {
        var tokens = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])
        tokens.refreshToken = tokens.refreshToken ?? refreshToken
        return tokens
    }

    /// Best effort: revoke access at Google when disconnecting.
    func revoke(refreshToken: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": refreshToken])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(params)
        let (data, response) = try await URLSession.shared.data(for: request)

        struct TokenResponse: Decodable {
            var access_token: String?
            var expires_in: Double?
            var refresh_token: String?
            var id_token: String?
            var error: String?
            var error_description: String?
        }
        let body = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = body.access_token else {
            throw AuthError.badResponse(body.error_description ?? body.error ?? "HTTP error")
        }
        return Tokens(
            accessToken: access,
            expiresAt: Date().addingTimeInterval((body.expires_in ?? 3600) - 60),
            refreshToken: body.refresh_token,
            email: body.id_token.flatMap(Self.email(fromIDToken:))
        )
    }

    // MARK: Helpers

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
            #endif
        }
    }

    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &g)! })
    }

    static func formBody(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Refresh tokens in the Keychain, one item per Google account.
enum GoogleKeychain {
    static let service = "com.rescalante.workspace.google"

    static func save(_ token: String, for email: String) {
        delete(email)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(_ email: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
