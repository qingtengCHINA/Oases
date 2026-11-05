import Foundation

/// Whether a request to an AI provider may leave the device now, and a way to stop the ones
/// under way (讲真话's `OnlineVerificationGate`, made thread-safe for Oases Chat's actors and
/// background automations).
///
/// "AI provider" is everything a model request or a provider sign-in reaches: the Oases gateway
/// (`api.oases.dev`, chat, images, speech, App Attest enrollment), the providers the user adds
/// (OpenAI, Anthropic, Gemini, OpenRouter, xAI, Kimi, Antigravity, voice vendors, their model
/// lists and OAuth sign-ins), and what an agent run sends on the user's behalf (remote MCP
/// servers, the Jina and DuckDuckGo search and reader the agent's web tools call). All of it needs
/// the one-page consent (`AIDataSharingConsent`, every user). A model served on this device
/// (loopback) sends nothing anywhere and is exempt.
///
/// Checked three times:
/// 1. before a send (`AIConsentGate.requireConsent`, which shows the consent page as a sheet
///    instead of sending);
/// 2. right before each request leaves (`checkTransfer` / `checkBeforeSending`, and the tracked
///    `data` / `bytes` helpers every sender above goes through), against the ticket of the run the
///    request belongs to: a run begun before a withdrawal stays refused even after a re-consent;
/// 3. when the consent is taken back (`voidRequests`, from `AIConsentAutomationLifecycle`): every
///    tracked request still in flight is
///    cancelled at the transport, the chat and agent runs under way stop, and the URL sessions the
///    Anthropic clients own drop their tasks.
///
/// A refusal at step 2 throws `CancellationError`, so a run ends quietly (the send-time gate is the
/// place that explains). The share extension, the widget and the Files extension send nothing to
/// AI providers themselves: the share extension hands its content to the app, which sends it
/// through this same gate.
enum AIRequestGate {
    /// A run's claim to send, taken when it starts. Travels with the run's task (`$ticket`), so
    /// every request the run makes, in every child task, is checked against it.
    struct Ticket: Equatable, Sendable {
        fileprivate let epoch: Int
    }

    /// The ticket of the run whose task is asking (nil outside a run: a background automation,
    /// a provider sign-in, a connection test).
    @TaskLocal static var ticket: Ticket?

    private static let lock = NSLock()
    /// Tests only: replaces the consent read (`setAllowsTransferForTesting`). The unit-test host
    /// starts allowed so the existing request tests keep testing what they test.
    nonisolated(unsafe) private static var testOverride: Bool? =
        AppLaunchCoordinator.isUnitTestHost ? true : nil
    /// Bumped by every withdrawal: tickets issued before it are refused from then on.
    nonisolated(unsafe) private static var epoch = 0
    /// Requests sent through `data` / `bytes`, while they live (weak).
    nonisolated(unsafe) private static var inFlight: [ObjectIdentifier: WeakTask] = [:]
    /// Sessions whose every task is an AI request (the Anthropic clients' own sessions).
    nonisolated(unsafe) private static var sessions: [WeakSession] = []

    /// Runs under way that stop themselves on a withdrawal (chat and agent view models).
    @MainActor private static var stoppers: [Stopper] = []

    // MARK: - State

    /// Requests to AI providers may go out now: the one-page consent is given.
    static var allowsTransfer: Bool {
        lock.withLock { testOverride } ?? AIDataSharingConsent.isAccepted
    }

    /// Tests: pins `allowsTransfer` (nil reads the consent again).
    static func setAllowsTransferForTesting(_ allowed: Bool?) {
        lock.withLock { testOverride = allowed }
    }

    // MARK: - Tickets and runs

    static func issueTicket() -> Ticket {
        lock.withLock { Ticket(epoch: epoch) }
    }

    /// The consent still stands and nothing was withdrawn since the ticket was issued.
    static func accepts(_ ticket: Ticket) -> Bool {
        lock.withLock { ticket.epoch == epoch } && allowsTransfer
    }

    /// Starts a run's task carrying a new ticket: every request the run makes, in every child
    /// task, is checked against it.
    @MainActor
    static func startRun(_ operation: sending @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        $ticket.withValue(issueTicket()) {
            Task { @MainActor in await operation() }
        }
    }

    /// `owner` stops what it runs when a consent is taken back (`stop` is called on the main
    /// actor, once per withdrawal, while `owner` lives).
    @MainActor
    static func registerStopper<Owner: AnyObject>(for owner: Owner, stop: @escaping @MainActor (Owner) -> Void) {
        stoppers.removeAll { $0.owner == nil }
        stoppers.append(Stopper(owner: owner) { object in
            if let owner = object as? Owner { stop(owner) }
        })
    }

    /// An `URLSession` all of whose tasks are AI requests: a withdrawal cancels them all.
    static func registerSession(_ session: URLSession) {
        lock.withLock {
            sessions.removeAll { $0.session == nil }
            sessions.append(WeakSession(session))
        }
    }

    // MARK: - Right before a request leaves

    /// The one-page consent (and the asking run's ticket) for a request to `url`:
    /// a request without user content (a model list, a provider sign-in, App Attest), or one whose
    /// content consent was already checked where it was built. Loopback is exempt.
    static func checkTransfer(to url: URL?) throws {
        if AIDataSharingConsent.isOnDevice(url) { return }
        if let ticket {
            guard accepts(ticket) else { throw CancellationError() }
        } else {
            guard allowsTransfer else { throw CancellationError() }
        }
    }

