import XCTest
@testable import Oases_Chat

/// iCloud sync and backup were removed from the product (`CloudSyncFeature`).
/// The engines stay in the tree but must stay unreachable: nothing reports
/// sync as on, and `ChatStore` keeps no sync bookkeeping that nothing would
/// ever drain.
final class CloudSyncRemovalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncRemovalTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func message(_ sessionId: String) -> RawMessage {
        RawMessage(id: UUID().uuidString, sessionId: sessionId, role: .user,
                   parts: [.text("hello")], createdAt: Date(), tokenUsage: nil, reasoningContent: nil)
    }

    func testSyncReportsOffEvenWithAToggleLeftOnByAnOlderBuild() {
        XCTAssertFalse(CloudSyncFeature.isEnabled)
        let key = "cloudSync.v2.enabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertFalse(SyncV2Bootstrap.isEnabled)
    }

    func testRetireStoredTogglesClearsLeftoverSwitches() throws {
        let suite = "CloudSyncRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in CloudSyncFeature.storedToggleKeys { defaults.set(true, forKey: key) }

        CloudSyncFeature.retireStoredToggles(in: defaults)

        for key in CloudSyncFeature.storedToggleKeys {
            XCTAssertFalse(defaults.bool(forKey: key), key)
        }
    }

    func testStoreKeepsNoDirtyRowsOrTombstones() async {
        let store = ChatStore(baseURL: directory)
        // Even with a zone name set, as a build that still synced would have.
        await store.setSyncZoneName("zone-test")
        await store.setSyncSendDeferred(true)

        let session = await store.createSession(modelId: "model", title: "S")
        await store.appendMessage(message(session.id))
        await store.markDirty(recordType: "SessionV2", recordId: session.id)
        await store.flushPendingSyncDirty()
        let dirty = await store.loadDirtyRecords()
        XCTAssertTrue(dirty.isEmpty)

        await store.deleteSession(session.id)
        let tombstone = await store.deletedSessionTombstone(session.id)
        XCTAssertNil(tombstone)
        let stillDirty = await store.loadDirtyRecords()
        XCTAssertTrue(stillDirty.isEmpty)

        await store.closeDatabase()
    }

    func testLeftoverDirtyQueueIsDroppedWhenTheStoreOpens() async {
        // A queue written while sync still existed…
        let old = ChatStore(baseURL: directory)
        await old.setCloudSyncTrackingEnabled(true)
        await old.setSyncZoneName("zone-test")
        await old.setSyncSendDeferred(true)
        await old.markDirty(recordType: "SessionV2", recordId: "s1")
        let queued = await old.loadDirtyRecords()
        XCTAssertEqual(queued.count, 1)
        await old.closeDatabase()

        // …has no consumer any more and is gone on the next open.
        let reopened = ChatStore(baseURL: directory)
        let leftover = await reopened.loadDirtyRecords()
        XCTAssertTrue(leftover.isEmpty)
        await reopened.closeDatabase()
    }
}
