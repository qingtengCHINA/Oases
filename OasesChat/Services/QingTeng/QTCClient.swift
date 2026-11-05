import Foundation

/// Where the QingTeng account lives (`qtc-center/docs/app-integration-guide.md`).
/// Only the public app id ships in the app; the backend key never does.
enum QTCConfig {
    static let baseURL = URL(string: "https://api.qingtengstudio.com")!
    /// The `X-QTC-App` id, and the `qtc-oases://oauth` return address for GitHub and Microsoft.
    static let appID = "oases"
    /// The audience of Oases Chat's Sign in with Apple codes (its bundle id, exact case), sent when deleting the account.
    static let appleClientID = "dev.oases.chat.ios"
}

/// A signed-in QingTeng account: the session token (a 30-day JWT) and its user id.
struct QTCSession: Codable, Equatable, Sendable {
    let token: String
    let userId: String
}

/// Printing a session never shows its token (it must not reach any log).
extension QTCSession: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "QTCSession(userId: \(userId), token: <redacted>)" }
    var debugDescription: String { description }
}

/// `GET /v1/me`, the parts Oases Chat shows. Oases Chat uses the account system only:
/// the QTC balance, gifts and the rest are not decoded and never shown.
struct QTCMe: Decodable, Equatable, Sendable {
    /// A sign-in method on the account. `provider` is an open set (apple,
    /// github, microsoft, ethereum, solana, and more later): never an enum,
    /// so a new one can't break decoding. `subject` is internal, not for display.
    struct Identity: Decodable, Equatable, Sendable {
        let provider: String
        let subject: String
    }

    /// Only Arc: Solana is cancelled (2026-10-23), so the `solana` field QTC
    /// may still send is not decoded and can never be shown.
    struct PayoutAddresses: Decodable, Equatable, Sendable {
        let arc: String?
    }

    let userId: String
    /// The account's permanent short number (shown as `#000001` on the ID card).
    /// Optional so a profile without it still decodes.
    let uid: Int?
    let identities: [Identity]
    let payoutAddresses: PayoutAddresses

    /// A UID as shown: `#` and at least 6 digits (482913 → "#482913", 1 → "#000001").
    static func formatUid(_ uid: Int) -> String {
        let digits = String(uid)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }
}

enum QTCError: Error, Equatable, Sendable {
    /// 401: signed out, expired, revoked on another device, deleted, or a credential that didn't verify.
    case unauthorized
    /// 409 `account_not_found`: no account has this GitHub / Microsoft login yet; the result code is still unused.
    case accountNotFound(provider: String)
    /// 409 `identity_taken`: the login belongs to another account.
    case identityTaken
    /// 503 `provider_unavailable`: that login isn't switched on at QTC.
    case providerUnavailable
    /// 400 `invalid_address`.
    case invalidAddress
    /// 429.
    case rateLimited
    /// 5xx (`internal_error`, `db_unavailable`, …).
    case unavailable
    /// No answer: offline, timed out, cancelled.
    case offline
    /// Any other answer, including a 2xx that didn't decode.
    case server(status: Int, code: String?)

    /// The QTC error behind a caught error (anything else counts as no answer).
    static func from(_ error: any Error) -> QTCError {
        error as? QTCError ?? .offline
    }
}

/// Result of `POST /v1/auth/oauth/exchange`.
enum OAuthExchange: Equatable, Sendable {
    case signedIn(QTCSession, created: Bool)
    case linked(alreadyBound: Bool)
}

