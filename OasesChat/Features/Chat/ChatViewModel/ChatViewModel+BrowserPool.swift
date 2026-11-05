import Foundation

/// Bridges `minis-browser-use` (and the chat-side browser UI) to a
/// per-session `BrowserTabPool`. OasesChat's `ChatViewModel` doesn't own a
/// browser pool by default; this extension lazily allocates one so that
/// `BrowserUseOffloadBridge` and the agent UI share the same tab state,
/// matching OpenMinis' `AIChatViewModel.browserTabPool`.
extension ChatViewModel {
    private static var poolKey: UInt8 = 0

    /// Per-vm tab pool. Lazily allocated on first access. The pool is
    /// tied to this vm via `associatedObject` so it goes away when the vm
    /// deinits, and the same instance is returned on every access.
    var browserTabPool: BrowserTabPool {
        if let existing = objc_getAssociatedObject(self, &Self.poolKey) as? BrowserTabPool {
            return existing
        }
        let pool = BrowserTabPool()
        if let sid = activeLiveSessionId, !sid.isEmpty {
            pool.sessionId = sid
        }
        objc_setAssociatedObject(self, &Self.poolKey, pool, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return pool
    }
}
