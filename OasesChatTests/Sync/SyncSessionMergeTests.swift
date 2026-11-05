import SwiftData
import XCTest
@testable import Oases_Chat

/// Inbound merge semantics. These are ported behaviours, not invented ones —
/// last-writer-wins, the tombstone skew window, and the running-session defer
/// all exist upstream because each one was a real sync bug. Reimplementing them
/// on SwiftData without tests would just move the bugs.
final class SyncSessionMergeTests: XCTestCase {

    private func makeMerge() throws -> SyncSessionMerge {
        let container = try ModelContainer(
            for: ConversationModel.self, MessageModel.self,
            // Matches the app container: the CloudKit entitlement would
            // otherwise auto-enable SwiftData mirroring and reject the schema.
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return SyncSessionMerge(modelContainer: container)
    }

    override func tearDown() {
        SyncTombstoneStore.shared.clearAll()
        super.tearDown()
    }

    // MARK: - Sessions

    func testRemoteSessionIsInsertedWhenAbsent() async throws {
        let merge = try makeMerge()
        let id = UUID().uuidString
        let applied = await merge.mergeRemoteSession(
            id: id, title: "From peer", modelId: "gpt-4o",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            lastMessage: "hello", fromDeviceId: "peer-1"
        )
        XCTAssertTrue(applied)

        let stored = await merge.getSession(id)
        XCTAssertEqual(stored?.title, "From peer")
        XCTAssertEqual(stored?.remoteDeviceId, "peer-1")
        XCTAssertEqual(stored?.lastMessagePreview, "hello")
    }

    func testNewerRemoteSessionWins() async throws {
        let merge = try makeMerge()
        let id = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: id, title: "old", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        let applied = await merge.mergeRemoteSession(
            id: id, title: "new", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        XCTAssertTrue(applied)
        let stored = await merge.getSession(id)
        XCTAssertEqual(stored?.title, "new")
    }

    /// A stale remote copy must not clobber a newer local edit.
    func testOlderRemoteSessionIsDropped() async throws {
        let merge = try makeMerge()
        let id = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: id, title: "local-newer", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 5000),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        let applied = await merge.mergeRemoteSession(
            id: id, title: "remote-older", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 3000),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        XCTAssertFalse(applied)
        let stored = await merge.getSession(id)
        XCTAssertEqual(stored?.title, "local-newer")
    }

    /// CloudKit can hand back a live copy fetched just before a delete landed.
    /// Re-inserting it would resurrect a chat the user deleted.
    func testDeletedSessionIsNotResurrectedByStaleRemote() async throws {
        let merge = try makeMerge()
        let id = UUID().uuidString
        let deletedAt = Date(timeIntervalSince1970: 5000)
        SyncTombstoneStore.shared.recordDeletion(type: "SessionV2", id: id, at: deletedAt)

        let applied = await merge.mergeRemoteSession(
            id: id, title: "zombie", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 4000),   // predates the delete
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        XCTAssertFalse(applied)
        let stored = await merge.getSession(id)
        XCTAssertNil(stored)
    }

    /// A genuinely newer remote edit *should* win over an old tombstone —
    /// the peer edited the session after this device deleted it.
    func testRemoteEditAfterDeleteIsApplied() async throws {
        let merge = try makeMerge()
        let id = UUID().uuidString
        SyncTombstoneStore.shared.recordDeletion(
            type: "SessionV2", id: id, at: Date(timeIntervalSince1970: 5000)
        )
        let applied = await merge.mergeRemoteSession(
            id: id, title: "edited later", modelId: "m",
            createdAt: Date(timeIntervalSince1970: 1000),
            // Beyond the 5s skew window.
            updatedAt: Date(timeIntervalSince1970: 5100),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        XCTAssertTrue(applied)
    }

    // MARK: - Messages

    func testRemoteMessageRequiresItsSessionToExist() async throws {
        let merge = try makeMerge()
        let applied = await merge.mergeRemoteMessage(
            id: UUID().uuidString, sessionId: UUID().uuidString,
            role: "user", content: "orphan", createdAt: Date()
        )
        XCTAssertFalse(applied, "a message must never be orphaned")
    }

    func testRemoteMessageIsInsertedUnderItsSession() async throws {
        let merge = try makeMerge()
        let sid = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: sid, title: "s", modelId: "m",
            createdAt: Date(), updatedAt: Date(),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        let mid = UUID().uuidString
        let applied = await merge.mergeRemoteMessage(
            id: mid, sessionId: sid, role: "assistant",
            content: "hi from peer", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100), sortOrder: 3
        )
        XCTAssertTrue(applied)

        let stored = await merge.loadSingleMessage(id: mid)
        XCTAssertEqual(stored?.content, "hi from peer")
        XCTAssertEqual(stored?.sortOrder, 3)
        let count = await merge.countLocalMessages()
        XCTAssertEqual(count, 1)
    }

    func testOlderRemoteMessageIsDropped() async throws {
        let merge = try makeMerge()
        let sid = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: sid, title: "s", modelId: "m",
            createdAt: Date(), updatedAt: Date(),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        let mid = UUID().uuidString
        _ = await merge.mergeRemoteMessage(
            id: mid, sessionId: sid, role: "assistant", content: "newer",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 500)
        )
        let applied = await merge.mergeRemoteMessage(
            id: mid, sessionId: sid, role: "assistant", content: "older",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        XCTAssertFalse(applied)
        let stored = await merge.loadSingleMessage(id: mid)
        XCTAssertEqual(stored?.content, "newer")
    }

    /// Merging into a session whose agent loop is mid-flight would scramble a
    /// locally authoritative transcript. CloudKit re-delivers, so skipping is
    /// safe.
    @MainActor
    func testMergeIsDeferredWhileSessionIsRunning() async throws {
        let merge = try makeMerge()
        let sid = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: sid, title: "s", modelId: "m",
            createdAt: Date(), updatedAt: Date(),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        SessionActivityTracker.shared.setActive(sid)
        defer { SessionActivityTracker.shared.setInactive(sid) }

        let applied = await merge.mergeRemoteMessage(
            id: UUID().uuidString, sessionId: sid,
            role: "assistant", content: "mid-run", createdAt: Date()
        )
        XCTAssertFalse(applied)
    }

    func testDeleteLocalMessageRemovesIt() async throws {
        let merge = try makeMerge()
        let sid = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: sid, title: "s", modelId: "m",
            createdAt: Date(), updatedAt: Date(),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        let mid = UUID().uuidString
        _ = await merge.mergeRemoteMessage(
            id: mid, sessionId: sid, role: "user", content: "x", createdAt: Date()
        )
        await merge.deleteLocalMessage(id: mid)
        let stored = await merge.loadSingleMessage(id: mid)
        XCTAssertNil(stored)
    }

    func testDeleteSessionLocalOnlyRemovesIt() async throws {
        let merge = try makeMerge()
        let sid = UUID().uuidString
        _ = await merge.mergeRemoteSession(
            id: sid, title: "s", modelId: "m",
            createdAt: Date(), updatedAt: Date(),
            lastMessage: nil, fromDeviceId: "peer-1"
        )
        await merge.deleteSessionLocalOnly(sid)
        let exists = await merge.sessionExists(sid)
        XCTAssertFalse(exists)
    }
}
