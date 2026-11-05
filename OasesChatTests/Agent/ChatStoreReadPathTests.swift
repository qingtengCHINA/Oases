import XCTest
@testable import Oases_Chat

final class ChatStoreReadPathTests: XCTestCase {
    func testSQLiteSessionMetadataAndMessagesAreReadable() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreReadPathTests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatStore(baseURL: directory)

        let session = await store.createSession(modelId: "model.stage1", title: "SQLite session")
        let didPin = await store.toggleSessionPin(session.id)
        XCTAssertTrue(didPin)

        let message = RawMessage(
            id: UUID().uuidString,
            sessionId: session.id,
            role: .user,
            parts: [.text("stage1 searchable text")],
            createdAt: Date(),
            tokenUsage: nil,
            reasoningContent: nil
        )
        await store.appendMessage(message)

        let metas = await store.querySessionsMeta(sessionIds: [session.id])
        guard let meta = metas.first else {
            XCTFail("ChatStore should return the created session metadata")
            await store.closeDatabase()
            try? FileManager.default.removeItem(at: directory)
            return
        }
        XCTAssertEqual(meta.title, "SQLite session")
        XCTAssertEqual(meta.modelId, "model.stage1")
        XCTAssertNotNil(meta.pinnedAt)
        XCTAssertEqual(meta.messageCount, 1)

        let hits = await store.searchMessages(sessionIds: [session.id], keywords: ["searchable"])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.messageId, message.id)
        XCTAssertTrue(hits.first?.snippet.contains("stage1 searchable text") == true)

        let page = await store.loadMessagePage(sessionId: session.id, limit: 10, maxChars: 1000)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.first?.text, "stage1 searchable text")

        await store.closeDatabase()
        try? FileManager.default.removeItem(at: directory)
    }
}
