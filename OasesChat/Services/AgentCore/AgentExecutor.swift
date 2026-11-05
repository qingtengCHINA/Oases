import Foundation

/// Task-local context carried from the persisted executor into a concrete
/// tool. Browser challenges use it to report approval boundaries without
/// coupling WebKit or SwiftUI to the run-state actor.
enum AgentToolInvocationContext {
    struct Value: Sendable {
        let runID: UUID
        let callID: String
        let onApprovalStateChanged: (@Sendable (Bool) async -> Void)?
    }

    @TaskLocal static var current: Value?
}

enum ModelEvent: Sendable, Equatable {
    case text(String)
    case toolCall(ModelToolCall)
    case finished
}

struct ModelToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let argumentsJSON: String

    init(id: String = UUID().uuidString, name: String, argumentsJSON: String = "{}") {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

struct ModelTurnRequest: Sendable, Equatable {
    enum Purpose: String, Sendable, Equatable {
        case plan
        case continueDelivery
        case finalResponse
    }

    let runID: UUID
    let userRequest: String
    let iteration: Int
    let transcript: [AgentEvent]
    let purpose: Purpose

    init(
        runID: UUID,
        userRequest: String,
        iteration: Int,
        transcript: [AgentEvent],
        purpose: Purpose = .plan
    ) {
        self.runID = runID
        self.userRequest = userRequest
        self.iteration = iteration
        self.transcript = transcript
        self.purpose = purpose
    }
}

protocol ModelStreaming: Sendable {
    func stream(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelEvent, Error>
}

struct ToolExecutionRequest: Sendable, Equatable {
    let runID: UUID
    let callID: String
    let name: String
    let argumentsJSON: String
    let attempt: Int

    init(runID: UUID, callID: String, name: String, argumentsJSON: String, attempt: Int) {
        self.runID = runID
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.attempt = attempt
    }
}

struct ToolExecutionRecord: Sendable, Equatable {
    enum Outcome: String, Sendable, Equatable {
        case succeeded
        case failed
        case cancelled
    }

    let request: ToolExecutionRequest
    let outcome: Outcome
    let output: String?
    let errorMessage: String?
    let location: ExecutionLocation
    let artifactIDs: [UUID]
    let artifacts: [ArtifactRecord]

    init(
        request: ToolExecutionRequest,
        outcome: Outcome,
        output: String? = nil,
        errorMessage: String? = nil,
        location: ExecutionLocation = .iosHost,
        artifactIDs: [UUID] = [],
        artifacts: [ArtifactRecord] = []
    ) {
        self.request = request
        self.outcome = outcome
        self.output = output
        self.errorMessage = errorMessage
        self.location = location
        self.artifactIDs = artifactIDs
        self.artifacts = artifacts
    }

    static func success(
        request: ToolExecutionRequest,
        output: String? = nil,
        location: ExecutionLocation = .iosHost,
        artifactIDs: [UUID] = [],
        artifacts: [ArtifactRecord] = []
    ) -> ToolExecutionRecord {
        ToolExecutionRecord(
            request: request,
            outcome: .succeeded,
            output: output,
            location: location,
            artifactIDs: artifactIDs,
            artifacts: artifacts
        )
    }

    static func failure(
        request: ToolExecutionRequest,
        message: String,
        location: ExecutionLocation = .iosHost,
        artifactIDs: [UUID] = [],
        artifacts: [ArtifactRecord] = []
    ) -> ToolExecutionRecord {
        ToolExecutionRecord(
            request: request,
            outcome: .failed,
            errorMessage: message,
            location: location,
            artifactIDs: artifactIDs,
            artifacts: artifacts
        )
    }

    static func cancelled(
        request: ToolExecutionRequest,
        message: String? = nil,
        location: ExecutionLocation = .iosHost,
        artifactIDs: [UUID] = [],
        artifacts: [ArtifactRecord] = []
    ) -> ToolExecutionRecord {
        ToolExecutionRecord(
            request: request,
            outcome: .cancelled,
            errorMessage: message,
            location: location,
            artifactIDs: artifactIDs,
            artifacts: artifacts
        )
    }

    func replacing(request: ToolExecutionRequest) -> ToolExecutionRecord {
        ToolExecutionRecord(
            request: request,
            outcome: outcome,
            output: output,
            errorMessage: errorMessage,
            location: location,
            artifactIDs: artifactIDs,
            artifacts: artifacts
        )
    }
}

protocol ToolExecuting: Sendable {
    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord
    /// After concurrent fan-out, flush buffered model-facing tool results
    /// in the original tool_use order. Default is a no-op for adapters that
    /// write history inline.
    func flushOrderedToolResults(callIDs: [String]) async
}

extension ToolExecuting {
    func flushOrderedToolResults(callIDs: [String]) async {}
}

protocol AgentRunPersisting: Sendable {
    func save(_ run: AgentRun) async throws
    func load(id: UUID) async throws -> AgentRun?
}

private struct ToolExecutionSummary: Sendable {
    let run: AgentRun
    let record: ToolExecutionRecord
    let signature: String
}

/// Owns the persisted agent lifecycle. The actor never touches SwiftUI state;
/// presentation layers consume the typed event stream and reload the run when
/// they need the current delivery.
actor AgentExecutor {
    private let model: any ModelStreaming
    private let toolExecutor: any ToolExecuting
    private let store: any AgentRunPersisting
    private let retryPolicy: AgentRetryPolicy
    private let maxIterations: Int
    private let maxDeliveryRecoveryAttempts: Int
    private let completionContract: AgentCompletionContract?
    private let memoryService: AgentRunMemoryService?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var cancelledRunIDs: Set<UUID> = []

    init(
        model: any ModelStreaming,
        toolExecutor: any ToolExecuting,
        store: any AgentRunPersisting,
        retryPolicy: AgentRetryPolicy = AgentRetryPolicy(),
        maxIterations: Int = 8,
        maxDeliveryRecoveryAttempts: Int = 2,
        completionContract: AgentCompletionContract? = nil,
        memoryService: AgentRunMemoryService? = nil
    ) {
        self.model = model
        self.toolExecutor = toolExecutor
        self.store = store
        self.retryPolicy = retryPolicy
        self.maxIterations = max(1, maxIterations)
        self.maxDeliveryRecoveryAttempts = max(1, maxDeliveryRecoveryAttempts)
        self.completionContract = completionContract
        self.memoryService = memoryService
    }

    func execute(runID: UUID) -> AsyncStream<AgentEvent> {
        var continuation: AsyncStream<AgentEvent>.Continuation?
        let stream = AsyncStream<AgentEvent> { continuation = $0 }
        guard let continuation else { return stream }

        continuations[runID] = continuation
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.run(runID: runID)
        }
        tasks[runID] = task
        return stream
    }

    func resume(runID: UUID) -> AsyncStream<AgentEvent> {
        execute(runID: runID)
    }

    func cancel(runID: UUID) async {
        cancelledRunIDs.insert(runID)
        tasks[runID]?.cancel()
        // Kill this run's guest shells only. Cancelling the task above already
        // stops its in-flight tool calls; this sweeps shells scoped to the
        // run's session (or, for a run without one, unscoped shells). A
        // global cancel would kill other sessions' commands too.
        if let run = try? await store.load(id: runID),
           let sid = run.context?.projectSessionID {
            _ = await ISHRuntimeService.shared.cancelAll(sessionId: sid)
        } else {
            _ = await ISHRuntimeService.shared.cancelUnscoped()
        }
        await persistCancellation(runID: runID)
    }

    private func run(runID: UUID) async {
        do {
            guard var run = try await store.load(id: runID) else {
                finishStream(runID: runID)
                return
            }

            if run.state.isTerminal || cancelledRunIDs.contains(runID) {
                if cancelledRunIDs.contains(runID), !run.state.isTerminal {
                    await persistCancellation(runID: runID)
                }
                finishStream(runID: runID)
                return
            }

            run = try await normalizeForExecution(run, runID: runID)
            var iteration = 0
            var accumulatedText = ""
            var completedSteps: [String] = []
            var warnings: [String] = []
            var successfulToolCount = 0
            var failureCounts: [String: Int] = [:]
            var artifactIDs = Set<UUID>()
            var artifacts: [UUID: ArtifactRecord] = [:]
            var deliveryRecoveryAttempts = 0

            while iteration < maxIterations {
                try checkCancellation(runID: runID)
                let purpose: ModelTurnRequest.Purpose = deliveryRecoveryAttempts == 0
                    ? .plan
                    : (completionContract?.requiresArtifact == true && artifactIDs.isEmpty
                        ? .continueDelivery
                        : .finalResponse)
                let request = ModelTurnRequest(
                    runID: runID,
                    userRequest: run.request ?? "",
                    iteration: iteration,
                    transcript: run.events,
                    purpose: purpose
                )

                var toolCalls: [ModelToolCall] = []
                var turnText = ""
                do {
                    for try await event in model.stream(request) {
                        try checkCancellation(runID: runID)
                        switch event {
                        case .text(let text):
                            turnText += text
                            accumulatedText += text
                            run = try await append(
                                .text(text, role: "assistant", location: .remoteOases),
                                to: run,
                                runID: runID
                            )
                        case .toolCall(let call):
                            toolCalls.append(call)
                        case .finished:
                            break
                        }
                    }
                } catch {
                    try checkCancellation(runID: runID)
                    let outcome: AgentDelivery.Outcome = successfulToolCount > 0 ? .partial : .failed
                    // i18n-ignore: delivery.remainingSteps is run-record / model-memory data, not rendered in UI
                    let remaining = outcome == .partial ? ["模型最终响应"] : ["重新请求模型"]
                    _ = try await finish(
                        run: run,
                        outcome: outcome,
                        summary: accumulatedText.isEmpty
                            ? String(localized: "模型连接中断，任务未完整交付。", comment: "Engineering agent run summary shown in chat when the model connection dropped mid-run")
                            : accumulatedText,
                        completedSteps: completedSteps,
                        remainingSteps: remaining,
                        warnings: warnings + [error.localizedDescription],
                        artifactIDs: Array(artifactIDs),
                        artifacts: Array(artifacts.values),
                        runID: runID
                    )
                    finishStream(runID: runID)
                    return
                }

                guard !toolCalls.isEmpty else {
                    let hasFinalText = !turnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let missingFinalResponse = !hasFinalText
                    let validatedArtifacts = AgentFinalizer.validatedArtifacts(Array(artifacts.values))
                    let artifactRequirementMissing = completionContract?.requiresArtifact == true && validatedArtifacts.isEmpty

                    // A model can finish a tool turn without producing either
                    // the next tool call or a final answer. Give it an
                    // explicit recovery turn before exposing a partial result
                    // to the user. The model adapter changes the prompt and
                    // tool budget based on `purpose`; this keeps the recovery
                    // visible in the persisted event stream and prevents the
                    // old "tools ran, then the chat ended" failure mode.
                    if (missingFinalResponse || artifactRequirementMissing),
                       deliveryRecoveryAttempts < maxDeliveryRecoveryAttempts,
                       iteration + 1 < maxIterations {
                        deliveryRecoveryAttempts += 1
                        run = try await append(
                            .diagnostic(
                                deliveryRecoveryMessage(
                                    missingFinalResponse: missingFinalResponse,
                                    artifactRequirementMissing: artifactRequirementMissing,
                                    attempt: deliveryRecoveryAttempts
                                ),
                                level: .warning,
                                code: "delivery_recovery",
                                location: .iosHost
                            ),
                            to: run,
                            runID: runID
                        )
                        iteration += 1
                        if run.state != .planning {
                            run = try await transition(.planning, from: run, runID: runID)
                        }
                        continue
                    }

                    let outcome: AgentDelivery.Outcome
                    if artifactRequirementMissing || missingFinalResponse {
                        outcome = successfulToolCount > 0 ? .partial : .failed
                    } else {
                        outcome = failureCounts.isEmpty ? .succeeded : .partial
                    }
                    var remainingSteps: [String] = []
                    if artifactRequirementMissing {
                        remainingSteps.append("required artifact")
                        warnings.append(String(localized: "工具结果未产生经过校验的本机产物。", comment: "Engineering agent run warning (shown as the run error message): tools produced no verified local artifact"))
                    }
                    if missingFinalResponse {
                        remainingSteps.append("model final response")
                        warnings.append(String(localized: "模型工具步骤结束后没有返回最终交付说明。", comment: "Engineering agent run warning (shown as the run error message): model returned no final delivery note after tool steps"))
                    }
                    run = try await finish(
                        run: run,
                        outcome: outcome,
                        summary: missingFinalResponse
                            ? (successfulToolCount > 0
                                ? String(localized: "工具步骤已完成，但模型未返回最终交付说明。", comment: "Engineering agent run summary shown in chat: tools finished but the model gave no final delivery note")
                                : String(localized: "模型未返回最终交付说明。", comment: "Engineering agent run summary shown in chat: the model gave no final delivery note"))
                            : (accumulatedText.isEmpty
                                ? String(localized: "任务已完成。", comment: "Engineering agent run summary shown in chat when the task finished without model text")
                                : accumulatedText),
                        completedSteps: completedSteps,
                        remainingSteps: remainingSteps,
                        warnings: warnings,
                        artifactIDs: Array(artifactIDs),
                        artifacts: Array(artifacts.values),
                        runID: runID
                    )
                    _ = run
                    finishStream(runID: runID)
                    return
                }

                run = try await transition(.runningTool, from: run, runID: runID)
                var repeatedFailure = false

                // Concurrent tool fan-out (OpenMinis-aligned). Results are
                // merged back in original tool_use order so the model history
                // stays consistent. Browser approval still serializes inside
                // the individual tool via AgentToolInvocationContext.
                let orderedSummaries = try await executeToolsConcurrently(
                    toolCalls,
                    run: run,
                    runID: runID
                )
                // Model-facing history must match tool_use order (not wall-clock).
                let orderedCallIDs = orderedSummaries.map(\.record.request.callID)
                await toolExecutor.flushOrderedToolResults(callIDs: orderedCallIDs)
                let orderedIDs = orderedCallIDs.joined(separator: ",")
                // Reload the authoritative run BEFORE appending. Each concurrent
                // tool persisted its own started/finished events through the
                // store, but `run` here is still the snapshot taken before the
                // fan-out. Appending to that stale copy and saving it would
                // write back a run whose `events` array never contained the
                // tool events — silently dropping every `.tool` event from the
                // persisted history while the in-memory stream still showed
                // them. (Reloading after the append doesn't help: the clobbering
                // save has already happened.)
                if let refreshed = try? await store.load(id: runID) {
                    run = refreshed
                }
                run = try await append(
                    .diagnostic(
                        "tool_batch_order=\(orderedIDs)",
                        level: .info,
                        code: "tool_batch_order",
                        location: .iosHost
                    ),
                    to: run,
                    runID: runID
                )
                for result in orderedSummaries {
                    artifactIDs.formUnion(result.record.artifactIDs)
                    for artifact in result.record.artifacts {
                        artifacts[artifact.id] = artifact
                    }
                    if result.record.outcome == .succeeded {
                        successfulToolCount += 1
                        completedSteps.append(result.record.request.name)
                    } else if result.record.outcome == .failed {
                        warnings.append(result.record.errorMessage ?? String(localized: "工具执行失败", comment: "Engineering agent run warning (shown as the run error message) when a tool failed without an error message"))
                        let count = (failureCounts[result.signature] ?? 0) + 1
                        failureCounts[result.signature] = count
                        if count >= retryPolicy.maxConsecutiveIdenticalFailures {
                            repeatedFailure = true
                        }
                    } else {
                        throw CancellationError()
                    }
                }

                if repeatedFailure {
                    let outcome: AgentDelivery.Outcome = successfulToolCount > 0 ? .partial : .failed
                    run = try await finish(
                        run: run,
                        outcome: outcome,
                        summary: outcome == .partial
                            ? String(localized: "部分工具已完成，但同一工具连续失败。", comment: "Engineering agent run summary shown in chat: some tools finished but one tool kept failing")
                            : String(localized: "同一工具连续失败，任务已停止。", comment: "Engineering agent run summary shown in chat: the same tool failed repeatedly and the run stopped"),
                        completedSteps: completedSteps,
                        remainingSteps: ["修复工具错误后重试"], // i18n-ignore: delivery.remainingSteps is run-record / model-memory data, not rendered in UI
                        warnings: warnings,
                        artifactIDs: Array(artifactIDs),
                        artifacts: Array(artifacts.values),
                        runID: runID
                    )
                    _ = run
                    finishStream(runID: runID)
                    return
                }

                iteration += 1
                if iteration >= maxIterations {
                    let outcome: AgentDelivery.Outcome = successfulToolCount > 0 ? .partial : .failed
                    run = try await finish(
                        run: run,
                        outcome: outcome,
                        summary: outcome == .partial
                            ? String(localized: "已完成部分工具步骤，但达到迭代上限。", comment: "Engineering agent run summary shown in chat: some tool steps finished before the iteration limit")
                            : String(localized: "工具步骤未完成，达到迭代上限。", comment: "Engineering agent run summary shown in chat: tool steps unfinished, iteration limit reached"),
                        completedSteps: completedSteps,
                        remainingSteps: ["model final response"],
                        warnings: warnings,
                        artifactIDs: Array(artifactIDs),
                        artifacts: Array(artifacts.values),
                        runID: runID
                    )
                    _ = run
                    finishStream(runID: runID)
                    return
                }

                run = try await transition(.planning, from: run, runID: runID)
            }
        } catch is CancellationError {
            await persistCancellation(runID: runID)
            finishStream(runID: runID)
        } catch {
            do {
                if let run = try await store.load(id: runID), !run.state.isTerminal {
                    _ = try await finish(
                        run: run,
                        outcome: .failed,
                        summary: String(localized: "Agent 执行失败。", comment: "Engineering agent run summary shown in chat when the run failed with an unexpected error"),
                        completedSteps: [],
                        remainingSteps: ["重新运行任务"], // i18n-ignore: delivery.remainingSteps is run-record / model-memory data, not rendered in UI
                        warnings: [error.localizedDescription],
                        runID: runID
                    )
                }
            } catch {
                // The original persistence error is the most useful terminal
                // signal available; the stream still must not remain open.
            }
            finishStream(runID: runID)
        }
    }

    private func deliveryRecoveryMessage(
        missingFinalResponse: Bool,
        artifactRequirementMissing: Bool,
        attempt: Int
    ) -> String {
        // Persisted `.diagnostic` event text only; the chat UI ignores diagnostics.
        let reason: String
        if artifactRequirementMissing && missingFinalResponse {
            reason = "缺少经过校验的本机产物和最终交付说明" // i18n-ignore: run diagnostic event, not rendered in UI
        } else if artifactRequirementMissing {
            reason = "缺少经过校验的本机产物" // i18n-ignore: run diagnostic event, not rendered in UI
        } else {
            reason = "缺少最终交付说明" // i18n-ignore: run diagnostic event, not rendered in UI
        }
        return "触发交付恢复第 \(attempt) 次：\(reason)。" // i18n-ignore: run diagnostic event, not rendered in UI
    }

    private func normalizeForExecution(_ input: AgentRun, runID: UUID) async throws -> AgentRun {
        var run = input
        switch run.state {
        case .queued:
            run = try await transition(.planning, from: run, runID: runID)
        case .runningTool, .waitingExternal:
            run = try await transition(.planning, from: run, runID: runID)
        case .finalizing:
            run = try await finish(
                run: run,
                outcome: .failed,
                summary: String(localized: "运行在最终交付前中断。", comment: "Engineering agent run summary shown in chat: the run was interrupted before final delivery"),
                completedSteps: [],
                remainingSteps: ["恢复任务"], // i18n-ignore: delivery.remainingSteps is run-record / model-memory data, not rendered in UI
                warnings: [String(localized: "恢复时发现未完成的 finalizing 状态", comment: "Engineering agent run warning (shown as the run error message): on resume the run was found stuck in its finalizing state")],
                runID: runID
            )
        case .planning:
            break
        case .awaitingApproval:
            run = try await transition(.planning, from: run, runID: runID)
        case .succeeded, .partiallySucceeded, .failed, .cancelled:
            break
        }
        return run
    }

    /// Fan out tool calls with a hard cap, then return summaries in the
    /// original tool_use order (Anthropic/OpenAI require matching order).
    private func executeToolsConcurrently(
        _ toolCalls: [ModelToolCall],
        run: AgentRun,
        runID: UUID
    ) async throws -> [ToolExecutionSummary] {
        let maxConcurrent = 8
        var results: [Int: ToolExecutionSummary] = [:]
        results.reserveCapacity(toolCalls.count)

        try await withThrowingTaskGroup(of: (Int, ToolExecutionSummary).self) { group in
            var nextIndex = 0
            var inFlight = 0

            func enqueueMore() {
                while inFlight < maxConcurrent, nextIndex < toolCalls.count {
                    let index = nextIndex
                    let call = toolCalls[index]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        // Each child works from the run snapshot at enqueue;
                        // executeTool reloads from the store before appending.
                        let summary = try await self.executeTool(call, run: run, runID: runID)
                        return (index, summary)
                    }
                }
            }

            enqueueMore()
            while let (index, summary) = try await group.next() {
                results[index] = summary
                inFlight -= 1
                enqueueMore()
            }
        }

        return AgentConcurrentToolOrdering.resultsInOriginalOrder(results, count: toolCalls.count)
    }

    private func executeTool(
        _ call: ModelToolCall,
        run: AgentRun,
        runID: UUID
    ) async throws -> ToolExecutionSummary {
        var currentRun = run
        var attempt = 1
        while true {
            try checkCancellation(runID: runID)
            let request = ToolExecutionRequest(
                runID: runID,
                callID: call.id,
                name: call.name,
                argumentsJSON: call.argumentsJSON,
                attempt: attempt
            )
            currentRun = try await append(
                .tool(
                    name: call.name,
                    phase: .started,
                    callID: call.id,
                    summary: "attempt \(attempt)",
                    location: .iosHost,
                    metadata: ["arguments": call.argumentsJSON]
                ),
                to: currentRun,
                runID: runID
            )

            let invocationContext = AgentToolInvocationContext.Value(
                runID: runID,
                callID: call.id,
                onApprovalStateChanged: { [weak self] awaiting in
                    guard let self else { return }
                    await self.setApprovalState(runID: runID, awaiting: awaiting)
                }
            )
            let toolExecutor = self.toolExecutor
            let record = await AgentToolInvocationContext.$current.withValue(invocationContext) {
                await toolExecutor.execute(request)
            }
            try checkCancellation(runID: runID)

            // The browser approval callback can update the persisted run while
            // the concrete tool is suspended. Reload before appending the
            // result so the approval status event is never overwritten by a
            // stale local copy of the run.
            if let refreshedRun = try? await store.load(id: runID) {
                currentRun = refreshedRun
            }
            if currentRun.state == .awaitingApproval {
                currentRun = try await transition(.runningTool, from: currentRun, runID: runID)
            }

            let phase: AgentEvent.ToolPhase
            switch record.outcome {
            case .succeeded: phase = .succeeded
            case .failed: phase = .failed
            case .cancelled: phase = .cancelled
            }
            currentRun = try await append(
                .tool(
                    name: call.name,
                    phase: phase,
                    callID: call.id,
                    summary: record.output ?? record.errorMessage,
                    location: record.location
                ),
                to: currentRun,
                runID: runID
            )

            if record.outcome != .failed {
                return ToolExecutionSummary(run: currentRun, record: record, signature: failureSignature(record))
            }

            guard retryPolicy.shouldRetry(record: record, attempt: attempt, identicalFailureCount: 1) else {
                return ToolExecutionSummary(run: currentRun, record: record, signature: failureSignature(record))
            }
            let delay = retryPolicy.delayNanoseconds(forRetryNumber: attempt)
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            attempt += 1
        }
    }

    private func finish(
        run: AgentRun,
        outcome: AgentDelivery.Outcome,
        summary: String,
        completedSteps: [String],
        remainingSteps: [String],
        warnings: [String],
        artifactIDs: [UUID] = [],
        artifacts: [ArtifactRecord] = [],
        runID: UUID
    ) async throws -> AgentRun {
        var currentRun = run
        if currentRun.state != .finalizing {
            currentRun = try await transition(.finalizing, from: currentRun, runID: runID)
        }
        let finalization = AgentFinalizer.finalize(
            contract: completionContract ?? AgentCompletionContract(requiresArtifact: false),
            artifacts: artifacts,
            completedSteps: completedSteps
        )
        let validatedArtifactIDs = finalization.validatedArtifacts.map(\.id)
        let effectiveArtifactIDs = validatedArtifactIDs
        var effectiveWarnings = uniqueWarnings(warnings)
        var effectiveOutcome = outcome
        var effectiveRemainingSteps = remainingSteps
        var effectiveSummary = summary
        if completionContract?.requiresArtifact == true, finalization.validatedArtifacts.isEmpty {
            effectiveWarnings.append(String(localized: "工具输出没有形成仍然存在且通过格式校验的本机产物。", comment: "Engineering agent run warning (shown as the run error message): no tool output left an existing, format-validated local artifact"))
            if effectiveOutcome == .succeeded {
                effectiveOutcome = completedSteps.isEmpty ? .failed : .partial
            }
            if !effectiveRemainingSteps.contains("required artifact") {
                effectiveRemainingSteps.append("required artifact")
            }
            if effectiveOutcome != outcome {
                // The localized sentence is complete on its own; `summary` is
                // separate (usually model) text appended after it.
                effectiveSummary = String(localized: "工具步骤已运行，但最终产物未通过本机文件校验。", comment: "Engineering agent run summary shown in chat: tools ran but the final artifact failed local file validation; the model's own summary may follow") + (summary.isEmpty ? "" : " \(summary)")
            }
        }
        currentRun.delivery = AgentDelivery(
            outcome: effectiveOutcome,
            summary: effectiveSummary,
            artifactIDs: effectiveArtifactIDs,
            completedSteps: completedSteps,
            remainingSteps: effectiveRemainingSteps,
            warnings: uniqueWarnings(effectiveWarnings)
        )
        try await store.save(currentRun)

        let terminalState: AgentRunState
        switch effectiveOutcome {
        case .succeeded: terminalState = .succeeded
        case .partial: terminalState = .partiallySucceeded
        case .failed: terminalState = .failed
        case .cancelled: terminalState = .cancelled
        }
        let terminalRun = try await transition(terminalState, from: currentRun, runID: runID)
        if let memoryService {
            let result = await memoryService.record(run: terminalRun, artifacts: artifacts)
            if result.persisted {
                NSLog("[OgentMemory] run=%@ persisted wiki=%@", runID.uuidString, result.wikiTopic)
            }
        }
        return terminalRun
    }

    private func transition(_ next: AgentRunState, from run: AgentRun, runID: UUID) async throws -> AgentRun {
        var updated = run
        let firstNewEvent = updated.events.count
        try updated.transition(to: next, location: .iosHost)
        try await store.save(updated)
        emit(events: updated.events, from: firstNewEvent, runID: runID)
        return updated
    }

    private func append(_ event: AgentEvent, to run: AgentRun, runID: UUID) async throws -> AgentRun {
        var updated = run
        updated.events.append(event)
        updated.updatedAt = event.timestamp
        try await store.save(updated)
        emit(event: event, runID: runID)
        return updated
    }

    private func persistCancellation(runID: UUID) async {
        do {
            guard var run = try await store.load(id: runID), !run.state.isTerminal else { return }
            run.delivery = nil
            let firstNewEvent = run.events.count
            try run.transition(to: .cancelled, location: .iosHost)
            try await store.save(run)
            emit(events: run.events, from: firstNewEvent, runID: runID)
            if let memoryService {
                _ = await memoryService.record(run: run, artifacts: [])
            }
            continuations[runID]?.finish()
        } catch {
            // Cancellation is best-effort if the persistence layer itself is
            // unavailable; the executor still closes the event stream.
        }
    }

    private func checkCancellation(runID: UUID) throws {
        if cancelledRunIDs.contains(runID) || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func setApprovalState(runID: UUID, awaiting: Bool) async {
        do {
            guard let run = try await store.load(id: runID), !run.state.isTerminal else { return }
            let next: AgentRunState = awaiting ? .awaitingApproval : .runningTool
            guard run.state != next, run.state.canTransition(to: next) else { return }
            _ = try await transition(next, from: run, runID: runID)
        } catch {
            // Approval is a lifecycle signal. If persistence is unavailable,
            // the tool result still follows the normal failure/cancellation
            // path and the outer executor records that terminal outcome.
        }
    }

    private func failureSignature(_ record: ToolExecutionRecord) -> String {
        [record.request.name, record.request.argumentsJSON, record.errorMessage ?? ""].joined(separator: "|")
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var unique: [String] = []
        for warning in warnings where !unique.contains(warning) {
            unique.append(warning)
        }
        return unique
    }

    private func emit(event: AgentEvent, runID: UUID) {
        continuations[runID]?.yield(event)
    }

    private func emit(events: [AgentEvent], from index: Int, runID: UUID) {
        guard index < events.count else { return }
        for event in events[index...] {
            emit(event: event, runID: runID)
        }
    }

    private func finishStream(runID: UUID) {
        continuations[runID]?.finish()
        continuations.removeValue(forKey: runID)
        tasks.removeValue(forKey: runID)
    }
}
