import AppIntents
import Foundation
import SwiftData
import UIKit
import UserNotifications
import UniformTypeIdentifiers

private let intentLogger = AppLogger(category: "SendPromptIntent")

/// Headless "send a prompt" intent for Shortcuts automations.
///
/// Ported from OpenMinis `Agent/Intents/SendPromptIntent.swift`. It runs with
/// `openAppWhenRun = false`, so the send has to survive without any UI: the
/// view model comes from `ChatViewModelCache` (shared with the UI, so the user
/// sees the same conversation), the run is registered with
/// `SessionActivityTracker` + `ShortcutRunTracker`, and
/// `BackgroundKeepAliveManager` is armed before the first await so an
/// intent-woken process isn't suspended mid-send.
///
/// Difference from OpenMinis: its `AIChatViewModel.send()` is fire-and-forget
/// with an `$isProcessing` publisher the intent waits on. OasesChat's
/// `ChatViewModel.send()` is `async` and returns when the turn is done, so
/// "wait for result" is just awaiting it — no publisher polling.
struct SendPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Prompt"
    static let description = IntentDescription(
        "Sends a prompt to Oases Chat without opening the app. Starts a new session, or continues one you pick."
    )
    /// The whole point: run headless from an automation.
    static let openAppWhenRun = false

    @Parameter(title: "Prompt", requestValueDialog: "What should Oases Chat do?")
    var prompt: String

    @Parameter(title: "Session", description: "Existing session to continue. Leave empty to start a new one.")
    var session: SessionEntity?

    @Parameter(
        title: "Wait For Result",
        description: "Wait for the reply and return it. Turn off to return immediately and get a notification when done.",
        default: true
    )
    var waitForResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog {
        // Limited mode: refuse before a session exists (no empty conversation
        // left behind, nothing sent).
        try await SessionIntentError.requireDataSharingConsent()
        // Arm keep-alive before any await, so an intent-woken process isn't
        // suspended before the send marks itself active.
        BackgroundKeepAliveManager.shared.setup()

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionIntentError.emptyPrompt
        }

        let context = ModelContext(ConversationContainer.shared)
        let conversation: ConversationModel
        let isNewSession: Bool

        if let session, let uuid = UUID(uuidString: session.id),
           let existing = ConversationContainer.conversation(id: uuid) {
            conversation = existing
            isNewSession = false
        } else {
            conversation = ConversationModel()
            conversation.title = String(trimmed.prefix(30))
            context.insert(conversation)
            try? context.save()
            isNewSession = true
        }

        let sid = conversation.id.uuidString
        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)

        let modelName = ProviderChatRouting.label(for: conversation.modelId)
            ?? Models.option(for: conversation.modelId)?.label
            ?? conversation.modelId

        // Register the run so the home screen shows a spinner and the Live
        // Activity reflects it, exactly as an in-app send would.
        SessionActivityTracker.shared.setActive(sid)
        SessionActivityTracker.shared.updateSessionTitle(sid, title: conversation.title)
        let pendingId = ShortcutRunTracker.beginIntentRun(intent: "SendPromptIntent", sessionId: sid, logEntry: true)

        ShortcutNotification.post(
            id: "shortcut-start-\(sid)",
            title: String(localized: "Oases Chat Task Started", comment: "Notification title when a Shortcuts prompt starts running"),
            body: "\(modelName): \(trimmed.prefix(50))\(trimmed.count > 50 ? "…" : "")",
            sessionId: sid,
            phase: .started
        )

        vm.input = trimmed

        if waitForResult {
            await vm.send()
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "waitForResult.done")

            let responseText = Self.extractResponseText(from: vm)
            ShortcutNotification.post(
                id: "shortcut-done-\(sid)",
                title: String(localized: "Oases Chat Task Completed", comment: "Notification title when a Shortcuts prompt finishes"),
                body: "\(modelName): \(responseText.prefix(200))",
                sessionId: sid,
                phase: .completed
            )
            let result = SendPromptResult(
                sessionId: sid,
                modelName: modelName,
                status: "Completed",
                isNewSession: isNewSession,
                prompt: trimmed,
                responseText: responseText
            )
            return .result(value: result, dialog: "\(responseText.prefix(500))")
        }

        // Fire-and-forget: return now, notify when the turn lands. The task is
        // detached from the intent's lifetime deliberately — the keep-alive
        // above is what buys it time to finish.
        Task { @MainActor in
            await vm.send()
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "async.done")
            ShortcutNotification.post(
                id: "shortcut-done-\(sid)",
                title: String(localized: "Oases Chat Task Completed", comment: "Notification title when a Shortcuts prompt finishes"),
                body: "\(modelName): \(Self.extractResponseText(from: vm).prefix(200))",
                sessionId: sid,
                phase: .completed
            )
        }

        let result = SendPromptResult(
            sessionId: sid,
            modelName: modelName,
            status: "Running",
            isNewSession: isNewSession,
            prompt: trimmed
        )
        return .result(value: result, dialog: "Working on it — I'll notify you when it's done.")
    }

    @MainActor
    static func extractResponseText(from vm: ChatViewModel) -> String {
        guard let last = vm.messages.last(where: { $0.role == .assistant }) else {
            return String(localized: "No response.", comment: "Shortcuts result / notification text when the agent produced no assistant message")
        }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "Task completed.", comment: "Agent notification / Live Activity text when the finished task produced no text reply") : text
    }

    /// `IntentFile` exposed via the Shortcuts UI often arrives with a
    /// generic name like "Photo". This uses the IntentFile's UTType to
    /// append a proper extension when the filename lacks one. Verbatim
    /// from OpenMinis — depended on by `RetryRunIntent` /
    /// `FollowUpSessionIntent` / `QuickTaskIntent`.
    /// Shortcut files → composer attachments. Images go through
    /// `AttachmentImporter.makeImageAttachment` (downsampled JPEG, same as an
    /// in-app pick) instead of a full-size base64 data URL; other files keep
    /// their bytes. Shared by `RetryRunIntent` / `FollowUpSessionIntent` /
    /// `QuickTaskIntent`.
    static func attachments(from files: [IntentFile]?) -> [Attachment] {
        guard let files, !files.isEmpty else { return [] }
        return files.map { file in
            let name = resolvedFileName(for: file)
            if file.type?.conforms(to: .image) == true,
               let image = AttachmentImporter.makeImageAttachment(data: file.data, name: name) {
                return image
            }
            let mime = file.type?.preferredMIMEType ?? "application/octet-stream"
            let kind: Attachment.Kind
            if file.type?.conforms(to: .image) == true { kind = .image }
            else if file.type?.conforms(to: .text) == true { kind = .text }
            else { kind = .file }
            let dataUrl = "data:\(mime);base64,\(file.data.base64EncodedString())"
            return Attachment(name: name, mimeType: mime, kind: kind, dataUrl: dataUrl)
        }
    }

    static func resolvedFileName(for file: IntentFile) -> String {
        let name = file.filename
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return name }
        if let type = file.type,
           let preferred = type.preferredFilenameExtension {
            return "\(name).\(preferred)"
        }
        return name
    }
}

