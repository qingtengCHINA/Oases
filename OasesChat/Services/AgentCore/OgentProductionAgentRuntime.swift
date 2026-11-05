import Foundation

/// Per-run model/tool state. Keeping the API history here means the executor
/// can retry or resume without rebuilding context from SwiftUI messages.
actor OgentProductionAgentSession {
    private let context: AgentRunContext
    private let memoryService: AgentRunMemoryService?
    private var history: [ChatAPIMessage]
    private var executedToolCalls = 0
    private var didHydrateTranscript = false
    private var didLoadSelectedMemory = false
    /// Buffered tool outputs awaiting ordered flush after concurrent fan-out.
    private var pendingToolResults: [String: String] = [:]

    init(context: AgentRunContext, memoryService: AgentRunMemoryService? = nil) {
        self.context = context
        self.memoryService = memoryService
        self.history = context.messages
    }

    func projectSessionID() -> String? {
        context.projectSessionID
    }

    func modelConfiguration(for request: ModelTurnRequest) async -> (history: [ChatAPIMessage], toolsJSON: String?) {
        if !didHydrateTranscript {
            hydrateHistory(from: request.transcript)
            didHydrateTranscript = true
        }
        let plan = ProjectAgentPlanner.plan(
            for: request.userRequest,
            iteration: request.iteration + 1,
            executedToolCalls: executedToolCalls
        )
        let route = ToolRouter().route(
            prompt: request.userRequest,
            schemaBudgetBytes: ProjectToolSchemaBudget.defaultMaxProjectToolSchemaBytes,
            preferredToolNames: plan.toolNames
        )
        if !didLoadSelectedMemory, context.surface == .project {
            didLoadSelectedMemory = true
            let alreadyHydrated = history.contains { message in
                message.plainText.contains("[Ogent selected run memory]")
                    || message.plainText.contains("[工程模式本机状态]") // i18n-ignore: sentinel matched in model-facing history
            }
            if !alreadyHydrated,
               let memoryService,
               let selectedMemory = await memoryService.relevantContext(query: request.userRequest) {
                history.insert(ChatAPIMessage(role: "system", content: .text(selectedMemory)), at: 0)
            }
        }

        switch request.purpose {
        case .plan:
            return (history, route.schemaJSON ?? (request.iteration == 0 ? context.toolsJSON : nil))
        case .continueDelivery:
            return (
                history + [ChatAPIMessage(
                    role: "user",
                    content: .text(Self.continuationPrompt(for: request.userRequest))
                )],
                route.schemaJSON ?? context.toolsJSON
            )
        case .finalResponse:
            return (
                history + [ChatAPIMessage(
                    role: "user",
                    content: .text(Self.finalizationPrompt)
                )],
                nil
            )
        }
    }

    // i18n-ignore: model-facing prompt
    private static let finalizationPrompt = """
    工具步骤已经返回。现在必须给用户最终交付说明，不要再调用工具，也不要只说“继续”或“稍后”。
    请准确说明：已经完成的内容、真实产物文件名或本机路径、来源链接（如有）、仍未完成的步骤和阻碍。
    如果没有有效产物，必须明确写出未交付，不能声称任务成功。
    """

    static func continuationPrompt(for request: String) -> String {
        // i18n-ignore: model-facing prompt
        """
        你正在执行工程任务：\(request)
        上一轮工具调用结束，但交付契约尚未满足。请继续调用必要的已选工具，实际生成并校验产物；不要只输出计划，也不要提前结束。
        """
    }

    /// Rebuild the current run's protocol history after a process restart.
    /// SwiftUI chat messages are not enough: the model also needs the
    /// assistant tool-call envelope and each matching tool result.
    private func hydrateHistory(from events: [AgentEvent]) {
        var assistantText = ""
        var pendingCalls: [String: WireToolCall] = [:]

        func flushToolCall(_ callID: String, output: String) {
            guard let call = pendingCalls.removeValue(forKey: callID) else { return }
            let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            history.append(
                ChatAPIMessage(
                    role: "assistant",
                    content: text.isEmpty ? nil : .text(text),
                    toolCalls: [call]
                )
            )
            assistantText = ""
            history.append(ChatAPIMessage(role: "tool", content: .text(output), toolCallId: callID))
            executedToolCalls += 1
        }

        for event in events {
            switch event.payload {
            case .text(let value):
                assistantText += value.text
            case .tool(let value):
                guard let callID = value.callID else { continue }
                switch value.phase {
                case .started:
                    let arguments = event.metadata["arguments"] ?? "{}"
                    let call = WireToolCall(
                        id: callID,
                        type: "function",
                        function: .init(
                            name: value.name,
                            arguments: arguments.isEmpty ? "{}" : arguments
                        )
                    )
                    pendingCalls[callID] = call
                case .succeeded:
                    flushToolCall(callID, output: value.summary ?? "")
                case .failed:
                    flushToolCall(callID, output: "[tool error] \(value.summary ?? "工具执行失败")") // i18n-ignore: tool result rebuilt into model-facing history
                case .cancelled, .progress:
                    break
                }
            case .status, .diagnostic:
                break
            }
        }

        // A crash can happen between a streamed assistant chunk and the tool
        // event. Keep that text for the next model turn rather than dropping
        // it during resume.
        let trailingText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingText.isEmpty {
            history.append(ChatAPIMessage(role: "assistant", content: .text(trailingText)))
        }
    }

    func appendAssistant(text: String, calls: [WireToolCall]) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : MessageContent.text(text)
        history.append(ChatAPIMessage(role: "assistant", content: content, toolCalls: calls.isEmpty ? nil : calls))
    }

    /// Stage a tool result for later ordered flush. Concurrent tools must not
    /// append at wall-clock completion or the next model turn sees wrong order.
    func stageToolResult(callID: String, output: String) {
        pendingToolResults[callID] = output
    }

    /// Append staged tool results in the original tool_use order.
    func flushToolResults(inOrder callIDs: [String]) {
        for callID in callIDs {
            guard let output = pendingToolResults.removeValue(forKey: callID) else { continue }
            executedToolCalls += 1
            history.append(
                ChatAPIMessage(
                    role: "tool",
                    content: .text(output),
                    toolCallId: callID
                )
            )
        }
        // Drop any orphan staged results (e.g. cancelled mid-batch) so they
        // never leak into a later turn out of order.
        pendingToolResults.removeAll()
    }

    /// Stage then flush a single result (non-batch call sites).
    func appendToolResult(callID: String, output: String) {
        stageToolResult(callID: callID, output: output)
        flushToolResults(inOrder: [callID])
    }

    /// Call-IDs of tool-role messages currently in history (model-facing order).
    func toolResultCallIDsInHistory() -> [String] {
        history.compactMap { message in
            guard message.role == "tool" else { return nil }
            return message.toolCallId
        }
    }

    /// Tool-role body strings in model-facing history order.
    func toolResultBodiesInHistory() -> [String] {
        history.compactMap { message in
            guard message.role == "tool" else { return nil }
            return message.plainText
        }
    }

    func historySnapshot() -> [ChatAPIMessage] {
        history
    }
}

