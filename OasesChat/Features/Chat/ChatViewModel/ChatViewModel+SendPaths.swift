import Foundation
import SwiftUI
import SwiftData

extension ChatViewModel {
    // MARK: - Per-mode send paths

    /// Appends the assistant placeholder and starts a new stream generation
    /// owned by it (see `activeStreamID`). `quotaCharge` is committed only if
    /// this turn finishes successfully.
    func makeAssistantPlaceholder(
        content: String = "",
        quotaCharge: (category: Models.Category, modelId: String)? = nil
    ) -> String {
        let assistant = ChatUIMessage.assistantPlaceholder(content: content)
        messages.append(assistant)
        isStreaming = true
        activeStreamID = assistant.id
        streamStartedAt = Date()
        liveSignals.didStartRun()
        pendingQuotaCharge = quotaCharge
        return assistant.id
    }

    /// Ordinary chat agent loop with streamed SSE + tool calls.
    /// Project / engineering mode is handled exclusively by
    /// `sendProjectWithAgentRun` (OgentProductionAgentRuntime).
    ///
    /// On each iteration:
    ///   1. Send current history (system + user + prior assistant/tool turns)
    ///   2. Stream text deltas into the assistant bubble + accumulate any
    ///      `tool_calls` deltas in a working set keyed by the OpenAI
    ///      delta `index`
    ///   3. If finish_reason is `tool_calls`, dispatch every accumulated
    ///      call via `ToolRegistry`, append the assistant tool-calls
    ///      message AND the tool result messages to the history, then
    ///      loop. Otherwise the turn is done.
    func sendChat(
        userWireContent: MessageContent,
        assistantId: String,
        routingPrompt: String,
        projectSessionID: String? = nil,
        projectID: String? = nil
    ) async {
        // Engineering mode owns the production AgentRun path — do not fall
        // through to the ordinary chat tool loop.
        if activeMode == .project {
            await sendProjectWithAgentRun(
                userWireContent: userWireContent,
                assistantId: assistantId,
                routingPrompt: routingPrompt,
                projectSessionID: projectSessionID,
                projectID: projectID
            )
            return
        }

        liveSignals.notePrompt(routingPrompt)
        let history = messages.dropLast().map(\.api)
        var apiHistory = history
        if let lastUserIdx = apiHistory.lastIndex(where: { $0.role == "user" }) {
            apiHistory[lastUserIdx] = ChatAPIMessage(role: "user", content: userWireContent)
        }
        let model = currentModel
        let effortValue = Models.option(for: model)?.supportsEffort == true ? effort.rawValue : nil
        let chatService = service
        let surface: AgentSurface = .chat
        let chatToolsJSON = ToolRegistry.shared.openAIToolsJSON(for: surface)

        currentTask = AIRequestGate.startRun { [weak self] in
            // Per-chunk watchdog — restarts every time a chunk arrives so a
            // healthy slow stream (long reasoning between tokens) is allowed
            // but a truly hung connection still fails fast.
            //
            // First-token grace is generous (60 s) since some reasoning
            // models do not emit anything until they finish thinking.
            // Subsequent chunks reset to a tighter 30 s budget.
            let watchdogBox = WatchdogBox()
            let arm: (TimeInterval) -> Void = { timeout in
                watchdogBox.arm(timeout: timeout) { [weak self] in
                    // A superseded turn's watchdog must not cancel or fail
                    // the stream that replaced it.
                    guard let self, self.ownsStream(assistantId) else { return }
                    self.currentTask?.cancel()
                    self.failStreaming(
                        assistantId: assistantId,
                        error: NSError(domain: "Chat", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: String(localized: "响应超时，请重试")])
                    )
                }
            }
            defer { watchdogBox.task?.cancel() }

            do {
                // Agent loop — runs once for plain text, multiple times
                // when the model requests tool calls. Chat surface uses a
                // modest iteration budget; engineering/project work is
                // handled by OgentProductionAgentRuntime instead.
                var workingHistory = apiHistory
                var iteration = 0
                let maxIterations = 5
                var executedToolCalls = 0
                var recoverableStreamError: Error?
                var receivedAny = false
                // After tools ran, a failed round gets one more try as a plain
                // answer: no tool schema, tool results folded into the prompt.
                var answeringWithoutTools = false

                while iteration < maxIterations || answeringWithoutTools {
                    try Task.checkCancellation()
                    iteration += 1
                    arm(60.0) // generous first-token grace each iteration

                    var textBuffer = ""
                    var assistantTextForHistory = ""
                    var lastFlush = Date()
                    var pendingCalls: [Int: WorkingToolCall] = [:]
                    var finishReason: String? = nil
                    let iterationToolsJSON = answeringWithoutTools ? nil : chatToolsJSON
                    let iterationHistory = answeringWithoutTools
                        ? Self.foldingToolRounds(workingHistory)
                        : workingHistory

                    let eventStream = await chatService.streamEvents(
                        messages: iterationHistory,
                        model: model,
                        effort: effortValue,
                        surface: surface,
                        toolsJSON: iterationToolsJSON
                    )
                    do {
                        for try await event in eventStream {
                            if Task.isCancelled { break }
                            arm(30.0) // reset per-chunk timeout

                            switch event {
                            case .textDelta(let delta):
                                if !receivedAny {
                                    receivedAny = true
                                    await MainActor.run { self?.setStreamingFlag(assistantId, true) }
                                }
                                textBuffer += delta
                                assistantTextForHistory += delta
                                let now = Date()
                                if now.timeIntervalSince(lastFlush) >= 0.04 {
                                    let payload = textBuffer
                                    textBuffer = ""
                                    lastFlush = now
                                    self?.replacePlaceholder(assistantId, with: payload, append: true)
                                }
                            case .toolCallDelta(let index, let id, let name, let argsDelta):
                                var entry = pendingCalls[index] ?? WorkingToolCall()
                                if let id { entry.id = id }
                                if let name { entry.name = name }
                                if let argsDelta { entry.arguments += argsDelta }
                                pendingCalls[index] = entry
                            case .finish(let reason):
                                finishReason = reason
                            case .usage:
                                break
                            }
                        }
                    } catch {
                        // Stop / watchdog cancellation arrives as
                        // CancellationError or a wrapped URLError.cancelled.
                        // It is never a recoverable stream failure — treating
                        // it as one finished the turn as a success and
                        // persisted the timeout text.
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        NSLog("[ChatAgent] stream iteration \(iteration) failed after \(executedToolCalls) tool(s): \(error.localizedDescription)")
                        let nothingSaidYet = await MainActor.run {
                            self?.assistantContentIsEmpty(assistantId) ?? true
                        }
                        if executedToolCalls > 0, nothingSaidYet, !answeringWithoutTools {
                            answeringWithoutTools = true
                            continue
                        }
                        if executedToolCalls > 0 || receivedAny {
                            recoverableStreamError = error
                            break
                        }
                        throw error
                    }
                    // A cancelled consumer sees the stream end without an
                    // error; don't mistake the truncated turn for an answer.
                    try Task.checkCancellation()
                    if !textBuffer.isEmpty {
                        self?.replacePlaceholder(assistantId, with: textBuffer, append: true)
                    }

                    // No tool calls -> done. Some OpenAI-compatible endpoints
                    // omit `finish_reason=tool_calls` even after streaming
                    // valid tool deltas; execute the accumulated calls instead
                    // of treating that as a completed answer.
                    if pendingCalls.isEmpty || answeringWithoutTools {
                        break
                    }
                    if finishReason != "tool_calls" {
                        NSLog(
                            "[ChatAgent] executing pending tool calls despite finish_reason=%@ count=%d",
                            finishReason ?? "nil",
                            pendingCalls.count
                        )
                    }

                    // Surface each pending call on the assistant bubble
                    // as a running pill, then dispatch + collect results.
                    let calls = pendingCalls
                        .sorted { $0.key < $1.key }
                        .map { _, wc in wc.materialize() }
                    executedToolCalls += calls.count
                    await MainActor.run {
                        self?.appendToolCalls(assistantId: assistantId, calls: calls)
                    }

                    // Build the assistant tool-calls message for history.
                    let assistantHistoryText = assistantTextForHistory
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let assistantToolCallsMessage = ChatAPIMessage(
                        role: "assistant",
                        content: .text(assistantHistoryText),
                        toolCalls: calls.map { c in
                            WireToolCall(
                                id: c.id, type: "function",
                                function: .init(name: c.name, arguments: c.inputJSON ?? "{}")
                            )
                        }
                    )
                    workingHistory.append(assistantToolCallsMessage)

                    for call in calls {
                        // Stop ends the batch: never start the remaining
                        // tools (a shell_execute watchdog is 30 minutes).
                        try Task.checkCancellation()
                        let toolStartedAt = Date()
                        await MainActor.run {
                            self?.updateToolCallStatus(assistantId: assistantId, id: call.id, status: .running, startedAt: toolStartedAt)
                        }
                        let tool = ToolRegistry.shared.tool(named: call.name)
                        let resultText: String
                        let endedStatus: ToolCallStatus
                        if let tool {
                            do {
                                let callId = call.id
                                let assistantTurnId = assistantId
                                arm(Self.toolWatchdogTimeout(for: call))
                                let arguments = call.inputJSON ?? "{}"
                                let result = try await AgentToolContext.$surface.withValue(.chat) {
                                    try await tool.invoke(argumentsJSON: arguments) { [weak self] line in
                                        Task { @MainActor [weak self] in
                                            self?.appendToolCallOutput(assistantId: assistantTurnId, id: callId, chunk: line)
                                        }
                                    }
                                }
                                resultText = Self.formatToolResult(result)
                                endedStatus = .completed
                                if let url = result.mediaUrl {
                                    await MainActor.run {
                                        self?.attachToolMedia(assistantId: assistantId, callId: call.id, url: url, mime: result.mediaMime)
                                    }
                                }
                            } catch {
                                resultText = "[tool error] \(error.localizedDescription)"
                                endedStatus = Task.isCancelled ? .canceled : .error
                            }
                        } else {
                            resultText = "[tool '\(call.name)' not registered]"
                            endedStatus = .error
                        }
                        let toolEndedAt = Date()
                        await MainActor.run {
                            self?.updateToolCallStatus(assistantId: assistantId, id: call.id, status: endedStatus, output: resultText, endedAt: toolEndedAt)
                        }
                        workingHistory.append(ChatAPIMessage(
                            role: "tool",
                            content: .text(Self.formatToolResultForModel(resultText, toolName: call.name)),
                            toolCallId: call.id
                        ))
                    }
                    // The last round answers from what the tools found
                    // instead of asking for yet another tool.
                    if iteration + 1 >= maxIterations {
                        answeringWithoutTools = true
                    }
                    // Loop again so the model can read the tool results.
                }

                if let recoverableStreamError {
                    // Chat surface: surface the error if we never produced a
                    // usable reply; otherwise keep partial tool/text output.
                    let hasContent = await MainActor.run {
                        !(self?.assistantContentIsEmpty(assistantId) ?? true)
                    }
                    if !hasContent {
                        throw recoverableStreamError
                    }
                    NSLog(
                        "[ChatAgent] recoverable stream error kept partial reply: %@",
                        recoverableStreamError.localizedDescription
                    )
                }

                watchdogBox.task?.cancel()
                await MainActor.run { self?.setStreamingFlag(assistantId, false) }
                if self?.finishStreaming(assistantId: assistantId, success: true) == true {
                    self?.persistAssistantMessage(id: assistantId)
                }
            } catch is CancellationError {
                await MainActor.run { self?.setStreamingFlag(assistantId, false) }
                self?.markUnfinishedToolCallsCanceled(assistantId: assistantId)
                self?.finishStreaming(assistantId: assistantId, success: false)
            } catch {
                await MainActor.run { self?.setStreamingFlag(assistantId, false) }
                self?.failStreaming(assistantId: assistantId, error: error)
            }
        }
    }

    /// Production engineering / project path. Uses one persisted AgentRun,
    /// one per-run API history, and typed terminal delivery via
    /// `OgentProductionAgentRuntime`. Ordinary chat stays in `sendChat`.
    func sendProjectWithAgentRun(
        userWireContent: MessageContent,
        assistantId: String,
        routingPrompt: String,
        projectSessionID: String?,
        projectID: String?
    ) async {
        let model = currentModel
        let effortValue = Models.option(for: model, category: .project)?.supportsEffort == true
            ? effort.rawValue
            : nil
        var history = messages.dropLast().map(\.api)
        if let lastUserIndex = history.lastIndex(where: { $0.role == "user" }) {
            history[lastUserIndex] = ChatAPIMessage(role: "user", content: userWireContent)
        }

        let plan = ProjectAgentPlanner.plan(for: routingPrompt, iteration: 1, executedToolCalls: 0)
        let routedTools = ToolRouter().route(
            prompt: routingPrompt,
            schemaBudgetBytes: ProjectToolSchemaBudget.defaultMaxProjectToolSchemaBytes,
            preferredToolNames: plan.toolNames
        )
        let context = AgentRunContext(
            model: model,
            effort: effortValue,
            surface: .project,
            messages: history,
            toolsJSON: routedTools.schemaJSON,
            projectSessionID: projectSessionID,
            projectID: projectID
        )
        let completionContract = AgentCompletionContract(
            requiresArtifact: plan.completionContract.requiresArtifact
        )
        let chatService = service
        let runtime = OgentProductionAgentRuntime(
            context: context,
            completionContract: completionContract,
            service: chatService,
            progress: { [weak self] request, line in
                Task { @MainActor [weak self] in
                    self?.appendToolCallOutput(
                        assistantId: assistantId,
                        id: request.callID,
                        chunk: line
                    )
                }
            }
        )

        currentTask = AIRequestGate.startRun { [weak self] in
            guard let self else { return }
            await self.runProjectAgent(
                runtime: runtime,
                assistantId: assistantId,
                routingPrompt: routingPrompt,
                model: model,
                plan: plan,
                projectSessionID: projectSessionID,
                projectID: projectID
            )
        }
    }

    func runProjectAgent(
        runtime: OgentProductionAgentRuntime,
        initialHandle: AgentRunHandle? = nil,
        assistantId: String,
        routingPrompt: String,
        model: String,
        plan: ProjectAgentPlan,
        projectSessionID: String?,
        projectID: String?
    ) async {
        var knownCallIDs = Set<String>()
        var callInputs: [String: String] = [:]
        var liveIteration = 0
        let liveTitle = String(routingPrompt.prefix(48))
        activeProjectRuntime = runtime
        activeProjectSessionID = projectSessionID
        // Live Activity is driven through SessionActivityTracker (the
        // OpenMinis model): marking a session active starts/refreshes the
        // activity, and per-tool updates flow through updateToolInfo.
        let liveSessionId = projectSessionID ?? activeProjectRunID?.uuidString ?? UUID().uuidString
        activeLiveSessionId = liveSessionId
        SessionActivityTracker.shared.setActive(liveSessionId)
        SessionActivityTracker.shared.updateSessionTitle(
            liveSessionId, title: liveTitle.isEmpty ? "Ogent" : liveTitle
        )
        SessionActivityTracker.shared.updateToolInfo(
            sessionId: liveSessionId, toolName: "terminal", toolStatus: plan.kind.rawValue
        )

        // This run's own id — the shared `activeProjectRunID` may already
        // belong to a newer turn by the time cancellation cleanup runs.
        var startedRunID: UUID?
        do {
            let handle: AgentRunHandle
            if let initialHandle {
                handle = initialHandle
            } else {
                handle = try await runtime.start()
            }
            startedRunID = handle.runID
            activeProjectRunID = handle.runID
            for await event in handle.events {
                if Task.isCancelled {
                    // Runtime / shell teardown happens once, in the
                    // cancellation handler below.
                    throw CancellationError()
                }
                switch event.payload {
                case .text(let text):
                    replacePlaceholder(assistantId, with: text.text, append: true)
                case .tool(let tool):
                    guard let callID = tool.callID else { continue }
                    switch tool.phase {
                    case .started:
                        liveIteration += 1
                        let arguments = event.metadata["arguments"] ?? "{}"
                        callInputs[callID] = arguments
                        if let liveSessionId = activeLiveSessionId {
                            SessionActivityTracker.shared.updateToolInfo(
                                sessionId: liveSessionId,
                                toolName: tool.name,
                                toolStatus: tool.name
                            )
                            SessionActivityTracker.shared.updateLoopIteration(
                                liveSessionId, iteration: liveIteration
                            )
                        }
                        if knownCallIDs.insert(callID).inserted {
                            appendToolCalls(
                                assistantId: assistantId,
                                calls: [ToolCall(
                                    id: callID,
                                    name: tool.name,
                                    displayName: ToolRegistry.shared.tool(named: tool.name)?.descriptor.displayName,
                                    status: .running,
                                    inputJSON: arguments,
                                    startedAt: event.timestamp
                                )]
                            )
                        }
                    case .succeeded, .failed, .cancelled:
                        let status: ToolCallStatus
                        switch tool.phase {
                        case .succeeded: status = .completed
                        case .failed: status = .error
                        case .cancelled: status = .canceled
                        default: status = .running
                        }
                        updateToolCallStatus(
                            assistantId: assistantId,
                            id: callID,
                            status: status,
                            output: tool.summary,
                            endedAt: event.timestamp
                        )
                        var traceCall = ToolCall(
                            id: callID,
                            name: tool.name,
                            displayName: ToolRegistry.shared.tool(named: tool.name)?.descriptor.displayName,
                            status: status,
                            inputJSON: callInputs[callID] ?? "{}",
                            output: tool.summary,
                            endedAt: event.timestamp
                        )
                        recordProjectToolTrace(
                            call: traceCall,
                            iteration: 0,
                            model: model,
                            userPrompt: routingPrompt,
                            sessionID: projectSessionID,
                            projectID: projectID
                        )
                        traceCall.output = tool.summary
                    case .progress:
                        break
                    }
                case .status, .diagnostic:
                    break
                }
            }
            try Task.checkCancellation()

            guard let run = try await runtime.load(runID: handle.runID),
                  let delivery = run.delivery else {
                throw NSError(
                    domain: "OgentAgent",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "工程 Agent 未生成终态交付记录。")]
                )
            }

            let snapshot = await Self.projectFinalizerSnapshot()
            // Stopped (or superseded) while loading the delivery: don't
            // write it into the transcript.
            try Task.checkCancellation()
            let repaired = replaceWithLocalFinalDeliveryIfNeeded(
                assistantId: assistantId,
                reason: delivery.summary,
                finalizerSnapshot: snapshot
            )
            if !repaired, assistantContentIsEmpty(assistantId) {
                replacePlaceholder(assistantId, with: delivery.summary, append: false)
            }

            if delivery.outcome == .failed || delivery.outcome == .partial {
                errorMessage = delivery.warnings.first
            }
            finishLiveActivitySession(lastMessage: delivery.summary)
            setStreamingFlag(assistantId, false)
            if finishStreaming(
                assistantId: assistantId,
                success: delivery.outcome != .failed && delivery.outcome != .cancelled
            ) {
                persistAssistantMessage(id: assistantId)
                recordProjectTurnMemory(
                    assistantId: assistantId,
                    model: model,
                    sessionID: projectSessionID,
                    projectID: projectID
                )
            }
            NSLog(
                "[ProjectAgent] persisted run=%@ state=%@ outcome=%@ tools=%d artifacts=%d kind=%@",
                handle.runID.uuidString,
                run.state.rawValue,
                delivery.outcome.rawValue,
                delivery.completedSteps.count,
                delivery.artifactIDs.count,
                plan.kind.rawValue
            )
        } catch let error where error is CancellationError || Task.isCancelled {
            if let startedRunID {
                await runtime.cancel(runID: startedRunID)
            }
            if let projectSessionID {
                _ = await ISHRuntimeService.shared.cancelAll(sessionId: projectSessionID)
            }
            // A newer turn may already own the shared runtime / Live Activity
            // state (Stop, then an immediate send); leave it alone.
            if !isSupersededStream(assistantId) {
                // Unscoped commands only; other sessions keep their shells.
                _ = await ISHRuntimeService.shared.cancelUnscoped()
            }
            if !isSupersededStream(assistantId) {
                activeProjectRuntime = nil
                activeProjectRunID = nil
                activeProjectSessionID = nil
                endLiveActivitySession()
            }
            setStreamingFlag(assistantId, false)
            finishStreaming(assistantId: assistantId, success: false)
        } catch {
            let reason = error.localizedDescription
            let snapshot = await Self.projectFinalizerSnapshot()
            if ownsStream(assistantId) {
                _ = replaceWithLocalFinalDeliveryIfNeeded(
                    assistantId: assistantId,
                    reason: reason,
                    finalizerSnapshot: snapshot
                )
                activeProjectRuntime = nil
                activeProjectRunID = nil
                activeProjectSessionID = nil
                finishLiveActivitySession(lastMessage: reason)
            }
            setStreamingFlag(assistantId, false)
            failStreaming(assistantId: assistantId, error: error)
        }
        if !isSupersededStream(assistantId) {
            activeProjectRuntime = nil
            activeProjectRunID = nil
            activeProjectSessionID = nil
        }
    }

    /// True when another turn has started since `assistantId`'s began.
    func isSupersededStream(_ assistantId: String) -> Bool {
        activeStreamID != nil && activeStreamID != assistantId
    }

    func setStreamingFlag(_ id: String, _ value: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isStreaming = value
    }

    /// After a cancelled turn, tools that never ran (or were interrupted)
    /// would otherwise keep spinning as pending/running pills.
    func markUnfinishedToolCallsCanceled(assistantId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        let now = Date()
        for cIdx in messages[idx].toolCalls.indices
        where messages[idx].toolCalls[cIdx].status == .pending || messages[idx].toolCalls[cIdx].status == .running {
            messages[idx].toolCalls[cIdx].status = .canceled
            messages[idx].toolCalls[cIdx].endedAt = now
        }
    }

    func recordProjectTurnMemory(assistantId: String, model: String, sessionID: String? = nil, projectID: String? = nil) {
        guard let assistantIndex = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        let assistant = messages[assistantIndex]
        let assistantText = assistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty, !AssistantPendingView.isPending(assistantText) else { return }

        let priorUser = messages[..<assistantIndex]
            .reversed()
            .first { $0.role == .user }
        let userPrompt = priorUser?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let conversationTitle = conversation?.title ?? "工程模式" // i18n-ignore: Ogent memory record (agent-facing)
        let conversationID = conversation?.id.uuidString ?? "unsaved"
        OgentConversationMemoryIngestor.recordProjectTurn(
            conversationTitle: conversationTitle,
            conversationID: conversationID,
            model: model,
            userPrompt: userPrompt,
            assistantText: assistantText,
            toolCalls: assistant.toolCalls,
            sessionID: sessionID
        )
        Task.detached(priority: .utility) {
            // i18n-ignore: Ogent project manifest record (agent-facing)
            let body = """
            ## 最终交付记忆
            - kind: project_turn_memory
            - model: \(model)
            - conversation_title: \(conversationTitle)
            - conversation_id: \(conversationID)
            - user_goal: \(String(userPrompt.prefix(500)))

            ### Assistant Delivery
            \(String(assistantText.prefix(2_000)))
            """
            _ = await OgentProjectSessionRecorder.recordManifestEvent(
                projectID: projectID,
                status: "completed",
                event: "memory:project_turn",
                body: body
            )
        }
    }

    func recordProjectToolTrace(
        call: ToolCall,
        iteration: Int,
        model: String,
        userPrompt: String,
        sessionID: String? = nil,
        projectID: String? = nil
    ) {
        let note = ProjectToolTrace.sessionNote(
            call: call,
            iteration: iteration,
            model: model,
            userPrompt: userPrompt
        )
        ISHRuntimeQueue.async {
            guard ISHRuntimeBootstrap.bootstrap() else {
                NSLog("[ProjectAgent] tool trace skipped bootstrap=false tool=%@", call.name)
                return
            }
            let result = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.sessionNoteCommand(sessionID: sessionID ?? "", note: note),
                timeout: 12,
                onProgress: { _ in }
            )
            let text = result.text ?? ""
            if text.contains("[exit=0") || text.contains("session note appended") {
                NSLog("[ProjectAgent] tool trace saved tool=%@ status=%@", call.name, call.status.rawValue)
            } else {
                NSLog("[ProjectAgent] tool trace save failed tool=%@ output=%@", call.name, String(text.prefix(500)))
            }
            if let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
                let manifestStatus: String
                switch call.status {
                case .completed:
                    manifestStatus = "tool_completed"
                case .error:
                    manifestStatus = "tool_failed"
                case .running:
                    manifestStatus = "tool_running"
                case .pending:
                    manifestStatus = "running"
                case .canceled:
                    manifestStatus = "tool_canceled"
                }
                let manifest = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.projectManifestUpdateCommand(
                        projectID: projectID,
                        status: manifestStatus,
                        event: "tool:\(call.name)",
                        body: note
                    ),
                    timeout: 12,
                    onProgress: { _ in }
                )
                let manifestText = manifest.text ?? ""
                if manifestText.contains("[exit=0") || manifestText.contains("project_manifest_update_ok") {
                    NSLog("[ProjectAgent] project manifest updated tool=%@ status=%@", call.name, manifestStatus)
                } else {
                    NSLog("[ProjectAgent] project manifest update failed tool=%@ output=%@", call.name, String(manifestText.prefix(500)))
                }
            }
        }
    }


}

// MARK: - Live Activity session bookkeeping

extension ChatViewModel {
    /// Drop the session from the tracker without a completion state — used on
    /// cancel, where there is no delivery to report.
    func endLiveActivitySession() {
        guard let id = activeLiveSessionId else { return }
        activeLiveSessionId = nil
        SessionActivityTracker.shared.setInactive(id)
        AgentLiveActivityManager.shared.endActivity()
    }

    /// Soft-finish: mark the session completed so the Live Activity shows the
    /// checkmark + last message and lingers until the user dismisses it.
    func finishLiveActivitySession(lastMessage: String) {
        guard let id = activeLiveSessionId else { return }
        activeLiveSessionId = nil
        AgentLiveActivityManager.shared.markSessionCompleted(
            sessionId: id, lastMessage: lastMessage
        )
        SessionActivityTracker.shared.setInactive(id)
    }
}