    /// A request carrying user content: the consent (`APIError.dataSharingConsentRequired`, so the
    /// UI can offer the consent sheet), then `checkTransfer` (the run's ticket). Loopback is exempt.
    static func checkBeforeSending(to url: URL?) throws {
        if AIDataSharingConsent.isOnDevice(url) { return }
        guard AIDataSharingConsent.isAccepted else { throw APIError.dataSharingConsentRequired }
        try checkTransfer(to: url)
    }

    /// `session.data(for:)` after `checkTransfer`, tracked so a withdrawal cancels it in flight.
    static func data(_ session: URLSession, for request: URLRequest) async throws -> (Data, URLResponse) {
        try checkTransfer(to: request.url)
        guard !AIDataSharingConsent.isOnDevice(request.url) else { return try await session.data(for: request) }
        return try await session.data(for: request, delegate: InFlightTracker(admittedAt: admissionEpoch()))
    }

    /// `session.data(from:)` after `checkTransfer`, tracked.
    static func data(_ session: URLSession, from url: URL) async throws -> (Data, URLResponse) {
        try checkTransfer(to: url)
        guard !AIDataSharingConsent.isOnDevice(url) else { return try await session.data(from: url) }
        return try await session.data(from: url, delegate: InFlightTracker(admittedAt: admissionEpoch()))
    }

    /// `session.bytes(for:)` after `checkTransfer`, tracked: a withdrawal ends the stream.
    static func bytes(_ session: URLSession, for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try checkTransfer(to: request.url)
        guard !AIDataSharingConsent.isOnDevice(request.url) else { return try await session.bytes(for: request) }
        return try await session.bytes(for: request, delegate: InFlightTracker(admittedAt: admissionEpoch()))
    }

    /// The epoch a request admitted now belongs to: its run's, or the current one outside a run.
    static func admissionEpoch() -> Int {
        ticket?.epoch ?? lock.withLock { epoch }
    }

    /// Tracks a task created for a request admitted at `admitted` (a WebSocket, say). Cancelled at
    /// once when a withdrawal came in between the check and the task.
    static func track(_ task: URLSessionTask, admittedAt admitted: Int) {
        let allowed = allowsTransfer
        let cancelNow: Bool = lock.withLock {
            guard admitted == epoch, allowed else { return true }
            inFlight = inFlight.filter { $0.value.isAlive }
            inFlight[ObjectIdentifier(task)] = WeakTask(task)
            return false
        }
        if cancelNow { task.cancel() }
    }

    /// Tracked requests in flight now (tests).
    static var inFlightCount: Int {
        lock.withLock { inFlight.values.filter(\.isAlive).count }
    }

    // MARK: - Withdrawal

    /// Voids every request already sent (its run's ticket is refused from now on, even after a
    /// re-consent), cancels every tracked request and every task of the registered sessions, and
    /// stops the runs under way: nothing more leaves after a withdrawal.
    @MainActor
    static func voidRequests() {
        let (tasks, liveSessions) = lock.withLock { () -> ([URLSessionTask], [URLSession]) in
            epoch += 1
            let tasks = inFlight.values.compactMap(\.task)
            inFlight = [:]
            sessions.removeAll { $0.session == nil }
            return (tasks, sessions.compactMap(\.session))
        }
        tasks.forEach { $0.cancel() }
        for session in liveSessions {
            session.getAllTasks { $0.forEach { $0.cancel() } }
        }
        stoppers.removeAll { $0.owner == nil }
        for stopper in stoppers {
            if let owner = stopper.owner { stopper.stop(owner) }
        }
    }

    // MARK: - Storage

    private struct Stopper {
        weak var owner: AnyObject?
        let stop: @MainActor (AnyObject) -> Void
    }

    private final class WeakTask: @unchecked Sendable {
        weak var task: URLSessionTask?
        init(_ task: URLSessionTask) { self.task = task }
        var isAlive: Bool { task.map { $0.state != .completed } ?? false }
    }

    private final class WeakSession: @unchecked Sendable {
        weak var session: URLSession?
        init(_ session: URLSession) { self.session = session }
    }
}

/// The per-request delegate of `AIRequestGate.data` / `bytes`: hands the task it creates to the
/// gate, which cancels it on a withdrawal. Implements nothing else, so every other callback still
/// reaches the session's own delegate.
private final class InFlightTracker: NSObject, URLSessionTaskDelegate, Sendable {
    private let admitted: Int

    init(admittedAt admitted: Int) {
        self.admitted = admitted
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        AIRequestGate.track(task, admittedAt: admitted)
    }
}

extension AccountStore {
    /// Talks to the QingTeng account server only while the one-page consent is given (sign-in,
    /// restoring the session, profile reads). Declined or withdrawn: void sign-ins under way (even
    /// if the consent is given again before they end), then sign out at once, clearing the
    /// keychain session (chats, providers and everything else stay).
    func followConsent() {
        mayTransfer = { AIDataSharingConsent.isAccepted }
        consentObserver = NotificationCenter.default.addObserver(
            forName: AIDataSharingConsent.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AIDataSharingConsent.isAccepted else { return }
                self.voidSignInsUnderWay()
                self.signOut()
            }
        }
    }
}
