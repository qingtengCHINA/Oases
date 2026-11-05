import SwiftData
import XCTest
@testable import Oases_Chat

/// The dirty queue is the piece that unblocked Sync V2: `SyncCore` reaches for
/// `markDirty` / `loadDirtyRecords` / `clearDirtyRecord` / `countDirtyRecords`,
/// which upstream implements as a SQLite table inside a 6211-line `ChatStore`.
/// This is a fresh SwiftData implementation, so its semantics need pinning —
/// especially the drain ordering, which decides whether a freshly typed message
/// gets starved behind a bulk backfill.
final class SyncDirtyQueueTests: XCTestCase {

    /// In-memory queue so tests never touch the app's real store.
    private func makeQueue() throws -> SyncDirtyQueue {
        let container = try ModelContainer(
            for: SyncDirtyRecordModel.self, SyncPushedRecordModel.self,
            // `cloudKitDatabase: .none` matters even in-memory: the app target
            // declares the CloudKit entitlement, so SwiftData would otherwise
            // auto-enable mirroring and reject these models for having
            // non-optional attributes without defaults.
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return SyncDirtyQueue(modelContainer: container)
    }

    func testMarkDirtyIsIgnoredBeforeZoneIsSet() async throws {
        let queue = try makeQueue()
        await queue.markDirty(recordType: "SessionV2", recordId: "a")
        let counts = await queue.countDirtyRecords()
        XCTAssertEqual(counts.total, 0, "a write before sync setup has nowhere to go")
    }

    func testMarkDirtyEnqueuesOnceZoneIsSet() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "SessionV2", recordId: "a")

        let counts = await queue.countDirtyRecords()
        XCTAssertEqual(counts.total, 1)
        XCTAssertEqual(counts.byType["SessionV2"], 1)
    }

    /// Re-marking the same record must replace, not duplicate — upstream relies
    /// on `INSERT OR REPLACE` against a composite primary key.
    func testRepeatedMarkUpdatesInPlace() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "SessionV2", recordId: "a", operation: "upsert")
        await queue.markDirty(recordType: "SessionV2", recordId: "a", operation: "delete")

        let counts = await queue.countDirtyRecords()
        XCTAssertEqual(counts.total, 1)
        let records = await queue.loadDirtyRecords()
        XCTAssertEqual(records.first?.operation, "delete")
    }

    /// Priority 0 (user write) must drain before priority 1 (migration backlog).
    func testUserWritesDrainBeforeMigrationBacklog() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "MessageV2", recordId: "backlog", priority: 1)
        await queue.markDirty(recordType: "MessageV2", recordId: "typed", priority: 0)

        let records = await queue.loadDirtyRecords()
        XCTAssertEqual(records.first?.recordId, "typed")
    }

    /// A peer applying an inbound batch must see sessions before their messages.
    func testParentsSortBeforeChildrenAtSamePriority() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "MessageV2", recordId: "m1")
        await queue.markDirty(recordType: "SessionV2", recordId: "s1")

        let records = await queue.loadDirtyRecords()
        XCTAssertEqual(records.map(\.recordType), ["SessionV2", "MessageV2"])
    }

    func testV2OnlyFilterExcludesLegacyTypes() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "SessionV2", recordId: "s1")
        await queue.markDirty(recordType: "LegacyThing", recordId: "x1")

        let all = await queue.loadDirtyRecords(v2Only: false)
        let v2 = await queue.loadDirtyRecords(v2Only: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(v2.map(\.recordType), ["SessionV2"])
    }

    func testClearDirtyRecordRemovesOnlyThatRow() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        await queue.markDirty(recordType: "SessionV2", recordId: "s1")
        await queue.markDirty(recordType: "SessionV2", recordId: "s2")

        await queue.clearDirtyRecord(recordName: "SessionV2:s1")
        let records = await queue.loadDirtyRecords()
        XCTAssertEqual(records.map(\.recordId), ["s2"])
    }

    /// The drain is capped so one cycle can't ship an unbounded batch.
    func testDrainIsCappedAtOneHundred() async throws {
        let queue = try makeQueue()
        await queue.setZoneName("zone-1")
        for i in 0..<150 {
            await queue.markDirty(recordType: "MessageV2", recordId: "m\(i)")
        }
        let records = await queue.loadDirtyRecords()
        XCTAssertEqual(records.count, 100)
        let counts = await queue.countDirtyRecords()
        XCTAssertEqual(counts.total, 150, "cap limits the batch, not the queue")
    }

    func testPushedRecordsAreDedupedAndCounted() async throws {
        let queue = try makeQueue()
        await queue.markRecordsPushed(["SessionV2:s1", "SessionV2:s2"])
        await queue.markRecordsPushed(["SessionV2:s1"])   // re-save of the same record
        let count = await queue.countPushedRecords()
        XCTAssertEqual(count, 2)
    }
}
