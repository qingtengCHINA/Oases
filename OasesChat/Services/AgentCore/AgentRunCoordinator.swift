import Foundation

extension AgentRunStore: AgentRunPersisting {}

struct AgentRunHandle: Sendable {
    let runID: UUID
    let events: AsyncStream<AgentEvent>
}

/// The single entry point intended for feature adapters. It creates the
/// persisted queued run before asking the executor to start, so a crash before
/// the first model event is still resumable.
actor AgentRunCoordinator {
    private let store: any AgentRunPersisting
    private let executor: AgentExecutor

    init(
        model: any ModelStreaming,
        toolExecutor: any ToolExecuting,
        store: any AgentRunPersisting,
        retryPolicy: AgentRetryPolicy = AgentRetryPolicy(),
        maxIterations: Int = 8,
        completionContract: AgentCompletionContract? = nil,
        memoryService: AgentRunMemoryService? = nil
    ) {
        self.store = store
        self.executor = AgentExecutor(
            model: model,
            toolExecutor: toolExecutor,
            store: store,
            retryPolicy: retryPolicy,
            maxIterations: maxIterations,
            completionContract: completionContract,
            memoryService: memoryService
        )
    }

    init(
        model: any ModelStreaming,
        toolExecutor: any ToolExecuting,
        store: AgentRunStore,
        retryPolicy: AgentRetryPolicy = AgentRetryPolicy(),
        maxIterations: Int = 8,
        completionContract: AgentCompletionContract? = nil,
        memoryService: AgentRunMemoryService? = nil
    ) {
        self.init(
            model: model,
            toolExecutor: toolExecutor,
            store: store as any AgentRunPersisting,
            retryPolicy: retryPolicy,
            maxIterations: maxIterations,
            completionContract: completionContract,
            memoryService: memoryService
        )
    }

    func start(request: String) async throws -> AgentRunHandle {
        try await start(request: request, context: nil)
    }

    func start(request: String, context: AgentRunContext?) async throws -> AgentRunHandle {
        let run = AgentRun(request: request, context: context)
        try await store.save(run)
        return AgentRunHandle(runID: run.id, events: await executor.execute(runID: run.id))
    }

    func resume(runID: UUID) async -> AsyncStream<AgentEvent> {
        await executor.resume(runID: runID)
    }

    func cancel(runID: UUID) async {
        await executor.cancel(runID: runID)
    }
}
