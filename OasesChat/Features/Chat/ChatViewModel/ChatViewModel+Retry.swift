import Foundation
import SwiftData

extension ChatViewModel {

    /// Truncate-and-retry: removes every message strictly after the target
    /// user message (both in-memory and in the SwiftData store), then re-runs
    /// the agent from that point. The target user message itself is removed
    /// (its content becomes the new prompt) so the transcript doesn't double
    /// up after the re-send.
    ///
    /// `replacementAttachments`, if non-nil, replaces the original user
    /// message's attachments; pass `nil` to keep whatever the target message
    /// already carried.
    ///
    /// Idempotent for an unknown `messageId`: returns without touching state.
    /// No-op if a stream is already in flight (`isStreaming == true`) — the
    /// caller must wait or cancel first.
    ///
    /// Mirrors OpenMinis `AIChatViewModel.retryFromMessage(_:replacementAttachments:)`.
    @MainActor
    func retryFromMessage(
        _ messageId: String,
        replacementAttachments: [Attachment]? = nil
    ) {
        // Limited mode: refuse before the truncation below, so a blocked
        // retry never drops the messages after the target.
        guard AIDataSharingConsent.isAccepted else {
            NSLog("[ChatViewModel] retry_blocked consent_required=1")
            return
        }
        guard !isStreaming else { return }
        guard let target = truncate(fromUserMessage: messageId) else { return }

        // Resolve attachments: caller override > original > none.
        let attachments = replacementAttachments ?? target.attachments ?? []
        input = target.content
        Task { @MainActor in await self.send(attachments: attachments) }
    }

    /// Regenerate an assistant reply: retries the user message it answered.
    @MainActor
    func regenerate(assistantMessageId: String) {
        guard !isStreaming,
              let idx = messages.firstIndex(where: { $0.id == assistantMessageId }),
              let user = messages[..<idx].last(where: { $0.role == .user }) else { return }
        retryFromMessage(user.id)
    }

    /// Edit and resend: the user message and everything after it leave the transcript; its
    /// text and attachments are returned for the composer.
    @MainActor
    func editMessage(_ messageId: String) -> (text: String, attachments: [Attachment])? {
        guard !isStreaming, let target = truncate(fromUserMessage: messageId) else { return nil }
        return (target.content, target.attachments ?? [])
    }

    /// Deletes one message, on screen and in the store.
    @MainActor
    func deleteMessage(_ messageId: String) {
        guard !isStreaming, let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages.remove(at: idx)
        guard let conv = conversation, let ctx = modelContext,
              let uuid = UUID(uuidString: messageId) else { return }
        let convId: UUID = conv.id
        let byId = #Predicate<MessageModel> { msg in msg.id == uuid }
        for row in fetchMessages(ctx, byId, "delete message") where row.conversation?.id == convId {
            ctx.delete(row)
        }
        conv.updatedAt = .now
        saveContext(ctx, "delete message")
    }

    /// Removes the message `messageId` and every later one, on screen and in the SwiftData
    /// store, and returns the removed message. The row is found by id —
    /// `ChatUIMessage.id` is the `MessageModel.id` for loaded messages and for everything
    /// persisted since ids were shared at insert time. `createdAt` equality is only a
    /// fallback for older in-session rows, whose UI and model timestamps differ.
    @MainActor
    @discardableResult
    func truncate(fromUserMessage messageId: String) -> ChatUIMessage? {
        guard let targetIdx = messages.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        let target = messages[targetIdx]
        let targetCreatedAt = target.createdAt
        // The target and everything after it (assistant reply, follow-ups, etc.).
        messages.removeSubrange(targetIdx...)

        guard let conv = conversation, let ctx = modelContext else { return target }
        // Capture locals as plain Sendable values so #Predicate's @Sendable
        // closure doesn't trip Swift 6 "Capture of non-Sendable type" warnings.
        let convId: UUID = conv.id
        let targetRoleRaw: String = target.role.rawValue
        var anchorRow: MessageModel?
        if let targetUUID = UUID(uuidString: target.id) {
            let byId = #Predicate<MessageModel> { msg in
                msg.id == targetUUID
            }
            anchorRow = fetchMessages(ctx, byId, "retry target by id")
                .first { $0.conversation?.id == convId }
        }
        if anchorRow == nil {
            let sameCreatedAt = #Predicate<MessageModel> { msg in
                msg.conversation?.id == convId
                    && msg.createdAt == targetCreatedAt
                    && msg.roleRaw == targetRoleRaw
            }
            anchorRow = fetchMessages(ctx, sameCreatedAt, "retry target by createdAt").first
        }
        // Newer than the stored row (or, without one, than the UI message —
        // an older in-session row is created just after its UI message, so
        // it falls on this side of the cutoff as well).
        let targetCutoff: Date = anchorRow?.createdAt ?? targetCreatedAt
        let newerPredicate = #Predicate<MessageModel> { msg in
            msg.conversation?.id == convId && msg.createdAt > targetCutoff
        }
        var toRemove = fetchMessages(ctx, newerPredicate, "retry newer rows")
        if let anchorRow, !toRemove.contains(where: { $0.id == anchorRow.id }) {
            toRemove.append(anchorRow)
        }
        for row in toRemove { ctx.delete(row) }
        conv.updatedAt = .now
        saveContext(ctx, "retry truncation")
        return target
    }

    private func fetchMessages(
        _ ctx: ModelContext,
        _ predicate: Predicate<MessageModel>,
        _ reason: String
    ) -> [MessageModel] {
        do {
            return try ctx.fetch(FetchDescriptor<MessageModel>(predicate: predicate))
        } catch {
            NSLog("[ChatViewModel] fetch failed (\(reason)): \(error.localizedDescription)")
            return []
        }
    }
}
