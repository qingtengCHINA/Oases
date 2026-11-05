import SwiftData
import XCTest
@testable import Oases_Chat

/// Read-only compatibility coverage for the engineering SQLite and native
/// SwiftData session stores. Every fixture owns both stores; production
/// singletons are deliberately not used.
final class SessionReadFacadeTests: XCTestCase {

    func testUnionOrderingDeduplicationAndOwnerRoutedReads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionReadFacadeTests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatStore(baseURL: directory)
        let container = try makeNativeContainer()
        let nativeEngine = SessionsQueryEngine(modelContainer: container)
        let facade = SessionReadFacade(chatStore: store, nativeEngine: nativeEngine)

        let engineeringDuplicate = await store.createSession(
            modelId: "engineering.model", title: "Engineering owner"
        )
        let engineeringOnly = await store.createSession(
            modelId: "engineering.model", title: "Engineering searchable"
        )
        let messageDate = Date(timeIntervalSince1970: 2_000_000_000)
        let engineeringOwnerMessage = RawMessage(
            id: "00000000-0000-0000-0000-000000000011",
            sessionId: engineeringDuplicate.id,
            role: .user,
            parts: [.text("engineering owner text")],
            createdAt: messageDate,
            tokenUsage: nil,
            reasoningContent: nil
        )
        let engineeringSearchMessage = RawMessage(
            id: "00000000-0000-0000-0000-000000000012",
            sessionId: engineeringOnly.id,
            role: .user,
            parts: [.text("needle engineering source")],
            createdAt: messageDate,
            tokenUsage: nil,
            reasoningContent: nil
        )
        await store.appendMessage(engineeringOwnerMessage)
        await store.appendMessage(engineeringSearchMessage)

