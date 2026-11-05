import Foundation
import XCTest
@testable import Oases_Chat

final class MemoryWikiRepositoryTests: XCTestCase {
    func testUpsertKeepsStableTopicAndRecordsRevisionHistory() async throws {
        let repository = try makeRepository()
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_100)

        let first = try await repository.upsert(
            topic: "Project / Release Plan",
            title: "Release plan",
            body: "Ship the first beta.",
            tags: ["release"],
            updatedAt: firstDate
        )
        let second = try await repository.upsert(
            topic: " project release plan ",
            title: "Release plan",
            body: "Ship the beta after the device smoke test.",
            tags: ["release", "device"],
            updatedAt: secondDate
        )

        XCTAssertEqual(first.topic, "project-release-plan")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.createdAt, firstDate)
        let pages = try await repository.all()
        XCTAssertEqual(pages.count, 1)

        let history = try await repository.history(topic: "project-release-plan")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.revision, 1)
        XCTAssertEqual(history.first?.body, "Ship the first beta.")
    }

    func testReplayingIdenticalWikiWriteIsIdempotent() async throws {
        let repository = try makeRepository()
        let runID = UUID()
        let first = try await repository.upsert(
            topic: "agent-project-alpha",
            title: "Project alpha",
            body: "Keep the local artifact.",
            tags: ["agent-run"],
            relatedTopics: ["agent-run-1"],
            sourceRunID: runID,
            provenance: MemoryProvenance(source: "test", sourceRunID: runID)
        )
        let replay = try await repository.upsert(
            topic: "agent-project-alpha",
            title: "Project alpha",
            body: "Keep the local artifact.",
            tags: ["agent-run"],
            relatedTopics: ["agent-run-1"],
            sourceRunID: runID,
            provenance: MemoryProvenance(source: "test", sourceRunID: runID)
        )

        XCTAssertEqual(replay, first)
        let history = try await repository.history(topic: "agent-project-alpha")
        XCTAssertTrue(history.isEmpty)
    }

    func testWikiReadsAfterRestartAndSearchesChineseAndEnglish() async throws {
        let url = try temporaryStoreURL()
        let repository = MemoryWikiRepository(fileURL: url)
        _ = try await repository.upsert(
            topic: "travel/kyoto",
            title: "旅行计划",
            body: "上海和京都的行程安排",
            tags: ["trip"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await repository.upsert(
            topic: "project/release",
            title: "Project release",
            body: "Milestones and release checklist",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        let restarted = MemoryWikiRepository(fileURL: url)
        let restartedPage = try await restarted.page(topic: "TRAVEL/KYOTO")
        let chineseResults = try await restarted.search("京都")
        let englishResults = try await restarted.search("release checklist")
        XCTAssertEqual(restartedPage?.title, "旅行计划")
        XCTAssertEqual(chineseResults.first?.page.title, "旅行计划")
        XCTAssertEqual(englishResults.first?.page.title, "Project release")
    }

    func testDeleteExportAndPrivacyPolicy() async throws {
        let repository = try makeRepository()
        _ = try await repository.upsert(topic: "temporary", title: "Temporary", body: "Remove me")
        let firstDelete = try await repository.delete(topic: "temporary")
        let secondDelete = try await repository.delete(topic: "temporary")
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)

        _ = try await repository.upsert(topic: "exported", title: "Exported", body: "Local project fact")
        let exported = String(decoding: try await repository.export(), as: UTF8.self)
        XCTAssertTrue(exported.contains("exported"))
        XCTAssertTrue(exported.contains("schemaVersion"))

        do {
            _ = try await repository.upsert(topic: "credentials", title: "Credentials", body: "api_key=sk-test-secret")
            XCTFail("Expected sensitive wiki content to be rejected")
        } catch let error as MemoryRepositoryError {
            XCTAssertEqual(error, .rejectedByPolicy(.apiKeys))
        }
    }

    func testInvalidTopicIsRejected() async throws {
        let repository = try makeRepository()
        do {
            _ = try await repository.upsert(topic: "  ///  ", title: "Empty", body: "No topic")
            XCTFail("Expected an empty topic to be rejected")
        } catch let error as MemoryRepositoryError {
            XCTAssertEqual(error, .invalidTopic)
        }
    }

    private func makeRepository() throws -> MemoryWikiRepository {
        MemoryWikiRepository(fileURL: try temporaryStoreURL())
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-wiki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("wiki.json")
    }
}
