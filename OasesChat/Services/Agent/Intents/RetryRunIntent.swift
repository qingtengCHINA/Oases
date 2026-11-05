import AppIntents
import Foundation
import UniformTypeIdentifiers

private let logger = AppLogger(category: "RetryRunIntent")

/// Retries (re-runs) from a specific user message in a session.
/// At runtime, shows a picker of user messages from the selected session,
/// then truncates all messages after the chosen one (DB + UI) and re-runs
/// the agent through `ChatViewModel.retryFromMessage`. When replacement
/// attachments are provided, they override the original ones.
@available(iOS 17.0, *)
struct RetryRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Retry Run"
    static let description = IntentDescription("Re-runs the AI agent from a specific user message in a session. Presents a list of user messages to choose from, then retries from that point.")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Message")
    var message: UserMessageEntity?

    @Parameter(title: "Attachments", description: "Images, videos, or files to replace existing attachments. Accepts output from previous Shortcuts actions. If empty, keeps original attachments.",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]?

    @Parameter(title: "Wait for Result", description: "When enabled, waits for the AI to finish and returns the full response for use in subsequent actions.", default: false)
    var waitForResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog {
        // Before the transcript is truncated: a refused retry must not lose
        // the messages after the target.
        try await SessionIntentError.requireDataSharingConsent()
        BackgroundKeepAliveManager.shared.setup()

        guard let uuid = UUID(uuidString: session.id),
              let conversation = ConversationContainer.conversation(id: uuid) else {
            logger.warning("[RetryRunIntent] session not found: \(session.id.prefix(8))")
            return .result(
                value: SendPromptResult(sessionId: session.id, modelName: "",
                                        status: "Error", isNewSession: false,
                                        prompt: "", responseText: String(localized: "Session not found.", comment: "Shortcuts result text: the chosen session was deleted")),
                dialog: "That session no longer exists."
            )
        }
        let sid = conversation.id.uuidString
        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)

        // Build user-message entity list from the current transcript so the
        // runtime can show a picker when `message` is unset and ambiguous.
        let userMessages = vm.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else {
            return .result(
                value: SendPromptResult(sessionId: sid, modelName: "",
                                        status: "Error", isNewSession: false,
                                        prompt: "", responseText: String(localized: "No user messages.", comment: "Shortcuts result text: the session has no user message to retry from")),
                dialog: "No user messages found in this session."
            )
        }

        // Same store + ordering as UserMessageEntityQuery, so an index the
        // user picked in Shortcuts lands on the same message here.
        let sessionTitle = conversation.title.isEmpty ? session.displayName : conversation.title
        let entities = userMessages.enumerated().map { idx, msg -> UserMessageEntity in
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = text.isEmpty ? String(localized: "(attachment)", comment: "Shortcuts message picker: preview of a message that only has attachments") : String(text.prefix(80))
            return UserMessageEntity(
                id: "\(sid):\(idx)",
                sessionId: sid,
                preview: preview,
                index: idx + 1,
                sessionTitle: sessionTitle
            )
        }

        let chosenEntity: UserMessageEntity
        if let provided = message {
            chosenEntity = provided
        } else if entities.count == 1 {
            chosenEntity = entities[0]
        } else {
            chosenEntity = try await $message.requestDisambiguation(
                among: entities,
                dialog: IntentDialog("Which message do you want to retry from?")
            )
        }

        let targetIdx = chosenEntity.index - 1
        let targetMessage = (targetIdx >= 0 && targetIdx < userMessages.count)
            ? userMessages[targetIdx]
            : userMessages.last!
        let promptText = targetMessage.content
        let promptPreview = String(promptText.prefix(50))

        // Build optional replacement attachments from IntentFile list.
        let built = SendPromptIntent.attachments(from: files)
        let replacementAttachments: [Attachment]? = built.isEmpty ? nil : built

        let modelName = ProviderChatRouting.label(for: conversation.modelId)
            ?? Models.option(for: conversation.modelId)?.label
            ?? conversation.modelId

        SessionActivityTracker.shared.setActive(sid)
        SessionActivityTracker.shared.updateSessionTitle(sid, title: conversation.title)
        let pendingId = ShortcutRunTracker.beginIntentRun(intent: "RetryRunIntent", sessionId: sid)
        ShortcutNotification.post(
            id: "shortcut-retry-\(sid)",
            title: String(localized: "Oases Chat: Retrying", comment: "Notification title when a Shortcuts retry starts"),
            body: "\(modelName): \(promptPreview)\(promptText.count > 50 ? "…" : "")",
            sessionId: sid,
            phase: .started
        )

        // Truncate-and-retry: drops every message after target (DB + UI),
        // then re-sends the target's content as a fresh turn. Replacement
        // attachments override the original ones when provided.
        vm.retryFromMessage(targetMessage.id, replacementAttachments: replacementAttachments)

        if waitForResult {
            // Wait for the fire-and-forget send inside retryFromMessage to
            // land. OasesChat's ChatViewModel exposes `isStreaming` as the
            // turn-in-flight signal.
            for _ in 0..<900 {
                if !vm.isStreaming { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "waitForResult.done")
            let responseText = SendPromptIntent.extractResponseText(from: vm)
            ShortcutNotification.post(
                id: "shortcut-retry-done-\(sid)",
                title: String(localized: "Oases Chat: Retry Done", comment: "Notification title when a Shortcuts retry finishes"),
                body: "\(modelName): \(responseText.prefix(200))",
                sessionId: sid,
                phase: .completed
            )
            let result = SendPromptResult(
                sessionId: sid, modelName: modelName, status: "Completed",
                isNewSession: false, prompt: promptText, responseText: responseText
            )
            return .result(value: result, dialog: "\(responseText.prefix(500))")
        }

        // Fire-and-forget.
        Task { @MainActor in
            for _ in 0..<900 {
                if !vm.isStreaming { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "async.done")
            ShortcutNotification.post(
                id: "shortcut-retry-done-\(sid)",
                title: String(localized: "Oases Chat: Retry Done", comment: "Notification title when a Shortcuts retry finishes"),
                body: "\(modelName): \(SendPromptIntent.extractResponseText(from: vm).prefix(200))",
                sessionId: sid,
                phase: .completed
            )
        }

        let result = SendPromptResult(
            sessionId: sid, modelName: modelName, status: "Retrying",
            isNewSession: false, prompt: promptText
        )
        return .result(value: result, dialog: "Retrying from message: \(promptPreview)\(promptText.count > 50 ? "…" : "")")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Retry \(\.$session) from \(\.$message)")
    }
}
