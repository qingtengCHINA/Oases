//
//  OffloadGateBridge.swift
//  OasesChat
//
//  Handler-level permission gate for native offloads (code review 2026-09-29,
//  3.6 P0). `NativeOffloadGate.m` registers every offload behind a trampoline
//  that calls `authorize` before the real handler runs, so chat mode,
//  engineering mode, automations, skills, MCP and the terminal all pass the
//  same gate. Previously only chat mode's `shell_execute` consulted
//  `OffloadPermissionManager`, and only for the first shell token.
//

import Foundation

@objc(OffloadGateBridge)
public final class OffloadGateBridge: NSObject {
    private static let logger = AppLogger(category: "OffloadGate")

    /// How long the main actor may take to pick up a decision. A main thread
    /// blocked on the iSH runtime (e.g. a synchronous shell call) would
    /// otherwise deadlock with this guest thread; deny well before the
    /// watchdog instead.
    static let mainActorPickupSeconds: TimeInterval = 5

    /// Safety valve once the main actor has the request. The gate always
    /// resolves on its own (prompts time out after
    /// `OffloadPermissionManager.promptTimeoutSeconds`, queued prompts wait
    /// their turn), so this only guards against a wedged main actor.
    static let decisionWaitSeconds: TimeInterval = 300

    /// Called on the guest thread right before an offload handler runs; blocks
    /// while a prompt is up. Returns `{ allowed: Bool, message: String }`.
    @objc public static func authorize(command: String, arguments: [String], fsContext: UInt64) -> NSDictionary {
        switch decision(command: command, arguments: arguments, fsContext: fsContext) {
        case .allowed:
            return ["allowed": true, "message": ""]
        case .denied(let message):
            logger.info("[OffloadGate] denied \(command)")
            return ["allowed": false, "message": message]
        }
    }

    private static func decision(command: String, arguments: [String], fsContext: UInt64) -> PermissionResult {
        let kind = OffloadCommandPolicy.classify(command: command, arguments: arguments)
        let level = OffloadPermissionManager.storedLevel(for: command)

        // Settle without the main actor whenever neither a session grant nor the
        // ability to prompt can change the answer (help, info, Bypass, disabled):
        // most calls never wait on the main thread.
        let strictest = OffloadPermissionManager.decide(
            command: command, kind: kind, level: level, granted: false, interactiveUIAvailable: false)
        if strictest == .allow { return .allowed }
        if case .deny(let message) = OffloadPermissionManager.decide(
            command: command, kind: kind, level: level, granted: true, interactiveUIAvailable: true) {
            return .denied(message)
        }

        guard !Thread.isMainThread else {
            return .denied("Permission denied: '\(command)' cannot be authorized from the main thread.")
        }
        let sessionId = OasesFsRouter.shared.sessionId(for: fsContext)
        let box = ResultBox()
        let pickedUp = DispatchSemaphore(value: 0)
        let decided = DispatchSemaphore(value: 0)
        Task { @MainActor in
            // A request abandoned after the pickup timeout must not prompt.
            guard box.claim() else { return }
            pickedUp.signal()
            let result = await OffloadPermissionManager.shared.authorizeOffload(
                command: command, arguments: arguments, sessionId: sessionId)
            box.store(result)
            decided.signal()
        }
        if pickedUp.wait(timeout: .now() + mainActorPickupSeconds) == .timedOut, box.abandon() {
            return .denied("Permission denied: Oases Chat is busy and could not check permission for '\(command)'. Retry in a moment.")
        }
        guard decided.wait(timeout: .now() + decisionWaitSeconds) == .success, let result = box.load() else {
            return .denied("Permission denied: timed out waiting for a permission decision on '\(command)'.")
        }
        return result
    }
}

/// Hand-off between the guest thread and the main-actor task: exactly one of
/// `claim` (main actor starts) and `abandon` (guest gave up) wins.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PermissionResult?
    private var claimed = false
    private var abandoned = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !abandoned else { return false }
        claimed = true
        return true
    }

    func abandon() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        abandoned = true
        return true
    }

    func store(_ result: PermissionResult) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> PermissionResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
