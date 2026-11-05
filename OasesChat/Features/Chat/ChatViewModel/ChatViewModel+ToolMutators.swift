import Foundation
import SwiftUI
import SwiftData

extension ChatViewModel {
    // MARK: - Tool-call mutators

    func appendToolCalls(assistantId: String, calls: [ToolCall]) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        messages[idx].toolCalls.append(contentsOf: calls)
    }

    func appendToolCallOutput(assistantId: String, id: String, chunk: String) {
        guard let mIdx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        guard let cIdx = messages[mIdx].toolCalls.firstIndex(where: { $0.id == id }) else { return }
        let prior = messages[mIdx].toolCalls[cIdx].output ?? ""
        messages[mIdx].toolCalls[cIdx].output = prior + chunk
    }

    func updateToolCallStatus(
        assistantId: String,
        id: String,
        status: ToolCallStatus,
        output: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        guard let mIdx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        guard let cIdx = messages[mIdx].toolCalls.firstIndex(where: { $0.id == id }) else { return }
        messages[mIdx].toolCalls[cIdx].status = status
        if let output { messages[mIdx].toolCalls[cIdx].output = output }
        if let startedAt { messages[mIdx].toolCalls[cIdx].startedAt = startedAt }
        if let endedAt { messages[mIdx].toolCalls[cIdx].endedAt = endedAt }
    }

    func attachToolMedia(assistantId: String, callId: String, url: String, mime: String?) {
        // Image tool results get hoisted to the assistant message's
        // `imageUrl` so the existing media bubble renders them. Audio
        // mirrors via `audioUrl`. Text-only tool results stay on the
        // ToolCall pill (output field).
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else { return }
        if let mime, mime.hasPrefix("audio/") {
            messages[idx].audioUrl = url
            messages[idx].audioMimeType = mime
        } else {
            messages[idx].imageUrl = url
        }
    }

    static func formatToolResult(_ result: ToolResult) -> String {
        if let text = result.text, !text.isEmpty {
            if let url = result.mediaUrl {
                return "\(text)\n(media: \(url))"
            }
            return text
        }
        if let url = result.mediaUrl {
            return "(media generated: \(url))"
        }
        return "(empty result)"
    }

    /// The working history with this turn's tool rounds turned into plain
    /// text: assistant tool-call messages keep only their words, and the tool
    /// results become one closing user note. Used for the answer-only retry,
    /// which sends no tool schema (some upstreams reject tool messages then).
    static func foldingToolRounds(_ history: [ChatAPIMessage]) -> [ChatAPIMessage] {
        var folded: [ChatAPIMessage] = []
        var findings: [String] = []
        for message in history {
            if message.role == "tool" {
                if case .text(let text)? = message.content {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { findings.append(trimmed) }
                }
                continue
            }
            if message.role == "assistant", message.toolCalls?.isEmpty == false {
                if case .text(let text)? = message.content,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    folded.append(ChatAPIMessage(role: "assistant", content: .text(text)))
                }
                continue
            }
            folded.append(message)
        }
        guard !findings.isEmpty else { return folded }
        // i18n-ignore: model-facing prompt
        let note = """
        [为回答上面的问题已经查到的资料]
        \(findings.joined(separator: "\n\n---\n\n"))
        [资料结束]
        请直接根据这些资料回答上面的问题，用用户的语言，必要时注明来源网址；资料不够时说明还缺什么。不要再调用工具。
        """
        folded.append(ChatAPIMessage(role: "user", content: .text(note)))
        return folded
    }

    static func formatToolResultForModel(_ text: String, toolName: String) -> String {
        let hardLimit: Int
        switch toolName {
        case "web_search":
            // Five results with dates and snippets; the reply is grounded on them.
            hardLimit = 5_000
        case "web_read":
            hardLimit = 6_000
        case "web_browse", "agent_reach":
            hardLimit = 2_400
        case "shell_execute", "shell_local", "ogent_agent", "video_downloader", "youtube_downloader", "nano_pdf", "file_read", "file_write", "file_edit":
            hardLimit = 3_200
        default:
            hardLimit = 2_400
        }
        guard text.count > hardLimit else { return text }
        let head = text.prefix(hardLimit)
        return """
        \(head)

        [tool output truncated for model context: original_chars=\(text.count), kept_chars=\(hardLimit). Use a narrower selector/query or another tool call if more detail is required.]
        """
    }

    static func projectFinalizerSnapshot() async -> String {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ToolResult, Never>) in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    cont.resume(returning: .textOnly("finalizer_snapshot=unavailable reason=ish_not_ready"))
                    return
                }
                let script = """
                \(OgentLinuxRuntime.finalizerSnapshotCommand) 2>/dev/null | sed -n '1,260p'
                """
                let result = ShellTool.runOnQueue(command: script, timeout: 15, onProgress: { _ in })
                cont.resume(returning: result)
            }
        }
        let text = (result.text ?? "")
            .replacingOccurrences(of: #"\n?\[exit=[^\n]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // i18n-ignore: model-facing prompt
        return """
        [Ogent finalizer local snapshot]
        这是 iOS 执行层在最终交付前自动读取的本机 checkpoint。即使模型没有显式调用 task_status，也必须基于这里的 completion_gates、task/artifact/plan/session/wiki/skills/subagents/profile 状态完成交付，不要继续调用工具。

        \(String(text.prefix(5_000)))
        [/Ogent finalizer local snapshot]
        """
    }

    func projectWireContentWithLocalContextIfNeeded(
        prompt: String,
        wireContent: MessageContent,
        routePlan precomputedPlan: ProjectAgentPlan? = nil
    ) async -> MessageContent {
        var prefixes: [String] = []
        let routePlan = precomputedPlan ?? ProjectAgentPlanner.plan(for: prompt, iteration: 1, executedToolCalls: 0)
        if routePlan.exposesTools {
            await Self.recordProjectRoutingDecision(prompt: prompt, plan: routePlan)
        }
        if let runtimeBrief = routePlan.runtimeBrief {
            prefixes.append(runtimeBrief)
        }
        if let profilePreflight = await OgentProjectProfilePreflight.contextPrompt(for: routePlan) {
            prefixes.append(profilePreflight)
        }
        let isContinuation = routePlan.isContinuation
        var snapshot: String?
        if isContinuation {
            let loadedSnapshot = await Self.loadProjectResumeSnapshot()
            if let loadedSnapshot,
               !loadedSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot = loadedSnapshot
                prefixes.append(Self.projectResumePrompt(prompt: prompt, snapshot: loadedSnapshot))
            }
        }
        let contextQuery = ProjectAgentPlanner.memoryQuery(prompt: prompt, snapshot: snapshot)
        if routePlan.contextPolicy == .bootstrap {
            if let bootstrapContext = await OgentProjectMemoryContextLoader.loadBootstrapContext(
                query: contextQuery,
                snapshot: snapshot,
                includeSnapshot: !isContinuation
            ) {
                prefixes.append(bootstrapContext)
            }
        } else if routePlan.contextPolicy == .memoryOnly,
                  let memory = await OgentProjectMemoryContextLoader.loadRelevantMemory(query: contextQuery) {
            prefixes.append(memory)
        } else if OgentProjectMemoryPolicy.shouldLoadRelevantMemory(for: routePlan),
                  let memory = await OgentProjectMemoryContextLoader.loadRelevantMemory(query: contextQuery) {
            prefixes.append(memory)
        }
        guard !prefixes.isEmpty else { return wireContent }
        return Self.prependingText(prefixes.joined(separator: "\n\n"), to: wireContent)
    }

    static func recordProjectRoutingDecision(prompt: String, plan: ProjectAgentPlan) async {
        let note = """
        project_route_decision
        task_kind=\(plan.kind.rawValue)
        context_policy=\(plan.contextPolicy.rawValue)
        tools=\(plan.toolSummary.isEmpty ? "none" : plan.toolSummary)
        skills=\(plan.selectedSkills.map(\.name).joined(separator: ",").isEmpty ? "none" : plan.selectedSkills.map(\.name).joined(separator: ","))
        mcp_servers=\(plan.selectedMCPServers.map(\.serverName).joined(separator: ",").isEmpty ? "none" : plan.selectedMCPServers.map(\.serverName).joined(separator: ","))
        prompt=\(String(prompt.prefix(600)))
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume()
                    return
                }
                _ = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.noteAppendCommand(note: note),
                    timeout: 8,
                    onProgress: { _ in }
                )
                continuation.resume()
            }
        }
    }

    static func loadProjectResumeSnapshot() async -> String? {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.workspaceSnapshotCommand,
                    timeout: 10,
                    onProgress: { _ in }
                )
                let output = (result.text ?? "")
                    .replacingOccurrences(of: #"\n?\[exit=[^\n]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output.isEmpty ? nil : String(output.prefix(3_500)))
            }
        }
    }

    static func projectResumePromptForSelfTest(prompt: String, snapshot: String) -> String {
        projectResumePrompt(prompt: prompt, snapshot: snapshot)
    }

    static func projectMemoryQueryForSelfTest(prompt: String, snapshot: String?) -> String {
        ProjectAgentPlanner.memoryQuery(prompt: prompt, snapshot: snapshot)
    }

    static func projectResumePrompt(prompt: String, snapshot: String) -> String {
        // i18n-ignore: model-facing prompt
        """
        [工程模式恢复上下文]
        用户这次输入很短，表示继续上一个工程任务。下面是 iPhone 本机 iSH/Ogent runtime 的最新 workspace snapshot。
        请先基于这个本机状态接续任务：不要重新开始任务，不要重复已经完成的工具步骤；如果信息还不够，优先调用 `ogent_agent workspace_snapshot` / `plan_read` / `session_read` 获取更多上下文。

        \(snapshot)
        [/工程模式恢复上下文]

        用户请求：\(prompt)
        """
    }

    static func prependingText(_ prefix: String, to content: MessageContent) -> MessageContent {
        switch content {
        case .text(let text):
            return .text("\(prefix)\n\n\(text)")
        case .parts(let parts):
            var merged = parts
            merged.insert(.text(prefix), at: 0)
            return .parts(merged)
        }
    }

    func assistantContentIsEmpty(_ id: String) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return true }
        let text = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || AssistantPendingView.isPending(text)
    }

    func assistantNeedsFinalDelivery(_ id: String) -> Bool {
        assistantNeedsFinalDelivery(id, finalizerSnapshot: nil)
    }

    func assistantNeedsFinalDelivery(_ id: String, finalizerSnapshot: String?) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return true }
        return Self.needsFinalDeliveryRepair(
            text: messages[idx].content,
            toolCalls: messages[idx].toolCalls,
            finalizerSnapshot: finalizerSnapshot
        )
    }

    func localFinalDelivery(assistantId: String, error: Error, finalizerSnapshot: String? = nil) -> String {
        localFinalDelivery(
            assistantId: assistantId,
            reason: "最终模型总结请求失败：\(userFacingErrorMessage(for: error))", // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            finalizerSnapshot: finalizerSnapshot
        )
    }

    func localFinalDelivery(assistantId: String, reason: String, finalizerSnapshot: String? = nil) -> String {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }) else {
            return ""
        }
        return Self.localFinalDelivery(
            toolCalls: messages[idx].toolCalls,
            existingText: messages[idx].content,
            failureMessage: reason,
            finalizerSnapshot: finalizerSnapshot
        )
    }

    @discardableResult
    func replaceWithLocalFinalDeliveryIfNeeded(
        assistantId: String,
        reason: String,
        finalizerSnapshot: String? = nil
    ) -> Bool {
        guard assistantNeedsFinalDelivery(assistantId, finalizerSnapshot: finalizerSnapshot) else { return false }
        let fallback = localFinalDelivery(
            assistantId: assistantId,
            reason: reason,
            finalizerSnapshot: finalizerSnapshot
        )
        guard !fallback.isEmpty else { return false }
        replacePlaceholder(assistantId, with: fallback, append: false)
        return true
    }

    func localFinalDeliveryFromPriorWork(error: Error, excluding assistantId: String) -> String? {
        let prior = messages
            .filter { $0.id != assistantId && $0.role == .assistant }
            .reversed()
            .first { !$0.toolCalls.isEmpty || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let prior else { return nil }
        let fallback = Self.localFinalDelivery(
            toolCalls: prior.toolCalls,
            existingText: prior.content,
            failureMessage: "最终模型总结请求失败：\(userFacingErrorMessage(for: error))", // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            finalizerSnapshot: nil
        )
        return fallback.isEmpty ? nil : fallback
    }

    static func localFinalDeliveryForSelfTest(
        toolCalls calls: [ToolCall],
        existingText: String,
        failureMessage: String,
        finalizerSnapshot: String? = nil
    ) -> String {
        localFinalDelivery(
            toolCalls: calls,
            existingText: existingText,
            failureMessage: failureMessage,
            finalizerSnapshot: finalizerSnapshot
        )
    }

    static func finalDeliveryNeedsRepairForSelfTest(text: String, toolCalls: [ToolCall]) -> Bool {
        needsFinalDeliveryRepair(text: text, toolCalls: toolCalls, finalizerSnapshot: nil)
    }

    static func finalDeliveryNeedsRepairForSelfTest(
        text: String,
        toolCalls: [ToolCall],
        finalizerSnapshot: String?
    ) -> Bool {
        needsFinalDeliveryRepair(text: text, toolCalls: toolCalls, finalizerSnapshot: finalizerSnapshot)
    }

    static func needsFinalDeliveryRepair(
        text rawText: String,
        toolCalls: [ToolCall],
        finalizerSnapshot: String?
    ) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || AssistantPendingView.isPending(text) { return true }
        if containsServiceFailureCopy(text) { return true }

        let checkpoint = finalizerSnapshot
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ProjectFinalizerCheckpoint(snapshot: $0) }
        let snapshotDeliverables = finalizerSnapshot.map(Self.extractDeliverablesFromSnapshot) ?? []
        let deliverables = uniqueDeliverables(
            extractDeliverables(from: toolCalls.filter { $0.status == .completed }) + snapshotDeliverables
        )

        if let checkpoint, checkpoint.shouldMarkIncomplete {
            let reportsIncomplete = text.localizedCaseInsensitiveContains("未完成") // i18n-ignore: marker matched against agent/model output
                || text.localizedCaseInsensitiveContains(checkpoint.deliveryState)
                || text.localizedCaseInsensitiveContains("失败") // i18n-ignore: marker matched against agent/model output
            if !reportsIncomplete { return true }
        }

        let finalMarkers = ["最终交付", "交付结果", "已导出", "已保存到", "未完成"] // i18n-ignore: marker matched against agent/model output
        guard finalMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) else {
            return true
        }

        if let checkpoint,
           checkpoint.requiresArtifact,
           deliverables.isEmpty {
            return !text.localizedCaseInsensitiveContains("未完成") // i18n-ignore: marker matched against agent/model output
                && !text.localizedCaseInsensitiveContains("缺少") // i18n-ignore: marker matched against agent/model output
                && !text.localizedCaseInsensitiveContains("没有可交付") // i18n-ignore: marker matched against agent/model output
        }
        guard !deliverables.isEmpty else { return false }

        let mentionsFile = deliverables.contains { item in
            text.localizedCaseInsensitiveContains(item.filename)
                || text.localizedCaseInsensitiveContains(item.path)
        }
        let mentionsOpenPath = ["iOS Documents", "文件预览", "分享入口", "已导出", "已保存到", "打开"] // i18n-ignore: marker matched against agent/model output
            .contains { text.localizedCaseInsensitiveContains($0) }
        if text.localizedCaseInsensitiveContains("未完成"), mentionsFile == false { // i18n-ignore: marker matched against agent/model output
            return true
        }
        return !(mentionsFile || mentionsOpenPath)
    }

    static func containsServiceFailureCopy(_ text: String) -> Bool {
        // i18n-ignore: substring markers matched against Chinese model/agent output
        let markers = [
            "服务暂时不可用", // i18n-ignore: substring marker
            "出错了，请重试", // i18n-ignore: substring marker
            "请稍后再试", // i18n-ignore: substring marker
            "模型服务额度不足", // i18n-ignore: substring marker
            "insufficient_user_quota",
            "upstream service unavailable"
        ]
        // `ChatErrorCopy` is localized, so in other languages its sentences no
        // longer contain the Chinese substrings above; match its translations
        // too so the repair check behaves the same in every language.
        let localizedErrorCopy = [
            String(localized: "出错了，请重试一次。"),
            String(localized: "模型服务额度不足，本地结果已保留。"),
            String(localized: "模型额度不足，请稍后再试或换一个图像模型。")
        ]
        return (markers + localizedErrorCopy).contains { text.localizedCaseInsensitiveContains($0) }
    }

    static func localFinalDelivery(
        toolCalls calls: [ToolCall],
        existingText: String,
        failureMessage: String,
        finalizerSnapshot: String? = nil
    ) -> String {
        let completed = calls.filter { $0.status == .completed }
        let failed = calls.filter { $0.status == .error }
        let snapshotHighlights = finalizerSnapshot.map(Self.finalizerSnapshotHighlights) ?? []
        let snapshotDeliverables = finalizerSnapshot.map(Self.extractDeliverablesFromSnapshot) ?? []
        let deliverables = uniqueDeliverables(extractDeliverables(from: completed) + snapshotDeliverables)
        let checkpoint = finalizerSnapshot
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ProjectFinalizerCheckpoint(snapshot: $0) }
        let latestUseful = completed
            .reversed()
            .compactMap { call -> String? in
                guard let output = call.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                    return nil
                }
                let cleaned = output
                    .replacingOccurrences(of: #"\n?\[oases:open\][^\n]*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                return "\(call.displayName ?? call.name):\n\(String(cleaned.prefix(1_800)))"
            }
            .first

        var lines = ["最终交付", ""] // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        if checkpoint?.shouldMarkIncomplete == true, deliverables.isEmpty {
            lines.append("未完成：\(checkpoint?.userFacingStatusLine ?? "本机 finalizer checkpoint 显示任务尚未达到交付条件。")") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            lines.append("原因：\(failureMessage)") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        } else if completed.isEmpty && failed.isEmpty {
            lines.append("未完成：工程模式尚未形成任何工具执行或产物。") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            lines.append("原因：\(failureMessage)") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        } else {
            lines.append("工具执行已结束，但需要由本机工程模式补全交付说明：\(failureMessage)") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        }
        lines.append("已完成工具：\(completed.count) 个；失败工具：\(failed.count) 个。") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        if let checkpoint, !checkpoint.compactSummary.isEmpty {
            lines.append("")
            lines.append("本机 checkpoint：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            for item in checkpoint.compactSummary.prefix(8) {
                lines.append("- \(item)")
            }
        }
        if !snapshotHighlights.isEmpty {
            lines.append("")
            lines.append("本机最近执行线索：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            for item in snapshotHighlights.prefix(12) {
                lines.append("- \(item)")
            }
        }
        if !deliverables.isEmpty {
            lines.append("")
            lines.append("已导出的产物：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            for item in deliverables.prefix(8) {
                lines.append("- \(item.filename)")
                lines.append("  iOS Documents: \(item.path)")
                if item.openable {
                    lines.append("  可在聊天里的文件预览/分享入口打开。") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
                }
            }
        }
        let partial = existingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\n?\[oases:open\][^\n]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty, !AssistantPendingView.isPending(partial) {
            lines.append("")
            lines.append("已生成的阶段性说明：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            lines.append(String(partial.prefix(1_200)))
        }
        if let latestUseful {
            lines.append("")
            lines.append("最新可用结果摘要：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            lines.append(latestUseful)
        }
        if !failed.isEmpty {
            lines.append("")
            lines.append("失败工具：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            for call in failed.prefix(5) {
                lines.append("- \(call.displayName ?? call.name): \(call.output ?? "无错误详情")") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
        }
        let nextStep = localFinalDeliveryNextStep(
            checkpoint: checkpoint,
            failed: failed,
            deliverables: deliverables
        )
        if !nextStep.isEmpty {
            lines.append("")
            lines.append("下一步：") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            lines.append(nextStep)
        }
        return lines.joined(separator: "\n")
    }

    static func localFinalDeliveryNextStep(
        checkpoint: ProjectFinalizerCheckpoint?,
        failed: [ToolCall],
        deliverables: [LocalDeliverable]
    ) -> String {
        if let checkpoint, checkpoint.shouldMarkIncomplete {
            let doctorCommand = checkpoint.modelDoctorNextCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let readinessCommand = checkpoint.localModelNextCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let localModelCommand = doctorCommand != "unknown" && doctorCommand != "none"
                ? doctorCommand
                : readinessCommand
            if checkpoint.expectedOutput == "local_model_runtime_report",
               !localModelCommand.isEmpty,
               localModelCommand != "unknown",
               localModelCommand != "none" {
                return "继续任务时先在 iSH/Ogent 里执行：\(localModelCommand)。完成后重新运行 `ogent_agent model_doctor` 和能力报告，直到 `real_local_model_runtime=ready` 且 `subagent_real_model_gate=ready`。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
            if checkpoint.deliveryState == "project_manifest_failed" {
                return "继续任务时先读取 project manifest 和最近失败工具 trace，按 recovery hint 改道；不要把已有 artifact 当作完整交付。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
            if checkpoint.deliveryState == "project_manifest_in_progress" {
                return "继续任务时先读取 project manifest / task_status，等待或补齐正在运行的步骤，再回到 finalizer checkpoint 验证。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
            if checkpoint.requiresArtifact, deliverables.isEmpty {
                return "继续任务时应先复用当前 Ogent session/workspace，补跑产物导出步骤（artifact_bridge 或 ogent_agent artifact_export），不要从头重做已完成的抓取/分析。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
            if checkpoint.deliveryState == "latest_task_failed" {
                return "继续任务时先读取最近失败日志，根据失败工具的 recovery hint 改道，再回到 finalizer checkpoint 验证。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
            }
            return "继续任务时先检查本机 finalizer checkpoint 的 delivery_state，并只补缺口。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        }
        if !deliverables.isEmpty {
            return "用户可以直接打开上面的 iOS Documents/文件预览路径；如果还要修改内容，请基于这些产物继续。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        }
        if !failed.isEmpty {
            return "继续任务时不要重复同一失败工具和参数，优先切换到 recovery/fallback 工具。" // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
        }
        return ""
    }

    struct LocalDeliverable: Hashable {
        let path: String
        let filename: String
        let openable: Bool
    }

    static func extractDeliverables(from calls: [ToolCall]) -> [LocalDeliverable] {
        var seen = Set<String>()
        var result: [LocalDeliverable] = []

        func append(path: String, openable: Bool) {
            let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.hasPrefix("/") || clean.hasPrefix("file://") else { return }
            guard !seen.contains(clean) else { return }
            seen.insert(clean)
            let filename = URL(fileURLWithPath: clean.replacingOccurrences(of: "file://", with: "")).lastPathComponent
            result.append(LocalDeliverable(path: clean, filename: filename.isEmpty ? clean : filename, openable: openable))
        }

        for call in calls {
            guard let output = call.output else { continue }
            for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                for marker in [("[oases:open]", true), ("ios=", false), ("ios:", false)] {
                    guard let range = line.range(of: marker.0) else { continue }
                    append(path: String(line[range.upperBound...]), openable: marker.1)
                }
            }
        }
        return result
    }

    static func extractDeliverablesFromSnapshot(_ snapshot: String) -> [LocalDeliverable] {
        var result: [LocalDeliverable] = []
        var seen = Set<String>()

        func append(path: String, openable: Bool) {
            let clean = path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            guard clean.hasPrefix("/") || clean.hasPrefix("file://") else { return }
            guard !seen.contains(clean) else { return }
            seen.insert(clean)
            let filePath = clean.replacingOccurrences(of: "file://", with: "")
            let filename = URL(fileURLWithPath: filePath).lastPathComponent
            result.append(LocalDeliverable(path: clean, filename: filename.isEmpty ? clean : filename, openable: openable))
        }

        for rawLine in snapshot.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in [("[oases:open]", true), ("ios=", true), ("ios:", true), ("iOS Documents:", true), ("guest=", false), ("guest:", false), ("path=", false), ("path:", false)] {
                guard let range = line.range(of: marker.0) else { continue }
                append(path: String(line[range.upperBound...]), openable: marker.1)
            }
            if line.hasPrefix("/root/.ogent/artifacts/") || line.hasPrefix("/var/minis/artifacts/") {
                append(path: line, openable: false)
            }
        }
        return result
    }

    static func uniqueDeliverables(_ items: [LocalDeliverable]) -> [LocalDeliverable] {
        var seen = Set<String>()
        var result: [LocalDeliverable] = []
        for item in items {
            guard !seen.contains(item.path) else { continue }
            seen.insert(item.path)
            result.append(item)
        }
        return result
    }

    static func finalizerSnapshotHighlights(_ snapshot: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let interestingNeedles = [
            "delivery_state=",
            "artifact_count=",
            "project_manifest_status=",
            "project_manifest_state=",
            "local_model_readiness_state=",
            "local_model_readiness_reason=",
            "local_model_next_command=",
            "model_doctor_status=",
            "model_doctor_next_command=",
            "real_local_model_runtime=",
            "subagent_real_model_gate=",
            "model_provider_note=",
            "mcp_12306_upstream=",
            "mcp_12306_shim=",
            "latest_task_exit=",
            "project_tool_trace",
            "- tool:",
            "- status:",
            "- output_digest:",
            "- recovery_hint:",
            "ios=",
            "path=",
            "guest=",
            "[exit=",
            "error",
            "failed",
            "failed_subagent_tasks=",
            "ready_to_summarize"
        ]

        for rawLine in snapshot.split(separator: "\n", omittingEmptySubsequences: false) {
            let clean = String(rawLine)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            guard interestingNeedles.contains(where: { clean.localizedCaseInsensitiveContains($0) }) else {
                continue
            }
            let item = String(clean.prefix(260))
            guard !seen.contains(item) else { continue }
            seen.insert(item)
            result.append(item)
            if result.count >= 18 { break }
        }
        return result
    }

    static func toolWatchdogTimeout(for call: ToolCall) -> TimeInterval {
        let declared = declaredToolTimeout(for: call)
        if declared <= 0 {
            return call.name == "shell_execute" || call.name == "shell_local" || isOgentAgentTool(call.name) ? 30 * 60 : 5 * 60
        }
        if call.name == "shell_execute" || call.name == "shell_local" || isOgentAgentTool(call.name) {
            return max(declared + 90, 5 * 60)
        }
        return max(declared + 30, 2 * 60)
    }

    static func isOgentAgentTool(_ name: String) -> Bool {
        name == "ogent_agent"
    }

    static func declaredToolTimeout(for call: ToolCall) -> TimeInterval {
        guard let data = call.inputJSON?.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        if let number = dict["timeout"] as? NSNumber {
            return number.doubleValue
        }
        if let double = dict["timeout"] as? Double {
            return double
        }
        return 0
    }

    /// Image generation — one-shot JSON. Mirrors Web `sendImage`.
    func sendImage(prompt: String, referenceImages: [String] = [], assistantId: String) async {
        let model = currentModel
        let effortValue = effort.rawValue
        let chatService = service
        let resolvedModel = ProviderChatRouting.vendorModelId(for: model)
            ?? Models.sanitizedId(model, category: .image)
        let plan = ImageGenerationPlan.forRequest(model: resolvedModel, prompt: prompt)
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].imageGenerationPlan = plan
        }
        currentTask = AIRequestGate.startRun { [weak self] in
            do {
                let url = try await chatService.generateImage(prompt: prompt,
                                                              model: model,
                                                              effort: effortValue,
                                                              referenceImages: referenceImages,
                                                              plan: plan)
                // Remote image URLs from image providers are temporary. Keep
                // the original URL if materialisation fails so a retryable
                // image view can still try it; never replace a valid result
                // with an error placeholder.
                try Task.checkCancellation()
                let persistedURL = await GeneratedImageLoader.materializedDataURL(source: url) ?? url
                try Task.checkCancellation()
                await MainActor.run {
                    self?.setImageMessage(id: assistantId, url: persistedURL, text: String(localized: "图片已生成。"))
                }
                if self?.finishStreaming(assistantId: assistantId, success: true) == true {
                    self?.persistAssistantMessage(id: assistantId)
                }
            } catch is CancellationError {
                self?.finishStreaming(assistantId: assistantId, success: false)
            } catch {
                self?.failStreaming(assistantId: assistantId, error: error)
            }
        }
    }

    /// TTS — non-streaming chat/completions with the TTS model. Mirrors Web `sendTts`.
    func sendAudio(prompt: String, assistantId: String) async {
        let model = currentModel
        let chatService = service
        currentTask = AIRequestGate.startRun { [weak self] in
            do {
                let (url, mime) = try await chatService.synthesizeSpeech(text: prompt, model: model)
                try Task.checkCancellation()
                await MainActor.run {
                    self?.setAudioMessage(id: assistantId, url: url, mime: mime, text: String(localized: "语音已生成。"))
                }
                if self?.finishStreaming(assistantId: assistantId, success: true) == true {
                    self?.persistAssistantMessage(id: assistantId)
                }
            } catch is CancellationError {
                self?.finishStreaming(assistantId: assistantId, success: false)
            } catch {
                self?.failStreaming(assistantId: assistantId, error: error)
            }
        }
    }


}
