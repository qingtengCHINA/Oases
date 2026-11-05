import XCTest
@testable import Oases_Chat

final class AgentFinalizerTests: XCTestCase {
    func testArtifactRequiredCannotSucceedFromToolTextAlone() {
        let result = AgentFinalizer.finalize(
            contract: AgentCompletionContract(requiresArtifact: true, requiredArtifactKinds: [.pptx]),
            artifacts: [],
            completedSteps: ["web research", "tool completed"]
        )

        XCTAssertEqual(result.delivery.outcome, .partial)
        XCTAssertTrue(result.delivery.artifactIDs.isEmpty)
        XCTAssertFalse(result.delivery.remainingSteps.isEmpty)
    }

    func testValidArtifactProducesSucceededDelivery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oases-\(UUID().uuidString).pdf")
        let data = Data("%PDF-1.7\ncontent\n%%EOF".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runID = UUID()
        let record = try ArtifactStore().record(fileURL: url, runID: runID, expectedKind: .pdf)

        let result = AgentFinalizer.finalize(
            contract: AgentCompletionContract(requiresArtifact: true, requiredArtifactKinds: [.pdf], minimumCompletedSteps: 1),
            artifacts: [record],
            completedSteps: ["create pdf"]
        )

        XCTAssertEqual(result.delivery.outcome, .succeeded)
        XCTAssertEqual(result.delivery.artifactIDs, [record.id])
        XCTAssertEqual(result.validatedArtifacts, [record])
    }
}
