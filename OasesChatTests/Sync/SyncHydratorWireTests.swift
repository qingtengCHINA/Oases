import XCTest
@testable import Oases_Chat

/// Wire-shape guarantees of the ChatStore hydrators: no secrets in CloudKit
/// fields, oversized parts routed to an asset, deterministic MemoryDaily
/// merges, and inbound SessionFile paths confined to their session folder.
final class SyncHydratorWireTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SyncedTypesBootstrap.registerAll()
    }

    // MARK: - Secrets never leave the Keychain

    func testEnvVarItemIsEmittedWithoutItsValue() throws {
        let entry = EnvVarEntry(id: "env-1", key: "OPENAI_API_KEY", note: "prod")
        let synced = ChatStoreSyncHydrators.syncedEnvVar(for: entry)
        XCTAssertEqual(synced.valueB64, "")
        let portable = try XCTUnwrap(SyncableTypeRegistry.shared.metadata(for: "EnvVarItem")?.buildPortable(synced))
        XCTAssertEqual(portable.fields["valueB64"], .string(""), "an empty value also scrubs an old server copy")
        XCTAssertEqual(portable.fields["key"], .string("OPENAI_API_KEY"))
    }

    func testLegacyInboundEnvValueNeverOverwritesALocalValue() {
        let b64 = Data("sk-remote".utf8).base64EncodedString()
        XCTAssertEqual(ChatStoreSyncHydrators.inboundEnvVarValue(valueB64: b64, localHasValue: true), "")
        XCTAssertEqual(ChatStoreSyncHydrators.inboundEnvVarValue(valueB64: b64, localHasValue: false), "sk-remote")
        XCTAssertEqual(ChatStoreSyncHydrators.inboundEnvVarValue(valueB64: "", localHasValue: false), "")
    }

    func testProviderInstanceIsEmittedWithoutSecretBlob() throws {
        let row: [String: Any] = [
            "label": "OpenAI", "provider_type": "openai",
            "secret_blob": Data("sk-live-secret".utf8).base64EncodedString(),
            "secret_kind": "apiKey",
            "created_at": 1_700_000_000.0, "updated_at": 1_700_000_100.0,
        ]
        let synced = ChatStoreSyncHydrators.syncedProviderInstance(id: "inst-1", row: row)
        XCTAssertNil(synced.secretBlob)
        XCTAssertEqual(synced.secretKind, "apiKey", "non-secret metadata still syncs")
        let portable = try XCTUnwrap(SyncableTypeRegistry.shared.metadata(for: "ProviderInstanceV3")?.buildPortable(synced))
        XCTAssertEqual(portable.fields["secretBlob"], .null)
        let serialized = portable.fields.values.map { "\($0)" }.joined()
        XCTAssertFalse(serialized.contains("sk-live-secret"))
    }

    // MARK: - Oversized MessageV2 parts

    func testOversizedPartsJsonRoutesToAssetAndDecodesBack() throws {
        let bigText = String(repeating: "x", count: 800_000)
        let parts = #"[{"type":"text","text":"\#(bigText)"}]"#
        let synced = SyncedMessage(id: "msg-big", sessionId: "s", role: "assistant", partsJson: parts,
                                   tokenUsageJson: nil, reasoningContent: nil, streamInterruptCount: 0,
                                   sortOrder: 0, createdAt: Date(), updatedAt: Date())
        let portable = try XCTUnwrap(SyncableTypeRegistry.shared.metadata(for: "MessageV2")?.buildPortable(synced))
        let routed = ChatStoreSyncHydrators.routeLargePartsToAsset(portable, messageId: "msg-big")
        XCTAssertEqual(routed.fields["partsJson_inlineSize"], .int(parts.utf8.count))
        let asset = try XCTUnwrap(routed.assets["partsJson"])
        XCTAssertEqual(try String(contentsOf: asset.fileURL, encoding: .utf8), parts)

        // What a receiver sees: no inline field, the payload in `partsJsonAsset`.
        var inboundFields = routed.fields
        inboundFields["partsJson"] = nil
        inboundFields["partsJson_inlineSize"] = nil
        let inbound = PortableRecord(
            id: routed.id, fields: inboundFields,
            assets: ["partsJsonAsset": PortableAsset(key: "partsJsonAsset", fileURL: asset.fileURL,
                                                    size: asset.size, mimeType: nil)],
            schemaVersion: routed.schemaVersion, minimumCompatibleVersion: nil,
            unknownFields: [:], updatedAt: routed.updatedAt
        )
        XCTAssertEqual(ChatStoreSyncHydrators.decodeMessage(inbound)?.partsJson, parts)
    }

    func testSmallPartsJsonStaysInline() throws {
        let synced = SyncedMessage(id: "msg-small", sessionId: "s", role: "user",
                                   partsJson: #"[{"type":"text","text":"hi"}]"#,
                                   tokenUsageJson: nil, reasoningContent: nil, streamInterruptCount: 0,
                                   sortOrder: 0, createdAt: Date(), updatedAt: Date())
        let portable = try XCTUnwrap(SyncableTypeRegistry.shared.metadata(for: "MessageV2")?.buildPortable(synced))
        let routed = ChatStoreSyncHydrators.routeLargePartsToAsset(portable, messageId: "msg-small")
        XCTAssertNil(routed.fields["partsJson_inlineSize"])
        XCTAssertTrue(routed.assets.isEmpty)
    }

    // MARK: - MemoryDaily union

    func testMemoryUnionIsDeterministicAndIdempotent() {
        typealias E = ChatStoreSyncHydrators.MemoryEntry
        let local = [E(timestamp: "2026-09-29 10:00:00", content: "local A"),
                     E(timestamp: "2026-09-29 10:00:00", content: "local B")]
        // Both local blocks survive a merge that adds nothing new…
        let echo = ChatStoreSyncHydrators.unionMemoryEntries(local: local, remote: [local[1]])
        XCTAssertEqual(echo.added, 0)
        XCTAssertEqual(Set(echo.entries.map(\.content)), ["local A", "local B"])

        // …a genuine conflict is added once, and re-merging it is a no-op.
        let remote = [E(timestamp: "2026-09-29 10:00:00", content: "remote C")]
        let first = ChatStoreSyncHydrators.unionMemoryEntries(local: local, remote: remote)
        XCTAssertEqual(first.added, 1)
        let second = ChatStoreSyncHydrators.unionMemoryEntries(local: first.entries, remote: remote)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.entries.count, 3)

        XCTAssertEqual(ChatStoreSyncHydrators.memoryConflictDigest("same"),
                       ChatStoreSyncHydrators.memoryConflictDigest("same"))
        XCTAssertNotEqual(ChatStoreSyncHydrators.memoryConflictDigest("same"),
                          ChatStoreSyncHydrators.memoryConflictDigest("other"))
    }

    // MARK: - SessionFile paths

    func testInboundSessionFilePathsAreConfined() throws {
        let ok = try XCTUnwrap(ChatStoreSyncHydrators.sessionFileDestination(sessionId: "abc", relativePath: "workspace/a/b.txt"))
        XCTAssertTrue(ok.path.hasSuffix("/minis/abc/workspace/a/b.txt"))
        for (sid, rel) in [("abc", "../../minis.db"), ("abc", "workspace/../../x"), ("abc", "/etc/passwd"),
                           ("..", "x"), ("a/b", "x"), ("abc", "workspace\\..\\x"), ("", "x"), ("abc", "")] {
            XCTAssertNil(ChatStoreSyncHydrators.sessionFileDestination(sessionId: sid, relativePath: rel), "\(sid) / \(rel)")
        }
    }
}
