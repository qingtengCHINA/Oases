import XCTest
@testable import Oases_Chat

final class ChatStoreSyncSchemaTests: XCTestCase {
    func testFreshStoreSupportsDirtyPriorityAndDeviceUploadTypes() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreSyncSchemaTests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatStore(baseURL: directory)
        // Sync bookkeeping is off in the app (`CloudSyncFeature`); opt in here.
        await store.setCloudSyncTrackingEnabled(true)

        await store.setSyncZoneName("zone-\(UUID().uuidString)")
        await store.setSyncSendDeferred(true)
        await store.markDirty(recordType: "MessageV2", recordId: "migration-record", priority: 1)
        await store.markDirty(recordType: "SessionV2", recordId: "user-record", priority: 0)

        let dirtyRecords = await store.loadDirtyRecords()
        XCTAssertEqual(dirtyRecords.first?.recordId, "user-record")
        XCTAssertTrue(dirtyRecords.contains {
            $0.recordType == "MessageV2" &&
            $0.recordId == "migration-record" &&
            $0.zoneName.hasPrefix("zone-")
        })

        let device = SyncDevice(
            id: "device-schema-test",
            deviceName: "Schema Test Device",
            zoneName: "schema-test-zone",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            osVersion: "iOS Test",
            uploadTypes: ["chatSessions", "memory"]
        )
        await store.upsertSyncDevice(device)

        let devices = await store.listSyncDevices()
        XCTAssertEqual(devices.first(where: { $0.id == device.id })?.uploadTypes, device.uploadTypes)

        await store.closeDatabase()
        try? FileManager.default.removeItem(at: directory)
    }
}