/// Bridges ChatService's OpenAI-compatible stream to the typed AgentExecutor
/// model protocol. It keeps tool-call accumulation out of ChatViewModel.
final class OgentProductionModelAdapter: @unchecked Sendable, ModelStreaming {
    private struct PendingCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""

        var wireCall: WireToolCall? {
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return WireToolCall(
                id: id,
                type: "function",
                function: .init(name: name, arguments: arguments.isEmpty ? "{}" : arguments)
            )
        }
    }

    private let service: any OgentChatStreaming
    private let session: OgentProductionAgentSession
    private let context: AgentRunContext

    init(service: any OgentChatStreaming, session: OgentProductionAgentSession, context: AgentRunContext) {
        self.service = service
        self.session = session
        self.context = context
    }

    func stream(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var assistantText = ""
                var pendingCalls: [Int: PendingCall] = [:]
                do {
                    let configuration = await session.modelConfiguration(for: request)
                    let upstream = await service.streamEvents(
                        messages: configuration.history,
                        model: context.model,
                        effort: context.effort,
                        surface: context.surface,
                        toolsJSON: configuration.toolsJSON
                    )
                    for try await event in upstream {
                        if Task.isCancelled { throw CancellationError() }
                        switch event {
                        case .textDelta(let delta):
                            assistantText += delta
                            continuation.yield(.text(delta))
                        case .toolCallDelta(let index, let id, let name, let argumentsDelta):
                            var call = pendingCalls[index] ?? PendingCall()
                            if let id, !id.isEmpty { call.id = id }
                            if let name, !name.isEmpty { call.name = name }
                            if let argumentsDelta { call.arguments += argumentsDelta }
                            pendingCalls[index] = call
                        case .finish, .usage:
                            break
                        }
                    }

                    let wireCalls = pendingCalls
                        .sorted { $0.key < $1.key }
                        .compactMap { $0.value.wireCall }
                    await session.appendAssistant(text: assistantText, calls: wireCalls)
                    for call in wireCalls {
                        continuation.yield(
                            .toolCall(
                                ModelToolCall(
                                    id: call.id,
                                    name: call.function.name,
                                    argumentsJSON: call.function.arguments
                                )
                            )
                        )
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    if !assistantText.isEmpty || !pendingCalls.isEmpty {
                        let wireCalls = pendingCalls
                            .sorted { $0.key < $1.key }
                            .compactMap { $0.value.wireCall }
                        await session.appendAssistant(text: assistantText, calls: wireCalls)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Executes the real registry tools and writes tool results back into the
/// per-run API history. Artifact paths are validated before entering the
/// typed delivery record, so prose cannot manufacture a successful artifact.
final class OgentProductionToolAdapter: @unchecked Sendable, ToolExecuting {
    private let registry: ToolRegistry
    private let session: OgentProductionAgentSession
    private let artifactStore: ArtifactStore
    private let progress: (@Sendable (ToolExecutionRequest, String) -> Void)?

    init(
        registry: ToolRegistry = .shared,
        session: OgentProductionAgentSession,
        artifactStore: ArtifactStore = ArtifactStore(),
        progress: (@Sendable (ToolExecutionRequest, String) -> Void)? = nil
    ) {
        self.registry = registry
        self.session = session
        self.artifactStore = artifactStore
        self.progress = progress
    }

    func execute(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        let sessionId = await session.projectSessionID()
        return await OasesPathResolver.ActiveSession.$id.withValue(sessionId) {
            await self.executeInSession(request)
        }
    }

    func flushOrderedToolResults(callIDs: [String]) async {
        await session.flushToolResults(inOrder: callIDs)
    }

    private func executeInSession(_ request: ToolExecutionRequest) async -> ToolExecutionRecord {
        let location = Self.location(for: request.name)
        guard let tool = registry.tool(named: request.name) else {
            let message = "Tool '\(request.name)' is not registered."
            // Stage only — AgentExecutor flushes in original tool_use order.
            await session.stageToolResult(callID: request.callID, output: "[tool error] \(message)")
            return .failure(request: request, message: message, location: location)
        }

        do {
            let result = try await tool.invoke(argumentsJSON: request.argumentsJSON) { [progress] line in
                progress?(request, line)
            }
            let output = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artifacts = Self.recordArtifacts(
                output: output,
                runID: request.runID,
                artifactStore: artifactStore
            )
            await session.stageToolResult(callID: request.callID, output: output)
            return .success(
                request: request,
                output: output,
                location: location,
                artifactIDs: artifacts.map(\.id),
                artifacts: artifacts
            )
        } catch is CancellationError {
            await session.stageToolResult(callID: request.callID, output: "[tool cancelled]")
            return .cancelled(request: request, location: location)
        } catch {
            let message = error.localizedDescription
            await session.stageToolResult(callID: request.callID, output: "[tool error] \(message)")
            return .failure(request: request, message: message, location: location)
        }
    }

    private static func location(for name: String) -> ExecutionLocation {
        let linuxTools: Set<String> = [
            "shell_execute", "shell_local", "ogent_agent", "mcp_status", "mcp_tools", "mcp_call",
            "mcp_selftest", "mcp_http_selftest", "mcp_config_selftest", "mcp_12306_selftest",
            "train_ticket_12306", "file_read", "file_write", "file_edit", "youtube_downloader",
            "video_downloader", "svg_logo_fetcher", "nano_pdf", "browser_use"
        ]
        return linuxTools.contains(name) ? .ishLinux : .iosHost
    }

    private static func recordArtifacts(
        output: String,
        runID: UUID,
        artifactStore: ArtifactStore
    ) -> [ArtifactRecord] {
        var seen = Set<String>()
        var records: [ArtifactRecord] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in ["[oases:open]", "ios=", "ios:"] {
                guard let range = line.range(of: marker) else { continue }
                var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
                guard path.hasPrefix("/"), seen.insert(path).inserted else { continue }
                let url = URL(fileURLWithPath: path)
                if let record = try? artifactStore.record(fileURL: url, runID: runID) {
                    records.append(record)
                }
            }
        }
        return records
    }
}

/// Concrete production composition for a single engineering run.
enum OgentProductionAgentRuntimeError: LocalizedError, Equatable {
    case runNotFound(UUID)
    case missingContext(UUID)

    var errorDescription: String? {
        switch self {
        case .runNotFound(let runID):
            return String(localized: "找不到要恢复的工程 Agent run：\(runID.uuidString)", comment: "Error shown when resuming an engineering agent run whose record is missing; the argument is the run ID")
        case .missingContext(let runID):
            return String(localized: "工程 Agent run 缺少可恢复的本地 context：\(runID.uuidString)", comment: "Error shown when an engineering agent run record lacks the local context needed to resume; the argument is the run ID")
        }
    }
}

final class OgentProductionAgentRuntime: @unchecked Sendable {
    let store: AgentRunStore
    let coordinator: AgentRunCoordinator
    let context: AgentRunContext

    init(
        context: AgentRunContext,
        completionContract: AgentCompletionContract,
        service: any OgentChatStreaming,
        progress: (@Sendable (ToolExecutionRequest, String) -> Void)? = nil,
        store: AgentRunStore = AgentRunStore(),
        registry: ToolRegistry = .shared,
        artifactStore: ArtifactStore = ArtifactStore()
    ) {
        self.context = context
        self.store = store
        let session = OgentProductionAgentSession(context: context, memoryService: .shared)
        let model = OgentProductionModelAdapter(service: service, session: session, context: context)
        let tools = OgentProductionToolAdapter(
            registry: registry,
            session: session,
            artifactStore: artifactStore,
            progress: progress
        )
        self.coordinator = AgentRunCoordinator(
            model: model,
            toolExecutor: tools,
            store: store,
            maxIterations: 18,
            completionContract: completionContract,
            memoryService: .shared
        )
    }

    func start() async throws -> AgentRunHandle {
        try await coordinator.start(request: context.messages.last?.plainText ?? "", context: context)
    }

    func load(runID: UUID) async throws -> AgentRun? {
        try await store.load(id: runID)
    }

    /// Resume a run through the same persisted executor used by `start`.
    /// The store check makes a missing or malformed run visible to the caller
    /// instead of returning an empty event stream that looks like success.
    func resume(runID: UUID) async throws -> AgentRunHandle {
        guard let run = try await store.load(id: runID) else {
            throw OgentProductionAgentRuntimeError.runNotFound(runID)
        }
        guard run.context != nil else {
            throw OgentProductionAgentRuntimeError.missingContext(runID)
        }
        return AgentRunHandle(runID: runID, events: await coordinator.resume(runID: runID))
    }

    /// Rebuild a production runtime after an app/process restart. `AgentRun`
    /// persists the model context, while tools and the service are injected
    /// afresh so no iSH process, WebKit object, or URLSession is reused across
    /// lifetimes. The completion contract is inferred from the original user
    /// request unless the caller has a stricter contract for this surface.
    static func resumePersistedRun(
        runID: UUID,
        service: any OgentChatStreaming,
        completionContract: AgentCompletionContract? = nil,
        progress: (@Sendable (ToolExecutionRequest, String) -> Void)? = nil,
        store: AgentRunStore = AgentRunStore(),
        registry: ToolRegistry = .shared,
        artifactStore: ArtifactStore = ArtifactStore()
    ) async throws -> (runtime: OgentProductionAgentRuntime, handle: AgentRunHandle) {
        guard let run = try await store.load(id: runID) else {
            throw OgentProductionAgentRuntimeError.runNotFound(runID)
        }
        guard let context = run.context else {
            throw OgentProductionAgentRuntimeError.missingContext(runID)
        }

        let request = run.request ?? context.messages.last?.plainText ?? ""
        let plannerContract = ProjectAgentPlanner.plan(
                for: request,
                iteration: 1,
                executedToolCalls: 0
            ).completionContract
        let inferredContract = completionContract
            ?? AgentCompletionContract(requiresArtifact: plannerContract.requiresArtifact)
        let runtime = OgentProductionAgentRuntime(
            context: context,
            completionContract: inferredContract,
            service: service,
            progress: progress,
            store: store,
            registry: registry,
            artifactStore: artifactStore
        )
        let handle = try await runtime.resume(runID: runID)
        return (runtime, handle)
    }

    /// Return the newest non-terminal project run for cold-launch recovery.
    /// Terminal runs are deliberately excluded so relaunch never duplicates a
    /// completed delivery; a caller must still decide whether the current UI
    /// is empty before presenting or resuming this candidate.
    static func latestInterruptedProjectRun(
        store: AgentRunStore = AgentRunStore()
    ) async throws -> AgentRun? {
        try await store.list().first { run in
            !run.state.isTerminal && run.context?.surface == .project
        }
    }

    func cancel(runID: UUID) async {
        await coordinator.cancel(runID: runID)
    }
}

private extension ChatAPIMessage {
    var plainText: String {
        guard let content else { return "" }
        switch content {
        case .text(let value): return value
        case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
        }
    }
}
