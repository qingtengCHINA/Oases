import Foundation
import SwiftData

private let sessionsQueryLogger = AppLogger(category: "SessionsQuery")

/// Read-side session/message queries for the `minis-sessions-cli` offload.
///
/// OpenMinis implements `querySessionsMeta` / `searchMessages` /
/// `loadMessagePage` / `messageCount` inside `ChatStore` (SQLite, 6211L).
/// OasesChat's session store is SwiftData, so this is a fresh implementation
/// that returns the same tuple shape the upstream offload bridge consumes.
///
/// The actor boundary mirrors the original: callers go through a
/// semaphore + Task.detached pattern in `SessionsOffloadBridge` to stay
/// synchronous from Objective-C.
@ModelActor
actor SessionsQueryEngine {
    static let shared = SessionsQueryEngine(modelContainer: ConversationContainer.shared)

    /// Plain value type — safe to hand across the actor boundary to the
    /// synchronous `@objc` bridge (all fields are `Sendable`).
    struct SessionMeta: Sendable {
        let sessionId: String
        let title: String
        let startedAt: Date
        let lastActive: Date
        let messageCount: Int
        let modelId: String?
        let pinnedAt: Date?
    }

    func getSession(id: String) -> SessionMeta? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        guard let conv = fetchConversationSync(uuid) else { return nil }
        return SessionMeta(
            sessionId: conv.id.uuidString,
            title: conv.title,
            startedAt: conv.createdAt,
            lastActive: conv.updatedAt,
            messageCount: conv.messages.count,
            modelId: conv.modelId,
            pinnedAt: nil
        )
    }

    func querySessionsMeta(sessionIds: [String]?,
                           keywords: [String]?,
                           limit: Int = 100,
                           startDate: Date? = nil,
                           endDate: Date? = nil) -> [SessionMeta] {
        guard limit > 0 else { return [] }

        var descriptor = FetchDescriptor<ConversationModel>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        guard let all = try? modelContext.fetch(descriptor) else { return [] }

        let idFilter: Set<UUID> = {
            guard let ids = sessionIds, !ids.isEmpty else { return [] }
            return Set(ids.compactMap { UUID(uuidString: $0) })
        }()
        // A non-empty filter containing no valid UUIDs is a real filter, not
        // the same thing as omitting the filter.
        if let ids = sessionIds, !ids.isEmpty, idFilter.isEmpty { return [] }

        let filtered = all.compactMap { conv -> SessionMeta? in
            if let ids = sessionIds, !ids.isEmpty, !idFilter.contains(conv.id) { return nil }
            if let s = startDate, conv.updatedAt < s { return nil }
            if let e = endDate, conv.updatedAt > e { return nil }

            // Match the SQLite reader's title-or-message semantics. This is
            // read-only and happens before the public limit is applied.
            if let kw = keywords, !kw.isEmpty {
                let title = conv.title as NSString
                let lower = title.lowercased
                let allHit = kw.allSatisfy { keyword in
                    let needle = keyword.lowercased()
                    return lower.contains(needle)
                        || conv.messages.contains { $0.content.lowercased().contains(needle) }
                }
                if !allHit { return nil }
            }

            let msgCount = conv.messages.count
            return SessionMeta(
                sessionId: conv.id.uuidString,
                title: conv.title,
                startedAt: conv.createdAt,
                lastActive: conv.updatedAt,
                messageCount: msgCount,
                modelId: conv.modelId,
                pinnedAt: nil
            )
        }

        // Filters must be applied before the public limit so an older
        // matching native session cannot be hidden by newer non-matches.
        return Array(filtered.prefix(limit))
    }

    struct MessageHit: Sendable, Equatable {
        let sessionId: String
        let sessionTitle: String?
        let messageId: String
        let role: String
        let createdAt: Date
        let snippet: String
    }

    func searchMessages(sessionIds: [String]?,
                        keywords: [String],
                        limit: Int = 50,
                        startDate: Date? = nil,
                        endDate: Date? = nil) -> [MessageHit] {
        guard limit > 0 else { return [] }

        let idFilter: Set<UUID> = {
            guard let ids = sessionIds, !ids.isEmpty else { return [] }
            return Set(ids.compactMap { UUID(uuidString: $0) })
        }()
        if let ids = sessionIds, !ids.isEmpty, idFilter.isEmpty { return [] }

        var descriptor = FetchDescriptor<MessageModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let all = try? modelContext.fetch(descriptor) else { return [] }
        let lowered = keywords.map { $0.lowercased() }

        var hits: [MessageHit] = []
        for msg in all {
            if let s = startDate, msg.createdAt < s { continue }
            if let e = endDate, msg.createdAt > e { continue }
            let content = msg.content.lowercased()
            if !lowered.allSatisfy({ content.contains($0) }) { continue }

            let conv = msg.conversation
            if let ids = sessionIds, !ids.isEmpty {
                guard let c = conv, idFilter.contains(c.id) else { continue }
            }
            guard let convId = conv?.id else { continue }

            hits.append(MessageHit(
                sessionId: convId.uuidString,
                sessionTitle: conv?.title,
                messageId: msg.id.uuidString,
                role: msg.roleRaw,
                createdAt: msg.createdAt,
                snippet: snippet(of: msg.content, maxChars: 200)
            ))
        }
        // Enforce the public limit only after all requested filters ran.
        return Array(hits.prefix(limit))
    }

    struct MessagePageRow: Sendable, Equatable {
        let messageId: String
        let role: String
        let createdAt: Date
        let text: String
        let truncated: Bool
    }

    func loadMessagePage(sessionId: String,
                         offset: Int = 0,
                         limit: Int = 20,
                         maxChars: Int = 1000) -> [MessagePageRow] {
        guard let sid = UUID(uuidString: sessionId), offset >= 0, limit > 0, maxChars >= 0 else {
            return []
        }
        // Resolve one conversation by UUID, then page its relationship. This
        // avoids scanning every MessageModel in the store for each page read.
        guard let conversation = fetchConversationSync(sid) else { return [] }
        let msgs = conversation.messages
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .dropFirst(offset)
            .prefix(limit)
        return msgs.map { msg in
            let (text, truncated) = truncate(msg.content, maxChars: maxChars)
            return MessagePageRow(
                messageId: msg.id.uuidString,
                role: msg.roleRaw,
                createdAt: msg.createdAt,
                text: text,
                truncated: truncated
            )
        }
    }

    struct UserMessage: Sendable, Equatable {
        let sessionId: String
        let messageId: String
        let text: String
        let createdAt: Date
    }

    /// Read user-authored native message content for vocabulary harvesting.
    /// Native SwiftData stores plain message content, unlike engineering
    /// ChatStore rows whose text is carried by `RawMessage.parts`.
    func userMessages(since: Date? = nil) -> [UserMessage] {
        let descriptor = FetchDescriptor<MessageModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let messages = try? modelContext.fetch(descriptor) else { return [] }
        return messages.compactMap { message in
            guard message.roleRaw == "user",
                  let conversation = message.conversation else { return nil }
            if let since, message.createdAt.timeIntervalSince1970 <= since.timeIntervalSince1970 {
                return nil
            }
            return UserMessage(
                sessionId: conversation.id.uuidString,
                messageId: message.id.uuidString,
                text: message.content,
                createdAt: message.createdAt
            )
        }
    }

    func messageCount(sessionId: String) -> Int {
        guard let sid = UUID(uuidString: sessionId) else { return 0 }
        return countMessagesSync(sid)
    }

    // MARK: - Private helpers

    private func countMessagesSync(_ conversationId: UUID) -> Int {
        fetchConversationSync(conversationId)?.messages.count ?? 0
    }

    /// Target one conversation row so page/count reads do not scan the global
    /// MessageModel table. The relationship is then faulted only for that row.
    private func fetchConversationSync(_ conversationId: UUID) -> ConversationModel? {
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == conversationId }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func snippet(of text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(trimmed, maxChars: maxChars).text
    }

    private func truncate(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxChars else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: maxChars)
        return (String(text[..<end]) + "…", true)
    }
}
