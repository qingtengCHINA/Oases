import Combine
import Foundation
import UIKit

private let logger = AppLogger(category: "SessionActivity")

// MARK: - Session Activity Tracker

/// Tracks which sessions are currently processing, so the home screen
/// can display a spinner even when the user navigates away from the chat.
@MainActor
final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    /// Session IDs that are currently processing (streaming / running tools).
    /// Canonical keys are real session IDs (UUIDs). Draft IDs are mirrored
    /// through `draftAliases` instead — see `setDraftAlias` — so the tracker
    /// only ever stores one entry per active session, preserving the
    /// "processing ends → entry clears" invariant that Live Activity relies
    /// on.
    @Published var activeSessions: Set<String> = []
    /// Maps a sidebar draft ID to its real session ID after ensureSession
    /// migrates from draft→real. Allows sidebar proxy rows that still
    /// identify themselves by draftId (ContentView's `displaySessions`) to
    /// reflect the live state of their underlying real session without
    /// double-inserting into `activeSessions`.
    @Published var draftAliases: [String: String] = [:]
    @Published var currentToolStatus: String = ""

    /// Per-session tool info for Live Activity carousel.
    struct SessionToolInfo {
        var title: String = ""
        var toolName: String = ""
        var toolStatus: String = ""
        var loopIteration: Int = 0
        /// When `toolName` last changed. Used to pick the most-recently-invoked
        /// tool across all sessions for the Dynamic Island minimal icon.
        var lastToolChange: Date = .distantPast
    }
    @Published var sessionToolInfo: [String: SessionToolInfo] = [:]

    /// The SF Symbol for the most-recently-invoked tool across all active
    /// sessions (the session whose `toolName` changed last). Drives the
    /// Dynamic Island minimal icon's "latest tool" frame. Nil when no active
    /// session has a tool yet.
    func latestToolName() -> String? {
        let active = activeSessions
        return sessionToolInfo
            .filter { active.contains($0.key) && !$0.value.toolName.isEmpty }
            .max { $0.value.lastToolChange < $1.value.lastToolChange }?
            .value.toolName
    }
    private var lastLiveActivityPush: Date = .distantPast
    private static let liveActivityThrottleInterval: TimeInterval = 5.0
    private var throttledUpdateWorkItem: DispatchWorkItem?

    func updateToolInfo(sessionId: String, toolName: String, toolStatus: String) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        let nameChanged = info.toolName != toolName
        let statusChanged = info.toolStatus != toolStatus
        info.toolName = toolName
        info.toolStatus = toolStatus
        if nameChanged {
            info.lastToolChange = Date()
        }
        sessionToolInfo[sessionId] = info
        guard nameChanged || statusChanged else { return }
        logger.info("[LiveActivity][toolInfo] sid=\(sessionId.prefix(8)) toolName=\(toolName) status=\(toolStatus) nameChanged=\(nameChanged)")
        if nameChanged {
            throttledUpdateWorkItem?.cancel()
            throttledUpdateWorkItem = nil
            lastLiveActivityPush = Date()
            BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolNameChange")
        } else {
            let elapsed = Date().timeIntervalSince(lastLiveActivityPush)
            if elapsed >= Self.liveActivityThrottleInterval {
                throttledUpdateWorkItem?.cancel()
                throttledUpdateWorkItem = nil
                lastLiveActivityPush = Date()
                BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusChange")
            } else if throttledUpdateWorkItem == nil {
                let delay = Self.liveActivityThrottleInterval - elapsed
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lastLiveActivityPush = Date()
                    self.throttledUpdateWorkItem = nil
                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusThrottled")
                }
                throttledUpdateWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    func updateLoopIteration(_ sessionId: String, iteration: Int) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        info.loopIteration = iteration
        sessionToolInfo[sessionId] = info
    }

    func updateSessionTitle(_ sessionId: String, title: String) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        guard info.title != title else { return }
        info.title = title
        sessionToolInfo[sessionId] = info
        BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "titleChange")
    }

    /// Thread-safe mirror of `activeSessions` + `draftAliases`, readable from
    /// non-MainActor contexts — notably the ChatStore actor's iCloud merge
    /// path, which must know whether a session is mid-run before applying a
    /// remote message. The `@MainActor`-isolated published state can't be read
    /// off-main, so every mutation also refreshes this lock-guarded snapshot.
    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var activeSessionsMirror: Set<String> = []
    nonisolated(unsafe) private static var draftAliasesMirror: [String: String] = [:]

    /// Non-MainActor query: is this session (or its draft alias) running
    /// locally? Used by sync to avoid clobbering a session that's actively
    /// streaming / running tools.
    nonisolated static func isActiveThreadSafe(_ sessionId: String) -> Bool {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        if activeSessionsMirror.contains(sessionId) { return true }
        if let real = draftAliasesMirror[sessionId], activeSessionsMirror.contains(real) { return true }
        return false
    }

    private func syncMirror() {
        Self.mirrorLock.lock()
        Self.activeSessionsMirror = activeSessions
        Self.draftAliasesMirror = draftAliases
        Self.mirrorLock.unlock()
    }

    func setActive(_ sessionId: String, source: String = #function) {
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.insert(sessionId)
        syncMirror()
        logger.info("🟢[Tracker] setActive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))]")
    }

    func setInactive(_ sessionId: String, source: String = #function) {
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.remove(sessionId)
        sessionToolInfo.removeValue(forKey: sessionId)
        // Drop any alias pointing at this session — if the real session is
        // no longer active, its draft alias should not linger either.
        let orphanedAliases = draftAliases.filter { $0.value == sessionId }.map { $0.key }
        for draftKey in orphanedAliases {
            draftAliases.removeValue(forKey: draftKey)
        }
        syncMirror()
        logger.info("🔴[Tracker] setInactive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))] clearedAliases=\(orphanedAliases.count)")
    }

    /// Register an alias from a draft ID to its newly-minted real session
    /// ID. After this, `isActive(draftId)` returns `isActive(realId)`.
    /// Removed automatically when the real session goes inactive.
    func setDraftAlias(draft draftId: String, real realId: String) {
        draftAliases[draftId] = realId
        syncMirror()
        logger.info("🔗[Tracker] setDraftAlias(\(draftId.prefix(8)) → \(realId.prefix(8)))")
    }

    func isActive(_ sessionId: String) -> Bool {
        if activeSessions.contains(sessionId) { return true }
        if let realId = draftAliases[sessionId],
           activeSessions.contains(realId) { return true }
        return false
    }
}

// KeepScreenAwakeController + SessionConcurrencyManager live in
// Services/Agent/Chat/ChatLifecycleSupport.swift
