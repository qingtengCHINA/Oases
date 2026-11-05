import AppIntents
import Foundation

/// [P2] Wraps a conversation as an `AppEntity` so Shortcuts and Siri can refer
/// to sessions by name.
///
/// Ported from OpenMinis `Agent/Intents/SessionEntity.swift`, re-pointed at
/// OasesChat's SwiftData store (`ConversationContainer`) instead of OpenMinis'
/// `ChatStore` actor.
struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Session")
    static let defaultQuery = SessionEntityQuery()

    /// UUID string — Shortcuts persists entity ids, so the UUID is stringified
    /// rather than exposing `UUID` directly.
    var id: String
    var displayName: String
    var modelId: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(id: String, displayName: String, modelId: String) {
        self.id = id
        self.displayName = displayName
        self.modelId = modelId
    }

    init(from conversation: ConversationModel) {
        self.id = conversation.id.uuidString
        self.displayName = conversation.title
        self.modelId = conversation.modelId
    }
}

struct SessionEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        identifiers
            .compactMap(UUID.init(uuidString:))
            .compactMap(ConversationContainer.conversation(id:))
            .map(SessionEntity.init(from:))
    }

    @MainActor
    func suggestedEntities() async throws -> [SessionEntity] {
        ConversationContainer.recentConversations().map(SessionEntity.init(from:))
    }
}
