import XCTest
@testable import Oases_Chat

/// Proves ordered reassembly after parallel tool fan-out on the real
/// AgentExecutor path (tool_batch_order diagnostic + AgentConcurrentToolOrdering).
final class ConcurrentToolOrderTests: XCTestCase {
    func testAgentConcurrentToolOrderingIsShippedContract() {
        let ordered = AgentConcurrentToolOrdering.resultsInOriginalOrder(
            [2: "C", 0: "A", 1: "B"],
            count: 3
        )
        XCTAssertEqual(ordered, ["A", "B", "C"])
    }

    func testExecutorEmitsOriginalToolUseOrderAfterParallelCompletion() async throws {
        let store = AgentRunStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-concurrent-\(UUID().uuidString)", isDirectory: true))
        let model = ScriptedModel(toolCalls: [
            ModelToolCall(id: "c1", name: "slow_tool", argumentsJSON: "{\"delay_ms\":50,\"tag\":\"A\"}"),
            ModelToolCall(id: "c2", name: "slow_tool", argumentsJSON: "{\"delay_ms\":5,\"tag\":\"B\"}"),
            ModelToolCall(id: "c3", name: "slow_tool", argumentsJSON: "{\"delay_ms\":15,\"tag\":\"C\"}"),
        ])
        let tools = OrderedSlowToolExecutor()
        let coordinator = AgentRunCoordinator(
            model: model,
            toolExecutor: tools,
            store: store,
            maxIterations: 2,
            completionContract: AgentCompletionContract(requiresArtifact: false)
        )

        let handle = try await coordinator.start(
            request: "run three parallel tools",
            context: AgentRunContext(
                model: "test",
                effort: nil,
                surface: .project,
                messages: [ChatAPIMessage(role: "user", content: .text("go"))],
                toolsJSON: nil,
                projectSessionID: "sess-order",
                projectID: nil
            )
        )

        var completionOrder: [String] = []
        var batchOrderLine: String?
        for await event in handle.events {
            if case .tool(let t) = event.payload, t.phase == .succeeded, let id = t.callID {
                completionOrder.append(id)
            }
            if case .diagnostic(let d) = event.payload, d.code == "tool_batch_order" {
                batchOrderLine = d.message
            }
        }

        XCTAssertEqual(Set(completionOrder), Set(["c1", "c2", "c3"]))
        XCTAssertGreaterThanOrEqual(tools.maxInFlight, 2, "expected parallel tool starts")
        // Production executor reassembly order (not wall-clock completion order).
        XCTAssertEqual(batchOrderLine, "tool_batch_order=c1,c2,c3", "got \(batchOrderLine ?? "nil") completion=\(completionOrder)")
        // Wall-clock: B (5ms) should finish before A (50ms).
        if let bIdx = completionOrder.firstIndex(of: "c2"),
           let aIdx = completionOrder.firstIndex(of: "c1") {
            XCTAssertLessThan(bIdx, aIdx)
        }
    }
}

private final class ScriptedModel: ModelStreaming, @unchecked Sendable {
    private let toolCalls: [ModelToolCall]
    private var turns = 0

    init(toolCalls: [ModelToolCall]) {
        self.toolCalls = toolCalls
    }

    func stream(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            defer { continuation.finish() }
            turns += 1
            if turns == 1 {
                for call in toolCalls {
                    continuation.yield(.toolCall(call))
                }
            } else {
                continuation.yield(.text("done"))
            }
            continuation.yield(.finished)
        }
    }
}

private final class OrderedSlowToolExecutor: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        lock.lock()
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()
        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        let args = (try? JSONSerialization.jsonObject(with: Data(request.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let delayMs = (args["delay_ms"] as? Int) ?? 10
        let tag = (args["tag"] as? String) ?? "?"
        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        return .success(request: request, output: "tag=\(tag)")
    }
}
