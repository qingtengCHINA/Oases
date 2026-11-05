import XCTest
@testable import Oases_Chat

final class AgentRunTests: XCTestCase {
    func testRunCannotCompleteWithoutDelivery() throws {
        var run = AgentRun.fixture(state: .finalizing)

        XCTAssertThrowsError(try run.transition(to: .succeeded)) { error in
            XCTAssertEqual(error as? AgentRunError, .missingDelivery(for: .succeeded))
        }
        XCTAssertEqual(run.state, .finalizing)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testPartialDeliveryIsTerminalAndResumable() throws {
        var run = AgentRun.fixture(state: .finalizing)
        run.delivery = AgentDelivery(
            outcome: .partial,
            summary: "已下载源数据，DOCX 未生成",
            artifactIDs: [],
            sourceLinks: [],
            completedSteps: ["下载源数据"],
            remainingSteps: ["生成 DOCX"],
            warnings: ["provider quota exceeded"]
        )

        try run.transition(to: .partiallySucceeded)

        XCTAssertTrue(run.state.isTerminal)
        XCTAssertEqual(run.events.count, 1)
        XCTAssertFalse(run.delivery?.remainingSteps.isEmpty ?? true)
        XCTAssertEqual(run.events[0].kind, .status)
    }

    func testInvalidTransitionIsRejected() throws {
        var run = AgentRun.fixture(state: .queued)

        XCTAssertThrowsError(try run.transition(to: .runningTool)) { error in
            XCTAssertEqual(error as? AgentRunError, .invalidTransition(from: .queued, to: .runningTool))
        }
        XCTAssertEqual(run.state, .queued)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testFailureTransitionCreatesTypedFailureDelivery() throws {
        var run = AgentRun.fixture(state: .planning)

        try run.transition(to: .failed)

        XCTAssertTrue(run.state.isTerminal)
        XCTAssertEqual(run.delivery?.outcome, .failed)
        XCTAssertEqual(run.events.count, 1)
    }

    func testStoreRoundTripsEnvelopeAndListsRuns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunTests-\(UUID().uuidString)", isDirectory: true)
        let store = AgentRunStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var run = AgentRun.fixture(state: .finalizing)
        run.delivery = AgentDelivery(outcome: .succeeded, summary: "已完成")
        try run.transition(to: .succeeded)
        try await store.save(run)

        let loaded = try await store.load(id: run.id)
        XCTAssertEqual(loaded?.id, run.id)
        XCTAssertEqual(loaded?.state, run.state)
        XCTAssertEqual(loaded?.delivery, run.delivery)
        XCTAssertEqual(loaded?.events.count, run.events.count)
        XCTAssertEqual(loaded?.updatedAt.timeIntervalSince1970 ?? 0, run.updatedAt.timeIntervalSince1970, accuracy: 1)
        let listedIDs = try await store.list().map(\.id)
        XCTAssertEqual(listedIDs, [run.id])

        let savedData = try Data(contentsOf: directory.appendingPathComponent("\(run.id.uuidString).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, AgentRunEnvelope.currentSchemaVersion)
    }
}

private extension AgentRun {
    static func fixture(state: AgentRunState) -> AgentRun {
        AgentRun(state: state)
    }
}
