import Foundation
import Combine
import UIKit
import UserNotifications

private let gateLogger = AppLogger(category: "ConfigConfirmGate")

/// Funnels every oases-config write through user confirmation.
///
/// The gate is a single global queue: at most one ConfirmSheet shows
/// at a time. Subsequent requests stack up so the agent can fire a
/// rapid sequence of writes and the user reviews them one by one in
/// arrival order. Each request carries a 120-second timeout — past
/// that, the request resolves as `.timedOut` automatically and any
/// future user interaction with the (stale) sheet is a no-op.
///
/// The bridge calls `await requestConfirmation(_:)` to suspend its
/// CLI handling until the user (or the timeout) decides. The UI
/// observes `pending` to render the front-of-queue sheet.
@MainActor
final class ConfigConfirmationGate: ObservableObject {
    static let shared = ConfigConfirmationGate()

    /// 120-second wall-clock window. After this, the request auto-rejects
    /// and the bridge returns exit code 124 to the CLI.
    ///
    /// [T-config-confirm-timeout-bg] Was 30s. The timer starts the moment the
    /// change is enqueued and runs regardless of foreground/background (that
    /// behavior is intentional and unchanged), so when the app is backgrounded
    /// the 30s window elapsed before the user ever saw the sheet — the user
    /// reported three back-to-back `outcome=timedOut` with no chance to
    /// approve. Widening to 2 minutes gives a backgrounded user time to react
    /// to the local notification (below) and return to the app.
    static let timeoutSeconds: TimeInterval = 120

    /// Front-of-queue request, if any. The sheet binds to this; setting
    /// it to nil dismisses the sheet.
    @Published private(set) var pending: PendingConfigChange?

    /// Backlog of additional requests waiting their turn. Drained one-
    /// by-one as each `pending` resolves.
    private var queue: [(PendingConfigChange, CheckedContinuation<PendingConfigChange.Outcome, Never>)] = []

    /// Continuations keyed by request id, so timeout fire-and-forget can
    /// resolve the right awaiter without race vs. user-tap.
    private var awaiters: [String: CheckedContinuation<PendingConfigChange.Outcome, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// [T-config-confirm-timeout-bg] Ids we've already sent a background
    /// "waiting for approval" notification for, so a change that surfaces in
    /// the background AND then triggers a later didEnterBackground pass isn't
    /// notified twice. Cleared per-id in `resolve`.
    private var notifiedIds: Set<String> = []

    /// Category id for the config-approval local notification.
    private static let notifyCategoryId = "CONFIG_CONFIRM_PENDING"

    private var didEnterBackgroundObserver: NSObjectProtocol?

    private init() {
        // [T-config-confirm-timeout-bg] If the sheet was already showing in
        // the foreground and the user then switches away, they may leave
        // without ever seeing it — notify for whatever is pending at that
        // moment (once per change).
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let change = self.pending else { return }
                self.notifyIfBackgrounded(change)
            }
        }
    }

    // MARK: Public — bridge entry point

    /// Suspend until the user resolves the request (approve / reject /
    /// per-row reject) or the 30 s timeout fires.
    func requestConfirmation(_ change: PendingConfigChange) async -> PendingConfigChange.Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<PendingConfigChange.Outcome, Never>) in
            gateLogger.info("request enqueue id=\(change.id) items=\(change.items.count) caption=\(change.caption ?? "")")
            awaiters[change.id] = cont
            // Schedule timeout. Cancelled in `resolve(...)` if the user
            // acts first.
            let id = change.id
            timeoutTasks[id] = Task { [weak self] in
                let nanos = UInt64(Self.timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.timeout(id: id)
            }
            if pending == nil {
                pending = change
                // [T-config-confirm-timeout-bg] If the app is already in the
                // background when this becomes the front-of-queue change, the
                // user won't see the sheet — nudge them with a local
                // notification so they can come back before the 120s timeout.
                notifyIfBackgrounded(change)
            } else {
                queue.append((change, cont))
                // Replace the queued continuation in `awaiters` map —
                // we need to keep id → cont indexable for timeout fire,
                // and the contineuation isn't captured anywhere else.
                awaiters[change.id] = cont
            }
        }
    }

    // MARK: UI callbacks

    /// User tapped "Apply All". The provided items list is the post-
    /// edit state of the row toggles (some may be reject-only).
    func userApprove(items: [PendingConfigChangeItem]) {
        guard let change = pending else { return }
        let approvedCount = items.filter { $0.isApproved }.count
        gateLogger.info("userApprove id=\(change.id) submittedItems=\(items.count) approvedItems=\(approvedCount) pendingItems=\(change.items.count)")
        change.outcome = .approved(items: items)
        resolve(id: change.id, outcome: .approved(items: items))
    }

    /// User tapped Cancel.
    func userReject() {
        guard let change = pending else { return }
        gateLogger.info("userReject id=\(change.id) pendingItems=\(change.items.count)")
        change.outcome = .rejected
        resolve(id: change.id, outcome: .rejected)
    }

    // MARK: Internals

    private func timeout(id: String) {
        // Already resolved? Skip.
        guard awaiters[id] != nil else { return }
        gateLogger.info("timeout for change \(id)")
        if pending?.id == id {
            pending?.outcome = .timedOut
        }
        resolve(id: id, outcome: .timedOut)
    }

    private func resolve(id: String, outcome: PendingConfigChange.Outcome) {
        guard let cont = awaiters.removeValue(forKey: id) else { return }
        gateLogger.info("resolve id=\(id) outcome=\(Self.describe(outcome))")
        timeoutTasks[id]?.cancel()
        timeoutTasks.removeValue(forKey: id)
        notifiedIds.remove(id)
        cont.resume(returning: outcome)
        // Advance queue.
        if pending?.id == id {
            if let next = queue.first {
                queue.removeFirst()
                pending = next.0
                // [T-config-confirm-timeout-bg] The newly-surfaced change also
                // needs a background nudge if the user is away.
                notifyIfBackgrounded(next.0)
                // its continuation is already in `awaiters`
            } else {
                pending = nil
            }
        }
    }

    // MARK: Background notification

    /// [T-config-confirm-timeout-bg] Post a local notification when a config
    /// change is waiting for approval AND the app is currently backgrounded.
    /// [Stage 4] Disabled until BackgroundKeepAliveManager is ported.
    private func notifyIfBackgrounded(_ change: PendingConfigChange) {
        // [Stage 4] BackgroundKeepAliveManager not yet ported — skip background notification.
        // Full implementation (UNUserNotificationCenter + badge update) will be
        // uncommented when BackgroundKeepAliveManager.backgroundNotificationsEnabled is available.
        gateLogger.info("bg-notify skipped id=\(change.id) — BackgroundKeepAliveManager not yet ported")
    }

    private static func describe(_ outcome: PendingConfigChange.Outcome) -> String {
        switch outcome {
        case .pending:
            return "pending"
        case .rejected:
            return "rejected"
        case .timedOut:
            return "timedOut"
        case .approved(let items):
            let approvedCount = items.filter { $0.isApproved }.count
            return "approved submittedItems=\(items.count) approvedItems=\(approvedCount)"
        }
    }
}
