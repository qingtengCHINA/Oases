import Foundation
import Observation
@preconcurrency import WebKit

/// A browser challenge is a user interaction boundary, not a recoverable
/// network error. The agent pauses the current browser call while the user
/// works in the same persistent WKWebView, then resumes extraction without
/// sending credentials or page contents through a second transport.
struct BrowserApprovalRequest: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID?
    let callID: String?
    let sessionID: String
    let challenge: BrowserChallenge
    let url: String
    let title: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        callID: String? = nil,
        sessionID: String,
        challenge: BrowserChallenge,
        url: String,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.callID = callID
        self.sessionID = sessionID
        self.challenge = challenge
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }

    var challengeTitle: String {
        switch challenge {
        case .login: return String(localized: "请在浏览器中完成登录", comment: "Browser approval sheet title: the agent paused so the user can sign in on the page")
        case .captcha: return String(localized: "请在浏览器中完成验证", comment: "Browser approval sheet title: the agent paused so the user can solve a CAPTCHA/verification")
        case .payment: return String(localized: "请确认支付页面", comment: "Browser approval sheet title: the agent reached a payment page and needs the user to confirm")
        case .destructiveAction: return String(localized: "请确认不可逆操作", comment: "Browser approval sheet title: the page asks for an irreversible action and needs the user to confirm")
        }
    }

    /// The request identity deliberately excludes query strings and fragments
    /// so an approval can be resumed without persisting URL credentials.
    var approvalKey: String {
        let safeURL: String
        if var components = URLComponents(string: url) {
            components.query = nil
            components.fragment = nil
            safeURL = components.string ?? url
        } else {
            safeURL = url
        }
        return [
            runID?.uuidString ?? "no-run",
            sessionID,
            challenge.rawValue,
            safeURL
        ].joined(separator: "|")
    }

    var persistenceSafeCopy: BrowserApprovalRequest {
        var safeURL = url
        if var components = URLComponents(string: url) {
            components.query = nil
            components.fragment = nil
            safeURL = components.string ?? url
        }
        return BrowserApprovalRequest(
            id: id,
            runID: runID,
            callID: callID,
            sessionID: sessionID,
            challenge: challenge,
            url: safeURL,
            title: String(title.prefix(240)),
            createdAt: createdAt
        )
    }
}

enum BrowserApprovalError: LocalizedError, Equatable, Sendable {
    case presentationUnavailable
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .presentationUnavailable:
            return String(localized: "浏览器需要用户在前台完成验证，但当前没有可用的浏览器界面。", comment: "Error when the agent's browser needs the user to verify in the foreground but no browser UI is available")
        case .cancelled:
            return String(localized: "用户取消了浏览器验证。", comment: "Error when the user cancelled the browser verification/approval sheet")
        case .timedOut:
            return String(localized: "浏览器验证等待超时。", comment: "Error when waiting for the user to finish browser verification timed out")
        }
    }
}

@MainActor
@Observable
final class BrowserApprovalCenter {
    static let shared = BrowserApprovalCenter()

    var pending: BrowserApprovalRequest?

    private enum Decision: String, Codable {
        case approved
        case cancelled
    }

    private struct PersistedState: Codable {
        let request: BrowserApprovalRequest
        let decision: Decision?
        let savedAt: Date
    }

    private let timeoutNanoseconds: UInt64
    private let persistenceURL: URL
    @ObservationIgnored private var persistedState: PersistedState?
    @ObservationIgnored private var continuations: [String: [CheckedContinuation<Bool, Error>]] = [:]
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var presentationAvailable = false
    @ObservationIgnored private var approvalStateChanged: (@Sendable (Bool) async -> Void)?

