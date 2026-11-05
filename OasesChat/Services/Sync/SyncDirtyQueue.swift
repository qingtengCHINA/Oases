import Foundation
import SwiftData

private let dirtyLogger = AppLogger(category: "SyncDirtyQueue")

// cloudSyncDidFetchChanges → Services/Shared/AppNotifications.swift

/// One pending change awaiting upload, mirroring OpenMinis' `sync_dirty_records`
/// SQLite table row-for-row.
///
/// Composite identity is `(recordType, recordId)`; `recordName` materialises the
/// `"Type:id"` form `SyncCore` uses so lookups don't have to re-split a string.
@Model
final class SyncDirtyRecordModel {
    /// `"<recordType>:<recordId>"` — the composite primary key, unique so a
    /// re-mark of the same record replaces rather than duplicates (matching
    /// the upstream `INSERT OR REPLACE`).
    @Attribute(.unique) var recordName: String
    var recordType: String
    var recordId: String
    var zoneName: String
    var operation: String
    /// 0 = user-driven write, 1 = migration backlog. Drains priority-ascending
    /// so a freshly typed message is never starved behind a bulk backfill.
    var priority: Int
    var createdAt: Date

    init(recordType: String, recordId: String, zoneName: String,
         operation: String, priority: Int) {
        self.recordName = "\(recordType):\(recordId)"
        self.recordType = recordType
        self.recordId = recordId
        self.zoneName = zoneName
        self.operation = operation
        self.priority = priority
        self.createdAt = Date()
    }
}

/// Plain value handed to sync callers, so they never hold a `@Model` across
/// actor boundaries.
struct DirtyRecord: Sendable, Equatable {
    let recordType: String
    let recordId: String
    let zoneName: String
    let operation: String
}

/// SwiftData implementation of OpenMinis' dirty-record queue.
///
/// This is the piece that made Sync V2 look unportable: `SyncCore` and friends
/// reach for `ChatStore.shared.{markDirty,loadDirtyRecords,clearDirtyRecord,
/// countDirtyRecords}`, and `ChatStore` is a 6211-line hand-written SQLite
/// store that OasesChat replaced with SwiftData.
///
/// But the queue itself doesn't depend on how *conversations* are stored — it's
/// a standalone table of `(type, id, zone, op, priority)` tuples. Reimplementing
/// those four methods against SwiftData is far less invasive than either porting
/// `ChatStore` wholesale or migrating the conversation layer off SwiftData.
///
/// Ordering matches upstream exactly: priority ascending, then parents
/// (Session*) before children (Message*), then newest-first within a group,
/// capped at 100 per drain.
@ModelActor
actor SyncDirtyQueue {
    static let shared = SyncDirtyQueue(modelContainer: SyncContainer.shared)

    /// Zone rows are stamped with. Empty means sync isn't initialised, in which
    /// case `markDirty` is a no-op — same guard as upstream, so a write before
    /// sync setup can't enqueue rows with no destination.
    private var zoneName: String = ""

    func setZoneName(_ name: String) {
        zoneName = name
    }

    func currentZoneName() -> String { zoneName }

    /// Record types belonging to the V2 sync surface. `loadDirtyRecords(v2Only:)`
    /// filters on these so v1-only rows can't starve V2 sends.
    static let v2RecordTypes: Set<String> = [
        "SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2",
        "SkillV2", "ProviderConfigV2", "EnvVarV2", "EnvVarItem",
        "SyncDeviceV2", "SoulV2",
    ]

    func markDirty(recordType: String, recordId: String,
                   operation: String = "upsert", priority: Int = 0) {
        guard !zoneName.isEmpty else {
            dirtyLogger.debug("markDirty SKIP type=\(recordType) — sync zone not initialised")
            return
        }
        let name = "\(recordType):\(recordId)"
        // Upsert: a repeat mark updates the existing row instead of adding one.
        let descriptor = FetchDescriptor<SyncDirtyRecordModel>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.operation = operation
            existing.priority = priority
            existing.zoneName = zoneName
            existing.createdAt = Date()
        } else {
            modelContext.insert(SyncDirtyRecordModel(
                recordType: recordType, recordId: recordId,
                zoneName: zoneName, operation: operation, priority: priority
            ))
        }
        try? modelContext.save()
    }

    /// Next batch to push, capped at 100.
    func loadDirtyRecords(v2Only: Bool = false) -> [DirtyRecord] {
        var descriptor = FetchDescriptor<SyncDirtyRecordModel>(
            sortBy: [
                SortDescriptor(\.priority, order: .forward),
                SortDescriptor(\.createdAt, order: .reverse),
            ]
        )
        // SwiftData can't express the upstream CASE-based type ordering in a
        // SortDescriptor, so parents-before-children is applied below.
        descriptor.fetchLimit = 500
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }

        let filtered = v2Only ? rows.filter { Self.v2RecordTypes.contains($0.recordType) } : rows
        let ordered = filtered.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            let lRank = Self.typeRank(lhs.recordType)
            let rRank = Self.typeRank(rhs.recordType)
            if lRank != rRank { return lRank < rRank }
            return lhs.createdAt > rhs.createdAt
        }
        return ordered.prefix(100).map {
            DirtyRecord(recordType: $0.recordType, recordId: $0.recordId,
                        zoneName: $0.zoneName, operation: $0.operation)
        }
    }

    /// A peer applying an inbound batch must see parents before their children.
    private static func typeRank(_ recordType: String) -> Int {
        switch recordType {
        case "Session", "SessionV2": return 0
        case "Message", "MessageV2": return 1
        default: return 2
        }
    }

    /// Clear one row. `recordName` is the `"Type:id"` form.
    func clearDirtyRecord(recordName: String) {
        let descriptor = FetchDescriptor<SyncDirtyRecordModel>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return }
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
    }

    func countDirtyRecords() -> (total: Int, byType: [String: Int]) {
        guard let rows = try? modelContext.fetch(FetchDescriptor<SyncDirtyRecordModel>()) else {
            return (0, [:])
        }
        var byType: [String: Int] = [:]
        for row in rows { byType[row.recordType, default: 0] += 1 }
        return (rows.count, byType)
    }

    /// V2-only counts split by priority, for the sync progress UI.
    func countDirtyByPriority() -> [Int: Int] {
        guard let rows = try? modelContext.fetch(FetchDescriptor<SyncDirtyRecordModel>()) else {
            return [:]
        }
        var counts: [Int: Int] = [:]
        for row in rows where Self.v2RecordTypes.contains(row.recordType) {
            counts[row.priority, default: 0] += 1
        }
        return counts
    }

    /// Record confirmed-pushed names. Insert-or-ignore, so duplicate saves
    /// are silent (matching upstream's `INSERT OR IGNORE`).
    func markRecordsPushed(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        for name in recordNames {
            let descriptor = FetchDescriptor<SyncPushedRecordModel>(
                predicate: #Predicate { $0.recordName == name }
            )
            let exists = (try? modelContext.fetch(descriptor).first) != nil
            if !exists {
                modelContext.insert(SyncPushedRecordModel(recordName: name))
            }
        }
        try? modelContext.save()
    }

    func countPushedRecords() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<SyncPushedRecordModel>())) ?? 0
    }

    func clearAll() {
        guard let rows = try? modelContext.fetch(FetchDescriptor<SyncDirtyRecordModel>()) else { return }
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
    }
}