/// The QingTeng account service shared by the app family (ported from
/// K线艺术家's `QTCClient`, account endpoints only: no balance, no QTC
/// purchases, no spending, no gifts).
///
/// Nothing here logs: session tokens, Apple identity tokens and
/// authorization codes, OAuth codes and verifiers, and payout addresses
/// must never reach a log.
actor QTCClient {
    private let baseURL: URL
    private let appID: String
    private let session: URLSession

    init(baseURL: URL = QTCConfig.baseURL, appID: String = QTCConfig.appID, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appID = appID
        self.session = session
    }

    // MARK: - Signing in

    /// `POST /v1/auth/apple` with the identity token Sign in with Apple just gave (send it at once; it is short-lived).
    func signInWithApple(idToken: String) async throws(QTCError) -> (session: QTCSession, created: Bool) {
        let login: Login = try await value("v1/auth/apple", json: ["idToken": idToken])
        return (login.session, login.created)
    }

    /// `POST /v1/auth/oauth/start`: the GitHub / Microsoft page to open. With
    /// a session token it links that login to the account instead of signing in.
    func oauthStart(provider: String, codeChallenge: String, linkingWith token: String?) async throws(QTCError) -> URL {
        struct Start: Decodable { let url: URL }
        let start: Start = try await value("v1/auth/oauth/start", json: [
            "provider": provider,
            "returnTo": "qtc-\(appID)://oauth",
            "codeChallenge": codeChallenge,
            "mode": token == nil ? "login" : "link",
        ], token: token)
        return start.url
    }

    /// `POST /v1/auth/oauth/exchange`. `createNew` (a JSON boolean, sent only
    /// when true) repeats a sign-in that answered `accountNotFound`, with the
    /// same code and verifier, after the user chose to create an account.
    func oauthExchange(code: String, codeVerifier: String, createNew: Bool, linkingWith token: String?) async throws(QTCError) -> OAuthExchange {
        var body: [String: Any] = ["code": code, "codeVerifier": codeVerifier]
        if createNew { body["createNew"] = true }
        if token == nil {
            let login: Login = try await value("v1/auth/oauth/exchange", json: body)
            return .signedIn(login.session, created: login.created)
        }
        let link: Binding = try await value("v1/auth/oauth/exchange", json: body, token: token)
        return .linked(alreadyBound: link.isAlreadyBound)
    }

    /// `POST /v1/auth/refresh`: a new 30-day token. No body and no `Content-Type`.
    func refresh(token: String) async throws(QTCError) -> QTCSession {
        try await value("v1/auth/refresh", token: token)
    }

    // MARK: - Account

    func me(token: String) async throws(QTCError) -> QTCMe {
        try await value("v1/me", method: "GET", token: token)
    }

    /// `POST /v1/me/identities/apple`. Returns true when this Apple account
    /// was already bound to the signed-in one.
    func bindApple(idToken: String, token: String) async throws(QTCError) -> Bool {
        let binding: Binding = try await value("v1/me/identities/apple", json: ["idToken": idToken], token: token)
        return binding.isAlreadyBound
    }

    /// `PUT /v1/me/payout-address` for Arc, the only chain (Solana is
    /// cancelled); a nil address clears it.
    func setPayoutAddress(arc address: String?, token: String) async throws(QTCError) -> QTCMe.PayoutAddresses {
        struct Answer: Decodable { let payoutAddresses: QTCMe.PayoutAddresses }
        let answer: Answer = try await value(
            "v1/me/payout-address", method: "PUT", json: ["chain": "arc", "address": address ?? NSNull()], token: token
        )
        return answer.payoutAddresses
    }

    /// `POST /v1/me/delete`: deletes the whole QingTeng account in every app.
    /// An Apple authorization code (fetched again after the user confirmed)
    /// lets QTC revoke Sign in with Apple; it goes with Oases Chat's client id.
    func deleteAccount(token: String, appleAuthorizationCode: String?) async throws(QTCError) {
        var body: [String: Any] = ["confirm": "DELETE"]
        if let appleAuthorizationCode {
            body["appleAuthorizationCode"] = appleAuthorizationCode
            body["appleClientId"] = QTCConfig.appleClientID
        }
        // The server revokes at Apple before it answers: allow well over 30 s.
        let (status, data) = try await send("v1/me/delete", json: body, token: token, sendsAppID: true, timeout: 60)
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
    }

    // MARK: - Transport

    /// `{token, userId, created}` from a sign-in.
    private struct Login: Decodable {
        let token: String
        let userId: String
        let created: Bool
        var session: QTCSession { QTCSession(token: token, userId: userId) }
    }

    /// `{status: "bound" | "already_bound"}` from a link.
    private struct Binding: Decodable {
        let status: String
        var isAlreadyBound: Bool { status == "already_bound" }
    }

    private func value<T: Decodable>(
        _ path: String, method: String = "POST", json: [String: Any]? = nil, token: String? = nil
    ) async throws(QTCError) -> T {
        let (status, data) = try await send(path, method: method, json: json, token: token)
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw .server(status: status, code: nil) }
        return value
    }

    /// One request; a body only when `json` is given (then with its `Content-Type`).
    private func send(
        _ path: String, method: String = "POST", json: [String: Any]? = nil, token: String? = nil,
        sendsAppID: Bool = false, timeout: TimeInterval? = nil
    ) async throws(QTCError) -> (status: Int, data: Data) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            guard let body = try? JSONSerialization.data(withJSONObject: json) else { throw .server(status: 0, code: "invalid_request") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if sendsAppID { request.setValue(appID, forHTTPHeaderField: "X-QTC-App") }
        if let timeout { request.timeoutInterval = timeout }
        let data: Data, response: URLResponse
        do {
            // Through the request gate like every sender tied to the one-page consent: a
            // withdrawal now cancels a sign-in, refresh or profile read in flight, instead of
            // only discarding its answer when it arrives.
            (data, response) = try await AIRequestGate.data(session, for: request)
        } catch {
            throw .offline
        }
        guard let http = response as? HTTPURLResponse else { throw .offline }
        return (http.statusCode, data)
    }

    /// Maps a non-2xx answer (`{"error": "<code>"}`) to an error.
    nonisolated static func error(status: Int, data: Data) -> QTCError {
        struct Body: Decodable {
            let error: String?
            let provider: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        switch (status, body?.error) {
        case (401, _): return .unauthorized
        case (409, "account_not_found"): return .accountNotFound(provider: body?.provider ?? "")
        case (409, "identity_taken"): return .identityTaken
        case (503, "provider_unavailable"): return .providerUnavailable
        case (400, "invalid_address"): return .invalidAddress
        case (429, _): return .rateLimited
        case (500..., _): return .unavailable
        default: return .server(status: status, code: body?.error)
        }
    }
}
