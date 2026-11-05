import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum OAuthProvider: String, CaseIterable, Sendable {
    case github
    case microsoft
}

enum OAuthResult: Equatable, Sendable {
    /// Signed in, as after Apple: keep the token and user id.
    case signedIn(token: String, userId: String, created: Bool)
    /// Linked to the signed-in account (`alreadyBound`: it already was).
    case linked(alreadyBound: Bool)
    /// Cancel on GitHub's or Microsoft's page, or on the system sheet: say nothing.
    case cancelled
    /// No account has this login yet and the user chose "已有账号": nothing
    /// was created; they sign in the old way and link it on the account page.
    case useExistingAccount
}

enum OAuthError: Error, Equatable, Sendable {
    /// `503 provider_unavailable`: this provider isn't switched on at QTC.
    case unavailable
    /// 401: the result code expired (say, the new-account question stayed
    /// open over 2 minutes), or, while linking, the session ended.
    case unauthorized
    /// `409 identity_taken`: the login belongs to another QingTeng account.
    case identityTaken
    /// `error=failed`, no answer, or anything else.
    case failed
}

/// Sign in with GitHub or Microsoft, or link one to the signed-in account,
/// through QTC (guide §4): PKCE, the provider's page in the system browser
/// session, then QTC's exchange. The app holds no GitHub or Microsoft
/// client id or secret.
///
/// Only this run's own callback is used: it comes back through the browser
/// session's completion. `qtc-oases://oauth` reaching the app any other way
/// (`onOpenURL`) is not an `oases://` link and `OasesChatApp` drops it before `DeepLinkRouter`.
///
/// Nothing here is logged: the verifier, the result code and the session
/// token must never reach a log.
@MainActor
final class OAuthSignIn {
    /// Opens the provider's page and comes back with the callback address,
    /// or nil when the user cancelled the system sheet. Tests inject one.
    typealias Opener = @MainActor (URL) async throws -> URL?

    /// `qtc-<app_id>`: QTC sends the browser back to `qtc-<app_id>://oauth`,
    /// which must equal the `returnTo` registered on its whitelist exactly.
    nonisolated static let callbackScheme = "qtc-\(QTCConfig.appID)"

    private let client: QTCClient
    private let opener: Opener
    /// One run at a time: a second one fails at once while the first is open.
    private var running = false

    init(client: QTCClient = QTCClient(), opener: Opener? = nil) {
        self.client = client
        if let opener {
            self.opener = opener
        } else {
            let browser = WebAuthenticationOpener(callbackScheme: Self.callbackScheme)
            self.opener = { url in try await browser.open(url) }
        }
    }

    /// Without a session token: sign in (asking `confirmNewAccount` when no
    /// account has this login yet; true creates one, false never does). With
    /// one: link the provider to that account; nothing is ever created then.
    ///
    /// `isStillWanted` is asked before the browser opens and before every
    /// exchange (the step that signs in or links): once the page has closed
    /// or the session has changed, the run ends as `.cancelled` and the
    /// result code is never used.
    func run(
        _ provider: OAuthProvider,
        linkingTo token: String? = nil,
        confirmNewAccount: @MainActor () async -> Bool = { false },
        isStillWanted: @MainActor () -> Bool = { true }
    ) async throws(OAuthError) -> OAuthResult {
        guard !running else { throw .failed }
        running = true
        defer { running = false }

        // A new verifier for every run, kept in memory only.
        let verifier = Self.makeVerifier()
        let authorizeURL: URL
        do {
            authorizeURL = try await client.oauthStart(
                provider: provider.rawValue, codeChallenge: Self.challenge(for: verifier), linkingWith: token
            )
        } catch {
            switch QTCError.from(error) {
            case .providerUnavailable: throw .unavailable
            case .unauthorized: throw .unauthorized
            default: throw .failed
            }
        }

        guard isStillWanted() else { return .cancelled }
        let callback: URL?
        do {
            callback = try await opener(authorizeURL)
        } catch {
            throw .failed
        }
        guard let callback else { return .cancelled }  // the system sheet's Cancel
        guard isStillWanted() else { return .cancelled }
        guard Self.isOwnCallback(callback) else { throw .failed }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.first(where: { $0.name == "error" })?.value == "cancelled" { return .cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw .failed }

        var outcome = await exchange(code: code, verifier: verifier, createNew: false, token: token)
        if token == nil, case .failure(.accountNotFound) = outcome {
            // The code is still unused: ask, and create only on a yes, with
            // the same code and verifier.
            guard await confirmNewAccount() else { return .useExistingAccount }
            guard isStillWanted() else { return .cancelled }
            outcome = await exchange(code: code, verifier: verifier, createNew: true, token: nil)
        }
        switch outcome {
        case .success(.signedIn(let session, let created)) where token == nil:
            return .signedIn(token: session.token, userId: session.userId, created: created)
        case .success(.linked(let alreadyBound)) where token != nil:
            return .linked(alreadyBound: alreadyBound)
        case .failure(.unauthorized):
            throw .unauthorized
        case .failure(.identityTaken):
            throw .identityTaken
        default:
            throw .failed
        }
    }

    private func exchange(code: String, verifier: String, createNew: Bool, token: String?) async -> Result<OAuthExchange, QTCError> {
        do {
            return .success(try await client.oauthExchange(code: code, codeVerifier: verifier, createNew: createNew, linkingWith: token))
        } catch {
            return .failure(QTCError.from(error))
        }
    }

    /// Whether `url` is QTC sending the browser back to this app: exactly
    /// `qtc-<app_id>://oauth`, plus its query.
    nonisolated static func isOwnCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host() == "oauth" && (url.path().isEmpty || url.path() == "/")
    }

    // MARK: - PKCE (S256)

    /// 32 random bytes in base64url: 43 characters.
    nonisolated static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()  // also cryptographically secure on Apple platforms
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return base64URL(Data(bytes))
    }

    /// base64url(SHA-256(verifier)): 43 characters.
    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The provider's sign-in page in the system browser session, sharing
/// Safari's cookies (`prefersEphemeralWebBrowserSession = false`) so a user
/// already signed in to GitHub or Microsoft there needn't type a password.
/// The custom scheme needs no Info.plist entry (Oases Chat lists it anyway, in project.yml's `CFBundleURLTypes`).
@MainActor
final class WebAuthenticationOpener: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let callbackScheme: String
    /// Held while open: a released session closes its page.
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL?, any Error>?

    init(callbackScheme: String) {
        self.callbackScheme = callbackScheme
    }

    /// The callback address, or nil when the user cancelled.
    func open(_ url: URL) async throws -> URL? {
        guard pending == nil else { throw OAuthError.failed }
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            // Called once when the page closes (back on the main actor to resume).
            // It holds self until then; `session = nil` afterwards breaks the cycle.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                Task { @MainActor in
                    if let callbackURL {
                        self.finish(.success(callbackURL))
                    } else if cancelled {
                        self.finish(.success(nil))
                    } else {
                        self.finish(.failure(OAuthError.failed))
                    }
                }
            }
            // Oases Chat still runs on iOS 17.0: the callback type arrived in 17.4 (PlusProMax's form).
            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { finish(.failure(OAuthError.failed)) }
        }
    }

    /// Resumes the waiting run once; a late second completion is ignored.
    private func finish(_ result: Result<URL?, any Error>) {
        pending?.resume(with: result)
        pending = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        PresentationAnchor.current()
    }
}