/// Distinct recordIDs ever confirmed saved to iCloud. Mirrors OpenMinis'
/// `sync_pushed_records`. The migration-progress UI counts these instead of
/// save events, which double-count every relaunch's re-mark + re-save cycle.
@Model
final class SyncPushedRecordModel {
    @Attribute(.unique) var recordName: String
    var pushedAt: Date

    init(recordName: String) {
        self.recordName = recordName
        self.pushedAt = Date()
    }
}

/// Zone the local device stamps its dirty rows with. OpenMinis derives this
/// from the CloudKit shared-zone name; until a transport is registered any
/// stable non-empty string works, since the guard only checks for emptiness.
enum SyncZone {
    static let defaultName = "OasesChatZone"
}

/// Container for sync-side models. Deliberately separate from
/// `ConversationContainer`: the dirty queue is high-churn bookkeeping, and
/// keeping it out of the conversation store means a corrupt queue can be
/// dropped without risking chat history.
enum SyncContainer {
    static let shared: ModelContainer = {
        do {
            // See ConversationContainer: the CloudKit entitlement would
            // otherwise auto-enable SwiftData mirroring on this container too.
            // The queue is local bookkeeping — it must never itself sync.
            return try ModelContainer(
                for: SyncDirtyRecordModel.self, SyncPushedRecordModel.self,
                configurations: ModelConfiguration(cloudKitDatabase: .none)
            )
        } catch {
            // Never crash launch over bookkeeping (a corrupt or unmigratable
            // store used to fatalError on every start). The live dirty queue
            // is ChatStore's `sync_dirty_records`; fall back to memory.
            dirtyLogger.error("Sync ModelContainer init failed, using in-memory store: \(error)")
            do {
                return try ModelContainer(
                    for: SyncDirtyRecordModel.self, SyncPushedRecordModel.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                )
            } catch {
                preconditionFailure("In-memory sync ModelContainer init failed: \(error)")
            }
        }
    }()
}
