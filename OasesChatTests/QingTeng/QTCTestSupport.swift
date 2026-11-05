import Foundation
import Testing
@testable import Oases_Chat

// Test doubles for the QingTeng account tests, ported from K线艺术家's test
// support (`StubURLProtocol.swift`, `SignInFlowTests.swift`,
// `OAuthSignInTests.swift`), through Xplate, PlusProMax and Stars. Oases Chat runs on iOS 17, so a
// lock stands in for `Synchronization.Mutex` (iOS 18), as in Xplate.

/// A value behind a lock, safe to share between the test and URL loading threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A scripted HTTP server for one test. Requests to its own made-up host are
/// recorded and answered by `handler`; nothing leaves the process. Each
/// server has a unique host, so tests running in parallel never share one.
final class StubServer: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var bodyText: String? { body.flatMap { String(data: $0, encoding: .utf8) } }

        /// The body's top-level string fields (nil when the body isn't a JSON object).
        var stringFields: [String: String]? {
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return object.compactMapValues { $0 as? String }
        }

        /// The body's top-level keys.
        var keys: Set<String> {
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
            return Set(object.keys)
        }

        func decode<T: Decodable>(_ type: T.Type) -> T? {
            body.flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
    }

    enum Reply: Sendable {
        /// A status code and a JSON body.
        case json(Int, String)
        /// The request never gets an answer (offline, timed out).
        case failure(URLError.Code)
    }

    typealias Handler = @Sendable (Request) -> Reply

    let baseURL: URL
    let session: URLSession
    private let handler: Locked<Handler>
    private let received = Locked<[Request]>([])

    init(_ handler: @escaping Handler = { _ in .json(404, #"{"error":"not_found"}"#) }) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        baseURL = URL(string: "https://\(host)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        self.handler = Locked(handler)
        StubURLProtocol.register(self, host: host)
    }

    /// Everything received so far, in order.
    var requests: [Request] { received.withLock { $0 } }

    var paths: [String] { requests.map(\.path) }

    func setHandler(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    /// Recorded at once, in arrival order.
    fileprivate func record(_ request: Request) {
        received.withLock { $0.append(request) }
    }

    /// May block (a `HeldReply`), so the protocol calls it off its loading thread.
    fileprivate func reply(to request: Request) -> Reply {
        let current = handler.withLock { $0 }
        return current(request)
    }
}

/// Routes requests to the `StubServer` that owns their host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Locked<[String: StubServer]>([:])

    fileprivate static func register(_ server: StubServer, host: String) {
        servers.withLock { $0[host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let recorded = StubServer.Request(
            method: request.httpMethod ?? "GET", path: url.path(),
            headers: request.allHTTPHeaderFields ?? [:], body: body
        )
        server.record(recorded)
        // The reply is worked out off the loading thread and delivered back on it: a held reply
        // must not block the session, or a second request on it (a token refresh during a held
        // deletion) never gets through.
        let runLoop = CFRunLoopGetCurrent()
        DispatchQueue.global().async { [self] in
            let reply = server.reply(to: recorded)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                deliver(reply, for: url)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private let stopped = Locked(false)

    private func deliver(_ reply: StubServer.Reply, for url: URL) {
        guard !stopped.withLock({ $0 }) else { return }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let text):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Unsigned JWTs with a chosen expiry: the app only reads `exp`, the server checks signatures.
enum TestJWT {
    static func token(expiresAt date: Date, subject: String = "u1") -> String {
        let header = base64URL(#"{"alg":"HS256","typ":"JWT"}"#)
        let claims = base64URL(#"{"sub":"\#(subject)","exp":\#(Int(date.timeIntervalSince1970))}"#)
        return "\(header).\(claims).c2lnbmF0dXJl"
    }

    static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An in-memory keychain that counts writes.
final class QTCMemoryKeychain: Sendable {
    private let state: Locked<(stored: QTCSession?, saves: Int, clears: Int)>

    init(_ stored: QTCSession? = nil) { state = Locked((stored, 0, 0)) }

    var stored: QTCSession? { state.withLock { $0.stored } }
    var saves: Int { state.withLock { $0.saves } }
    var clears: Int { state.withLock { $0.clears } }

    var keychain: SessionKeychain {
        SessionKeychain(
            load: { self.state.withLock { $0.stored } },
            save: { session in self.state.withLock { $0.stored = session; $0.saves += 1 } },
            clear: { self.state.withLock { $0.stored = nil; $0.clears += 1 } }
        )
    }
}

/// A QTC client talking to `server`, as Oases Chat (`X-QTC-App: oases`).
func qtcClient(_ server: StubServer) -> QTCClient {
    QTCClient(baseURL: server.baseURL, appID: "oases", session: server.session)
}

/// `GET /v1/me` with these sign-in methods. The server also sends a balance
/// and gifts; Oases Chat ignores both.
func meJSON(_ providers: [String], uid: Int = 482913, arc: String? = nil, solana: String? = nil) -> String {
    let identities = providers.map { #"{"provider":"\#($0)","subject":"s-\#($0)"}"# }.joined(separator: ",")
    let quoted = { (value: String?) in value.map { "\"\($0)\"" } ?? "null" }
    return #"{"userId":"u1","uid":\#(uid),"balance":120,"identities":[\#(identities)],"payoutAddresses":{"arc":\#(quoted(arc)),"solana":\#(quoted(solana))},"gifts":{"dailyLimit":10000,"dailyRemaining":10000,"resetsAt":"2026-10-25T00:00:00.000Z"}}"#
}

/// Waits (briefly) until `condition` holds; the flows under test run in other tasks.
@MainActor
func eventuallyHolds(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

/// Stands in for Sign in with Apple.
@MainActor
final class FakeApple {
    var result: Result<AppleCredential, any Error>
    private(set) var calls = 0
    /// Runs while Apple's sheet is "up".
    var whileOpen: (@MainActor () -> Void)?

    init(_ result: Result<AppleCredential, any Error> = .success(AppleCredential(idToken: "apple-id-token", authorizationCode: "apple-code"))) {
        self.result = result
    }

    var authorizer: AppleSignIn.Authorizer {
        {
            self.calls += 1
            self.whileOpen?()
            return try self.result.get()
        }
    }
}

/// Stands in for ASWebAuthenticationSession: records what it opened and
/// "comes back" with a fixed callback (nil = the system's Cancel).
@MainActor
final class FakeBrowser {
    var callback: URL?
    private(set) var opened: [URL] = []
    /// Runs while the page is "open" (the user signs out meanwhile, the sheet closes…).
    var whileOpen: (@MainActor () -> Void)?

    init(_ callback: String?) { self.callback = callback.map { URL(string: $0)! } }

    var opener: OAuthSignIn.Opener {
        { url in
            self.opened.append(url)
            self.whileOpen?()
            return self.callback
        }
    }
}

/// Scripted replies handed out in order.
final class ReplyQueue: Sendable {
    private let replies: Locked<[StubServer.Reply]>

    init(_ replies: [StubServer.Reply]) { self.replies = Locked(replies) }

    func next() -> StubServer.Reply? {
        replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// A QTC stub for GitHub / Microsoft sign-in: `start` answers with an
/// authorize address, and each `exchange` takes the next scripted reply.
final class OAuthServer: Sendable {
    static let authorizeURL = "https://github.com/login/oauth/authorize?client_id=qtc&state=s1"

    let stub: StubServer

    init(start: StubServer.Reply = .json(200, #"{"url":"\#(OAuthServer.authorizeURL)"}"#),
         exchange: [StubServer.Reply] = [],
         me: StubServer.Reply = .json(200, meJSON([])),
         other: @escaping StubServer.Handler = { _ in .json(404, #"{"error":"not_found"}"#) }) {
        let exchanges = ReplyQueue(exchange)
        stub = StubServer { request in
            switch request.path {
            case "/v1/auth/oauth/start": return start
            // A result code is single-use: once the script runs out, exchanges are 401.
            case "/v1/auth/oauth/exchange": return exchanges.next() ?? .json(401, #"{"error":"unauthorized"}"#)
            case "/v1/me": return me
            default: return other(request)
            }
        }
    }

    var client: QTCClient { qtcClient(stub) }
    var starts: [StubServer.Request] { stub.requests.filter { $0.path == "/v1/auth/oauth/start" } }
    var exchanges: [StubServer.Request] { stub.requests.filter { $0.path == "/v1/auth/oauth/exchange" } }
}

/// A reply the server holds back until the test lets it go (the request is
/// recorded at once, so the test can act while it is "in flight").
final class HeldReply: Sendable {
    private let release = DispatchSemaphore(value: 0)
    let reply: StubServer.Reply

    init(_ reply: StubServer.Reply) { self.reply = reply }

    /// Called by the stub, on the loading thread.
    func wait() -> StubServer.Reply {
        _ = release.wait(timeout: .now() + 10)
        return reply
    }

    func letGo() { release.signal() }
}

/// A switch a test turns off mid-run.
@MainActor
final class WantedFlag {
    var value = true
}

/// The "新建账号 / 已有账号" question with a fixed answer; counts how often it was asked.
@MainActor
final class NewAccountQuestion {
    let answer: Bool
    private(set) var asked = 0

    init(answer: Bool) { self.answer = answer }

    func ask() async -> Bool {
        asked += 1
        return answer
    }
}

/// Sign in with Apple that stays "up" until the test answers it.
@MainActor
final class AppleGate {
    private var pending: CheckedContinuation<AppleCredential, any Error>?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    var authorizer: AppleSignIn.Authorizer {
        {
            try await withCheckedThrowingContinuation { continuation in
                self.pending = continuation
                self.openWaiters.forEach { $0.resume() }
                self.openWaiters = []
            }
        }
    }

    var isOpen: Bool { pending != nil }

    func waitUntilOpen() async {
        guard pending == nil else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func finish(_ result: Result<AppleCredential, any Error> = .success(AppleCredential(idToken: "apple-id-token", authorizationCode: "apple-code"))) {
        pending?.resume(with: result)
        pending = nil
    }
}

/// The account and consent copy in one language, read straight from `QingTengStrings` (not through
/// the app's language, which differs from run to run).
enum AccountCopy {
    /// The QingTeng table for `language` (a `SettingsCopy.code`).
    static func table(_ language: String) -> [String: String] {
        QingTengStrings.tables[language] ?? [:]
    }

    static func zhHans(_ key: String) -> String? { table("zh-Hans")[key] }
}
