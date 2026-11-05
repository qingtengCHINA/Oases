import AppIntents
import Foundation
import UniformTypeIdentifiers

private let logger = AppLogger(category: "FollowUpIntent")

/// Sends a follow-up prompt to an existing session, continuing the conversation.
///
/// Ported from OpenMinis `Agent/Intents/FollowUpSessionIntent.swift`. Differs
/// from `SendPromptIntent` only in that the session parameter is required and
/// attachments are accepted. OasesChat's `ChatViewModel.send(attachments:)`
/// takes a `[Attachment]` directly, so we build the attachment list here from
/// the IntentFile array and pass it in — no Combine observation needed.
struct FollowUpSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow Up Session"
    static let description = IntentDescription("Sends a follow-up prompt to an existing Oases Chat session, continuing the conversation with the AI agent.")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Prompt", requestValueDialog: "What follow-up would you like to send?")
    var prompt: String

    @Parameter(title: "Attachments", description: "Images, videos, or files to attach to the prompt. Accepts output from previous Shortcuts actions (e.g. filtered photos or documents).",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]?

    @Parameter(title: "Wait for Result", description: "When enabled, waits for the AI to finish and returns the full response for use in subsequent actions.", default: false)
    var waitForResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog {
        try await SessionIntentError.requireDataSharingConsent()
        BackgroundKeepAliveManager.shared.setup()

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionIntentError.emptyPrompt }

        guard let uuid = UUID(uuidString: session.id),
              let conversation = ConversationContainer.conversation(id: uuid) else {
            logger.warning("[FollowUpIntent] session not found: \(session.id.prefix(8))")
            return .result(
                value: SendPromptResult(sessionId: session.id, modelName: "",
                                        status: "Error", isNewSession: false,
                                        prompt: trimmed, responseText: String(localized: "Session not found.", comment: "Shortcuts result text: the chosen session was deleted")),
                dialog: "That session no longer exists."
            )
        }
        let sid = conversation.id.uuidString

        // Build Attachment list from IntentFile, if any (images downsampled
        // like in-app picks; see SendPromptIntent.attachments(from:)).
        let attachments = SendPromptIntent.attachments(from: files)

        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)
        vm.input = trimmed

        let modelName = ProviderChatRouting.label(for: conversation.modelId)
            ?? Models.option(for: conversation.modelId)?.label
            ?? conversation.modelId

        SessionActivityTracker.shared.setActive(sid)
        SessionActivityTracker.shared.updateSessionTitle(sid, title: conversation.title)
        let pendingId = ShortcutRunTracker.beginIntentRun(intent: "FollowUpSessionIntent", sessionId: sid)

        ShortcutNotification.post(
            id: "shortcut-followup-\(sid)",
            title: String(localized: "Oases Chat Task Started", comment: "Notification title when a Shortcuts prompt starts running"),
            body: "\(modelName): \(trimmed.prefix(50))\(trimmed.count > 50 ? "…" : "")",
            sessionId: sid,
            phase: .started
        )

        if waitForResult {
            await vm.send(attachments: attachments)
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "waitForResult.done")
            let responseText = SendPromptIntent.extractResponseText(from: vm)
            ShortcutNotification.post(
                id: "shortcut-followup-done-\(sid)",
                title: String(localized: "Oases Chat Task Completed", comment: "Notification title when a Shortcuts prompt finishes"),
                body: "\(modelName): \(responseText.prefix(200))",
                sessionId: sid,
                phase: .completed
            )
            let result = SendPromptResult(
                sessionId: sid, modelName: modelName, status: "Completed",
                isNewSession: false, prompt: trimmed, responseText: responseText
            )
            return .result(value: result, dialog: "\(responseText.prefix(500))")
        }

        // Fire-and-forget.
        Task { @MainActor in
            await vm.send(attachments: attachments)
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "async.done")
            ShortcutNotification.post(
                id: "shortcut-followup-done-\(sid)",
                title: String(localized: "Oases Chat Task Completed", comment: "Notification title when a Shortcuts prompt finishes"),
                body: "\(modelName): \(SendPromptIntent.extractResponseText(from: vm).prefix(200))",
                sessionId: sid,
                phase: .completed
            )
        }

        let result = SendPromptResult(
            sessionId: sid, modelName: modelName, status: "Running",
            isNewSession: false, prompt: trimmed
        )
        return .result(value: result, dialog: "Working on it — I'll notify you when it's done.")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Follow up \(\.$session) with \(\.$prompt)")
    }
}