    init(
        timeoutNanoseconds: UInt64 = 15 * 60 * 1_000_000_000,
        persistenceURL: URL? = nil
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.persistedState = Self.loadState(from: self.persistenceURL)
        if let state = self.persistedState,
           Date().timeIntervalSince(state.savedAt) < 30 * 60 {
            // A decision may have been made while the AgentExecutor was not
            // attached yet (for example, after the app was relaunched). Keep
            // that decision for the next matching waitForApproval call. The
            // old implementation discarded it during init, so an approval
            // made on the restored sheet could never resume the run.
            self.pending = state.decision == nil ? state.request : nil
        } else {
            self.pending = nil
            if self.persistedState != nil {
                self.persistedState = nil
                Self.removeState(at: self.persistenceURL)
            }
        }
    }

    func setPresentationAvailable(_ available: Bool) {
        presentationAvailable = available
        // Keep the request alive while the scene is backgrounded. The sheet
        // is bound to `pending` and will be presented again when the scene
        // returns to the foreground, preserving the same WebKit session.
    }

    func waitForApproval(_ request: BrowserApprovalRequest) async throws -> Bool {
        if let persistedState,
           persistedState.request.approvalKey == request.approvalKey,
           let decision = persistedState.decision {
            self.persistedState = nil
            Self.removeState(at: persistenceURL)
            switch decision {
            case .approved:
                return true
            case .cancelled:
                throw BrowserApprovalError.cancelled
            }
        }

        if let pending, pending.approvalKey != request.approvalKey {
            // Only one foreground WebKit challenge can be shown at a time.
            // Failing the second request explicitly is safer than silently
            // cancelling the first task and losing its persisted checkpoint.
            throw BrowserApprovalError.presentationUnavailable
        }

        let isNewRequest = pending == nil
        if isNewRequest {
            pending = request
            persistedState = PersistedState(
                request: request.persistenceSafeCopy,
                decision: nil,
                savedAt: Date()
            )
            persistState()
            approvalStateChanged = AgentToolInvocationContext.current?.onApprovalStateChanged
            if let approvalStateChanged {
                await approvalStateChanged(true)
            }
            scheduleTimeout(for: request.approvalKey)
        }

        let approvalKey = request.approvalKey
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuations[approvalKey, default: []].append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(.failure(CancellationError()))
            }
        }
    }

    func approve() {
        resolve(.success(true), decision: .approved)
    }

    func cancel() {
        resolve(.failure(BrowserApprovalError.cancelled), decision: .cancelled)
    }

    func webView(for sessionID: String) -> WKWebView? {
        AgentBrowserController.shared.webView(for: sessionID)
    }

    private func resolve(_ result: Result<Bool, Error>, decision: Decision? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let approvalKey = pending?.approvalKey
        let continuations = approvalKey.flatMap { self.continuations.removeValue(forKey: $0) } ?? []
        let approvalStateChanged = approvalStateChanged
        self.approvalStateChanged = nil
        if continuations.isEmpty, let request = pending, let decision {
            persistedState = PersistedState(
                request: request.persistenceSafeCopy,
                decision: decision,
                savedAt: Date()
            )
            persistState()
        } else {
            persistedState = nil
            Self.removeState(at: persistenceURL)
        }
        pending = nil
        if let approvalStateChanged {
            Task { await approvalStateChanged(false) }
        }
        switch result {
        case .success(let approved):
            continuations.forEach { $0.resume(returning: approved) }
        case .failure(let error):
            continuations.forEach { $0.resume(throwing: error) }
        }
    }

    private func scheduleTimeout(for approvalKey: String) {
        timeoutTask?.cancel()
        let timeoutNanoseconds = self.timeoutNanoseconds
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.pending?.approvalKey == approvalKey else { return }
            self.resolve(.failure(BrowserApprovalError.timedOut))
        }
    }

    private func persistState() {
        guard let persistedState else { return }
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(persistedState)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Approval remains functional in memory if local persistence is
            // unavailable; no web content or credentials are logged here.
        }
    }

    private static func defaultPersistenceURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("OasesChat", isDirectory: true)
            .appendingPathComponent("browser-approval.json")
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private static func removeState(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
