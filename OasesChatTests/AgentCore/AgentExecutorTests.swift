import XCTest
@testable import Oases_Chat

final class AgentExecutorTests: XCTestCase {
    func testTextOnlySuccessPersistsTerminalDelivery() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "用一句话回答")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .text("已完成"),
            .finished
        ]])
        let tools = ScriptedToolExecutor()
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 3
        )

        let events = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .succeeded)
        XCTAssertEqual(saved.delivery?.outcome, .succeeded)
        XCTAssertEqual(saved.delivery?.summary, "已完成")
        XCTAssertTrue(events.contains { $0.kind == .text })
        XCTAssertTrue(events.contains { isStatus($0, to: .succeeded) })
    }

    func testToolSuccessThenFinalResponseSucceeds() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "生成文件")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .toolCall(ModelToolCall(id: "call-1", name: "make_file", argumentsJSON: "{}")),
            .finished
        ], [
            .text("文件已生成"),
            .finished
        ]])
        let tools = ScriptedToolExecutor(records: [
            .success(name: "make_file", callID: "call-1", output: "artifact-ready")
        ])
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 3
        )

        _ = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .succeeded)
        XCTAssertEqual(saved.delivery?.summary, "文件已生成")
        let requestCount = await tools.requests.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(saved.events.filter { $0.kind == .tool }.count, 2)
    }

    func testToolSuccessWithoutFinalResponseGetsARecoveryTurn() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "生成文件")
        try await store.save(run)

        let model = ScriptedModel(responses: [
            [
                .text("我先执行工具"),
                .toolCall(ModelToolCall(id: "call-1", name: "make_file", argumentsJSON: "{}")),
                .finished
            ],
            [.finished],
            [.text("已生成并完成交付说明"), .finished]
        ])
        let tools = ScriptedToolExecutor(records: [
            .success(name: "make_file", callID: "call-1", output: "artifact-ready")
        ])
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 3
        )

        _ = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .succeeded)
        XCTAssertEqual(saved.delivery?.outcome, .succeeded)
        XCTAssertEqual(saved.delivery?.summary, "我先执行工具已生成并完成交付说明")
        XCTAssertTrue(saved.events.contains {
            guard case .diagnostic(let diagnostic) = $0.payload else { return false }
            return diagnostic.code == "delivery_recovery"
        })
    }

    func testToolApprovalBoundaryPersistsAwaitingStateAndReturnsToRunningTool() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "需要浏览器确认")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .toolCall(ModelToolCall(id: "call-approval", name: "web_browse", argumentsJSON: "{}")),
            .finished
        ], [
            .text("已完成浏览器确认"),
            .finished
        ]])
        let tools = ApprovalAwareToolExecutor()
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 3
        )

        let events = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .succeeded)
        XCTAssertTrue(events.contains { isStatus($0, to: .awaitingApproval) })
        XCTAssertTrue(events.contains { isStatus($0, to: .runningTool) })
    }

    func testRepeatedToolFailureStopsAccordingToRetryPolicy() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "执行不稳定工具")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .toolCall(ModelToolCall(id: "call-1", name: "flaky", argumentsJSON: "{\"x\":1}")),
            .finished
        ]])
        let tools = ScriptedToolExecutor(records: [
            .failure(name: "flaky", callID: "call-1", message: "temporary"),
            .failure(name: "flaky", callID: "call-1", message: "temporary")
        ])
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: AgentRetryPolicy(
                maxAttempts: 2,
                initialDelayNanoseconds: 0,
                maxConsecutiveIdenticalFailures: 1
            ),
            maxIterations: 3
        )

        _ = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(saved.delivery?.outcome, .failed)
        let requestCount = await tools.requests.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(saved.delivery?.warnings.contains("temporary") ?? false)
    }

    func testIterationLimitProducesPartialDeliveryInsteadOfSuccess() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "持续调用工具")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .toolCall(ModelToolCall(id: "call-1", name: "step", argumentsJSON: "{}")),
            .finished
        ]])
        let tools = ScriptedToolExecutor(records: [
            .success(name: "step", callID: "call-1", output: "step done")
        ])
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 1
        )

        _ = await collect(await executor.execute(runID: run.id))
        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)

        XCTAssertEqual(saved.state, .partiallySucceeded)
        XCTAssertEqual(saved.delivery?.outcome, .partial)
        XCTAssertTrue(saved.delivery?.remainingSteps.contains("model final response") ?? false)
    }

    func testCancellationPersistsCancelledDelivery() async throws {
        let store = TestRunStore()
        let run = AgentRun(request: "执行一个长任务")
        try await store.save(run)

        let model = ScriptedModel(responses: [[
            .toolCall(ModelToolCall(id: "call-1", name: "long_task", argumentsJSON: "{}")),
            .finished
        ]])
        let tools = BlockingToolExecutor()
        let executor = AgentExecutor(
            model: model,
            toolExecutor: tools,
            store: store,
            retryPolicy: .noRetries,
            maxIterations: 3
        )

        let stream = await executor.execute(runID: run.id)
        for _ in 0..<100 where !(await tools.started) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await executor.cancel(runID: run.id)
        _ = await collect(stream)

        let loaded = try await store.load(id: run.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.state, .cancelled)
        XCTAssertEqual(saved.delivery?.outcome, .cancelled)
        XCTAssertTrue(saved.events.contains { isStatus($0, to: .cancelled) })
    }

    private func isStatus(_ event: AgentEvent, to state: AgentRunState) -> Bool {
        guard case .status(let status) = event.payload else { return false }
        return status.to == state
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}

