import Foundation
import XCTest
@testable import Oases_Chat

final class MemoryRepositoryTests: XCTestCase {
    func testDocumentCodablePreservesProvenanceSensitivityAndSchemaVersion() throws {
        let runID = UUID()
        let document = makeDocument(
            title: "Project preferences",
            body: "Use concise release notes.",
            tags: ["project", "preferences"],
            sourceRunID: runID,
            provenance: MemoryProvenance(source: "unit-test", sourceRunID: runID),
            sensitivity: .normal
        )

        let data = try JSONEncoder.memory.encode(document)
        let decoded = try JSONDecoder.memory.decode(MemoryDocument.self, from: data)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.provenance.source, "unit-test")
        XCTAssertEqual(decoded.sensitivity, .normal)
        XCTAssertEqual(decoded.schemaVersion, MemoryDocument.currentSchemaVersion)
    }

    func testDuplicateTopicUpdatesExistingDocumentInsteadOfAppending() async throws {
        let repository = try makeRepository()
        let first = makeDocument(title: "Release plan", body: "Initial plan")
        let duplicate = makeDocument(title: "  release   plan ", body: "Revised plan")

        let savedFirst = try await repository.save(first)
        let savedDuplicate = try await repository.save(duplicate)
        let documents = try await repository.all()

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(savedDuplicate.id, savedFirst.id)
        XCTAssertEqual(documents.first?.body, "Revised plan")
        XCTAssertEqual(documents.first?.createdAt, first.createdAt)
    }

    func testRepositoryReadsDocumentsAfterRestart() async throws {
        let repositoryURL = try temporaryStoreURL()
        let firstRepository = MemoryRepository(fileURL: repositoryURL)
        let document = makeDocument(title: "Restart check", body: "Persisted locally")
        _ = try await firstRepository.save(document)

        let restartedRepository = MemoryRepository(fileURL: repositoryURL)
        let documents = try await restartedRepository.all()

        XCTAssertEqual(documents, [document])
    }

    func testDefaultPolicyRejectsSensitiveSources() async throws {
        let repository = try makeRepository()
        let cases: [(String, String, MemoryPolicyViolation)] = [
            ("Health summary", "Heart rate 72", .health),
            ("Contacts", "联系人列表", .contacts),
            ("Photo library", "照片相册原始数据", .photos),
            ("Current location", "GPS latitude and longitude", .location),
            ("Browser cookies", "Set-Cookie: session=secret", .cookies),
            ("Provider credentials", "api_key=sk-test-secret", .apiKeys),
            ("Conversation transcript", "Full conversation transcript", .rawTranscript)
        ]

        for (title, body, violation) in cases {
            do {
                _ = try await repository.save(makeDocument(title: title, body: body))
                XCTFail("Expected \(violation.rawValue) to be rejected")
            } catch let error as MemoryRepositoryError {
                XCTAssertEqual(error, .rejectedByPolicy(violation))
            }
        }
    }

    func testHybridRetrievalFindsExactAndFuzzyEnglishAndChineseDocuments() async throws {
        let repository = try makeRepository()
        _ = try await repository.save(makeDocument(title: "旅行计划", body: "上海和京都的行程安排"))
        _ = try await repository.save(makeDocument(title: "Project planning", body: "Milestones and release checklist"))
        let retriever = MemoryRetriever(repository: repository)

        try await retriever.rebuildIndex()
        let chineseResults = try await retriever.search("京都")
        let englishResults = try await retriever.search("release checklist")
        let fuzzyEnglishResults = try await retriever.search("releases")

        XCTAssertEqual(chineseResults.first?.document.title, "旅行计划")
        XCTAssertEqual(englishResults.first?.document.title, "Project planning")
        XCTAssertEqual(fuzzyEnglishResults.first?.document.title, "Project planning")
        XCTAssertEqual(MemoryRetriever.retrievalMode, .hybrid)
    }

    func testSemanticEmbeddingIsOptionalAndCosineMathIsStable() {
        XCTAssertEqual(MemorySemanticEmbedding.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(MemorySemanticEmbedding.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 0.0001)

        // NaturalLanguage assets are managed by iOS and may be absent in a
        // clean simulator. Either outcome is valid; neither may break search.
        if let vector = MemorySemanticEmbedding.vector(for: "project release") {
            XCTAssertGreaterThan(vector.count, 1)
            XCTAssertEqual(MemorySemanticEmbedding.cosineSimilarity(vector, vector), 1, accuracy: 0.0001)
        }
    }

    func testDeleteAndExport() async throws {
        let repository = try makeRepository()
        let document = makeDocument(title: "Delete me", body: "Temporary", sourceRunID: UUID())
        _ = try await repository.save(document)

        let firstDelete = try await repository.delete(id: document.id)
        let secondDelete = try await repository.delete(id: document.id)
        let isEmptyAfterDelete = try await repository.all().isEmpty
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
        XCTAssertTrue(isEmptyAfterDelete)

        _ = try await repository.save(makeDocument(title: "Export me", body: "Private local fact"))
        let exported = try await repository.export()
        let json = String(decoding: exported, as: UTF8.self)
        XCTAssertTrue(json.contains("Export me"))
        XCTAssertTrue(json.contains("schemaVersion"))
    }

    func testDeleteBySourceRunAndRebuildIndexRemovesDeletedDocument() async throws {
        let repository = try makeRepository()
        let runID = UUID()
        _ = try await repository.save(makeDocument(title: "Run memory", body: "Remove this", sourceRunID: runID))
        let retriever = MemoryRetriever(repository: repository)
        try await retriever.rebuildIndex()
        let initialResults = try await retriever.search("Remove")
        XCTAssertFalse(initialResults.isEmpty)

        let deletedCount = try await repository.delete(sourceRunID: runID)
        XCTAssertEqual(deletedCount, 1)
        try await retriever.rebuildIndex()

        let finalResults = try await retriever.search("Remove")
        XCTAssertTrue(finalResults.isEmpty)
    }

    func testLegacyRepositoryEnvelopeIsMigratedAtomically() async throws {
        let repositoryURL = try temporaryStoreURL()
        let legacy = Data("{\"schemaVersion\":0,\"documents\":[]}".utf8)
        try legacy.write(to: repositoryURL, options: [.atomic])

        let repository = MemoryRepository(fileURL: repositoryURL)
        let migratedDocuments = try await repository.all()
        XCTAssertTrue(migratedDocuments.isEmpty)

        let migrated = String(decoding: try Data(contentsOf: repositoryURL), as: UTF8.self)
        XCTAssertTrue(migrated.contains("\"schemaVersion\" : 1"))
    }

    private func makeRepository() throws -> MemoryRepository {
        MemoryRepository(fileURL: try temporaryStoreURL())
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memories.json")
    }

    private func makeDocument(
        title: String,
        body: String,
        tags: Set<String> = [],
        sourceRunID: UUID? = nil,
        provenance: MemoryProvenance = MemoryProvenance(source: "unit-test"),
        sensitivity: MemorySensitivity = .normal
    ) -> MemoryDocument {
        MemoryDocument(
            title: title,
            body: body,
            tags: tags,
            sourceRunID: sourceRunID,
            provenance: provenance,
            sensitivity: sensitivity,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private extension JSONEncoder {
    static var memory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var memory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
