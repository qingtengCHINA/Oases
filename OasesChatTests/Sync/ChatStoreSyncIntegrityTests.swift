import XCTest
@testable import Oases_Chat

/// The real ChatStore side of the v2 sync chain, on a throwaway SQLite
/// store: metadata-clock merge, conditional dirty clears, delete
/// tombstones / unpushed-content detection, and prune anchor protection.
final class ChatStoreSyncIntegrityTests: XCTestCase {

    private var directory: URL!
    private var store: ChatStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreSyncIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        store = ChatStore(baseURL: directory)
        // iCloud sync is switched off in the app (`CloudSyncFeature`); these
        // tests pin the dormant engine's store contract, so opt this
        // throwaway store back into sync bookkeeping.
        await store.setCloudSyncTrackingEnabled(true)
        // Dirty rows are written, but no send is scheduled (keeps the sync
        // engines out of the test).
        await store.setSyncSendDeferred(true)
    }

    override func tearDown() async throws {
        await store.closeDatabase()
        try? FileManager.default.removeItem(at: directory)
        store = nil
        try await super.tearDown()
    }

    private func message(_ sessionId: String, _ text: String, at date: Date = Date()) -> RawMessage {
        RawMessage(id: UUID().uuidString, sessionId: sessionId, role: .user,
                   parts: [.text(text)], createdAt: date, tokenUsage: nil, reasoningContent: nil)
    }

    // MARK: - Metadata clock (field-level LWW)

    func testPeerReplyDoesNotOverwriteLocalRename() async throws {
        let session = await store.createSession(modelId: "model", title: "Original")
        await store.updateSessionTitle(session.id, title: "Renamed")
        let renamedMeta = await store.sessionMetaUpdatedAt(session.id)
        let renamedAt = try XCTUnwrap(renamedMeta)

        // A reply on this device moves the activity clock only.
        await store.appendMessage(message(session.id, "local reply"))
        let metaAfterReply = await store.sessionMetaUpdatedAt(session.id)
        XCTAssertEqual(metaAfterReply, renamedAt)

        // The peer replied later but never renamed: its SessionV2 carries its
        // (older) metadata clock, even though its activity is newer.
        var peer = session
        peer.title = "Original"
        peer.updatedAt = session.createdAt
        await store.mergeRemoteSession(peer, fromDeviceId: "")
        let afterStale = await store.getSession(session.id)
        XCTAssertEqual(afterStale?.title, "Renamed")

        // A genuinely newer rename on the peer still wins.
        peer.title = "Peer rename"
        peer.updatedAt = renamedAt.addingTimeInterval(60)
        await store.mergeRemoteSession(peer, fromDeviceId: "")
        let afterNewer = await store.getSession(session.id)
        XCTAssertEqual(afterNewer?.title, "Peer rename")
        // …and a V2 merge (no origin device) doesn't flag the row remote.
        XCTAssertFalse(afterNewer?.isRemote ?? true)
    }

    func testExplicitRemoteUnpinPropagates() async throws {
        let session = await store.createSession(modelId: "model", title: "Pinned")
        _ = await store.toggleSessionPin(session.id)
        let pinnedMetaValue = await store.sessionMetaUpdatedAt(session.id)
        let pinnedMeta = try XCTUnwrap(pinnedMetaValue)

        var peer = session
        peer.updatedAt = pinnedMeta.addingTimeInterval(30)
        await store.mergeRemoteSession(peer, fromDeviceId: "",
                                       remotePinnedAtRaw: Date(timeIntervalSince1970: 0))
        let merged = await store.getSession(session.id)
        XCTAssertNil(merged?.pinnedAt)
    }

    func testOutboundSessionCarriesMetaClockAndExplicitUnpin() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(id: "s", title: "t", category: nil, modelId: "m",
                                  createdAt: created, updatedAt: created.addingTimeInterval(500))
        let meta = created.addingTimeInterval(10)
        let synced = ChatStoreSyncHydrators.syncedSession(session, memoryEnabled: true,
                                                          modelBinding: nil, metaUpdatedAt: meta)
        XCTAssertEqual(synced.updatedAt, meta)
        XCTAssertEqual(synced.pinnedAt, Date(timeIntervalSince1970: 0))
    }

    // MARK: - Conditional dirty clear

    func testPushAckKeepsRowRemarkedAfterSnapshot() async throws {
        await store.setSyncZoneName("zone-test")
        await store.markDirty(recordType: "SessionV2", recordId: "s1")
        let firstLoad = await store.loadDirtyRecords(v2Only: true)
        let snapshot = try XCTUnwrap(firstLoad.first { $0.recordId == "s1" })

        try await Task.sleep(nanoseconds: 5_000_000)
        await store.markDirty(recordType: "SessionV2", recordId: "s1")   // edit while push in flight

        await store.clearDirtyRecord(recordName: "SessionV2:s1", ifNotModifiedAfter: snapshot.createdAt)
        let stillDirty = await store.loadDirtyRecords(v2Only: true).contains { $0.recordId == "s1" }
        XCTAssertTrue(stillDirty, "a re-mark after the snapshot must survive the older ack")

        let secondLoad = await store.loadDirtyRecords(v2Only: true)
        let fresh = try XCTUnwrap(secondLoad.first { $0.recordId == "s1" })
        await store.clearDirtyRecord(recordName: "SessionV2:s1", ifNotModifiedAfter: fresh.createdAt)
        let cleared = await store.loadDirtyRecords(v2Only: true).contains { $0.recordId == "s1" }
        XCTAssertFalse(cleared)
    }

    // MARK: - Deletes and tombstones

    func testUnpushedLocalMessagesAreDetected() async {
        await store.setSyncZoneName("zone-test")
        let session = await store.createSession(modelId: "model", title: "S")
        let before = await store.hasUnpushedLocalContent(sessionId: session.id)
        XCTAssertFalse(before)

        await store.appendMessage(message(session.id, "not pushed yet"))
        let pending = await store.hasUnpushedLocalContent(sessionId: session.id)
        XCTAssertTrue(pending)

        let ids = await store.loadMessages(sessionId: session.id).map(\.id)
        for id in ids {
            await store.clearDirtyRecord(recordName: "Message:\(id)")
            await store.clearDirtyRecord(recordName: "MessageV2:\(id)")
        }
        let afterPush = await store.hasUnpushedLocalContent(sessionId: session.id)
        XCTAssertFalse(afterPush)
    }

    func testDeletedSessionTombstoneBlocksStaleButNotNewerRecreate() async {
        let id = UUID().uuidString
        let deletedAt = Date()
        await store.recordDeletedSessionTombstone(id, at: deletedAt)

        let stale = ChatSession(id: id, title: "stale", category: nil, modelId: "m",
                                createdAt: deletedAt.addingTimeInterval(-100),
                                updatedAt: deletedAt.addingTimeInterval(-50))
        await store.mergeRemoteSession(stale, fromDeviceId: "")
        let resurrected = await store.sessionExists(id: id)
        XCTAssertFalse(resurrected)

        var recreated = stale
        recreated.updatedAt = deletedAt.addingTimeInterval(60)
        await store.mergeRemoteSession(recreated, fromDeviceId: "")
        let exists = await store.sessionExists(id: id)
        XCTAssertTrue(exists)
        let tombstone = await store.deletedSessionTombstone(id)
        XCTAssertNil(tombstone, "a newer re-create clears the tombstone so its messages can follow")
    }

    func testDeletedMessageTombstoneBlocksReinsert() async {
        let session = await store.createSession(modelId: "model", title: "S")
        let messageId = UUID().uuidString
        let deletedAt = Date()
        await store.recordDeletedRecordTombstone(type: "Message", id: messageId, at: deletedAt)

        await store.mergeRemoteMessage(
            id: messageId, sessionId: session.id, role: "user",
            partsJson: #"[{"type":"text","text":"old"}]"#,
            createdAt: deletedAt.addingTimeInterval(-30), tokenUsageJson: nil, sortOrder: 0,
            reasoningContent: nil, streamInterruptCount: 0,
            updatedAt: deletedAt.addingTimeInterval(-30)
        )
        let reinserted = await store.loadSingleMessage(id: messageId)
        XCTAssertNil(reinserted)
    }

    // MARK: - Prune

    func testPruneKeepsCompactMarkerAnchors() async {
        let session = await store.createSession(modelId: "model", title: "Long")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let anchorA = message(session.id, "compacted tail", at: start)
        let anchorB = message(session.id, "first kept", at: start.addingTimeInterval(1))
        await store.appendMessages([anchorA, anchorB])
        await store.insertCompactMarker(CompactMarker(
            id: UUID().uuidString, sessionId: session.id, summary: "summary",
            firstKeptSortOrder: 1, compactedCount: 1, createdAt: start,
            uiBoundarySortOrder: nil, boundaryMessageId: nil,
            firstKeptMessageId: anchorB.id, lastCompactedMessageId: anchorA.id, version: 2
        ))

        // 2050 more rows push the session past the 2048-row prune threshold.
        let filler = (0..<2050).map { i in
            message(session.id, "filler \(i)", at: start.addingTimeInterval(Double(i + 2)))
        }
        await store.appendMessages(filler)

        let keptA = await store.loadSingleMessage(id: anchorA.id)
        let keptB = await store.loadSingleMessage(id: anchorB.id)
        XCTAssertNotNil(keptA)
        XCTAssertNotNil(keptB)
        let prunedFirstFiller = await store.loadSingleMessage(id: filler[0].id)
        XCTAssertNil(prunedFirstFiller, "the oldest non-anchor rows are what gets pruned")
        let count = await store.messageCount(sessionId: session.id)
        XCTAssertEqual(count, 2048)
    }

    // MARK: - Session load image budget

    func testOnlyRecentImageMessagesAreInlined() {
        let ref = MediaRef(id: "img", relativePath: "x.png", mimeType: "image/png",
                           originalFileName: nil, linuxPath: "/var/minis/attachments/x.png")
        let messages = (0..<5).map { i in
            RawMessage(id: "m\(i)", sessionId: "s", role: .user, parts: [.mediaRef(ref)],
                       createdAt: Date(timeIntervalSince1970: Double(i)), tokenUsage: nil, reasoningContent: nil)
        }
        XCTAssertEqual(RawMessage.idsWithRecentImages(in: messages, limit: 2), ["m3", "m4"])

        let agent = messages[0].toAgentMessage(mediaResolver: { _ in URL(fileURLWithPath: "/nonexistent") },
                                               loadImageData: false)
        guard case .text(let placeholder)? = agent.parts.first else {
            return XCTFail("an image left out of memory becomes a path reference")
        }
        XCTAssertTrue(placeholder.contains("/var/minis/attachments/x.png"))
    }
}