private actor TestRunStore: AgentRunPersisting {
    private var runs: [UUID: AgentRun] = [:]

    func save(_ run: AgentRun) async throws {
        runs[run.id] = run
    }

    func load(id: UUID) async throws -> AgentRun? {
        runs[id]
    }
}

private final class ScriptedModel: @unchecked Sendable, ModelStreaming {
    private var responses: [[ModelEvent]]
    private let lock = NSLock()

    init(responses: [[ModelEvent]]) {
        self.responses = responses
    }

    func stream(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.lock()
        let response = responses.isEmpty ? [.finished] : responses.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in response {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private actor ScriptedToolExecutor: ToolExecuting {
    private var records: [ToolExecutionRecord]
    private(set) var requests: [ToolExecutionRequest] = []

    init(records: [ToolExecutionRecord] = []) {
        self.records = records
    }

    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        requests.append(request)
        if records.isEmpty {
            return .success(request: request, output: "ok")
        }
        let record = records.removeFirst()
        return record.with(request: request)
    }
}

private actor BlockingToolExecutor: ToolExecuting {
    private(set) var started = false

    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        started = true
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return .cancelled(request: request, message: "cancelled by test")
    }
}

private actor ApprovalAwareToolExecutor: ToolExecuting {
    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        if let callback = AgentToolInvocationContext.current?.onApprovalStateChanged {
            await callback(true)
            await callback(false)
        }
        return .success(request: request, output: "approved")
    }
}

private extension ToolExecutionRecord {
    static func success(name: String, callID: String, output: String?) -> ToolExecutionRecord {
        .success(
            request: ToolExecutionRequest(
                runID: UUID(),
                callID: callID,
                name: name,
                argumentsJSON: "{}",
                attempt: 1
            ),
            output: output
        )
    }

    static func failure(name: String, callID: String, message: String) -> ToolExecutionRecord {
        .failure(
            request: ToolExecutionRequest(
                runID: UUID(),
                callID: callID,
                name: name,
                argumentsJSON: "{\"x\":1}",
                attempt: 1
            ),
            message: message
        )
    }

    func with(request: ToolExecutionRequest) -> ToolExecutionRecord {
        ToolExecutionRecord(
            request: request,
            outcome: outcome,
            output: output,
            errorMessage: errorMessage,
            location: location
        )
    }
}
