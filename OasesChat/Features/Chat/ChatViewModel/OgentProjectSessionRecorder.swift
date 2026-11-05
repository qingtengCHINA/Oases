// i18n-ignore-file: Ogent session/plan/manifest records written to the iSH workspace for the agent, and self-tests; no UI copy.

enum OgentProjectSessionRecorder {
    static func recordTurnStart(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        plan: ProjectAgentPlan
    ) async -> OgentProjectTurnHandle? {
        let planWritten = plan.exposesTools
            ? await writePlan(
                title: conversationTitle.isEmpty ? "Ogent 工程任务" : conversationTitle,
                steps: hostPlanSteps(for: plan, userPrompt: userPrompt)
            )
            : true
        let body = sessionNoteBody(
            conversationTitle: conversationTitle,
            conversationID: conversationID,
            model: model,
            userPrompt: userPrompt,
            plan: plan,
            planWritten: planWritten,
            marker: nil
        )
        if let sessionID = await startSession(title: conversationTitle.isEmpty ? "project-turn" : conversationTitle) {
            let projectID = await startProjectManifest(
                title: conversationTitle.isEmpty ? "Ogent 工程任务" : conversationTitle,
                sessionID: sessionID,
                body: body
            )
            let noteBody = projectID.map { body + "\n- project_id: \($0)" } ?? body
            let wrote = await writeSessionNote(noteBody, sessionID: sessionID)
            return (planWritten && wrote) ? OgentProjectTurnHandle(sessionID: sessionID, projectID: projectID) : nil
        }
        let wrote = await writeSessionNote(body, sessionID: nil)
        if planWritten && wrote {
            let snapshot = await readWorkspaceSnapshot()
            if let sessionID = extractCurrentSessionID(from: snapshot) {
                return OgentProjectTurnHandle(
                    sessionID: sessionID,
                    projectID: extractCurrentProjectID(from: snapshot)
                )
            }
        }
        return nil
    }

    static func recordLifecycleEvent(
        event: String,
        state: ProjectAgentExecutionState,
        model: String,
        userPrompt: String,
        reason: String? = nil,
        finalizerSnapshot: String? = nil,
        sessionID: String? = nil,
        projectID: String? = nil
    ) async -> Bool {
        let note = ProjectLifecycleTrace.sessionNote(
            event: event,
            state: state,
            model: model,
            userPrompt: userPrompt,
            reason: reason,
            finalizerSnapshot: finalizerSnapshot
        )
        let sessionWrote = await writeSessionNote(note, sessionID: sessionID)
        let hasProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let manifestWrote = await recordManifestEvent(
            projectID: projectID,
            status: manifestStatus(for: event, state: state),
            event: "lifecycle:\(event)",
            body: note
        )
        return sessionWrote && (!hasProjectID || manifestWrote)
    }

