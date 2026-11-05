import AppIntents
import Foundation

/// Represents a user message in a session, selectable in Shortcuts.
/// Gated behind iOS 17+ because UserMessageEntityQuery uses
/// @IntentParameterDependency which crashes Swift metadata resolution on iOS 16.
@available(iOS 17.0, *)
struct UserMessageEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "User Message")
    static let defaultQuery = UserMessageEntityQuery()

    var id: String          // "sessionId:index"
    var sessionId: String
    var preview: String     // Truncated text content
    var index: Int          // 1-based index among user messages
    var sessionTitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "#\(index): \(preview)",
            subtitle: "\(sessionTitle)"
        )
    }

    /// Build entities from a session's user messages.
    ///
    /// `SessionEntity` ids are chat-mode conversation UUIDs
    /// (`ConversationContainer`), and `RetryRunIntent` resolves the chosen
    /// index against that conversation's `ChatViewModel` — so this reads the
    /// same store with the same ordering/role mapping as
    /// `ChatViewModel.load(conversation:)`. (It used to read the engineering
    /// `ChatStore`, where those UUIDs never exist, so the picker was empty.)
    @MainActor
    static func load(sessionId: String, sessionTitle: String) -> [UserMessageEntity] {
        guard let uuid = UUID(uuidString: sessionId),
              let conversation = ConversationContainer.conversation(id: uuid) else { return [] }
        let userMessages = conversation.sortedMessages.filter {
            (ChatUIMessage.Role(rawValue: $0.roleRaw) ?? .user) == .user
        }
        return userMessages.enumerated().map { idx, msg in
            let joined = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview: String
            if joined.count > 80 {
                preview = String(joined.prefix(80)) + "…"
            } else {
                preview = joined.isEmpty ? String(localized: "(attachment)", comment: "Shortcuts message picker: preview of a message that only has attachments") : joined
            }
            return UserMessageEntity(
                id: "\(sessionId):\(idx)",
                sessionId: sessionId,
                preview: preview,
                index: idx + 1,
                sessionTitle: sessionTitle
            )
        }
    }
}

// MARK: - Query with session dependency

@available(iOS 17.0, *)
struct UserMessageEntityQuery: EntityQuery {
    @IntentParameterDependency<RetryRunIntent>(\.$session)
    var retryIntent

    @MainActor
    func entities(for identifiers: [String]) async throws -> [UserMessageEntity] {
        var bySession: [String: [Int]] = [:]
        for identifier in identifiers {
            let parts = identifier.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let idx = Int(parts[1]) else { continue }
            bySession[String(parts[0]), default: []].append(idx)
        }

        var results: [UserMessageEntity] = []
        for (sessionId, indices) in bySession {
            let title = UUID(uuidString: sessionId)
                .flatMap(ConversationContainer.conversation(id:))?.title ?? String(localized: "Untitled", comment: "Fallback title for a session without one")
            let all = UserMessageEntity.load(sessionId: sessionId, sessionTitle: title)
            results.append(contentsOf: all.filter { indices.contains($0.index - 1) })
        }
        return results
    }

    @MainActor
    func suggestedEntities() async throws -> [UserMessageEntity] {
        // Show only the selected session's messages when available
        if let sessionEntity = retryIntent?.session {
            return UserMessageEntity.load(
                sessionId: sessionEntity.id,
                sessionTitle: sessionEntity.displayName
            )
        }

        // Fallback (no session selected): recent conversations' messages
        var entities: [UserMessageEntity] = []
        for conversation in ConversationContainer.recentConversations(limit: 10) {
            entities.append(contentsOf: UserMessageEntity.load(
                sessionId: conversation.id.uuidString,
                sessionTitle: conversation.title
            ))
        }
        return entities
    }
}