        let duplicateUUID = try XCTUnwrap(UUID(uuidString: engineeringDuplicate.id))
        let nativeDuplicateMessages = [
            NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                role: "user",
                content: "needle native collision",
                createdAt: messageDate
            ),
            NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                role: "assistant",
                content: "native collision assistant",
                createdAt: messageDate.addingTimeInterval(1)
            ),
        ]
        try insertNativeConversation(
            container,
            id: duplicateUUID,
            title: "Native duplicate must lose",
            updatedAt: Date(timeIntervalSince1970: 4_000_000_000),
            messages: nativeDuplicateMessages
        )

        let nativeA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let nativeB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let nativeTieDate = Date(timeIntervalSince1970: 4_000_000_000)
        try insertNativeConversation(
            container,
            id: nativeA,
            title: "Native A",
            updatedAt: nativeTieDate,
            messages: [NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
                role: "user",
                content: "needle native A",
                createdAt: messageDate
            )]
        )
        try insertNativeConversation(
            container,
            id: nativeB,
            title: "Native B",
            updatedAt: nativeTieDate,
            messages: [NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
                role: "user",
                content: "needle native B",
                createdAt: messageDate
            )]
        )

        let allSessions = await facade.listSessions(limit: 100)
        let allSessionIds = allSessions.map(\.id)
        XCTAssertEqual(allSessionIds.filter { $0.lowercased() == engineeringDuplicate.id.lowercased() }.count, 1)
        XCTAssertEqual(allSessions.first(where: { $0.id.lowercased() == engineeringDuplicate.id.lowercased() })?.owner, .engineering)
        XCTAssertTrue(allSessionIds.contains(nativeA.uuidString))
        XCTAssertTrue(allSessionIds.contains(nativeB.uuidString))
        let filteredCollisionSessions = await facade.listSessions(
            keywords: ["native"], limit: 100
        )
        XCTAssertFalse(filteredCollisionSessions.contains {
            $0.id.lowercased() == engineeringDuplicate.id.lowercased()
        })

        // Native A and B have equal last-active timestamps, so canonical UUID
        // ordering must be stable and independent of SwiftData fetch order.
        let nativeTieIds = allSessions
            .filter { $0.id == nativeA.uuidString || $0.id == nativeB.uuidString }
            .map(\.id)
        XCTAssertEqual(nativeTieIds, [nativeA.uuidString, nativeB.uuidString])
        let limitedSessions = await facade.listSessions(limit: 2)
        XCTAssertEqual(limitedSessions, Array(allSessions.prefix(2)))

        let allHits = await facade.searchMessages(keywords: ["needle"], limit: 100)
        let hitIds = allHits.map(\.messageId)
        XCTAssertTrue(hitIds.contains(engineeringSearchMessage.id))
        XCTAssertTrue(hitIds.contains("00000000-0000-0000-0000-000000000031"))
        XCTAssertTrue(hitIds.contains("00000000-0000-0000-0000-000000000032"))
        // The native duplicate matches, but its session is engineering-owned;
        // native message rows must not leak through the owner boundary.
        XCTAssertFalse(hitIds.contains("00000000-0000-0000-0000-000000000021"))
        let nativeTieHitIds = allHits
            .filter {
                $0.messageId == "00000000-0000-0000-0000-000000000031"
                    || $0.messageId == "00000000-0000-0000-0000-000000000032"
            }
            .map(\.messageId)
        XCTAssertEqual(nativeTieHitIds, [
            "00000000-0000-0000-0000-000000000031",
            "00000000-0000-0000-0000-000000000032",
        ])
        let limitedHits = await facade.searchMessages(keywords: ["needle"], limit: 2)
        XCTAssertEqual(limitedHits, Array(allHits.prefix(2)))

        let ownerMetaResult = await facade.getSession(id: engineeringDuplicate.id)
        let ownerMeta = try XCTUnwrap(ownerMetaResult)
        XCTAssertEqual(ownerMeta.owner, .engineering)
        let duplicateOwner = await facade.sessionOwner(id: duplicateUUID.uuidString)
        XCTAssertEqual(duplicateOwner, .engineering)
        let engineeringCount = await facade.messageCount(sessionId: engineeringDuplicate.id)
        XCTAssertEqual(engineeringCount, 1)
        let ownerPage = await facade.loadMessagePage(
            sessionId: duplicateUUID.uuidString, limit: 10, maxChars: 1000
        )
        XCTAssertEqual(ownerPage.count, 1)
        XCTAssertEqual(ownerPage.first?.text, "engineering owner text")

        let nativeOwner = await facade.sessionOwner(id: nativeA.uuidString)
        XCTAssertEqual(nativeOwner, .native)
        let verificationContext = ModelContext(container)
        let savedMessages = try verificationContext.fetch(FetchDescriptor<MessageModel>())
        XCTAssertEqual(savedMessages.count, 4)
        XCTAssertTrue(savedMessages.contains { $0.conversation?.id == nativeA })
        let nativeCount = await facade.messageCount(sessionId: nativeA.uuidString)
        XCTAssertEqual(nativeCount, 1)
        let nativePage = await facade.loadMessagePage(
            sessionId: nativeA.uuidString, limit: 10, maxChars: 1000
        )
        XCTAssertEqual(nativePage.first?.text, "needle native A")

        await store.closeDatabase()
        try? FileManager.default.removeItem(at: directory)
    }

    func testInvalidNativeIdFiltersReturnNoneAndFilterBeforeLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionReadFacadeInvalidID-\(UUID().uuidString)", isDirectory: true)
        let store = ChatStore(baseURL: directory)
        let container = try makeNativeContainer()
        let nativeEngine = SessionsQueryEngine(modelContainer: container)
        let facade = SessionReadFacade(chatStore: store, nativeEngine: nativeEngine)

        let newerNonMatch = Date(timeIntervalSince1970: 3_000_000_000)
        let olderMatch = Date(timeIntervalSince1970: 2_000_000_000)
        try insertNativeConversation(
            container,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            title: "newer unrelated",
            updatedAt: newerNonMatch,
            messages: [NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
                role: "user", content: "nothing relevant", createdAt: newerNonMatch
            )]
        )
        let matchingID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        try insertNativeConversation(
            container,
            id: matchingID,
            title: "older matching",
            updatedAt: olderMatch,
            messages: [NativeMessageFixture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
                role: "user", content: "needle older match", createdAt: olderMatch
            )]
        )

        let filtered = await nativeEngine.querySessionsMeta(
            sessionIds: nil, keywords: ["needle"], limit: 1
        )
        XCTAssertEqual(filtered.map(\.sessionId), [matchingID.uuidString])
        let nativeInvalid = await nativeEngine.querySessionsMeta(
            sessionIds: ["not-a-uuid"], keywords: nil, limit: 100
        )
        XCTAssertTrue(nativeInvalid.isEmpty)
        let nativeSearchInvalid = await nativeEngine.searchMessages(
            sessionIds: ["not-a-uuid"], keywords: ["needle"], limit: 100
        )
        XCTAssertTrue(nativeSearchInvalid.isEmpty)

        let facadeInvalidList = await facade.listSessions(sessionIds: ["not-a-uuid"], limit: 100)
        XCTAssertTrue(facadeInvalidList.isEmpty)
        let facadeInvalidSearch = await facade.searchMessages(
            sessionIds: ["not-a-uuid"], keywords: ["needle"], limit: 100
        )
        XCTAssertTrue(facadeInvalidSearch.isEmpty)

        await store.closeDatabase()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeNativeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ConversationModel.self, MessageModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func insertNativeConversation(
        _ container: ModelContainer,
        id: UUID,
        title: String,
        updatedAt: Date,
        messages: [NativeMessageFixture]
    ) throws {
        let context = ModelContext(container)
        let conversation = ConversationModel()
        conversation.id = id
        conversation.title = title
        conversation.createdAt = updatedAt
        conversation.updatedAt = updatedAt
        context.insert(conversation)

        for (index, fixture) in messages.enumerated() {
            let message = MessageModel(role: fixture.role, content: fixture.content)
            message.id = fixture.id
            message.createdAt = fixture.createdAt
            message.sortOrder = index
            message.conversation = conversation
            conversation.messages.append(message)
            context.insert(message)
        }
        try context.save()
    }

    private struct NativeMessageFixture {
        let id: UUID
        let role: String
        let content: String
        let createdAt: Date
    }
}