/// Opens the app on the session and sends there, for "Hey Siri, ask Oases …".
/// Same pipeline as `SendPromptIntent`, but foreground.
struct AskOasesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Oases Chat"
    static let description = IntentDescription(
        "Opens Oases Chat, sends your prompt, and shows the conversation."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Prompt", requestValueDialog: "What would you like to ask?")
    var prompt: String

    @Parameter(title: "Session", description: "Existing session to continue. Leave empty to start a new one.")
    var session: SessionEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SessionIntentError.requireDataSharingConsent()
        BackgroundKeepAliveManager.shared.setup()

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionIntentError.emptyPrompt }

        let context = ModelContext(ConversationContainer.shared)
        let conversation: ConversationModel
        if let session, let uuid = UUID(uuidString: session.id),
           let existing = ConversationContainer.conversation(id: uuid) {
            conversation = existing
        } else {
            conversation = ConversationModel()
            conversation.title = String(trimmed.prefix(30))
            context.insert(conversation)
            try? context.save()
        }

        let sid = conversation.id.uuidString
        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)
        vm.input = trimmed

        SessionActivityTracker.shared.setActive(sid)
        Task { @MainActor in
            await vm.send()
            SessionActivityTracker.shared.setInactive(sid)
        }

        // Route the (now-open) app to this session — the same event
        // `OpenSessionIntent` and notification taps use.
        NotificationNavigationStore.shared.setPending(sid)
        NotificationCenter.default.post(
            name: .openSessionFromIntent,
            object: nil,
            userInfo: ["sessionId": sid]
        )
        intentLogger.info("AskOases send sid=\(sid.prefix(8))")
        return .result(dialog: "On it — opening Oases Chat.")
    }
}

/// Local notifications for Shortcuts runs. Tapping one opens the session.
enum ShortcutNotification {
    static let categoryId = "SHORTCUT_TASK"

    enum Phase { case started, completed }

    @MainActor
    static func post(id: String, title: String, body: String, sessionId: String, phase: Phase) {
        // Respect the global task-notification toggle (default on).
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "backgroundNotificationsEnabled") == nil
                || defaults.bool(forKey: "backgroundNotificationsEnabled") else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryId, actions: [], intentIdentifiers: [])
        ])

        let content = UNMutableNotificationContent()
        if BackgroundKeepAliveManager.shared.liveActivityPrivacyMode {
            // Task Status Privacy: same rule as the Live Activity and the
            // background-task notification — no prompt, reply, model or task
            // name on the Lock Screen. The tap still opens the session.
            content.title = "Oases Chat"
            content.body = phase == .started
                ? SettingsCopy.t("任务已开始", "Task started")
                : SettingsCopy.t("任务已完成", "Task completed")
        } else {
            content.title = title
            content.body = body
        }
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = ["sessionId": sessionId]

        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
