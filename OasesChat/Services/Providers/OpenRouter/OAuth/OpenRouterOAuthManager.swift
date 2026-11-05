import Foundation
import UIKit
import SafariServices
import CryptoKit
import os.log

private let logger = AppLogger(category: "OpenRouterOAuth")

@MainActor
final class OpenRouterOAuthManager: NSObject, ObservableObject {

    static let shared = OpenRouterOAuthManager()

    // MARK: - OAuth Config

    private let authBaseURL = "https://openrouter.ai/auth"
    private let keysURL = "https://openrouter.ai/api/v1/auth/keys"
    private let callbackPort: UInt16 = 3000
    private func callbackURL(path: String) -> String { "http://localhost:\(callbackPort)\(path)" }

    // MARK: - Published State

    @Published private(set) var isAuthenticating = false

    // MARK: - Private

    private var callbackServer: OAuthCallbackServer?
    private weak var safariVC: SFSafariViewController?

    private override init() {
        super.init()
    }

    // MARK: - Public API (per-instance)

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadAPIKey(instanceId: instanceId) != nil
    }

    func maskedToken(instanceId: String) -> String? {
        guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: instanceId) else { return nil }
        return ClaudeOAuthManager.maskToken(key)
    }

    func login(instanceId: String) async throws {
        logger.info("=== OpenRouter OAuth login started (instance: \(instanceId)) ===")
        callbackServer?.stop()
        callbackServer = nil
        isAuthenticating = true
        defer {
            isAuthenticating = false
            callbackServer?.stop()
            callbackServer = nil
            safariVC?.dismiss(animated: true)
            safariVC = nil
        }

        let (verifier, challenge) = generatePKCE()
        logger.info("PKCE generated — verifier length: \(verifier.count), challenge: \(challenge.prefix(16))...")
        // OpenRouter's PKCE flow has no `state` parameter, so the per-login
        // state rides in the callback PATH (a path survives however the
        // server appends `?code=`). The callback server only answers that
        // exact path, so a callback minted for any other login — or forged
        // by another local process — is rejected with a 404 and never
        // resolves this login.
        let state = Self.generateState()
        let callbackPath = Self.callbackPath(forState: state)

        // 1. Start local HTTP server
        let server = OAuthCallbackServer(port: callbackPort, callbackPath: callbackPath)
        self.callbackServer = server
        try server.start()
        logger.info("Callback server started on port \(self.callbackPort)")

        // 2. Build authorization URL
        var components = URLComponents(string: authBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL(path: callbackPath)),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let authorizationURL = components.url!
        // Host only: the full URL carries state / code_challenge.
        logger.info("Authorization URL host: \(authorizationURL.host ?? "?")")

        // 3. Open in-app Safari
        presentSafariViewController(url: authorizationURL)
        logger.info("Opened in-app Safari for OpenRouter authorization")

        // 4. Wait for callback (5 min timeout)
        logger.info("Waiting for callback...")
        let result = try await server.waitForCallback(timeout: 300)
        logger.info("Callback received — code length: \(result.code.count)")

        // 5. Exchange code for permanent API key
        logger.info("Exchanging code for API key...")
        let apiKey = try await exchangeCode(result.code, verifier: verifier)
        #if DEBUG
        // [T-log-redaction] Length only - never a key prefix.
        logger.info("API key received — \(LogRedaction.secret(apiKey))")
        #else
        logger.info("API key received")
        #endif

        // 6. Store as permanent API key (not OAuth token — it's a permanent key)
        ProviderKeychainHelper.saveAPIKey(apiKey, instanceId: instanceId)
        logger.info("=== OpenRouter OAuth login complete (instance: \(instanceId)) ===")
    }

    func logout(instanceId: String) {
        logger.info("Logout — clearing API key (instance: \(instanceId))")
        ProviderKeychainHelper.deleteAPIKey(instanceId: instanceId)
    }

    // MARK: - State

    /// Callback path carrying the per-login state: `/callback/<state>`.
    nonisolated static func callbackPath(forState state: String) -> String {
        "/callback/\(state)"
    }

    /// 32 random bytes, base64url — unguessable and path-safe.
    nonisolated static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedOpenRouter()
    }

    // MARK: - PKCE

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 96)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedOpenRouter()

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64URLEncodedOpenRouter()

        return (verifier, challenge)
    }

    // MARK: - Token Exchange

    private func exchangeCode(_ code: String, verifier: String) async throws -> String {
        let body: [String: String] = [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ]

        var request = URLRequest(url: URL(string: keysURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/oases-chat/oaseschat", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Oases Chat", forHTTPHeaderField: "X-Title")

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData

        logger.info("POST \(self.keysURL)")

        let (data, response) = try await AIRequestGate.data(URLSession.shared, for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"

        logger.info("Response status: \(statusCode)")
        // [T-oauth-no-secret-in-log] The success body carries the permanent
        // API key itself; only its key names are logged.
        if (200..<300).contains(statusCode) {
            logger.info("Response keys: \(LogRedaction.jsonKeys(data))")
        }

        guard (200..<300).contains(statusCode) else {
            #if DEBUG
            logger.error("Key exchange FAILED — status \(statusCode): \(LogRedaction.scrubTokens(String(responseBody.prefix(500))))")
            #else
            logger.error("Key exchange FAILED — status \(statusCode)")
            #endif
            throw LLMError.providerError(message: "OpenRouter key exchange failed: \(responseBody)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let key = json["key"] as? String else {
            logger.error("Missing 'key' in response: \(json.keys.joined(separator: ", "))")
            throw LLMError.decodingError(underlying: NSError(domain: "OpenRouterOAuth", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing key in response"]))
        }

        return key
    }

    // MARK: - In-App Safari

    private func presentSafariViewController(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        let vc = SFSafariViewController(url: url)
        topVC.present(vc, animated: true)
        self.safariVC = vc
    }
}

// MARK: - Helpers

private extension Data {
    func base64URLEncodedOpenRouter() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