    static func runSelfTest() async -> String {
        let marker = "ogent_auto_session_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let body = sessionNoteBody(
            conversationTitle: "selftest",
            conversationID: "selftest",
            model: "selftest",
            userPrompt: "auto session selftest",
            plan: ProjectAgentPlanner.plan(
                for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档",
                iteration: 1,
                executedToolCalls: 0
            ),
            planWritten: true,
            marker: marker
        )
        guard let sessionID = await startSession(title: "auto-session-selftest") else {
            return "auto_session_failed: session start failed"
        }
        let wrote = await writeSessionNote(body, sessionID: sessionID)
        guard wrote else {
            return "auto_session_failed: write failed"
        }
        let read = await readSession(sessionID)
        return read.contains(marker) ? "auto_session_ok marker=\(marker)" : "auto_session_failed: marker missing"
    }

    static func runLifecycleTraceSelfTest() async -> String {
        let marker = "ogent_lifecycle_trace_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        guard let sessionID = await startSession(title: "lifecycle-trace-selftest") else {
            return "lifecycle_trace_failed marker=\(marker) session=false"
        }
        var state = ProjectAgentExecutionState(
            initialPlan: ProjectAgentPlanner.plan(
                for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档",
                iteration: 1,
                executedToolCalls: 0
            )
        )
        _ = state.beginIteration()
        state.recordToolCalls(1, maxIterations: 18)
        state.beginFinalization()
        let snapshot = """
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        completion_contract=web_research_to_user_artifact
        expected_output=web_research_exported_artifact
        requires_artifact=true
        finalizer_gate=must_reference_exported_artifact_or_mark_missing
        artifact_count=1
        delivery_state=ready_to_summarize
        - kind: project_lifecycle_trace
        - reason: \(marker)
        """
        let wrote = await recordLifecycleEvent(
            event: "enter_finalizer",
            state: state,
            model: "selftest",
            userPrompt: "验证工程生命周期 trace 会写入 Ogent session \(marker)",
            reason: "selftest lifecycle marker \(marker)",
            finalizerSnapshot: snapshot
        )
        let tail = await readSessionTail(sessionID, lines: 120)
        let finalizer = await ChatViewModel.projectFinalizerSnapshot()
        let passed = wrote
            && tail.contains("project_lifecycle_trace")
            && tail.contains("enter_finalizer")
            && tail.contains(marker)
            && tail.contains("Recovery policy")
            && finalizer.contains("--- recent session ---")
            && finalizer.contains(marker)
        return passed
            ? "lifecycle_trace_ok marker=\(marker)"
            : "lifecycle_trace_failed marker=\(marker) wrote=\(wrote) tail_has_marker=\(tail.contains(marker)) finalizer_has_marker=\(finalizer.contains(marker))\nTAIL:\(String(tail.prefix(1_200)))\nSNAPSHOT:\(String(finalizer.prefix(1_200)))"
    }

    static func runHostPreflightSelfTest() async -> String {
        let marker = "ogent_host_preflight_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let plan = ProjectAgentPlanner.plan(
            for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档 \(marker)",
            iteration: 1,
            executedToolCalls: 0
        )
        let handle = await recordTurnStart(
            conversationTitle: "host-preflight-selftest",
            conversationID: "selftest-\(marker)",
            model: "selftest",
            userPrompt: "帮我爬取 oilprice.com 三天新闻并写入 word 文档 \(marker)",
            plan: plan
        )
        let sessionID = handle?.sessionID
        let projectID = handle?.projectID
        let snapshot = await readWorkspaceSnapshot()
        let currentSessionID = extractCurrentSessionID(from: snapshot)
        let currentProjectID = extractCurrentProjectID(from: snapshot)
        let session = await readSession(sessionID ?? currentSessionID ?? "")
        let manifest = await readProjectManifest(projectID ?? currentProjectID ?? "")
        let combined = snapshot + "\n" + session + "\n" + manifest
        let contract = plan.completionContract
        let passed = sessionID != nil
            && projectID != nil
            && currentSessionID == sessionID
            && currentProjectID == projectID
            && combined.contains(marker)
            && combined.contains("current_session=\(sessionID ?? "")")
            && combined.contains("current_project=\(projectID ?? "")")
            && combined.contains("project_manifest_ok")
            && combined.contains("project_id=\(projectID ?? "")")
            && combined.contains("task_kind: \(plan.kind.rawValue)")
            && combined.contains("tools_exposed: \(plan.toolSummary)")
            && combined.contains("completion_contract: \(contract.summary)")
            && combined.contains("requires_artifact: \(contract.requiresArtifact ? "true" : "false")")
            && (combined.contains("skills_selected: agent-reach") || combined.contains("只加载本轮相关技能：agent-reach"))
            && combined.contains("Ogent host preflight")
        return passed
            ? "host_preflight_ok marker=\(marker)"
            : "host_preflight_failed marker=\(marker) sessionID=\(sessionID ?? "nil") projectID=\(projectID ?? "nil") currentSession=\(currentSessionID ?? "nil") currentProject=\(currentProjectID ?? "nil")\n\(String(combined.prefix(4_000)))"
    }

    static func runToolTraceSelfTest() async -> String {
        let marker = "ogent_tool_trace_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        guard let sessionID = await startSession(title: "tool-trace-selftest") else {
            return "tool_trace_failed marker=\(marker) session=false"
        }
        let filler = (1...220)
            .map { "- filler_line_\($0) keeps tool trace beyond session head" }
            .joined(separator: "\n")
        _ = await writeSessionNote(filler, sessionID: sessionID)
        let note = ProjectToolTrace.sessionNote(
            call: ToolCall(
                id: "tool-trace-selftest",
                name: "artifact_bridge",
                displayName: "Artifacts",
                status: .completed,
                inputJSON: #"{"action":"create_docx"}"#,
                output: "Created DOCX: tool-trace-\(marker).docx\nios=/tmp/Ogent Artifacts/tool-trace-\(marker).docx\n[exit=0]",
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2)
            ),
            iteration: 1,
            model: "selftest",
            userPrompt: "验证工程工具 trace 会写入 Ogent session \(marker)"
        )
        let wrote = await writeSessionNote(note, sessionID: sessionID)
        let read = await readSession(sessionID)
        let tail = await readSessionTail(sessionID, lines: 120)
        let snapshot = await ChatViewModel.projectFinalizerSnapshot()
        let passed = wrote
            && !read.contains(marker)
            && tail.contains("project_tool_trace")
            && tail.contains("artifact_bridge")
            && tail.contains(marker)
            && snapshot.contains("--- recent session ---")
            && snapshot.contains(marker)
        return passed
            ? "tool_trace_ok marker=\(marker)"
            : "tool_trace_failed marker=\(marker) wrote=\(wrote) head_has_marker=\(read.contains(marker)) tail_has_marker=\(tail.contains(marker)) snapshot_has_marker=\(snapshot.contains(marker))\nHEAD:\(String(read.prefix(1_200)))\nTAIL:\(String(tail.prefix(1_200)))\nSNAPSHOT:\(String(snapshot.prefix(1_200)))"
    }

    private static func writePlan(title: String, steps: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: false)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.planWriteCommand(title: title, steps: steps),
                    timeout: 10,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                continuation.resume(returning: text.contains("[exit=0") && text.contains("plan saved"))
            }
        }
    }

    private static func readWorkspaceSnapshot() async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.workspaceSnapshotCommand,
                    timeout: 10,
                    onProgress: { _ in }
                )
                continuation.resume(returning: result.text ?? "")
            }
        }
    }

    private static func extractCurrentSessionID(from snapshot: String) -> String? {
        snapshot
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("current_session=") else { return nil }
                let value = line.dropFirst("current_session=".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value == "none" ? nil : value
            }
            .first
    }

    private static func extractCurrentProjectID(from snapshot: String) -> String? {
        snapshot
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("current_project=") else { return nil }
                let value = line.dropFirst("current_project=".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value == "none" ? nil : value
            }
            .first
    }

    private static func extractProjectID(from text: String) -> String? {
        text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("project_id=") else { return nil }
                let value = line.dropFirst("project_id=".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value == "none" ? nil : value
            }
            .last
    }

    private static func startProjectManifest(title: String, sessionID: String, body: String) async -> String? {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.projectManifestStartCommand(title: title, sessionID: sessionID, body: body),
                    timeout: 10,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                guard text.contains("[exit=0") || text.contains("project_manifest_start_ok") else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: extractProjectID(from: text))
            }
        }
    }

    static func recordManifestEvent(projectID: String?, status: String, event: String, body: String) async -> Bool {
        guard let projectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectID.isEmpty else {
            return false
        }
        return await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: false)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.projectManifestUpdateCommand(
                        projectID: projectID,
                        status: status,
                        event: event,
                        body: body
                    ),
                    timeout: 12,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                continuation.resume(returning: text.contains("[exit=0") || text.contains("project_manifest_update_ok"))
            }
        }
    }

    static func readProjectManifest(_ projectID: String, tailLines: Int = 160) async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.projectManifestReadCommand(projectID: projectID, tailLines: tailLines),
                    timeout: 10,
                    onProgress: { _ in }
                )
                continuation.resume(returning: result.text ?? "")
            }
        }
    }

    private static func manifestStatus(for event: String, state: ProjectAgentExecutionState) -> String {
        let lowered = event.lowercased()
        if lowered.contains("completed") {
            return "completed"
        }
        if lowered.contains("fallback") {
            return "local_fallback"
        }
        if lowered.contains("error") || lowered.contains("failure") {
            return "recovering"
        }
        if lowered.contains("finalizer") {
            return "finalizing"
        }
        return state.phase.rawValue
    }

    private static func startSession(title: String) async -> String? {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: nil)
                    return
                }
                let previousSnapshot = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.workspaceSnapshotCommand,
                    timeout: 10,
                    onProgress: { _ in }
                ).text ?? ""
                let previousSessionID = extractCurrentSessionID(from: previousSnapshot)
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionStartCommand(title: title),
                    timeout: 10,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                let idFromOutput = text
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        guard let range = line.range(of: "session started -> ") else { return nil }
                        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .last
                if let idFromOutput, !idFromOutput.isEmpty, text.contains("[exit=0") {
                    continuation.resume(returning: idFromOutput)
                    return
                }

                // Very short guest commands can close stdout in the same
                // scheduler slice as process exit. The command still commits
                // its session files, so read the durable current-session
                // pointer before treating startup as a failure.
                let snapshot = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.workspaceSnapshotCommand,
                    timeout: 10,
                    onProgress: { _ in }
                ).text ?? ""
                if let recoveredID = extractCurrentSessionID(from: snapshot),
                   recoveredID != previousSessionID {
                    continuation.resume(returning: recoveredID)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func writeSessionNote(_ body: String, sessionID: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: false)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionNoteCommand(sessionID: sessionID ?? "", note: body),
                    timeout: 10,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                continuation.resume(returning: text.contains("[exit=0") || text.contains("session note appended ->"))
            }
        }
    }

    private static func readSession(_ sessionID: String) async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionReadCommand(sessionID: sessionID),
                    timeout: 10,
                    onProgress: { _ in }
                )
                continuation.resume(returning: result.text ?? "")
            }
        }
    }

    private static func readSessionTail(_ sessionID: String, lines: Int) async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionReadCommand(sessionID: sessionID, tailLines: lines),
                    timeout: 10,
                    onProgress: { _ in }
                )
                continuation.resume(returning: result.text ?? "")
            }
        }
    }

    private static func sessionNoteBody(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        plan: ProjectAgentPlan,
        planWritten: Bool,
        marker: String?
    ) -> String {
        let contract = plan.completionContract
        var lines: [String] = [
            "## 工程回合开始",
            "- kind: ogent_host_preflight",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- conversation_title: \(conversationTitle)",
            "- conversation_id: \(conversationID)",
            "- model: \(model)",
            "- task_kind: \(plan.kind.rawValue)",
            "- context_policy: \(plan.contextPolicy.rawValue)",
            "- tools_exposed: \(plan.toolSummary.isEmpty ? "none" : plan.toolSummary)",
            "- skills_selected: \(plan.selectedSkills.map(\.name).joined(separator: ",").isEmpty ? "none" : plan.selectedSkills.map(\.name).joined(separator: ","))",
            "- mcp_servers_selected: \(plan.selectedMCPServers.map(\.serverName).joined(separator: ",").isEmpty ? "none" : plan.selectedMCPServers.map(\.serverName).joined(separator: ","))",
            "- completion_contract: \(contract.summary)",
            "- expected_output: \(contract.expectedOutput)",
            "- requires_artifact: \(contract.requiresArtifact ? "true" : "false")",
            "- finalizer_gate: \(contract.finalizerGate)",
            "- plan_written: \(planWritten ? "true" : "false")",
            "- delivery_guard: finalizer_reads_task_status_and_artifacts"
        ]
        if let marker {
            lines.append("- session_marker: \(marker)")
        }
        if !plan.selectedSkills.isEmpty {
            lines.append("")
            lines.append("### 本轮选中的技能")
            for skill in plan.selectedSkills {
                let tool = skill.toolName.map { " tool=\($0)" } ?? ""
                lines.append("- \(skill.name)\(tool): \(skill.reason)")
            }
        }
        if !plan.selectedMCPServers.isEmpty {
            lines.append("")
            lines.append("### 本轮选中的 MCP server")
            for server in plan.selectedMCPServers {
                lines.append("- \(server.serverName): \(server.reason)")
            }
        }
        lines.append("")
        lines.append("### 用户目标")
        lines.append(truncate(userPrompt.isEmpty ? "(empty)" : userPrompt, limit: 2_000))
        lines.append("")
        lines.append("### Ogent host preflight")
        for step in hostPlanSteps(for: plan, userPrompt: userPrompt) {
            lines.append("- \(step)")
        }
        return lines.joined(separator: "\n")
    }

    private static func hostPlanSteps(for plan: ProjectAgentPlan, userPrompt: String) -> [String] {
        let goal = truncate(
            userPrompt
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 140
        )
        var steps: [String] = [
            "确认用户目标和约束：\(goal.isEmpty ? "(empty)" : goal)",
            "按本机 planner 暴露最小工具集合：\(plan.toolSummary.isEmpty ? "none" : plan.toolSummary)"
        ]
        if !plan.selectedSkills.isEmpty {
            steps.append("只加载本轮相关技能：\(plan.selectedSkills.map(\.name).joined(separator: ","))")
        }
        if plan.toolNames.contains("web_search") || plan.toolNames.contains("web_browse") || plan.toolNames.contains("agent_reach") {
            steps.append("完成网页发现/浏览，保留 URL、cookie session 和可复用抓取结果。")
        }
        if plan.toolNames.contains("ogent_agent")
            || plan.toolNames.contains("shell_execute")
            || plan.toolNames.contains("shell_local") {
            steps.append("在 iSH/Ogent workspace 中执行脚本或命令，并保存日志。")
        }
        if plan.toolNames.contains("artifact_bridge") {
            steps.append("把用户可用产物导出到 iOS Documents/Ogent Artifacts。")
        }
        if plan.toolNames.contains("mcp_status") || plan.toolNames.contains("mcp_call") {
            steps.append("按需发现并调用已启用 MCP server，不发送无关 MCP schemas。")
        }
        if plan.toolNames.contains("train_ticket_12306") {
            steps.append("通过内置 12306 MCP 窄封装查询站点码、余票、中转或经停信息。")
        }
        if plan.toolNames.contains("metal_bridge") {
            steps.append("通过 iOS host-side Metal bridge 验证 GPU 能力，不在 iSH 内直接访问 Metal。")
        }
        steps.append("最终前读取 task_status、artifact_list 和 plan_read，必须给出最终交付或明确失败点。")
        return steps
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n...[truncated \(text.count - limit) chars]"
    }
}

