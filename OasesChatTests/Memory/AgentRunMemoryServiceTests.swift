import XCTest
@testable import Oases_Chat

final class AgentRunMemoryServiceTests: XCTestCase {
    func testTerminalProjectRunWritesStableWikiAndSurvivesRepositoryRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memoryURL = root.appendingPathComponent("memories.json")
        let wikiURL = root.appendingPathComponent("wiki.json")
        let service = AgentRunMemoryService(
            repository: MemoryRepository(fileURL: memoryURL),
            wikiRepository: MemoryWikiRepository(fileURL: wikiURL)
        )
        let run = try makeCompletedRun(
            request: "制作一个关于本地资料的 pptx",
            projectID: "project-alpha",
            sessionID: "session-alpha"
        )

        let result = await service.record(run: run, artifacts: [])
        XCTAssertTrue(result.persisted)
        XCTAssertEqual(result.wikiTopic, "agent-project-project-alpha")

        let restartedService = AgentRunMemoryService(
            repository: MemoryRepository(fileURL: memoryURL),
            wikiRepository: MemoryWikiRepository(fileURL: wikiURL)
        )
        let context = await restartedService.relevantContext(query: "pptx 本地资料")
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("制作一个关于本地资料的 pptx") == true)
        XCTAssertTrue(context?.contains("agent-project-project-alpha") == true)
    }

    func testTerminalRunMemoryRedactsSecretsAndDoesNotStoreTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-memory-redaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wiki = MemoryWikiRepository(fileURL: root.appendingPathComponent("wiki.json"))
        let service = AgentRunMemoryService(
            repository: MemoryRepository(fileURL: root.appendingPathComponent("memories.json")),
            wikiRepository: wiki
        )
        let run = try makeCompletedRun(
            request: "api_key=sk-live-secret 制作文件",
            projectID: "redaction-test",
            sessionID: nil
        )

        let result = await service.record(run: run, artifacts: [])
        XCTAssertTrue(result.persisted)
        let page = try await wiki.page(topic: result.wikiTopic)
        XCTAssertNotNil(page)
        XCTAssertFalse(page?.body.contains("sk-live-secret") == true)
        XCTAssertFalse(page?.body.localizedCaseInsensitiveContains("full conversation transcript") == true)
        XCTAssertTrue(page?.body.contains("[redacted]") == true)
    }

    func testPendingJournalIsReplayedAfterServiceRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-memory-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runID = UUID()
        let document = MemoryDocument(
            title: "agent-run-journal",
            body: "journal recovery marker",
            sourceRunID: runID,
            provenance: MemoryProvenance(source: "test", sourceRunID: runID)
        )
        let wiki = AgentRunMemoryWikiWrite(
            topic: "agent-project-journal",
            title: "Journal project",
            body: "journal recovery marker",
            tags: ["agent-run"],
            relatedTopics: ["agent-run-journal"],
            sourceRunID: runID,
            provenance: MemoryProvenance(source: "test", sourceRunID: runID),
            updatedAt: Date()
        )
        let journalURL = root.appendingPathComponent("pending-agent-run.json")
        let journal = AgentRunMemoryJournal(
            schemaVersion: AgentRunMemoryJournal.currentSchemaVersion,
            document: document,
            wiki: wiki
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL, options: [.atomic])

        let service = AgentRunMemoryService(
            repository: MemoryRepository(fileURL: root.appendingPathComponent("memories.json")),
            wikiRepository: MemoryWikiRepository(fileURL: root.appendingPathComponent("wiki.json")),
            journalURL: journalURL
        )
        let context = await service.relevantContext(query: "journal recovery")

        XCTAssertTrue(context?.contains("journal recovery marker") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRecordingSameRunTwiceDoesNotCreateDuplicateWikiRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-run-memory-idempotent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wiki = MemoryWikiRepository(fileURL: root.appendingPathComponent("wiki.json"))
        let service = AgentRunMemoryService(
            repository: MemoryRepository(fileURL: root.appendingPathComponent("memories.json")),
            wikiRepository: wiki,
            journalURL: root.appendingPathComponent("pending-agent-run.json")
        )
        let run = try makeCompletedRun(request: "重复写入交付摘要", projectID: "idempotent", sessionID: nil)

        let firstResult = await service.record(run: run, artifacts: [])
        let secondResult = await service.record(run: run, artifacts: [])
        XCTAssertTrue(firstResult.persisted)
        XCTAssertTrue(secondResult.persisted)
        let page = try await wiki.page(topic: "agent-project-idempotent")
        let history = try await wiki.history(topic: "agent-project-idempotent")
        XCTAssertEqual(page?.revision, 1)
        XCTAssertTrue(history.isEmpty)
    }

    private func makeCompletedRun(
        request: String,
        projectID: String,
        sessionID: String?
    ) throws -> AgentRun {
        let context = AgentRunContext(
            model: "oases-project",
            effort: nil,
            surface: .project,
            messages: [ChatAPIMessage(role: "user", content: .text(request))],
            toolsJSON: nil,
            projectSessionID: sessionID,
            projectID: projectID
        )
        var run = AgentRun(request: request, context: context)
        try run.transition(to: .planning)
        try run.transition(to: .finalizing)
        run.delivery = AgentDelivery(
            outcome: .succeeded,
            summary: "交付完成",
            sourceLinks: [URL(string: "https://example.com/article?token=private")!],
            completedSteps: ["创建文件"]
        )
        try run.transition(to: .succeeded)
        return run
    }
}
