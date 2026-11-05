import Foundation

/// Buffers notification-tap / intent navigation until ContentView can consume it.
/// On a cold launch the delegate's `didReceive` fires before ContentView has
/// mounted its `.onReceive(.openSessionFromIntent)` subscriber, so the posted
/// NotificationCenter event is lost — and the Launch Session preference then
/// opens a fresh session instead of the tapped one.
@MainActor
final class NotificationNavigationStore {
    static let shared = NotificationNavigationStore()

    private var pendingSessionId: String?
    private var pendingSetAt: Date?
    private var handledAt: Date?

    func setPending(_ sessionId: String) {
        pendingSessionId = sessionId
        pendingSetAt = Date()
    }

    /// One-shot consume for the cold-launch path. Entries older than 30s are stale.
    func takePending() -> String? {
        defer {
            pendingSessionId = nil
            pendingSetAt = nil
        }
        guard let sid = pendingSessionId,
              let t = pendingSetAt,
              Date().timeIntervalSince(t) < 30 else { return nil }
        return sid
    }

    func markHandled() {
        pendingSessionId = nil
        pendingSetAt = nil
        handledAt = Date()
    }

    var handledRecently: Bool {
        guard let t = handledAt else { return false }
        return Date().timeIntervalSince(t) < 10
    }
}
