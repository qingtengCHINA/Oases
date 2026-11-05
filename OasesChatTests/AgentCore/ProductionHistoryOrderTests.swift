import XCTest
@testable import Oases_Chat

/// Criterion 3: model-facing history order after concurrent tools must match
/// original tool_use order on the real OgentProductionToolAdapter path.
final class ProductionHistoryOrderTests: XCTestCase {
    func testStagedResultsFlushInOriginalToolUseOrder() async throws {
        let session = OgentProductionAgentSession(
            context: AgentRunContext(
                model: "test",
                effort: nil,
                surface: .project,
                messages: [ChatAPIMessage(role: "user", content: .text("parallel"))],
                toolsJSON: nil,
                projectSessionID: "hist-order",
                projectID: nil
            )
        )

        // Simulate assistant emitting three tool_calls.
        await session.appendAssistant(
            text: "calling tools",
            calls: [
                WireToolCall(id: "c1", type: "function", function: .init(name: "slow", arguments: "{}")),
                WireToolCall(id: "c2", type: "function", function: .init(name: "slow", arguments: "{}")),
                WireToolCall(id: "c3", type: "function", function: .init(name: "slow", arguments: "{}")),
            ]
        )

        // Wall-clock completion: c2, then c3, then c1 (out of order).
        await session.stageToolResult(callID: "c2", output: "out-B")
        await session.stageToolResult(callID: "c3", output: "out-C")
        await session.stageToolResult(callID: "c1", output: "out-A")

        // Production flush after concurrent fan-out uses tool_use order.
        await session.flushToolResults(inOrder: ["c1", "c2", "c3"])

        let ids = await session.toolResultCallIDsInHistory()
        XCTAssertEqual(ids, ["c1", "c2", "c3"], "model history must not follow wall-clock completion")
        let toolBodies = await session.toolResultBodiesInHistory()
        XCTAssertEqual(toolBodies, ["out-A", "out-B", "out-C"])
    }

    func testProductionToolAdapterStagesThenFlushesInOrder() async throws {
        // Register deterministic tools for c1/c2/c3 delays via one tool name.
        let registry = ToolRegistry()
        let slow = DelayedTagTool()
        registry.register(slow)

        let session = OgentProductionAgentSession(
            context: AgentRunContext(
                model: "test",
                effort: nil,
                surface: .project,
                messages: [ChatAPIMessage(role: "user", content: .text("go"))],
                toolsJSON: nil,
                projectSessionID: "adapter-order",
                projectID: nil
            )
        )
        await session.appendAssistant(
            text: "",
            calls: [
                WireToolCall(id: "c1", type: "function", function: .init(name: "delayed_tag", arguments: "{\"delay_ms\":40,\"tag\":\"A\"}")),
                WireToolCall(id: "c2", type: "function", function: .init(name: "delayed_tag", arguments: "{\"delay_ms\":5,\"tag\":\"B\"}")),
                WireToolCall(id: "c3", type: "function", function: .init(name: "delayed_tag", arguments: "{\"delay_ms\":15,\"tag\":\"C\"}")),
            ]
        )

        let adapter = OgentProductionToolAdapter(
            registry: registry,
            session: session,
            artifactStore: ArtifactStore()
        )

        // Concurrent executes (completion order B, C, A).
        async let r1 = adapter.execute(ToolExecutionRequest(
            runID: UUID(), callID: "c1", name: "delayed_tag",
            argumentsJSON: "{\"delay_ms\":40,\"tag\":\"A\"}", attempt: 1
        ))
        async let r2 = adapter.execute(ToolExecutionRequest(
            runID: UUID(), callID: "c2", name: "delayed_tag",
            argumentsJSON: "{\"delay_ms\":5,\"tag\":\"B\"}", attempt: 1
        ))
        async let r3 = adapter.execute(ToolExecutionRequest(
            runID: UUID(), callID: "c3", name: "delayed_tag",
            argumentsJSON: "{\"delay_ms\":15,\"tag\":\"C\"}", attempt: 1
        ))
        _ = await (r1, r2, r3)

        // Before flush, history must not yet contain tool results.
        let before = await session.toolResultCallIDsInHistory()
        XCTAssertTrue(before.isEmpty, "results must be staged, not wall-clock appended")

        // Production AgentExecutor order after concurrent fan-out.
        await adapter.flushOrderedToolResults(callIDs: ["c1", "c2", "c3"])

        let after = await session.toolResultCallIDsInHistory()
        XCTAssertEqual(after, ["c1", "c2", "c3"])
        let bodies = await session.toolResultBodiesInHistory()
        XCTAssertEqual(bodies, ["tag=A", "tag=B", "tag=C"])
    }
}

private final class DelayedTagTool: AgentTool, @unchecked Sendable {
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "delayed_tag",
            summary: "test",
            displayName: "test",
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{}}",
            surfaces: [.project]
        )
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let delayMs = (args["delay_ms"] as? Int) ?? 10
        let tag = (args["tag"] as? String) ?? "?"
        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        return .textOnly("tag=\(tag)")
    }
}
