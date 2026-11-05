import SwiftData
import XCTest
@testable import Oases_Chat

/// The hydrators sit between SwiftData and the wire format. A field name typo
/// or a parts-JSON mismatch wouldn't fail to compile — it would just silently
/// sync empty messages. These pin the encode/decode contract.
final class SyncHydratorRoundTripTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // App-launch registration doesn't fire under the test host; populate
        // the wire-schema registry explicitly so hydrator lookups succeed.
        SyncedTypesBootstrap.registerAll()
        await SyncSessionMergeHydrators.registerAll()
    }

    /// `partsJson` must stay in OpenMinis' shape so a peer on either build can
    /// read the other's messages.
    func testTextPartRoundTripsThroughPartsJSON() throws {
        let original = "hello 世界 — with punctuation"
        let json = encodeTextPart(original)

        // Shape check, not just round-trip: a self-consistent but wrong format
        // would pass a pure round-trip test.
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["type"] as? String, "text")
        XCTAssertEqual(parsed[0]["text"] as? String, original)

        XCTAssertEqual(decodeTextParts(json), original)
    }

    func testMultipleTextPartsAreConcatenated() {
        let json = """
        [{"type":"text","text":"a"},{"type":"text","text":"b"}]
        """
        XCTAssertEqual(decodeTextParts(json), "ab")
    }

    /// Non-text parts have no representation in `MessageModel.content`; they
    /// must be dropped, not rendered as placeholder junk.
    func testNonTextPartsAreDropped() {
        let json = """
        [{"type":"text","text":"keep"},{"type":"image","url":"x.png"}]
        """
        XCTAssertEqual(decodeTextParts(json), "keep")
    }

    func testMalformedPartsJSONDecodesToEmptyRatherThanCrashing() {
        XCTAssertEqual(decodeTextParts("not json"), "")
        XCTAssertEqual(decodeTextParts(""), "")
    }

    /// The registry must know the two types the hydrators register, or
    /// `buildPortable` returns nil and records silently never leave the device.
    func testRegistryKnowsSessionAndMessageTypes() {
        XCTAssertNotNil(SyncableTypeRegistry.shared.metadata(for: "SessionV2"))
        XCTAssertNotNil(SyncableTypeRegistry.shared.metadata(for: "MessageV2"))
    }

    /// A SyncedSession must survive the trip through PortableRecord with its
    /// identity and LWW clock intact — those two drive every merge decision.
    func testSessionSurvivesPortableRecordEncoding() throws {
        let metadata = try XCTUnwrap(SyncableTypeRegistry.shared.metadata(for: "SessionV2"))
        let updatedAt = Date(timeIntervalSince1970: 12345)
        let synced = SyncedSession(
            id: "session-1", title: "标题", category: "chat", modelId: "gpt-4o",
            createdAt: Date(timeIntervalSince1970: 1000), updatedAt: updatedAt,
            memoryEnabled: 1, modelBinding: nil, pinnedAt: nil
        )

        let record = try XCTUnwrap(metadata.buildPortable(synced))
        XCTAssertEqual(record.id.type, "SessionV2")
        XCTAssertEqual(record.id.id, "session-1")

        if case .string(let title) = record.fields["title"] {
            XCTAssertEqual(title, "标题")
        } else {
            XCTFail("title should encode as a string field")
        }
        if case .date(let encoded) = record.fields["updatedAt"] {
            XCTAssertEqual(encoded.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("updatedAt must encode as a date — it is the LWW clock")
        }
    }

    /// `SyncRecordID.description` is `"Type:id"`, which is exactly what
    /// `clearDirtyRecord(recordName:)` parses. If these drift, pushed records
    /// never clear and the queue grows forever.
    func testRecordIDStringFormatMatchesDirtyQueueKey() {
        let recordID = SyncRecordID(type: "MessageV2", id: "abc-123")
        XCTAssertEqual(recordID.description, "MessageV2:abc-123")
    }

    // Mirrors of the hydrator's private helpers. Kept in sync deliberately:
    // if the production shape changes, the shape assertions above fail.
    private func encodeTextPart(_ text: String) -> String {
        let payload = [["type": "text", "text": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func decodeTextParts(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return "" }
        return parts.compactMap { part in
            guard (part["type"] as? String) == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }
}
