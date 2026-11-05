import Foundation
import SwiftData

private let mergeLogger = AppLogger(category: "SyncMerge")

/// Inbound hydration for Sync V2 — the half that writes peer records back into
/// the local session store.
///
/// OpenMinis implements these inside `ChatStore` (SQLite). This is a SwiftData
/// reimplementation, so the *semantics* are ported rather than the code:
///
///   - **Last-writer-wins on `updatedAt`.** A remote record older than the
///     local copy is dropped, not applied.
///   - **Tombstone guard.** A record whose `updatedAt` predates a local delete
///     (within a 5s clock-skew window) is a stale resurrection — CloudKit can
///     hand back a live copy fetched before the delete landed.
///   - **Defer while a session is running.** During an agent loop the message
///     list is locally authoritative: appends bump sort order every tool round,
///     and a remote message landing mid-run (often this device's own rows
///     echoed back) would win LWW and scramble the transcript. CloudKit
///     re-delivers unmerged changes, so skipping is safe.
///
/// Everything runs on one `@ModelActor` so a merge batch can't interleave with
/// itself.
@ModelActor
actor SyncSessionMerge {
    static let shared = SyncSessionMerge(modelContainer: ConversationContainer.shared)

    /// Clock-skew tolerance when comparing a remote timestamp against a local
    /// tombstone. Matches OpenMinis.
    private static let tombstoneSkew: TimeInterval = 5

    // MARK: - Sessions

    func getSession(_ id: String) -> ConversationModel? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == uuid }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func sessionExists(_ id: String) -> Bool {
        getSession(id) != nil
    }

    func allSessionIds() -> [String] {
        let descriptor = FetchDescriptor<ConversationModel>()
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }
        return rows.map { $0.id.uuidString }
    }

    /// True when `remoteUpdatedAt` predates this session's local delete — the
    /// remote copy is stale and re-inserting it would resurrect a deleted chat.
    func isResurrectionOfDeleted(_ sessionId: String, remoteUpdatedAt: Date) -> Bool {
        guard let deletedAt = SyncTombstoneStore.shared.deletedAt(
            type: "SessionV2", id: sessionId
        ) else { return false }
        return remoteUpdatedAt.timeIntervalSince1970 <= deletedAt.timeIntervalSince1970 + Self.tombstoneSkew
    }

    /// Generic per-record variant, for types whose delete propagates but whose
    /// merge would otherwise re-insert a stale live record.
    func isRecentlyDeletedRecord(type: String, id: String, remoteUpdatedAt: Date) -> Bool {
        guard let deletedAt = SyncTombstoneStore.shared.deletedAt(type: type, id: id) else {
            return false
        }
        return remoteUpdatedAt.timeIntervalSince1970 <= deletedAt.timeIntervalSince1970 + Self.tombstoneSkew
    }

    /// Apply a peer's session record. Creates when absent, LWW-updates when the
    /// remote copy is newer, drops it otherwise.
    @discardableResult
    func mergeRemoteSession(
        id: String,
        title: String,
        modelId: String,
        createdAt: Date,
        updatedAt: Date,
        lastMessage: String?,
        fromDeviceId: String,
        deviceName: String? = nil
    ) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }

        if isResurrectionOfDeleted(id, remoteUpdatedAt: updatedAt) {
            mergeLogger.info("mergeRemoteSession SKIP (deleted locally): id=\(id.prefix(8))")
            return false
        }

        if let existing = getSession(id) {
            guard updatedAt > existing.updatedAt else {
                mergeLogger.debug("mergeRemoteSession SKIP (local newer): id=\(id.prefix(8))")
                return false
            }
            existing.title = title
            existing.modelId = modelId
            existing.updatedAt = updatedAt
            existing.lastMessagePreview = lastMessage
            existing.remoteDeviceId = fromDeviceId
            existing.remoteDeviceName = deviceName
            try? modelContext.save()
            mergeLogger.info("mergeRemoteSession UPDATE: id=\(id.prefix(8))")
            return true
        }

        let conversation = ConversationModel(
            remoteId: uuid, title: title, modelId: modelId,
            createdAt: createdAt, updatedAt: updatedAt, deviceId: fromDeviceId
        )
        conversation.remoteDeviceName = deviceName
        conversation.lastMessagePreview = lastMessage
        modelContext.insert(conversation)
        try? modelContext.save()
        mergeLogger.info("mergeRemoteSession INSERT: id=\(id.prefix(8))")
        return true
    }

    /// Hard-delete without queueing a cloud delete — the caller is applying an
    /// authoritative remote deletion.
    func deleteSessionLocalOnly(_ id: String) {
        guard let conversation = getSession(id) else { return }
        modelContext.delete(conversation)
        try? modelContext.save()
    }

    // MARK: - Messages

    func loadSingleMessage(id: String) -> MessageModel? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.id == uuid }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// LWW clock for a message, falling back to `createdAt` for rows written
    /// before the sync fields existed.
    func messageUpdatedAt(id: String) -> Date? {
        guard let message = loadSingleMessage(id: id) else { return nil }
        return message.updatedAt ?? message.createdAt
    }

    /// Apply a peer's message. Returns false when skipped (session running,
    /// session missing, local copy newer, or record recently deleted).
    @discardableResult
    func mergeRemoteMessage(
        id: String,
        sessionId: String,
        role: String,
        content: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        sortOrder: Int = 0
    ) async -> Bool {
        // Never merge into a session whose agent loop is mid-flight.
        let isRunning = await MainActor.run {
            SessionActivityTracker.shared.activeSessions.contains(sessionId)
        }
        if isRunning {
            mergeLogger.info("mergeRemoteMessage DEFER (session running): id=\(id.prefix(8))")
            return false
        }

        let effectiveUpdatedAt = updatedAt ?? createdAt
        if isRecentlyDeletedRecord(type: "MessageV2", id: id, remoteUpdatedAt: effectiveUpdatedAt) {
            mergeLogger.info("mergeRemoteMessage SKIP (deleted locally): id=\(id.prefix(8))")
            return false
        }

        // A message can only exist under a session that's already here —
        // otherwise ordering is wrong and the row would be orphaned.
        guard let conversation = getSession(sessionId) else {
            mergeLogger.info("mergeRemoteMessage SKIP (no local session): sid=\(sessionId.prefix(8))")
            return false
        }
        guard let uuid = UUID(uuidString: id) else { return false }

        if let existing = loadSingleMessage(id: id) {
            let localClock = existing.updatedAt ?? existing.createdAt
            guard effectiveUpdatedAt > localClock else { return false }
            existing.content = content
            existing.roleRaw = role
            existing.updatedAt = effectiveUpdatedAt
            existing.sortOrder = sortOrder
            try? modelContext.save()
            return true
        }

        let message = MessageModel(role: role, content: content)
        message.id = uuid
        message.createdAt = createdAt
        message.updatedAt = effectiveUpdatedAt
        message.sortOrder = sortOrder
        message.conversation = conversation
        modelContext.insert(message)
        try? modelContext.save()
        return true
    }

    func deleteLocalMessage(id: String) {
        guard let message = loadSingleMessage(id: id) else { return }
        modelContext.delete(message)
        try? modelContext.save()
    }

    // MARK: - Counts (migration progress UI)

    func countLocalSessions() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<ConversationModel>())) ?? 0
    }

    func countLocalMessages() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<MessageModel>())) ?? 0
    }

    /// Re-queue every local session + message for upload. Used when a peer
    /// joins an empty zone, or after a full reset.
    func markAllLocalForReupload() async {
        let sessions = (try? modelContext.fetch(FetchDescriptor<ConversationModel>())) ?? []
        for conversation in sessions {
            await SyncDirtyQueue.shared.markDirty(
                recordType: "SessionV2", recordId: conversation.id.uuidString, priority: 1
            )
            for message in conversation.messages {
                await SyncDirtyQueue.shared.markDirty(
                    recordType: "MessageV2", recordId: message.id.uuidString, priority: 1
                )
            }
        }
        mergeLogger.info("markAllLocalForReupload: queued \(sessions.count) sessions")
    }
}

/// Delete tombstones, so an inbound record can be recognised as a stale
/// resurrection of something deleted here.
///
/// OpenMinis stores these as columns on the session row plus a generic
/// `deleted_records` table. This is the standalone equivalent: a small
/// UserDefaults-backed map, because the data is tiny (one timestamp per
/// deleted record id) and must outlive the row it refers to.
final class SyncTombstoneStore: @unchecked Sendable {
    static let shared = SyncTombstoneStore()

    private let key = "sync.deletedRecordTombstones"
    private let lock = NSLock()

    private init() {}

    private func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func recordDeletion(type: String, id: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map["\(type):\(id)"] = at.timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: key)
    }

    func deletedAt(type: String, id: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let ts = load()["\(type):\(id)"] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Clear a tombstone after a deliberate resurrect re-pushes the record.
    func clearDeletion(type: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map.removeValue(forKey: "\(type):\(id)")
        UserDefaults.standard.set(map, forKey: key)
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
