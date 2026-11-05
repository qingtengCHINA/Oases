import Foundation

/// Read-only compatibility layer for the two session stores.
///
/// Engineering mode persists sessions in `ChatStore`/SQLite while native chat
/// persists `ConversationModel`/`MessageModel` in SwiftData. This facade keeps
/// callers from accidentally treating one store as the complete history. It
/// owns no write path and is injectable so tests can use isolated stores.
actor SessionReadFacade {

    enum Owner: Sendable, Equatable {
        case engineering
        case native
    }

    struct SessionMeta: Sendable, Equatable {
        let id: String
        let title: String?
        let startedAt: Date
        let lastActive: Date
        let messageCount: Int
        let modelId: String?
        let pinnedAt: Date?
        let owner: Owner
    }

    struct MessageHit: Sendable, Equatable {
        let sessionId: String
        let sessionTitle: String?
        let messageId: String
        let role: String
        let createdAt: Date
        let snippet: String
        let owner: Owner
    }

    struct MessagePageRow: Sendable, Equatable {
        let messageId: String
        let role: String
        let createdAt: Date
        let text: String
        let truncated: Bool
    }

    struct UserMessage: Sendable, Equatable {
        let sessionId: String
        let messageId: String
        let text: String
        let timestamp: Double
    }

    static let shared = SessionReadFacade(
        chatStore: ChatStore.shared,
        nativeEngine: SessionsQueryEngine.shared
    )

    private let chatStore: ChatStore
    private let nativeEngine: SessionsQueryEngine

    init(chatStore: ChatStore, nativeEngine: SessionsQueryEngine) {
        self.chatStore = chatStore
        self.nativeEngine = nativeEngine
    }

    // MARK: - Session metadata

    /// Query both stores, then apply one deterministic global sort/limit.
    /// Engineering rows overwrite native rows with the same normalized UUID.
    func listSessions(
        sessionIds: [String]? = nil,
        keywords: [String]? = nil,
        limit: Int = 100,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async -> [SessionMeta] {
        guard limit > 0 else { return [] }
        let ids = expandedSessionIds(sessionIds)

        async let engineeringRows = chatStore.querySessionsMeta(
            sessionIds: ids,
            keywords: keywords,
            limit: Self.unboundedSessionLimit,
            startDate: startDate,
            endDate: endDate
        )
        // Resolve ownership independently of the requested metadata filters.
        // A native duplicate must not become visible merely because the
        // engineering copy misses a keyword/date filter.
        async let engineeringOwnedRows = chatStore.querySessionsMeta(
            sessionIds: ids,
            keywords: nil,
            limit: Self.unboundedSessionLimit
        )
        async let nativeRows = nativeEngine.querySessionsMeta(
            sessionIds: ids,
            keywords: keywords,
            limit: Self.unboundedSessionLimit,
            startDate: startDate,
            endDate: endDate
        )
        let (engineering, engineeringOwned, native) = await (
            engineeringRows, engineeringOwnedRows, nativeRows
        )

        let engineeringSessionKeys = Set(engineeringOwned.map { Self.identityKey($0.id) })
        var merged: [String: SessionMeta] = [:]
        for row in native {
            let meta = Self.nativeMeta(row)
            guard !engineeringSessionKeys.contains(Self.identityKey(meta.id)) else { continue }
            merged[Self.identityKey(meta.id)] = meta
        }
        for row in engineering {
            let meta = Self.engineeringMeta(row)
            // Engineering mode owns an overlapping normalized identity.
            merged[Self.identityKey(meta.id)] = meta
        }

        return merged.values.sorted(by: Self.sessionSort).prefix(limit).map { $0 }
    }

    func getSession(id: String) async -> SessionMeta? {
        // Resolve engineering first: an overlapping UUID belongs to the
        // engineering store for all owner-routed reads and mutations.
        let engineeringRows = await chatStore.querySessionsMeta(
            sessionIds: expandedSessionIds([id]),
            keywords: nil,
            limit: Self.unboundedSessionLimit
        )
        if let row = engineeringRows.first(where: { Self.identityKey($0.id) == Self.identityKey(id) }) {
            return Self.engineeringMeta(row)
        }

        guard let row = await nativeEngine.getSession(id: id) else { return nil }
        return Self.nativeMeta(row)
    }

    func sessionOwner(id: String) async -> Owner? {
        await getSession(id: id)?.owner
    }

    // MARK: - Message search

    /// Search both stores and apply one deterministic global sort/limit.
    /// Matching message identities are de-duplicated with engineering
    /// precedence, while distinct messages in one session remain distinct hits.
    func searchMessages(
        sessionIds: [String]? = nil,
        keywords: [String],
        limit: Int = 50,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async -> [MessageHit] {
        guard limit > 0, !keywords.isEmpty else { return [] }
        let ids = expandedSessionIds(sessionIds)

        async let engineeringRows = chatStore.searchMessages(
            sessionIds: ids,
            keywords: keywords,
            limit: Self.unboundedSearchLimit,
            startDate: startDate,
            endDate: endDate
        )
        // Ownership is independent of whether an engineering message happens
        // to match this particular keyword. Otherwise a native hit could leak
        // from a session that is engineering-owned but has no matching
        // engineering message.
        async let engineeringOwnedRows = chatStore.querySessionsMeta(
            sessionIds: ids,
            keywords: nil,
            limit: Self.unboundedSessionLimit
        )
        async let nativeRows = nativeEngine.searchMessages(
            sessionIds: ids,
            keywords: keywords,
            limit: Self.unboundedSearchLimit,
            startDate: startDate,
            endDate: endDate
        )
        let (engineering, engineeringOwned, native) = await (
            engineeringRows, engineeringOwnedRows, nativeRows
        )

        let engineeringSessionKeys = Set(engineeringOwned.map { Self.identityKey($0.id) })
        var merged: [String: MessageHit] = [:]

        for row in engineering {
            let hit = Self.engineeringHit(row)
            merged[Self.messageIdentity(hit)] = hit
        }
        for row in native {
            let hit = Self.nativeHit(row)
            // When both stores expose the same session, engineering is the
            // owner. Do not combine native message hits into that session.
            guard !engineeringSessionKeys.contains(Self.identityKey(hit.sessionId)) else { continue }
            merged[Self.messageIdentity(hit)] = hit
        }

        return merged.values.sorted(by: Self.messageSort).prefix(limit).map { $0 }
    }

    // MARK: - Owner-routed message reads

    func loadMessagePage(
        sessionId: String,
        offset: Int = 0,
        limit: Int = 20,
        maxChars: Int = 1000
    ) async -> [MessagePageRow] {
        guard offset >= 0, limit > 0, maxChars >= 0,
              let meta = await getSession(id: sessionId) else { return [] }

        switch meta.owner {
        case .engineering:
            return await chatStore.loadMessagePage(
                sessionId: meta.id,
                offset: offset,
                limit: limit,
                maxChars: maxChars
            ).map { row in
                MessagePageRow(
                    messageId: row.messageId,
                    role: row.role,
                    createdAt: row.createdAt,
                    text: row.text,
                    truncated: row.truncated
                )
            }
        case .native:
            return await nativeEngine.loadMessagePage(
                sessionId: meta.id,
                offset: offset,
                limit: limit,
                maxChars: maxChars
            ).map { row in
                MessagePageRow(
                    messageId: row.messageId,
                    role: row.role,
                    createdAt: row.createdAt,
                    text: row.text,
                    truncated: row.truncated
                )
            }
        }
    }

    func messageCount(sessionId: String) async -> Int {
        guard let meta = await getSession(id: sessionId) else { return 0 }
        switch meta.owner {
        case .engineering:
            return await chatStore.messageCount(sessionId: meta.id)
        case .native:
            return await nativeEngine.messageCount(sessionId: meta.id)
        }
    }

    // MARK: - Vocabulary source

    /// Read user-authored text from both stores. Engineering rows contribute
    /// only `.text` RawMessage parts; native rows contribute plain `user`
    /// MessageModel content. The caller owns attachment-markup stripping.
    func userMessages(since: Double = 0) async -> [UserMessage] {
        let engineeringSessions = await chatStore.querySessionsMeta(
            sessionIds: nil,
            keywords: nil,
            limit: Self.unboundedSessionLimit
        )
        let engineeringSessionKeys = Set(engineeringSessions.map { Self.identityKey($0.id) })

        // Only sessions active since `since` can hold newer messages: a
        // session's `lastActive` (its `updated_at`) is moved forward to at
        // least every message's `created_at` as the message is stored. This
        // skips fully loading every session in the store on each
        // incremental read.
        let sinceDate = Date(timeIntervalSince1970: since)
        var result: [UserMessage] = []
        for session in engineeringSessions where session.lastActive >= sinceDate {
            let messages = await chatStore.loadMessages(sessionId: session.id)
            for message in messages where message.role == .user {
                let timestamp = message.createdAt.timeIntervalSince1970
                guard timestamp > since else { continue }
                let text = message.parts.compactMap { part -> String? in
                    guard case .text(let value) = part else { return nil }
                    return value
                }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                result.append(UserMessage(
                    sessionId: session.id,
                    messageId: message.id,
                    text: text,
                    timestamp: timestamp
                ))
            }
        }

        let nativeMessages = await nativeEngine.userMessages(
            since: Date(timeIntervalSince1970: since)
        )
        for message in nativeMessages {
            // Engineering wins ownership for overlapping normalized UUIDs.
            guard !engineeringSessionKeys.contains(Self.identityKey(message.sessionId)) else { continue }
            result.append(UserMessage(
                sessionId: message.sessionId,
                messageId: message.messageId,
                text: message.text,
                timestamp: message.createdAt.timeIntervalSince1970
            ))
        }

        return result.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            let leftMessage = Self.identityKey(lhs.messageId)
            let rightMessage = Self.identityKey(rhs.messageId)
            if leftMessage != rightMessage { return leftMessage < rightMessage }
            return Self.identityKey(lhs.sessionId) < Self.identityKey(rhs.sessionId)
        }
    }

    // MARK: - Normalization / mapping

    private static let unboundedSessionLimit = Int(Int32.max)
    // ChatStore's search reader over-fetches by `limit * 3` internally.
    private static let unboundedSearchLimit = Int(Int32.max / 3)

    private func expandedSessionIds(_ ids: [String]?) -> [String]? {
        guard let ids, !ids.isEmpty else { return ids }
        var expanded: [String] = []
        for id in ids {
            expanded.append(id)
            if let uuid = UUID(uuidString: id) {
                expanded.append(uuid.uuidString)
                expanded.append(uuid.uuidString.lowercased())
            }
        }
        var seen = Set<String>()
        return expanded.filter { seen.insert($0).inserted }
    }

    private static func identityKey(_ id: String) -> String {
        if let uuid = UUID(uuidString: id) {
            return uuid.uuidString.lowercased()
        }
        // SQLite engineering IDs may be non-UUID strings; preserve them as-is.
        return id
    }

    private static func engineeringMeta(_ row: ChatStore.SessionMeta) -> SessionMeta {
        SessionMeta(
            id: row.id,
            title: row.title,
            startedAt: row.startedAt,
            lastActive: row.lastActive,
            messageCount: row.messageCount,
            modelId: row.modelId,
            pinnedAt: row.pinnedAt,
            owner: .engineering
        )
    }

    private static func nativeMeta(_ row: SessionsQueryEngine.SessionMeta) -> SessionMeta {
        SessionMeta(
            id: row.sessionId,
            title: row.title,
            startedAt: row.startedAt,
            lastActive: row.lastActive,
            messageCount: row.messageCount,
            modelId: row.modelId,
            pinnedAt: row.pinnedAt,
            owner: .native
        )
    }

    private static func engineeringHit(
        _ row: (sessionId: String, sessionTitle: String?, messageId: String,
                role: String, createdAt: Date, snippet: String)
    ) -> MessageHit {
        MessageHit(
            sessionId: row.sessionId,
            sessionTitle: row.sessionTitle,
            messageId: row.messageId,
            role: row.role,
            createdAt: row.createdAt,
            snippet: row.snippet,
            owner: .engineering
        )
    }

    private static func nativeHit(_ row: SessionsQueryEngine.MessageHit) -> MessageHit {
        MessageHit(
            sessionId: row.sessionId,
            sessionTitle: row.sessionTitle,
            messageId: row.messageId,
            role: row.role,
            createdAt: row.createdAt,
            snippet: row.snippet,
            owner: .native
        )
    }

    private static func messageIdentity(_ hit: MessageHit) -> String {
        "\(identityKey(hit.sessionId))\u{1F}\(identityKey(hit.messageId))"
    }

    private static func sessionSort(_ lhs: SessionMeta, _ rhs: SessionMeta) -> Bool {
        if lhs.lastActive != rhs.lastActive { return lhs.lastActive > rhs.lastActive }
        let left = identityKey(lhs.id)
        let right = identityKey(rhs.id)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    private static func messageSort(_ lhs: MessageHit, _ rhs: MessageHit) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let left = identityKey(lhs.messageId)
        let right = identityKey(rhs.messageId)
        if left != right { return left < right }
        let leftSession = identityKey(lhs.sessionId)
        let rightSession = identityKey(rhs.sessionId)
        if leftSession != rightSession { return leftSession < rightSession }
        return lhs.owner == .engineering && rhs.owner == .native
    }
}
