import Foundation

/// Identity + capability descriptor for one agent surface (chat,
/// project, future voice-agent, …). The agent loop reads this to
/// decide which tools to advertise, which system prompt to send,
/// and which permission policy applies.
struct AgentProfile {
    let id: String
    let surface: AgentSurface
    let displayName: String
    let systemPrompt: String
    /// Names of the tools this agent exposes (subset of registry).
    /// Empty means "every registered tool for this surface".
    let toolAllowlist: Set<String>
    /// Default model id used when the user hasn't picked one.
    let defaultModelId: String

    func descriptors() -> [ToolDescriptor] {
        let all = ToolRegistry.shared.descriptors(for: surface)
        return toolAllowlist.isEmpty
            ? all
            : all.filter { toolAllowlist.contains($0.name) }
    }
}

/// Catalogue of the agents this app ships with. New profiles
/// (custom user agents, MCP-imported agents) plug in here later
/// without touching the chat loop.
enum AgentCatalogue {
    static let chat = AgentProfile(
        id: "oases.chat",
        surface: .chat,
        displayName: "Oases Chat",
        // i18n-ignore: model-facing system prompt
        systemPrompt: """
        你是简洁的技术专家，同时也是一个无所不知的 AI 助手。没有空洞，只有事实。但同时也不要丢掉幽默感，适当时候可以尖锐直率一些。
        你可以联网：问题涉及新闻、近期事件、价格、天气、赛程、版本号等可能在训练数据之后变化的信息时，直接调用 web_search（最近的新闻用 freshness=day 或 week），一次搜索通常就够；用户给了链接、或摘要不足以回答时才用 web_read 读那一页。
        回答时直接给结论，在用到的事实后面用 Markdown 链接注明来源；不要复述你调用了什么工具、搜了什么关键词，界面会自己显示。
        需要其他外部能力（生成图片、朗读、查日历、提醒事项、通讯录、照片、定位、剪贴板、记忆）时，调用对应的工具。普通对话和知识问答直接回答，不要无故调用工具。
        """,
        toolAllowlist: [], // expose every chat-surface tool
        defaultModelId: Models.defaultChat
    )

    static let project = AgentProfile(
        id: "oases.project",
        surface: .project,
        displayName: "Ogent",
        // i18n-ignore: model-facing system prompt
        systemPrompt: """
        你是 Ogent，Oases Chat 的工程模式代理。你是一个私有设备端 AI 智能体：工程步骤优先在用户 iPhone 本机执行，主工作台是 iSH Alpine Linux 沙箱里的持久 Ogent runtime。模型推理可以走 Oases 端点或用户自定义 provider，但工具执行、workspace、产物、MCP、技能、子代理和 wiki/RAG 都必须保持在设备端。

        运行规则：
        - 不要假设所有工具都可用；当前回合能用的能力会由本机 planner 以“工程模式运行 brief”提供，并且 tools schema 也只包含本轮必要工具。
        - 任务开头先用一句话拆出最小可执行计划，然后逐步用工具推进。
        - 不要把计划只写在聊天文字里；需要跨轮保留的计划、观察、产物位置必须写入 Linux-side Ogent runtime。
        - 最终回复前，如果本轮调用过工程工具，先用 `ogent_agent task_status` 检查最近任务、产物和 plan 状态，避免漏交付或误判任务完成。
        - 工具结果会自动出现在对话里，不要在文字里重复贴一遍；简短说明下一步即可。
        - 不能只停在工具调用列表。每个任务必须以"最终交付"结束，并且最终回复必须以“最终交付”开头：明确说明已完成什么、产物文件名、是否已导出到 iOS Documents/可预览分享；如果失败，说明失败点、已保留的日志/产物和下一步。
        - 涉及破坏性操作（rm -rf、覆盖已存在文件、安装系统包）前先简短确认。
        """,
        toolAllowlist: [], // expose every project-surface tool
        defaultModelId: Models.defaultProject
    )

    static func profile(for mode: AppMode) -> AgentProfile {
        switch mode {
        case .chat: return chat
        case .project: return project
        case .image, .tts: return chat // fallback — these modes don't use tools yet
        }
    }
}

/// Host-side planning layer for project mode.
///
/// This is intentionally outside `ChatViewModel`: the view model owns UI
/// streaming, while the agent layer owns intent classification, tool exposure,
/// and context budget decisions. The model should not receive every skill and
/// MCP schema by default; this planner exposes only the capabilities relevant
/// to the current task and iteration.
struct ProjectSkillSelection: Equatable {
    let name: String
    let toolName: String?
    let reason: String
}

struct ProjectMCPSelection: Equatable {
    let serverName: String
    let reason: String
}

struct ProjectAgentPlan: Equatable {
    enum TaskKind: String {
        case conversation
        case generalProject
        case linuxWork
        case webResearch
        case webDeliverable
        case artifact
        case media
        case mcp
        case diagnostics
        case systemSkill
        case metal
        case localModel
    }

    enum ContextPolicy: String {
        case none
        case memoryOnly
        case bootstrap
    }

    let kind: TaskKind
    let toolNames: Set<String>
    let contextPolicy: ContextPolicy
    let isContinuation: Bool
    var selectedSkills: [ProjectSkillSelection] = []
    var selectedMCPServers: [ProjectMCPSelection] = []

    var exposesTools: Bool { !toolNames.isEmpty }

    var completionContract: ProjectCompletionContract {
        ProjectCompletionContract(plan: self)
    }

    var toolSummary: String {
        toolNames.sorted().joined(separator: ",")
    }

    var logSummary: String {
        let skills = selectedSkills.map(\.name).joined(separator: ",")
        let mcp = selectedMCPServers.map(\.serverName).joined(separator: ",")
        return "kind=\(kind.rawValue) context=\(contextPolicy.rawValue) tools=\(toolSummary) skills=\(skills) mcp=\(mcp)"
    }

    var runtimeBrief: String? {
        guard exposesTools else { return nil }
        let contract = completionContract
        var lines = [
            // i18n-ignore: model-facing runtime brief
            "[工程模式运行 brief]",
            "task_kind=\(kind.rawValue)",
            "tools_exposed=\(toolSummary)",
            "skills_selected=\(selectedSkills.map(\.name).joined(separator: ","))",
            "mcp_servers_selected=\(selectedMCPServers.map(\.serverName).joined(separator: ","))",
            "context_policy=\(contextPolicy.rawValue)",
            "completion_contract=\(contract.summary)",
            "expected_output=\(contract.expectedOutput)",
            "requires_artifact=\(contract.requiresArtifact ? "true" : "false")",
            "",
            // i18n-ignore: model-facing runtime brief
            "本机 planner 已经只暴露本轮需要的工具。不要要求用户配置额外 provider；未配置自定义 provider 时模型默认走 Oases 端点。"
        ]

        if isContinuation {
            // i18n-ignore: model-facing runtime brief
            lines.append("这是继续/恢复任务：先复用已有 Ogent workspace、plan、sessions 和 artifacts，不要从零开始。")
        }
        if toolNames.contains("ogent_agent") {
            // i18n-ignore: model-facing runtime brief
            lines.append("多步骤工程工作进入 `ogent_agent`：先 plan_write/session_start，再 run_script；最终前用 task_status/artifact_list 检查交付状态。")
        }
        if toolNames.contains("shell_execute") || toolNames.contains("shell_local") {
            // i18n-ignore: model-facing runtime brief
            lines.append("一次性 Linux 检查可用 `shell_execute`；长任务显式设置 timeout，通常 300-1200 秒。工作区路径：`/var/oases/workspace`。")
        }
        if toolNames.contains("web_browse") || toolNames.contains("web_search") || toolNames.contains("agent_reach") {
            // i18n-ignore: model-facing runtime brief
            lines.append("网页任务优先 `web_search` / `agent_reach search` 找入口，再用 `web_browse` 驱动持久 WebKit 浏览器；cookie 保存在会话里。网页失败是可恢复状态，换 Agent Reach/Jina reader 或已有页面结果继续，不要反复改 iSH DNS。")
        }
        if toolNames.contains("artifact_bridge") {
            // i18n-ignore: model-facing runtime brief
            lines.append("用户要 PPTX/DOCX/下载文件时优先 `artifact_bridge`，直接导出到 iOS Documents/Ogent Artifacts；已有 guest artifact 可用 `ogent_agent artifact_export`。")
        }
        if toolNames.contains("mcp_status") || toolNames.contains("mcp_tools") || toolNames.contains("mcp_call") {
            // i18n-ignore: model-facing runtime brief
            lines.append("MCP 任务先 `mcp_status`，再 `mcp_tools` 发现当前启用 server，最后 `mcp_call`。STDIO 在 iSH 内启动并注入环境变量，HTTP 使用 JSON-RPC POST。")
        }
        if toolNames.contains("train_ticket_12306") {
            // i18n-ignore: model-facing runtime brief
            lines.append("铁路/12306 任务优先用 `train_ticket_12306`，它是内置 12306 MCP 的窄封装；可执行 station_code_by_city、station_code_by_name、tickets、interline_tickets、train_route。只在需要未知工具 schema 时再退回 `mcp_tools`/`mcp_call`。")
        }
        if toolNames.contains("ogent_health_check") || toolNames.contains("ogent_capability_report") {
            // i18n-ignore: model-facing runtime brief
            lines.append("诊断/目标验收必须同时解释本机执行层和模型端点：`ogent_capability_report_ok` 不等于全部完成，`halo_target_complete` 和 completion_gates 才是总 gate。")
        }
        if !toolNames.intersection(["calendar_read", "reminder_create", "contact_search", "photo_list", "location_current"]).isEmpty {
            // i18n-ignore: model-facing runtime brief
            lines.append("iOS 原生数据源只读取必要摘要。")
        }
        if !toolNames.intersection(["youtube_downloader", "video_downloader", "svg_logo_fetcher", "nano_pdf"]).isEmpty {
            // i18n-ignore: model-facing runtime brief
            lines.append("媒体/文件技能按需调用：视频下载走 downloader 并自动导出，SVG logo 保存到 Ogent Artifacts，PDF 编辑走 nano_pdf。")
        }
        if !selectedSkills.isEmpty {
            // i18n-ignore: model-facing runtime brief
            lines.append("本轮已由本机 skill planner 选中少量相关技能；只围绕这些技能行动，不要请求或展开全部技能定义：")
            for skill in selectedSkills.prefix(5) {
                let tool = skill.toolName.map { " tool=\($0)" } ?? ""
                lines.append("- \(skill.name)\(tool): \(skill.reason)")
            }
        }
        if !selectedMCPServers.isEmpty {
            // i18n-ignore: model-facing runtime brief
            lines.append("本轮已由本机 MCP planner 选中可能相关 server；先用 `mcp_tools` 定向发现这些 server，再按需 `mcp_call`，不要枚举无关 server：")
            for server in selectedMCPServers.prefix(5) {
                lines.append("- \(server.serverName): \(server.reason)")
            }
            if selectedMCPServers.contains(where: { $0.serverName.localizedCaseInsensitiveContains("12306") }) {
                // i18n-ignore: model-facing runtime brief
                lines.append("内置 12306 MCP 使用 iSH 本机 `ogent-agent mcp-12306-server` stdio 入口；运行时优先使用上游 `Joooook/12306-mcp` npm 包，iSH 网络或 npm 不可用时自动退回 Oases shim。模型侧优先调用 `train_ticket_12306`，只有需要未知 schema 时再用 `mcp_tools`/`mcp_call`。")
            }
        }
        if toolNames.contains("metal_bridge") {
            // i18n-ignore: model-facing runtime brief
            lines.append("iSH 不能直接 import iOS Metal framework；GPU 能力必须通过 host-side `metal_bridge`，不要在 Linux 内寻找 Metal 设备。")
        }
        if kind == .localModel {
            // i18n-ignore: model-facing runtime brief
            lines.append("本机模型任务必须区分 routing harness 和真实推理：先用 `ogent_agent model_readiness` 读取 iSH readiness manifest，再用 `ogent_agent model_plan` 审计依赖、llama-server、GGUF、配置和 `real_local_model_runtime` gate，并按 `local_model_next_command` / `model_deployment_next_command` 执行；有 GGUF URL 时再用 `model_provision` 一键完成 profile、runner、GGUF、真实启动与 probe。缺 GGUF 时用 `model_install_gguf` 下载用户提供的 GGUF URL，缺 runner 时用 `model_build_llama`；启动时传 `requireRealModel=true`，不要把 compatibility harness 当作完成。")
        }
        // i18n-ignore: model-facing runtime brief
        lines.append("必须以“最终交付”结束，说明完成项、产物文件名/导出位置或失败点与下一步。")
        // i18n-ignore: model-facing runtime brief
        lines.append("[/工程模式运行 brief]")
        return lines.joined(separator: "\n")
    }
}

struct ProjectCompletionContract: Equatable {
    let expectedOutput: String
    let requiresArtifact: Bool
    let summary: String
    let finalizerGate: String

    init(plan: ProjectAgentPlan) {
        let toolNames = plan.toolNames
        let toolRequiresArtifact = !toolNames.intersection([
            "artifact_bridge",
            "youtube_downloader",
            "video_downloader",
            "nano_pdf",
            "svg_logo_fetcher"
        ]).isEmpty

        switch plan.kind {
        case .conversation:
            expectedOutput = "direct_answer"
            requiresArtifact = false
            summary = "answer_only"
            finalizerGate = "answer_must_address_user_prompt"
        case .webResearch:
            expectedOutput = "research_summary_with_sources"
            requiresArtifact = toolRequiresArtifact
            summary = toolRequiresArtifact ? "web_research_plus_exported_artifact" : "web_research_answer"
            finalizerGate = toolRequiresArtifact ? "must_reference_exported_artifact_or_mark_missing" : "must_include_findings_and_sources"
        case .webDeliverable:
            expectedOutput = "web_research_exported_artifact"
            requiresArtifact = true
            summary = "web_research_to_user_artifact"
            finalizerGate = "must_reference_exported_artifact_or_mark_missing"
        case .artifact:
            expectedOutput = "exported_artifact"
            requiresArtifact = true
            summary = "artifact_creation"
            finalizerGate = "must_reference_exported_artifact_or_mark_missing"
        case .media:
            expectedOutput = "exported_media_or_file"
            requiresArtifact = true
            summary = "media_or_file_delivery"
            finalizerGate = "must_reference_exported_artifact_or_mark_missing"
        case .mcp:
            expectedOutput = "mcp_result_answer"
            requiresArtifact = toolRequiresArtifact
            summary = toolRequiresArtifact ? "mcp_answer_plus_artifact" : "mcp_answer"
            finalizerGate = toolRequiresArtifact ? "must_reference_exported_artifact_or_mark_missing" : "must_report_mcp_result_or_error"
        case .diagnostics:
            expectedOutput = "diagnostic_report"
            requiresArtifact = false
            summary = "diagnostic_report"
            finalizerGate = "must_report_pass_fail_markers_and_next_action"
        case .systemSkill:
            expectedOutput = "ios_action_result"
            requiresArtifact = toolRequiresArtifact
            summary = toolRequiresArtifact ? "ios_action_plus_artifact" : "ios_action_result"
            finalizerGate = toolRequiresArtifact ? "must_reference_exported_artifact_or_mark_missing" : "must_report_ios_action_result"
        case .metal:
            expectedOutput = "metal_capability_report"
            requiresArtifact = false
            summary = "metal_host_bridge_report"
            finalizerGate = "must_report_host_bridge_status_not_linux_metal"
        case .localModel:
            expectedOutput = "local_model_runtime_report"
            requiresArtifact = false
            summary = "local_model_runtime_validation"
            finalizerGate = "must_report_real_model_runtime_status"
        case .linuxWork:
            expectedOutput = toolRequiresArtifact ? "linux_result_exported_artifact" : "linux_result_summary"
            requiresArtifact = toolRequiresArtifact
            summary = toolRequiresArtifact ? "linux_work_plus_artifact" : "linux_work_result"
            finalizerGate = toolRequiresArtifact ? "must_reference_exported_artifact_or_mark_missing" : "must_report_script_result_or_failure"
        case .generalProject:
            expectedOutput = toolRequiresArtifact ? "project_exported_artifact" : "project_result"
            requiresArtifact = toolRequiresArtifact
            summary = toolRequiresArtifact ? "project_result_plus_artifact" : "project_result"
            finalizerGate = toolRequiresArtifact ? "must_reference_exported_artifact_or_mark_missing" : "must_report_project_result_or_failure"
        }
    }
}

struct ProjectFinalizerCheckpoint: Equatable {
    let completionContract: String
    let expectedOutput: String
    let requiresArtifact: Bool
    let finalizerGate: String
    let artifactCount: Int?
    let projectManifestStatus: String
    let deliveryState: String
    let latestTaskExit: String
    let localModelReadinessState: String
    let localModelReadinessReason: String
    let localModelRunnerState: String
    let localModelGGUFState: String
    let localModelRuntimeState: String
    let localModelNextCommand: String
    let modelDoctorStatus: String
    let modelDoctorNextCommand: String
    let realLocalModelRuntime: String
    let subagentRealModelGate: String
    let isUnavailable: Bool

    init(snapshot: String) {
        func value(_ key: String) -> String? {
            snapshot
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .compactMap { line -> String? in
                    let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard clean.hasPrefix("\(key)=") else { return nil }
                    return String(clean.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .last
        }

        completionContract = value("completion_contract") ?? "unknown"
        expectedOutput = value("expected_output") ?? "unknown"
        requiresArtifact = (value("requires_artifact") ?? "false").localizedCaseInsensitiveContains("true")
        finalizerGate = value("finalizer_gate") ?? "unknown"
        artifactCount = value("artifact_count").flatMap(Int.init)
        projectManifestStatus = value("project_manifest_status") ?? "unknown"
        deliveryState = value("delivery_state") ?? "unknown"
        latestTaskExit = value("latest_task_exit") ?? "unknown"
        localModelReadinessState = value("local_model_readiness_state") ?? "unknown"
        localModelReadinessReason = value("local_model_readiness_reason") ?? "unknown"
        localModelRunnerState = value("local_model_runner_state") ?? "unknown"
        localModelGGUFState = value("local_model_gguf_state") ?? "unknown"
        localModelRuntimeState = value("local_model_runtime_state") ?? "unknown"
        localModelNextCommand = value("local_model_next_command") ?? "unknown"
        modelDoctorStatus = value("model_doctor_status") ?? "unknown"
        modelDoctorNextCommand = value("model_doctor_next_command") ?? "unknown"
        realLocalModelRuntime = value("real_local_model_runtime") ?? "unknown"
        subagentRealModelGate = value("subagent_real_model_gate") ?? "unknown"
        isUnavailable = snapshot.localizedCaseInsensitiveContains("reason=ish_not_ready")
            || snapshot.localizedCaseInsensitiveContains("finalizer_snapshot=unavailable")
    }

    var shouldMarkIncomplete: Bool {
        guard !isUnavailable else { return false }
        if expectedOutput == "local_model_runtime_report" {
            let realRuntimeReady = realLocalModelRuntime.hasPrefix("ready")
                || localModelRuntimeState == "ready"
            let doctorReady = modelDoctorStatus == "ready" || modelDoctorStatus == "unknown"
            let readinessReady = localModelReadinessState == "ready" || localModelReadinessState == "unknown"
            if !(realRuntimeReady && doctorReady && readinessReady) {
                return true
            }
        }
        if deliveryState == "artifact_required_missing" { return true }
        if deliveryState == "plan_open_no_artifact" { return true }
        if deliveryState == "latest_task_failed" { return true }
        if deliveryState == "project_manifest_failed" { return true }
        if deliveryState == "project_manifest_in_progress" { return true }
        if ["tool_failed", "recovering", "tool_canceled"].contains(projectManifestStatus), (artifactCount ?? 0) == 0 { return true }
        if ["running", "tool_running"].contains(projectManifestStatus), (artifactCount ?? 0) == 0 { return true }
        if requiresArtifact, (artifactCount ?? 0) == 0 { return true }
        return false
    }

    var userFacingStatusLine: String? {
        guard !isUnavailable, deliveryState != "unknown" else { return nil }
        switch deliveryState {
        case "artifact_required_missing":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 显示需要产物，但 Ogent Artifacts 里还没有可交付文件。"
        case "plan_open_no_artifact":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 显示计划仍有未完成步骤，且还没有可交付文件。"
        case "latest_task_failed":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 显示最近工程任务失败，退出状态：\(latestTaskExit)。"
        case "project_manifest_failed":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 project manifest 显示工程仍处在失败/恢复状态：\(projectManifestStatus)。"
        case "project_manifest_in_progress":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 project manifest 显示工程仍在运行，尚未进入可交付状态：\(projectManifestStatus)。"
        case "ready_with_warnings":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 显示已有产物，但最近仍有失败/恢复记录，需要在交付中说明风险。"
        case "ready_to_summarize":
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 显示已有可总结的交付结果。"
        default:
            if expectedOutput == "local_model_runtime_report",
               shouldMarkIncomplete {
                let state = localModelReadinessState == "unknown" ? localModelRuntimeState : localModelReadinessState
                // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
                return "本机模型 runtime 尚未达到真实 iSH 推理条件：state=\(state)，reason=\(localModelReadinessReason)。"
            }
            // i18n-ignore: model copy written into the Ogent session note; display copy is localizedStatusLine
            return "本机 finalizer checkpoint 状态：\(deliveryState)。"
        }
    }

    /// Display copy of `userFacingStatusLine` in the UI language, for text
    /// shown in chat (the local final-delivery fallback). The source wording
    /// above stays as is: it is also written into the Ogent session note.
    var localizedStatusLine: String? {
        guard !isUnavailable, deliveryState != "unknown" else { return nil }
        switch deliveryState {
        case "artifact_required_missing":
            return String(localized: "本机 finalizer checkpoint 显示需要产物，但 Ogent Artifacts 里还没有可交付文件。", comment: "Ogent final-delivery status line")
        case "plan_open_no_artifact":
            return String(localized: "本机 finalizer checkpoint 显示计划仍有未完成步骤，且还没有可交付文件。", comment: "Ogent final-delivery status line")
        case "latest_task_failed":
            return String(localized: "本机 finalizer checkpoint 显示最近工程任务失败，退出状态：\(latestTaskExit)。", comment: "Ogent final-delivery status line; argument is the task exit status")
        case "project_manifest_failed":
            return String(localized: "本机 project manifest 显示工程仍处在失败/恢复状态：\(projectManifestStatus)。", comment: "Ogent final-delivery status line; argument is a status code")
        case "project_manifest_in_progress":
            return String(localized: "本机 project manifest 显示工程仍在运行，尚未进入可交付状态：\(projectManifestStatus)。", comment: "Ogent final-delivery status line; argument is a status code")
        case "ready_with_warnings":
            return String(localized: "本机 finalizer checkpoint 显示已有产物，但最近仍有失败/恢复记录，需要在交付中说明风险。", comment: "Ogent final-delivery status line")
        case "ready_to_summarize":
            return String(localized: "本机 finalizer checkpoint 显示已有可总结的交付结果。", comment: "Ogent final-delivery status line")
        default:
            if expectedOutput == "local_model_runtime_report",
               shouldMarkIncomplete {
                let state = localModelReadinessState == "unknown" ? localModelRuntimeState : localModelReadinessState
                let reason = localModelReadinessReason
                return String(localized: "本机模型 runtime 尚未达到真实 iSH 推理条件：state=\(state)，reason=\(reason)。", comment: "Ogent final-delivery status line; arguments are a state code and a reason code")
            }
            let state = deliveryState
            return String(localized: "本机 finalizer checkpoint 状态：\(state)。", comment: "Ogent final-delivery status line; argument is a state code")
        }
    }

    var compactSummary: [String] {
        var lines: [String] = []
        if completionContract != "unknown" {
            lines.append("completion_contract=\(completionContract)")
        }
        if expectedOutput != "unknown" {
            lines.append("expected_output=\(expectedOutput)")
        }
        lines.append("requires_artifact=\(requiresArtifact ? "true" : "false")")
        if let artifactCount {
            lines.append("artifact_count=\(artifactCount)")
        }
        if projectManifestStatus != "unknown" {
            lines.append("project_manifest_status=\(projectManifestStatus)")
        }
        if deliveryState != "unknown" {
            lines.append("delivery_state=\(deliveryState)")
        }
        if finalizerGate != "unknown" {
            lines.append("finalizer_gate=\(finalizerGate)")
        }
        if localModelReadinessState != "unknown" {
            lines.append("local_model_readiness_state=\(localModelReadinessState)")
        }
        if localModelReadinessReason != "unknown" {
            lines.append("local_model_readiness_reason=\(localModelReadinessReason)")
        }
        if localModelRunnerState != "unknown" {
            lines.append("local_model_runner_state=\(localModelRunnerState)")
        }
        if localModelGGUFState != "unknown" {
            lines.append("local_model_gguf_state=\(localModelGGUFState)")
        }
        if localModelRuntimeState != "unknown" {
            lines.append("local_model_runtime_state=\(localModelRuntimeState)")
        }
        if localModelNextCommand != "unknown" {
            lines.append("local_model_next_command=\(localModelNextCommand)")
        }
        if modelDoctorStatus != "unknown" {
            lines.append("model_doctor_status=\(modelDoctorStatus)")
        }
        if modelDoctorNextCommand != "unknown" {
            lines.append("model_doctor_next_command=\(modelDoctorNextCommand)")
        }
        if realLocalModelRuntime != "unknown" {
            lines.append("real_local_model_runtime=\(realLocalModelRuntime)")
        }
        if subagentRealModelGate != "unknown" {
            lines.append("subagent_real_model_gate=\(subagentRealModelGate)")
        }
        return lines
    }
}

struct ProjectToolTrace {
    static func sessionNote(
        call: ToolCall,
        iteration: Int,
        model: String,
        userPrompt: String
    ) -> String {
        var lines: [String] = [
            // i18n-ignore: model-facing session note / finalizer instruction
            "## 工程工具执行记录",
            "- kind: project_tool_trace",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- iteration: \(iteration)",
            "- model: \(model)",
            "- tool_name: \(call.name)",
            "- tool_label: \(call.displayName ?? call.name)",
            "- status: \(call.status.rawValue)"
        ]
        if let duration = duration(call) {
            lines.append(String(format: "- duration_seconds: %.1f", duration))
        }
        lines.append("- user_goal: \(singleLine(userPrompt, limit: 220))")
        if let input = call.inputJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
            lines.append("")
            lines.append("### Input Summary")
            lines.append(redact(singleLine(input, limit: 700)))
        }
        if let output = call.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            lines.append("")
            lines.append("### Output Digest")
            lines.append(outputDigest(output, status: call.status))
        }
        if call.status == .error {
            lines.append("")
            lines.append("### Recovery Hint")
            lines.append("Treat this as recoverable tool state: inspect the error, switch fallback tools if available, and do not restart completed steps.")
        }
        return lines.joined(separator: "\n")
    }

    private static func duration(_ call: ToolCall) -> TimeInterval? {
        guard let started = call.startedAt, let ended = call.endedAt else { return nil }
        return max(0, ended.timeIntervalSince(started))
    }

    private static func outputDigest(_ output: String, status: ToolCallStatus) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let important = lines.filter { line in
            line.contains("[oases:open]")
                || line.contains("ios=")
                || line.contains("guest=")
                || line.localizedCaseInsensitiveContains("artifact")
                || line.localizedCaseInsensitiveContains("created docx")
                || line.localizedCaseInsensitiveContains("created pptx")
                || line.localizedCaseInsensitiveContains("downloaded")
                || line.localizedCaseInsensitiveContains("error")
                || line.localizedCaseInsensitiveContains("failed")
                || line.localizedCaseInsensitiveContains("[exit=")
        }
        let selected = important.isEmpty
            ? Array(lines.prefix(status == .error ? 16 : 10))
            : Array(important.prefix(18))
        return selected
            .map { redact(singleLine($0, limit: 500)) }
            .joined(separator: "\n")
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)) + "..."
    }

    private static func redact(_ text: String) -> String {
        var output = text
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)["'\s:=]+[^"',\s}]{6,}"#,
            #"(?i)(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "$1=[REDACTED]",
                options: .regularExpression
            )
        }
        return output
    }
}

struct ProjectLifecycleTrace {
    static func sessionNote(
        event: String,
        state: ProjectAgentExecutionState,
        model: String,
        userPrompt: String,
        reason: String? = nil,
        finalizerSnapshot: String? = nil
    ) -> String {
        let contract = state.initialPlan.completionContract
        var lines: [String] = [
            // i18n-ignore: model-facing session note / finalizer instruction
            "## 工程生命周期记录",
            "- kind: project_lifecycle_trace",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- event: \(singleLine(event, limit: 120))",
            "- phase: \(state.phase.rawValue)",
            "- iteration: \(state.iteration)",
            "- executed_tools: \(state.executedToolCalls)",
            "- stopped_for_iteration_limit: \(state.stoppedForIterationLimit ? "true" : "false")",
            "- model: \(model)",
            "- task_kind: \(state.initialPlan.kind.rawValue)",
            "- tools_exposed: \(state.initialPlan.toolSummary.isEmpty ? "none" : state.initialPlan.toolSummary)",
            "- completion_contract: \(contract.summary)",
            "- expected_output: \(contract.expectedOutput)",
            "- requires_artifact: \(contract.requiresArtifact ? "true" : "false")",
            "- finalizer_gate: \(contract.finalizerGate)",
            "- user_goal: \(singleLine(userPrompt, limit: 220))"
        ]
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append("- reason: \(redact(singleLine(reason, limit: 420)))")
        }
        if let finalizerSnapshot, !finalizerSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let checkpoint = ProjectFinalizerCheckpoint(snapshot: finalizerSnapshot)
            lines.append("")
            lines.append("### Finalizer Checkpoint")
            lines.append(contentsOf: checkpoint.compactSummary.map { "- \($0)" })
            if let statusLine = checkpoint.userFacingStatusLine {
                lines.append("- status_line: \(singleLine(statusLine, limit: 360))")
            }
        }
        lines.append("")
        lines.append("Recovery policy: continue from current Ogent session/workspace; reuse completed tool results and artifacts; do not restart completed steps.")
        return lines.joined(separator: "\n")
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)) + "..."
    }

    private static func redact(_ text: String) -> String {
        var output = text
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)["'\s:=]+[^"',\s}]{6,}"#,
            #"(?i)(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "$1=[REDACTED]",
                options: .regularExpression
            )
        }
        return output
    }
}

/// Runtime execution state for one project-mode turn.
///
/// Hermes/Halo-style agents need a durable notion of lifecycle, not just a
/// loop counter in the UI. This object keeps model iterations, tool execution,
/// finalization and local fallback policy together so `ChatViewModel` only
/// streams/render events while the agent layer decides when a task has to
/// produce a concrete handoff.
struct ProjectAgentExecutionState: Equatable {
    enum Phase: String {
        case planning
        case modelTurn
        case runningTools
        case finalizing
        case localFallback
        case completed
    }

    let initialPlan: ProjectAgentPlan
    private(set) var phase: Phase = .planning
    private(set) var iteration: Int = 0
    private(set) var executedToolCalls: Int = 0
    private(set) var stoppedForIterationLimit = false

    init(initialPlan: ProjectAgentPlan) {
        self.initialPlan = initialPlan
    }

    var requiresFinalDelivery: Bool {
        initialPlan.kind != .conversation || initialPlan.exposesTools
    }

    mutating func beginIteration() -> Int {
        iteration += 1
        phase = .modelTurn
        return iteration
    }

    mutating func recordToolCalls(_ count: Int, maxIterations: Int) {
        guard count > 0 else { return }
        executedToolCalls += count
        phase = .runningTools
        if iteration >= maxIterations {
            stoppedForIterationLimit = true
        }
    }

    mutating func markIterationLimitReached() {
        stoppedForIterationLimit = true
    }

    mutating func markRecoverableStreamError() {
        phase = .localFallback
    }

    mutating func beginFinalization() {
        phase = .finalizing
    }

    mutating func complete() {
        phase = .completed
    }

    func plan(for prompt: String) -> ProjectAgentPlan {
        ProjectAgentPlanner.plan(
            for: prompt,
            iteration: max(iteration, 1),
            executedToolCalls: executedToolCalls
        )
    }

    func shouldForceFinalDelivery(assistantNeedsFinalDelivery: Bool) -> Bool {
        if stoppedForIterationLimit && (executedToolCalls > 0 || requiresFinalDelivery) {
            return true
        }
        guard assistantNeedsFinalDelivery else { return false }
        return executedToolCalls > 0 || requiresFinalDelivery
    }

    func localFallbackReason(userFacingError: String) -> String {
        if executedToolCalls == 0, requiresFinalDelivery {
            // i18n-ignore: model-facing session note / finalizer instruction
            return "工程任务未形成合格交付，模型请求失败：\(userFacingError)"
        }
        // i18n-ignore: model-facing session note / finalizer instruction
        return "最终模型总结请求失败：\(userFacingError)"
    }

    func finalDeliveryInstruction() -> String {
        if stoppedForIterationLimit {
            // i18n-ignore: model-facing session note / finalizer instruction
            return """
            工具执行阶段已达到本轮上限。禁止继续调用工具。你现在进入 Ogent finalizer 阶段：必须基于已有工具结果给出最终交付。回复必须以“最终交付”开头，并说明：完成了什么、产物文件名/导出位置、用户可以如何打开；如果未完成，说明卡在哪一步、已保留的日志/文件以及下一步。
            """
        }
        if executedToolCalls == 0, requiresFinalDelivery {
            // i18n-ignore: model-facing session note / finalizer instruction
            return """
            当前工程任务没有形成合格交付，且模型没有调用任何工程工具。禁止空泛继续计划。你现在进入 Ogent finalizer 阶段：必须基于已有本机状态、计划和可用工具说明给出最终交付。回复必须以“最终交付”开头；如果未实际完成用户目标，明确写“未完成”，说明缺少的工具调用/下一步执行动作，不要假装已经完成。
            """
        }
        // i18n-ignore: model-facing session note / finalizer instruction
        return """
        工具执行已经结束，但还没有给用户最终交付。禁止继续调用工具。你现在进入 Ogent finalizer 阶段：必须基于已有工具结果给出最终交付。回复必须以“最终交付”开头，并说明：完成了什么、产物文件名/导出位置、用户可以如何打开；如果未完成，说明卡在哪一步、已保留的日志/文件以及下一步。
        """
    }

    var logSummary: String {
        "phase=\(phase.rawValue) iteration=\(iteration) tools=\(executedToolCalls) stopped=\(stoppedForIterationLimit ? 1 : 0) initial=\(initialPlan.logSummary)"
    }
}

struct ProjectToolFailureRecovery {
    static func signature(for call: ToolCall) -> String {
        "\(call.name)|\(normalizedArguments(call.inputJSON ?? "{}"))"
    }

    static func instruction(
        failedCalls: [ToolCall],
        plan: ProjectAgentPlan,
        iteration: Int
    ) -> String {
        guard !failedCalls.isEmpty else { return "" }
        var lines = [
            "[Ogent tool failure recovery]",
            "iteration=\(iteration)",
            "task_kind=\(plan.kind.rawValue)",
            "completion_contract=\(plan.completionContract.summary)",
            "retry_policy=do_not_repeat_same_failed_call_without_changed_args_or_fallback",
            "preserve_completed_tool_results=true",
            "final_delivery_allowed=true_if_fallback_cannot_improve_result",
            "",
            // i18n-ignore: model-facing tool-failure recovery instruction
            "本轮有工具失败。下一步不要原样重复同一个失败调用；先复用已经成功的工具结果和已生成产物，再按下面 fallback 改道。若 fallback 仍无法推进，必须进入最终交付，说明未完成点、已保留的日志/文件和下一步。",
            "failed_tools:"
        ]
        for call in failedCalls.prefix(6) {
            let error = summarize(call.output ?? "unknown tool failure")
            lines.append("- \(call.name) id=\(call.id) error=\(error)")
            lines.append("  fallback=\(fallback(for: call.name, plan: plan))")
        }
        if failedCalls.count > 6 {
            lines.append("- additional_failures=\(failedCalls.count - 6)")
        }
        lines.append("[/Ogent tool failure recovery]")
        return lines.joined(separator: "\n")
    }

    private static func fallback(for toolName: String, plan: ProjectAgentPlan) -> String {
        switch toolName {
        case "web_browse":
            return "agent_reach search/extract, web_search, or shell_execute curl/Jina reader; keep browser cookies/session evidence if already available"
        case "agent_reach":
            return "web_browse persistent browser, web_search, or shell_execute curl/Jina reader"
        case "web_search":
            return "agent_reach search or web_browse direct URL navigation"
        case "shell_execute", "shell_local":
            return "ogent_agent run_script for long Linux work, or ogent_agent rootfs_doctor/rootfs_repair before retrying shell"
        case "ogent_agent":
            return "shell_execute for simple one-shot checks; if runtime/rootfs issue, call rootfs_doctor/rootfs_repair then continue"
        case "mcp_call":
            if plan.selectedMCPServers.contains(where: { $0.serverName.localizedCaseInsensitiveContains("12306") }) {
                return "train_ticket_12306 narrow wrapper, then mcp_status/mcp_tools only if raw schema is required"
            }
            return "mcp_status then mcp_tools for the selected server; if server remains unavailable, report MCP status and continue with local/web fallback"
        case "mcp_tools":
            return "mcp_status for enabled server health; use a narrow built-in wrapper when available"
        case "train_ticket_12306":
            return "mcp_status/mcp_tools serverName=12306-mcp, station-code lookup first, or report upstream network limitation while preserving station results"
        case "artifact_bridge":
            return "ogent_agent artifact_list/artifact_export; use shell_execute or document skill to create a file in OGENT_ARTIFACTS"
        case "youtube_downloader", "video_downloader":
            return "try the other downloader skill, then shell_execute yt-dlp/curl if installed; export partial logs/artifacts"
        case "nano_pdf":
            return "artifact_bridge or shell_execute Python/PDF utilities; if unavailable, deliver source files plus exact missing dependency"
        case "svg_logo_fetcher":
            return "web_browse or shell_execute curl to fetch SVG, then artifact_bridge export"
        case "metal_bridge":
            return "host-side capability report; do not retry inside Linux because iSH cannot import iOS Metal directly"
        default:
            return "choose a different exposed tool or enter final delivery with the preserved failure trace"
        }
    }

    private static func summarize(_ text: String, limit: Int = 220) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard compact.count > limit else { return compact }
        let idx = compact.index(compact.startIndex, offsetBy: limit)
        return String(compact[..<idx]) + "..."
    }

    private static func normalizedArguments(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(json),
              let normalized = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: normalized, encoding: .utf8) else {
            return trimmed
        }
        return text
    }
}

struct ProjectAgentContextCompactor {
    struct Result {
        let messages: [ChatAPIMessage]
        let didCompact: Bool
        let beforeTokens: Int
        let afterTokens: Int
        let budgetTokens: Int
        let compactedMessages: Int
        let persistentSummary: String?

        var logSummary: String {
            "context_compaction=\(didCompact ? "applied" : "skipped") before_tokens=\(beforeTokens) after_tokens=\(afterTokens) budget_tokens=\(budgetTokens) compacted_messages=\(compactedMessages)"
        }
    }

    private static let defaultProjectTokenBudget = 120_000
    private static let thresholdRatio = 0.90
    private static let preferredSuffixMessages = 12

    static func compactIfNeeded(
        messages: [ChatAPIMessage],
        model: String,
        toolsJSON: String?
    ) -> Result {
        compactIfNeeded(messages: messages, model: model, toolsJSON: toolsJSON, overrideBudgetTokens: nil)
    }

    fileprivate static func compactIfNeeded(
        messages: [ChatAPIMessage],
        model: String,
        toolsJSON: String?,
        overrideBudgetTokens: Int?
    ) -> Result {
        let budget = overrideBudgetTokens ?? tokenBudget(for: model)
        let before = estimateTokens(messages: messages, toolsJSON: toolsJSON)
        let threshold = Int(Double(budget) * thresholdRatio)
        guard before >= threshold, messages.count > 6 else {
            return Result(
                messages: messages,
                didCompact: false,
                beforeTokens: before,
                afterTokens: before,
                budgetTokens: budget,
                compactedMessages: 0,
                persistentSummary: nil
            )
        }

        let suffixStart = safeSuffixStart(messages: messages, preferredSuffixCount: preferredSuffixMessages)
        guard suffixStart > 0 else {
            return Result(
                messages: messages,
                didCompact: false,
                beforeTokens: before,
                afterTokens: before,
                budgetTokens: budget,
                compactedMessages: 0,
                persistentSummary: nil
            )
        }

        let oldMessages = Array(messages[..<suffixStart])
        let suffix = Array(messages[suffixStart...])
        let summary = summaryText(for: oldMessages, beforeTokens: before, budgetTokens: budget)
        let compacted = [ChatAPIMessage(role: "user", content: .text(summary))] + suffix
        let after = estimateTokens(messages: compacted, toolsJSON: toolsJSON)
        return Result(
            messages: compacted,
            didCompact: true,
            beforeTokens: before,
            afterTokens: after,
            budgetTokens: budget,
            compactedMessages: oldMessages.count,
            persistentSummary: summary
        )
    }

    static func estimateTokens(messages: [ChatAPIMessage], toolsJSON: String?) -> Int {
        let messageChars = messages.reduce(AgentCatalogue.project.systemPrompt.count) { partial, message in
            partial
                + message.role.count
                + contentText(message.content).count
                + (message.toolCallId?.count ?? 0)
                + (message.toolCalls?.reduce(0) { inner, call in
                    inner + call.id.count + call.function.name.count + call.function.arguments.count
                } ?? 0)
                + 24
        }
        let toolChars = toolsJSON?.count ?? 0
        return max(1, Int(ceil(Double(messageChars + toolChars) / 3.6)))
    }

    private static func tokenBudget(for model: String) -> Int {
        if model.localizedCaseInsensitiveContains("flash-lite") { return 64_000 }
        if model.localizedCaseInsensitiveContains("kimi") { return 128_000 }
        if model.localizedCaseInsensitiveContains("gpt-5") { return 128_000 }
        if model.localizedCaseInsensitiveContains("deepseek") { return 128_000 }
        return defaultProjectTokenBudget
    }

    private static func safeSuffixStart(messages: [ChatAPIMessage], preferredSuffixCount: Int) -> Int {
        guard messages.count > preferredSuffixCount else { return 0 }
        var start = max(0, messages.count - preferredSuffixCount)
        if messages[start].role == "tool" {
            var cursor = start - 1
            var pairedAssistantStart: Int?
            while cursor >= 0 {
                let candidate = messages[cursor]
                if candidate.role == "assistant", candidate.toolCalls?.isEmpty == false {
                    pairedAssistantStart = cursor
                    break
                }
                if cursor == 0 { break }
                cursor -= 1
            }
            if let pairedAssistantStart {
                start = pairedAssistantStart
            } else {
                while start < messages.count, messages[start].role == "tool" {
                    start += 1
                }
            }
        }
        return start
    }

    private static func summaryText(
        for messages: [ChatAPIMessage],
        beforeTokens: Int,
        budgetTokens: Int
    ) -> String {
        var lines = [
            // i18n-ignore: model-facing context-compaction summary
            "[工程模式自动上下文压缩]",
            // i18n-ignore: model-facing context-compaction summary
            "旧上下文接近窗口 90%，本机 Ogent runtime 已压缩较早消息，保留最近 tool-call 协议块和当前任务状态。",
            "before_estimated_tokens=\(beforeTokens)",
            "budget_tokens=\(budgetTokens)",
            "compacted_messages=\(messages.count)",
            "",
            // i18n-ignore: model-facing context-compaction summary
            "## 用户目标线索"
        ]

        let userGoals = messages
            .filter { $0.role == "user" }
            .compactMap { shortLine(contentText($0.content), limit: 360) }
            .suffix(6)
        if userGoals.isEmpty {
            // i18n-ignore: model-facing context-compaction summary
            lines.append("- 无较早用户目标。")
        } else {
            lines.append(contentsOf: userGoals.map { "- \($0)" })
        }

        let deliveries = messages
            .filter { $0.role == "assistant" }
            .compactMap { contentText($0.content) }
            .filter { text in
                // i18n-ignore: model-facing context-compaction summary
                text.localizedCaseInsensitiveContains("最终交付")
                    // i18n-ignore: model-facing context-compaction summary
                    || text.localizedCaseInsensitiveContains("已导出")
                    // i18n-ignore: model-facing context-compaction summary
                    || text.localizedCaseInsensitiveContains("未完成")
            }
            .suffix(4)
            .compactMap { shortLine($0, limit: 520) }
        if !deliveries.isEmpty {
            lines.append("")
            // i18n-ignore: model-facing context-compaction summary
            lines.append("## 既有交付/结论")
            lines.append(contentsOf: deliveries.map { "- \($0)" })
        }

        let toolClues = messages
            .filter { $0.role == "tool" }
            .flatMap { importantLines(from: contentText($0.content)) }
            .suffix(18)
        if !toolClues.isEmpty {
            lines.append("")
            // i18n-ignore: model-facing context-compaction summary
            lines.append("## 工具/产物/错误线索")
            lines.append(contentsOf: toolClues.map { "- \($0)" })
        }

        lines.append("")
        // i18n-ignore: model-facing context-compaction summary
        lines.append("继续时优先复用这些线索和最近保留的 tool results；不要重新跑已经完成的步骤。")
        // i18n-ignore: model-facing context-compaction summary
        lines.append("[/工程模式自动上下文压缩]")
        return lines.joined(separator: "\n")
    }

    private static func importantLines(from text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                return line.contains("[oases:open]")
                    || line.contains("ios=")
                    || line.contains("guest=")
                    || line.localizedCaseInsensitiveContains("artifact")
                    || line.localizedCaseInsensitiveContains("created docx")
                    || line.localizedCaseInsensitiveContains("created pptx")
                    || line.localizedCaseInsensitiveContains("error")
                    || line.localizedCaseInsensitiveContains("failed")
                    || line.localizedCaseInsensitiveContains("[exit=")
            }
            .prefix(24)
            .compactMap { shortLine($0, limit: 420) }
    }

    private static func contentText(_ content: MessageContent?) -> String {
        guard let content else { return "" }
        switch content {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.map { part in
                if let text = part.text { return text }
                if let url = part.imageUrl?.url { return "[image_url \(String(url.prefix(80)))]" }
                return ""
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }
    }

    private static func shortLine(_ text: String, limit: Int) -> String? {
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)) + "..."
    }
}

enum ProjectToolSchemaBudget {
    static let defaultMaxProjectToolSchemaBytes = 36_000

    static func fit(
        _ plan: ProjectAgentPlan,
        maxBytes: Int = defaultMaxProjectToolSchemaBytes,
        schemaBytes: ((Set<String>) -> Int)? = nil
    ) -> ProjectAgentPlan {
        guard maxBytes > 0, !plan.toolNames.isEmpty else { return plan }
        let byteCount: (Set<String>) -> Int = schemaBytes ?? { names in
            ToolRegistry.shared.openAIToolsJSON(for: .project, allowedNames: names)?.utf8.count ?? 0
        }
        guard byteCount(plan.toolNames) > maxBytes else { return plan }

        var tools = plan.toolNames
        var skills = plan.selectedSkills
        let protected = protectedTools(for: plan)

        for skill in Array(skills.reversed()) {
            guard byteCount(tools) > maxBytes else { break }
            guard let toolName = skill.toolName, !protected.contains(toolName) else { continue }
            tools.remove(toolName)
            skills.removeAll { $0.toolName == toolName }
        }

        for toolName in optionalDropOrder where byteCount(tools) > maxBytes {
            guard tools.contains(toolName), !protected.contains(toolName) else { continue }
            tools.remove(toolName)
            skills.removeAll { $0.toolName == toolName }
        }

        return ProjectAgentPlan(
            kind: plan.kind,
            toolNames: tools,
            contextPolicy: plan.contextPolicy,
            isContinuation: plan.isContinuation,
            selectedSkills: skills,
            selectedMCPServers: plan.selectedMCPServers
        )
    }

    private static let optionalDropOrder = [
        "mcp_http_selftest",
        "mcp_config_selftest",
        "mcp_selftest",
        "mcp_12306_selftest",
        "ogent_capability_report",
        "ogent_health_check",
        "file_read",
        "file_write",
        "file_edit",
        "speech_synth",
        "image_gen",
        "metal_bridge"
    ]

    private static func protectedTools(for plan: ProjectAgentPlan) -> Set<String> {
        var protected = Set<String>()
        if plan.toolNames.contains("ogent_agent") { protected.insert("ogent_agent") }
        if plan.toolNames.contains("shell_execute") || plan.toolNames.contains("shell_local") {
            protected.insert("shell_execute")
        }
        if plan.toolNames.contains("artifact_bridge") { protected.insert("artifact_bridge") }
        if plan.toolNames.contains("file_read") { protected.insert("file_read") }
        if plan.toolNames.contains("file_write") { protected.insert("file_write") }
        if plan.toolNames.contains("file_edit") { protected.insert("file_edit") }

        switch plan.kind {
        case .webResearch, .webDeliverable:
            protected.formUnion(["web_search", "web_browse", "agent_reach"])
        case .mcp:
            protected.formUnion(["mcp_status", "mcp_tools", "mcp_call", "train_ticket_12306"])
        case .media:
            protected.formUnion(["video_downloader", "youtube_downloader", "svg_logo_fetcher", "nano_pdf"])
        case .systemSkill:
            protected.formUnion(["calendar_read", "reminder_create", "contact_search", "photo_list", "location_current"])
        case .localModel:
            protected.formUnion(["ogent_agent", "shell_execute"])
        case .metal:
            protected.insert("metal_bridge")
        case .artifact:
            protected.insert("artifact_bridge")
        case .diagnostics:
            protected.formUnion(["ogent_health_check", "ogent_capability_report", "mcp_status"])
        case .conversation, .generalProject, .linuxWork:
            break
        }
        return protected.intersection(plan.toolNames)
    }
}

enum ProjectAgentPlanner {
    static func plan(for prompt: String, iteration: Int, executedToolCalls: Int) -> ProjectAgentPlan {
        let text = normalized(prompt).lowercased()
        guard !text.isEmpty else {
            return ProjectAgentPlan(kind: .conversation, toolNames: [], contextPolicy: .none, isContinuation: false)
        }

        let continuation = isContinuationPrompt(prompt)
        if isPlainConversation(text), !continuation {
            return ProjectAgentPlan(kind: .conversation, toolNames: [], contextPolicy: .none, isContinuation: false)
        }

        var names = Set<String>()
        if needsWeb(text) {
            names.formUnion(["web_search", "web_browse", "browser_use", "agent_reach"])
        }
        if needsMemory(text) {
            names.formUnion(["memory_write", "memory_get"])
        }
        if needsClipboard(text) {
            names.insert("apple_clipboard")
        }
        if needsLinuxWork(text) {
            names.formUnion(["ogent_agent", "shell_execute", "file_read", "file_write", "file_edit"])
        }
        if needsArtifact(text) {
            names.formUnion(["artifact_bridge"])
        }
        if needsFiles(text) {
            names.formUnion(["file_read", "file_write", "file_edit"])
        }
        if needsMCP(text) {
            names.formUnion(["mcp_status", "mcp_tools", "mcp_call"])
            if needsSelfTest(text) {
                names.formUnion(["mcp_selftest", "mcp_http_selftest", "mcp_config_selftest"])
                if needs12306MCP(text) {
                    names.insert("mcp_12306_selftest")
                }
            }
        }
        if needs12306MCP(text) {
            names.formUnion(["train_ticket_12306", "mcp_status", "mcp_tools", "mcp_call"])
            if needsSelfTest(text) {
                names.insert("mcp_12306_selftest")
            }
        }
        let selectedMCPServers = ProjectMCPPlanner.select(for: text)
        if !selectedMCPServers.isEmpty {
            names.formUnion(["mcp_status", "mcp_tools", "mcp_call"])
            if selectedMCPServers.contains(where: { $0.serverName.localizedCaseInsensitiveContains("12306") }) {
                names.insert("train_ticket_12306")
                if needsSelfTest(text) {
                    names.insert("mcp_12306_selftest")
                }
            }
        }
        if needsCapability(text) {
            names.formUnion(["ogent_health_check", "ogent_capability_report", "ogent_agent", "mcp_status"])
        }
        if needsSystemSkills(text) {
            names.formUnion(systemSkillNames(for: text))
        }
        if needsMediaSkills(text) {
            names.formUnion(mediaSkillNames(for: text))
        }
        if needsMetal(text) {
            names.insert("metal_bridge")
        }
        if needsLocalModel(text) {
            names.formUnion(["ogent_agent", "shell_execute"])
        }

        if continuation {
            names.formUnion(["ogent_agent", "artifact_bridge", "shell_execute"])
        }
        if names.isEmpty, text.count > 18 || containsAny(text, workKeywords) {
            names.formUnion(["ogent_agent", "shell_execute", "file_read", "file_write", "file_edit", "artifact_bridge"])
        }
        if iteration > 1 || executedToolCalls > 0 {
            names.formUnion(["ogent_agent", "artifact_bridge"])
            if needsWeb(text) {
                names.formUnion(["web_search", "web_browse", "agent_reach"])
            }
        }

        let selectedSkills = ProjectSkillPlanner.select(for: text)
        for skill in selectedSkills {
            if let toolName = skill.toolName {
                names.insert(toolName)
            }
        }

        let plan = ProjectAgentPlan(
            kind: taskKind(for: text, toolNames: names),
            toolNames: names,
            contextPolicy: contextPolicy(for: text, isContinuation: continuation),
            isContinuation: continuation,
            selectedSkills: selectedSkills,
            selectedMCPServers: selectedMCPServers
        )
        return ProjectToolSchemaBudget.fit(plan)
    }

    static func isContinuationPrompt(_ prompt: String) -> Bool {
        let collapsed = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        guard !collapsed.isEmpty, collapsed.count <= 24 else { return false }
        let exact: Set<String> = [
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "继续", "继续吧", "继续执行", "继续做", "继续上次任务", "继续刚才的任务",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "接着来", "接着做", "接着执行", "往下做", "下一步",
            "continue", "resume", "goon", "keepgoing"
        ]
        return exact.contains(collapsed)
    }

    static func memoryQuery(prompt: String, snapshot: String?) -> String {
        let cleanPrompt = normalized(prompt)
        guard isContinuationPrompt(prompt),
              let snapshot,
              !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cleanPrompt
        }
        let cleanSnapshot = normalized(snapshot)
        return "\(cleanPrompt)\n\n\(String(cleanSnapshot.prefix(1_500)))"
    }

    private static let workKeywords = [
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        "工程", "代码", "脚本", "运行", "构建", "测试", "修复", "实现", "开发",
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        "制作", "生成", "创建", "写入", "保存", "导出", "下载", "爬取", "抓取",
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        "ppt", "pptx", "word", "docx", "pdf", "文件", "artifact", "deliver"
    ]

    private static func taskKind(for text: String, toolNames: Set<String>) -> ProjectAgentPlan.TaskKind {
        if toolNames.isEmpty { return .conversation }
        if needsCapability(text) { return .diagnostics }
        if needsMCP(text) || toolNames.contains("mcp_call") { return .mcp }
        if needsLocalModel(text) { return .localModel }
        if needsMetal(text) { return .metal }
        if needsSystemSkills(text) { return .systemSkill }
        if needsMediaSkills(text) { return .media }
        if needsWeb(text), needsArtifact(text) { return .webDeliverable }
        if needsWeb(text) { return .webResearch }
        if needsArtifact(text) { return .artifact }
        if needsLinuxWork(text) { return .linuxWork }
        return .generalProject
    }

    private static func contextPolicy(for text: String, isContinuation: Bool) -> ProjectAgentPlan.ContextPolicy {
        if isContinuation || needsBootstrapContext(text) || needsLocalModel(text) {
            return .bootstrap
        }
        if needsMemoryContext(text) {
            return .memoryOnly
        }
        return .none
    }

    private static func isPlainConversation(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .punctuationCharacters)
        let exact: Set<String> = [
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "你好", "您好", "hi", "hello", "hey", "在吗", "谢谢", "thanks",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "你是谁", "你是什么模型", "你是什么model", "whatmodelareyou"
        ]
        guard compact.count <= 18 else { return false }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(compact, ["工程", "模式", "测试", "自检", "检查", "状态"]) {
            return false
        }
        return exact.contains(compact) || exact.contains(text)
    }

    private static func needsWeb(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["网页", "浏览", "搜索", "新闻", "爬", "抓取", "网站", "链接", "url", "http://", "https://", "oilprice", "website", "web", "search", "browse"])
    }

    private static func needsLinuxWork(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["linux", "ish", "shell", "终端", "命令", "脚本", "代码", "运行", "安装", "apk", "pip", "npm", "构建", "测试", "工程", "agent", "workspace", "rootfs"])
            || containsAny(text, workKeywords)
    }

    private static func needsArtifact(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["ppt", "pptx", "word", "docx", "文档", "报告", "文件", "导出", "保存", "交付", "下载", "artifact", "deliverable"])
    }

    private static func needsFiles(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["读取文件", "写文件", "写入文件", "保存到", "documents", "files", "file", "目录", "路径"])
    }

    private static func needsMemory(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["记住", "记忆", "回忆", "memory", "记得", "笔记", "recall", "remember"])
    }

    private static func needsClipboard(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["剪贴板", "粘贴板", "clipboard", "pasteboard", "复制到剪贴", "读取剪贴"])
    }

    private static func needsMCP(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["mcp", "模型上下文协议", "claude desktop", "stdio", "json-rpc", "server", "服务器工具"])
    }

    private static func needs12306MCP(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["12306", "火车票", "火车", "高铁", "动车", "列车", "车票", "余票", "候补", "车次", "铁路", "出发站", "到达站"])
    }

    private static func needsSelfTest(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["自检", "测试", "验证", "诊断", "selftest", "doctor", "probe"])
    }

    private static func needsCapability(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["目标完成", "完成了吗", "是否正常", "能力", "接好", "健康检查", "状态", "诊断", "检查工程", "报错", "崩溃", "quota", "额度"])
    }

    private static func needsSystemSkills(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["日历", "提醒", "联系人", "通讯录", "照片", "相册", "位置", "定位", "健康", "步数", "心率", "calendar", "reminder", "contact", "photo", "location", "health"])
    }

    private static func systemSkillNames(for text: String) -> Set<String> {
        var names = Set<String>()
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["日历", "日程", "calendar", "schedule"]) { names.insert("calendar_read") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["提醒", "待办", "reminder", "todo"]) { names.insert("reminder_create") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["联系人", "通讯录", "contact"]) { names.insert("contact_search") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["照片", "相册", "photo"]) { names.insert("photo_list") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["位置", "定位", "where am i", "location"]) { names.insert("location_current") }
        return names
    }

    private static func needsMediaSkills(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["视频", "youtube", "youtu.be", "下载视频", "音频", "svg", "logo", "图标", "pdf", "图片", "画图", "语音", "朗读"])
    }

    private static func mediaSkillNames(for text: String) -> Set<String> {
        var names = Set<String>()
        if containsAny(text, ["youtube", "youtu.be"]) { names.insert("youtube_downloader") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["视频", "下载视频", "音频", "download video"]) { names.insert("video_downloader") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["svg", "logo", "图标"]) { names.insert("svg_logo_fetcher") }
        if containsAny(text, ["pdf"]) { names.insert("nano_pdf") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["ppt", "pptx", "word", "docx", "文档"]) { names.insert("artifact_bridge") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["图片", "画图", "生成图", "image", "draw"]) { names.insert("image_gen") }
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        if containsAny(text, ["语音", "朗读", "tts", "speech"]) { names.insert("speech_synth") }
        return names
    }

    private static func needsMetal(_ text: String) -> Bool {
        // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
        containsAny(text, ["metal", "gpu", "加速", "显卡", "compute"])
    }

    static func needsLocalModel(_ text: String) -> Bool {
        containsAny(text, [
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "本机模型", "本地模型", "设备端模型", "ish 模型", "ish模型",
            "local model", "local-model", "local llm", "llama", "llama.cpp",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "gguf", "model runtime", "模型运行时", "模型 endpoint", "模型端点",
            "real_local_model_runtime"
        ])
    }

    private static func needsBootstrapContext(_ text: String) -> Bool {
        containsAny(text, [
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "继续", "恢复", "接着", "上次", "刚才", "之前", "workspace", "snapshot",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "状态", "健康检查", "自检", "诊断", "检查", "目标完成", "完成了吗", "能力报告",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "测试",
            "resume", "continue", "status", "health check", "diagnose", "capability"
        ])
    }

    private static func needsMemoryContext(_ text: String) -> Bool {
        containsAny(text, [
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "记得", "记忆", "历史", "上次", "之前", "根据以前", "wiki", "rag",
            // i18n-ignore: intent keywords matched against the user's prompt / model-facing planner reason
            "长期", "偏好", "约定", "memory", "remember", "previous"
        ])
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

enum ProjectSkillPlanner {
    static func select(for normalizedLowercasePrompt: String) -> [ProjectSkillSelection] {
        select(
            for: normalizedLowercasePrompt,
            descriptors: ToolRegistry.shared.descriptors(for: .project)
        )
    }

    static func select(for normalizedLowercasePrompt: String, descriptors: [ToolDescriptor]) -> [ProjectSkillSelection] {
        let text = normalizedLowercasePrompt
        var selections: [ProjectSkillSelection] = []

        func add(_ name: String, tool: String?, reason: String) {
            guard !selections.contains(where: { $0.name == name }) else { return }
            selections.append(ProjectSkillSelection(name: name, toolName: tool, reason: reason))
        }

        // i18n-ignore: skill-planner keywords and model-facing selection reasons
        if containsAny(text, ["网页", "浏览", "搜索", "新闻", "爬", "抓取", "网站", "链接", "url", "http://", "https://", "oilprice", "web", "search", "browse"]) {
            // i18n-ignore: skill-planner keywords and model-facing selection reasons
            add("agent-reach", tool: "agent_reach", reason: "网页发现、reader fallback、搜索入口和恢复性网页抓取。")
        }
        if containsAny(text, ["youtube", "youtu.be"]) {
            // i18n-ignore: skill-planner keywords and model-facing selection reasons
            add("youtube-downloader", tool: "youtube_downloader", reason: "YouTube 下载，使用 yt-dlp 并导出到 Ogent Artifacts。")
        }
        // i18n-ignore: skill-planner keywords and model-facing selection reasons
        if containsAny(text, ["视频", "下载视频", "音频", "download video", "douyin", "bilibili", "twitter", "x.com"]) {
            // i18n-ignore: skill-planner keywords and model-facing selection reasons
            add("video-downloader", tool: "video_downloader", reason: "通用视频/音频下载，适合多站点 URL。")
        }
        // i18n-ignore: skill-planner keywords and model-facing selection reasons
        if containsAny(text, ["pdf", "合并pdf", "拆分pdf", "压缩pdf", "提取pdf"]) {
            // i18n-ignore: skill-planner keywords and model-facing selection reasons
            add("nano-pdf", tool: "nano_pdf", reason: "轻量 PDF 处理和产物导出。")
        }
        // i18n-ignore: skill-planner keywords and model-facing selection reasons
        if containsAny(text, ["svg", "logo", "图标", "品牌标识"]) {
            // i18n-ignore: skill-planner keywords and model-facing selection reasons
            add("svg-logo-fetcher", tool: "svg_logo_fetcher", reason: "品牌 SVG/logo 查找、下载和导出。")
        }

        for descriptor in dynamicSkillMatches(for: text, descriptors: descriptors) {
            add(
                descriptor.displayName,
                tool: descriptor.name,
                // i18n-ignore: skill-planner keywords and model-facing selection reasons
                reason: "本机能力索引匹配：\(shortReason(descriptor.summary))"
            )
        }

        return Array(selections.prefix(5))
    }

    private static let routerCoreTools: Set<String> = [
        "shell_execute", "shell_local", "ogent_agent", "ogent_health_check", "ogent_capability_report",
        "web_search", "web_browse", "browser_use", "agent_reach", "artifact_bridge",
        "file_read", "file_write", "file_edit",
        "memory_write", "memory_get", "apple_clipboard",
        "mcp_status", "mcp_tools", "mcp_call", "mcp_selftest", "mcp_http_selftest", "mcp_config_selftest", "mcp_12306_selftest",
        "train_ticket_12306",
        "calendar_read", "reminder_create", "contact_search", "photo_list", "location_current",
        "metal_bridge",
        "svg_logo_fetcher", "video_downloader", "youtube_downloader", "nano_pdf",
        "image_gen", "speech_synth"
    ]

    private static func dynamicSkillMatches(for text: String, descriptors: [ToolDescriptor]) -> [ToolDescriptor] {
        let queryTokens = significantTokens(text)
        guard !queryTokens.isEmpty else { return [] }
        return descriptors
            .filter { !routerCoreTools.contains($0.name) }
            .map { descriptor -> (ToolDescriptor, Int) in
                let haystack = "\(descriptor.name) \(descriptor.displayName) \(descriptor.summary)".lowercased()
                let score = queryTokens.reduce(0) { partial, token in
                    partial + (haystack.localizedCaseInsensitiveContains(token) ? 1 : 0)
                } + (text.localizedCaseInsensitiveContains(descriptor.name.lowercased()) ? 3 : 0)
                return (descriptor, score)
            }
            .filter { $0.1 >= 2 }
            .sorted {
                if $0.1 == $1.1 { return $0.0.name < $1.0.name }
                return $0.1 > $1.1
            }
            .prefix(5)
            .map(\.0)
    }

    private static func significantTokens(_ text: String) -> [String] {
        let latin = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        // i18n-ignore: skill-planner keywords and model-facing selection reasons
        let chineseHints = ["网页", "搜索", "新闻", "视频", "下载", "文档", "报告", "日历", "提醒", "健康", "记忆", "自动化", "代码", "测试", "部署", "邮件", "表格", "图片", "音频"]
            .filter { text.localizedCaseInsensitiveContains($0) }
        return Array(Set(latin + chineseHints))
    }

    private static func shortReason(_ text: String) -> String {
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 96 else { return clean }
        return String(clean.prefix(96)) + "..."
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

enum ProjectMCPPlanner {
    static func select(for normalizedLowercasePrompt: String) -> [ProjectMCPSelection] {
        select(for: normalizedLowercasePrompt, enabledServers: MCPSettingsStore.enabled())
    }

    static func select(for normalizedLowercasePrompt: String, enabledServers: [OasesMCPServerConfig]) -> [ProjectMCPSelection] {
        let text = normalizedLowercasePrompt.lowercased()
        let tokens = significantTokens(text)
        guard !text.isEmpty, !enabledServers.isEmpty, !tokens.isEmpty else { return [] }

        return enabledServers
            .map { server -> (OasesMCPServerConfig, Int, String) in
                let haystack = "\(server.name) \(server.sourceEndpointSummary)".lowercased()
                let tokenScore = tokens.reduce(0) { partial, token in
                    partial + (haystack.localizedCaseInsensitiveContains(token) ? 1 : 0)
                }
                let exactScore = text.localizedCaseInsensitiveContains(server.name.lowercased()) ? 4 : 0
                let trainScore = trainTicketScore(prompt: text, serverHaystack: haystack)
                let reason: String
                if trainScore > 0 {
                    // i18n-ignore: MCP-planner keywords and model-facing selection reasons
                    reason = "任务涉及 12306/火车票/高铁/余票，匹配已启用 12306 MCP server。"
                } else {
                    // i18n-ignore: MCP-planner keywords and model-facing selection reasons
                    reason = "任务文本匹配已启用 MCP server 名称或端点。"
                }
                return (server, tokenScore + exactScore + trainScore, reason)
            }
            .filter { $0.1 >= 2 }
            .sorted {
                if $0.1 == $1.1 { return $0.0.name < $1.0.name }
                return $0.1 > $1.1
            }
            .prefix(5)
            .map { server, _, reason in
                ProjectMCPSelection(serverName: server.name, reason: reason)
            }
    }

    private static func significantTokens(_ text: String) -> [String] {
        let latin = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        // i18n-ignore: MCP-planner keywords and model-facing selection reasons
        let chineseHints = ["网页", "搜索", "文件", "日历", "提醒", "邮件", "仓库", "代码", "部署", "数据库", "表格", "支付", "视频", "火车", "火车票", "高铁", "动车", "列车", "车票", "余票", "候补", "车次", "铁路", "出发站", "到达站"]
            .filter { text.localizedCaseInsensitiveContains($0) }
        return Array(Set(latin + chineseHints))
    }

    private static func trainTicketScore(prompt: String, serverHaystack: String) -> Int {
        let is12306Server = serverHaystack.localizedCaseInsensitiveContains("12306")
            || serverHaystack.localizedCaseInsensitiveContains("railway")
            || serverHaystack.localizedCaseInsensitiveContains("train")
        guard is12306Server else { return 0 }
        // i18n-ignore: MCP-planner keywords and model-facing selection reasons
        let hints = ["12306", "火车票", "火车", "高铁", "动车", "列车", "车票", "余票", "候补", "车次", "铁路", "出发站", "到达站"]
        guard hints.contains(where: { prompt.localizedCaseInsensitiveContains($0) }) else { return 0 }
        return prompt.localizedCaseInsensitiveContains("12306") ? 8 : 5
    }
}

enum ProjectToolRoutingSelfTest {
    static func run() -> String {
        let cases: [(prompt: String, expected: Set<String>, context: ProjectAgentPlan.ContextPolicy)] = [
            // i18n-ignore: self-test fixture / expectation
            ("你好", [], .none),
            // i18n-ignore: self-test fixture / expectation
            ("帮我爬取一下 oilprice.com 的三天新闻信息，并写入 word 文档", ["web_search", "web_browse", "agent_reach", "artifact_bridge"], .none),
            // i18n-ignore: self-test fixture / expectation
            ("下载这个 YouTube 视频 https://youtu.be/example", ["youtube_downloader", "video_downloader"], .none),
            // i18n-ignore: self-test fixture / expectation
            ("检查工程模式和 MCP 是否接好了", ["ogent_capability_report", "ogent_health_check", "mcp_status"], .bootstrap),
            // i18n-ignore: self-test fixture / expectation
            ("测试 12306 MCP 是否可用", ["train_ticket_12306", "mcp_status", "mcp_tools", "mcp_call", "mcp_selftest", "mcp_http_selftest", "mcp_config_selftest", "mcp_12306_selftest"], .bootstrap),
            // i18n-ignore: self-test fixture / expectation
            ("帮我查明天北京到上海的高铁余票", ["train_ticket_12306", "mcp_status", "mcp_tools", "mcp_call"], .none),
            // i18n-ignore: self-test fixture / expectation
            ("用 Metal GPU 跑一次加速自检", ["metal_bridge"], .bootstrap),
            // i18n-ignore: self-test fixture / expectation
            ("检查 iSH 本机模型 llama.cpp GGUF runtime 是否就绪", ["ogent_agent", "shell_execute"], .bootstrap),
            // i18n-ignore: self-test fixture / expectation
            ("继续", ["ogent_agent", "artifact_bridge", "shell_execute"], .bootstrap)
        ]
        let fullJSON = ToolRegistry.shared.openAIToolsJSON(for: .project) ?? ""
        var lines = [
            "project_tool_router_selftest",
            "full_project_tools_bytes=\(fullJSON.utf8.count)"
        ]
        var ok = true
        for item in cases {
            let plan = ProjectAgentPlanner.plan(for: item.prompt, iteration: 1, executedToolCalls: 0)
            let json = ToolRegistry.shared.openAIToolsJSON(for: .project, allowedNames: plan.toolNames) ?? ""
            let brief = plan.runtimeBrief ?? ""
            let missing = item.expected.subtracting(plan.toolNames)
            if !missing.isEmpty { ok = false }
            // i18n-ignore: self-test fixture / expectation
            if item.prompt == "你好", plan.exposesTools { ok = false }
            if plan.contextPolicy != item.context { ok = false }
            // i18n-ignore: self-test fixture / expectation
            if item.prompt == "你好", plan.runtimeBrief != nil { ok = false }
            if !item.expected.isEmpty, json.utf8.count >= fullJSON.utf8.count {
                ok = false
            }
            if item.prompt.contains("oilprice"), !brief.contains("web_browse") || brief.contains("mcp_call") {
                ok = false
            }
            if item.prompt.contains("oilprice"), !brief.contains("agent-reach") {
                ok = false
            }
            if item.prompt.contains("oilprice") {
                let requiredSchemas = ["web_search", "web_browse", "agent_reach", "artifact_bridge"]
                let forbiddenSchemas = ["mcp_call", "youtube_downloader", "video_downloader", "nano_pdf", "metal_bridge"]
                let subsetOK = requiredSchemas.allSatisfy { schemaContainsTool(json, named: $0) }
                    && !forbiddenSchemas.contains { schemaContainsTool(json, named: $0) }
                    && json.utf8.count < fullJSON.utf8.count
                if !subsetOK { ok = false }
                lines.append("oilprice_schema_subset=\(subsetOK ? "ok" : "failed") required=\(requiredSchemas.joined(separator: ",")) forbidden_absent=\(forbiddenSchemas.joined(separator: ","))")
            }
            if item.prompt.contains("YouTube"), !brief.contains("youtube-downloader") {
                ok = false
            }
            if item.prompt.contains("llama.cpp") {
                let localModelChecks: [(String, Bool)] = [
                    ("kind", plan.kind == .localModel),
                    ("brief_require_real", brief.contains("requireRealModel=true")),
                    ("brief_real_runtime", brief.contains("real_local_model_runtime")),
                    ("brief_model_plan", brief.contains("model_plan")),
                    ("brief_model_provision", brief.contains("model_provision")),
                    ("brief_model_install_gguf", brief.contains("model_install_gguf")),
                    ("schema_model_plan", json.contains("model_plan")),
                    ("schema_model_provision", json.contains("model_provision")),
                    ("schema_model_install_gguf", json.contains("model_install_gguf"))
                ]
                let failedLocalModelChecks = localModelChecks.filter { !$0.1 }.map(\.0)
                let localModelOK = failedLocalModelChecks.isEmpty
                if !localModelOK { ok = false }
                lines.append("local_model_router=\(localModelOK ? "ok" : "failed") failed_checks=\(failedLocalModelChecks.joined(separator: ","))")
            }
            lines.append(
                "case=\(item.prompt) \(plan.logSummary) routed_tools_bytes=\(json.utf8.count) brief_bytes=\(brief.utf8.count) missing_expected=\(missing.sorted().joined(separator: ",")) expected_context=\(item.context.rawValue)"
            )
        }

        let dynamicDescriptor = ToolDescriptor(
            name: "sec_filing_analyst",
            summary: "Analyze SEC filings, 10-K reports, risk factors, revenue tables, and public company disclosures.",
            displayName: "SEC Filing Analyst",
            inputSchemaJSON: #"{"type":"object","properties":{"ticker":{"type":"string"}}}"#,
            surfaces: [.project],
            requiresPermission: false
        )
        let dynamicSkills = ProjectSkillPlanner.select(
            // i18n-ignore: self-test fixture / expectation
            for: "帮我分析 SEC 10-K filing 里的 revenue risk",
            descriptors: [dynamicDescriptor]
        )
        let dynamicSkillOK = dynamicSkills.contains { $0.toolName == "sec_filing_analyst" }
        if !dynamicSkillOK { ok = false }
        lines.append("dynamic_skill_router=\(dynamicSkillOK ? "ok" : "failed") selected=\(dynamicSkills.map(\.name).joined(separator: ","))")

        let largeSkillToolNames = (0..<6).map { "oversized_dynamic_skill_\($0)" }
        let largeSkills = largeSkillToolNames.enumerated().map { index, toolName in
            ProjectSkillSelection(name: "Oversized Dynamic Skill \(index)", toolName: toolName, reason: "selftest")
        }
        let webCoreTools = Set(["web_search", "web_browse", "agent_reach", "artifact_bridge"])
        let oversizedPlan = ProjectAgentPlan(
            kind: .webDeliverable,
            toolNames: webCoreTools.union(largeSkillToolNames),
            contextPolicy: .none,
            isContinuation: false,
            selectedSkills: largeSkills,
            selectedMCPServers: []
        )
        let budgetedPlan = ProjectToolSchemaBudget.fit(
            oversizedPlan,
            maxBytes: 12_000,
            schemaBytes: { names in
                names.reduce(3_500) { partial, name in
                    partial + (name.hasPrefix("oversized_dynamic_skill_") ? 5_000 : 900)
                }
            }
        )
        let budgetedBytes = budgetedPlan.toolNames.reduce(3_500) { partial, name in
            partial + (name.hasPrefix("oversized_dynamic_skill_") ? 5_000 : 900)
        }
        let schemaBudgetOK = webCoreTools.isSubset(of: budgetedPlan.toolNames)
            && budgetedPlan.selectedSkills.count < largeSkills.count
            && budgetedBytes <= 12_000
        if !schemaBudgetOK { ok = false }
        lines.append("schema_budget_guard=\(schemaBudgetOK ? "ok" : "failed") bytes=\(budgetedBytes) skills_after=\(budgetedPlan.selectedSkills.count)")

        let mcpServers = [
            OasesMCPServerConfig(
                name: "github-issues",
                transport: .http,
                isEnabled: true,
                urlString: "https://mcp.example.local/github/issues",
                environment: []
            ),
            OasesMCPServerConfig(
                name: "calendar-private",
                transport: .http,
                isEnabled: true,
                urlString: "https://mcp.example.local/calendar",
                environment: []
            ),
            MCPSettingsStore.builtin12306MCP
        ]
        let mcpSelections = ProjectMCPPlanner.select(
            // i18n-ignore: self-test fixture / expectation
            for: "查一下 github issues 里的崩溃问题",
            enabledServers: mcpServers
        )
        let mcpRouterOK = mcpSelections.map(\.serverName) == ["github-issues"]
        if !mcpRouterOK { ok = false }
        lines.append("dynamic_mcp_router=\(mcpRouterOK ? "ok" : "failed") selected=\(mcpSelections.map(\.serverName).joined(separator: ","))")

        let trainMCPSelections = ProjectMCPPlanner.select(
            // i18n-ignore: self-test fixture / expectation
            for: "帮我查明天北京到上海的高铁余票",
            enabledServers: mcpServers
        )
        let trainMCPRouterOK = trainMCPSelections.map(\.serverName).first == MCPSettingsStore.builtin12306MCPName
        if !trainMCPRouterOK { ok = false }
        lines.append("dynamic_mcp_12306_router=\(trainMCPRouterOK ? "ok" : "failed") selected=\(trainMCPSelections.map(\.serverName).joined(separator: ","))")

        let builtin12306ConfigOK = MCPSettingsStore.builtin12306MCP.transport == .stdio
            && MCPSettingsStore.builtin12306MCP.command == "/bin/sh"
            && MCPSettingsStore.builtin12306MCP.arguments == ["/usr/local/bin/ogent-agent", "mcp-12306-server"]
        if !builtin12306ConfigOK { ok = false }
        lines.append("builtin_12306_mcp_config=\(builtin12306ConfigOK ? "ok" : "failed") endpoint=\(MCPSettingsStore.builtin12306MCP.sourceEndpointSummary)")

        let live12306Schema = ToolRegistry.shared.openAIToolsJSON(
            for: .project,
            allowedNames: ProjectAgentPlanner.plan(
                // i18n-ignore: self-test fixture / expectation
                for: "测试 12306 MCP 是否可用",
                iteration: 1,
                executedToolCalls: 0
            ).toolNames
        ) ?? ""
        let live12306SchemaOK = schemaContainsTool(live12306Schema, named: "mcp_12306_selftest")
            && schemaContainsTool(live12306Schema, named: "train_ticket_12306")
            && schemaContainsTool(live12306Schema, named: "mcp_tools")
        if !live12306SchemaOK { ok = false }
        lines.append("builtin_12306_live_selftest_schema=\(live12306SchemaOK ? "ok" : "failed")")

        let ticketPlan = ProjectAgentPlanner.plan(
            // i18n-ignore: self-test fixture / expectation
            for: "帮我查明天北京到上海的高铁余票",
            iteration: 1,
            executedToolCalls: 0
        )
        let ticketSchema = ToolRegistry.shared.openAIToolsJSON(for: .project, allowedNames: ticketPlan.toolNames) ?? ""
        let ticketWrapperOK = ticketPlan.toolNames.contains("train_ticket_12306")
            && schemaContainsTool(ticketSchema, named: "train_ticket_12306")
            && !schemaContainsTool(ticketSchema, named: "web_browse")
            && !schemaContainsTool(ticketSchema, named: "youtube_downloader")
        if !ticketWrapperOK { ok = false }
        lines.append("builtin_12306_ticket_wrapper_schema=\(ticketWrapperOK ? "ok" : "failed") tools=\(ticketPlan.toolSummary)")

        lines.insert(ok ? "project_tool_router_ok" : "project_tool_router_failed", at: 1)
        return lines.joined(separator: "\n")
    }

    private static func schemaContainsTool(_ json: String, named name: String) -> Bool {
        json.contains(#""name":"\#(name)""#)
    }
}

enum ProjectAgentExecutionSelfTest {
    static func run() -> String {
        let initialPlan = ProjectAgentPlanner.plan(
            // i18n-ignore: self-test fixture / expectation
            for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档",
            iteration: 1,
            executedToolCalls: 0
        )
        var state = ProjectAgentExecutionState(initialPlan: initialPlan)
        let firstIteration = state.beginIteration()
        // i18n-ignore: self-test fixture / expectation
        let firstPlan = state.plan(for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档")
        let projectPlanMustFinalizeWithoutTools = state.shouldForceFinalDelivery(assistantNeedsFinalDelivery: true)
        let noToolInstruction = state.finalDeliveryInstruction()
        state.recordToolCalls(2, maxIterations: 18)
        let shouldNotFinalizeYet = !state.shouldForceFinalDelivery(assistantNeedsFinalDelivery: false)
        let shouldFinalize = state.shouldForceFinalDelivery(assistantNeedsFinalDelivery: true)
        state.markIterationLimitReached()
        let limitInstruction = state.finalDeliveryInstruction()
        state.beginFinalization()
        let finalizingOK = state.phase == .finalizing
        state.markRecoverableStreamError()
        let fallbackReason = state.localFallbackReason(userFacingError: "quota")
        state.complete()
        let lifecycleTrace = ProjectLifecycleTrace.sessionNote(
            event: "completed",
            state: state,
            model: "selftest",
            // i18n-ignore: self-test fixture / expectation
            userPrompt: "生成 word 文档",
            reason: "authorization Bearer secret-value"
        )
        let trace = ProjectToolTrace.sessionNote(
            call: ToolCall(
                id: "trace-selftest",
                name: "artifact_bridge",
                displayName: "Artifacts",
                status: .completed,
                inputJSON: #"{"apiKey":"secret-value","action":"create_docx"}"#,
                output: "Created DOCX: trace.docx\nios=/tmp/Ogent Artifacts/trace.docx\n[exit=0]",
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 3)
            ),
            iteration: 2,
            model: "selftest",
            // i18n-ignore: self-test fixture / expectation
            userPrompt: "生成 word 文档"
        )

        let ok = firstIteration == 1
            && initialPlan.toolNames.contains("web_browse")
            && initialPlan.toolNames.contains("artifact_bridge")
            && firstPlan.toolNames.contains("agent_reach")
            && state.requiresFinalDelivery
            && projectPlanMustFinalizeWithoutTools
            // i18n-ignore: self-test fixture / expectation
            && noToolInstruction.contains("没有调用任何工程工具")
            // i18n-ignore: self-test fixture / expectation
            && noToolInstruction.contains("未完成")
            && state.executedToolCalls == 2
            && shouldNotFinalizeYet
            && shouldFinalize
            && limitInstruction.contains("Ogent finalizer")
            // i18n-ignore: self-test fixture / expectation
            && limitInstruction.contains("最终交付")
            && finalizingOK
            && fallbackReason.contains("quota")
            && state.phase == .completed
            && trace.contains("project_tool_trace")
            && trace.contains("artifact_bridge")
            && trace.contains("trace.docx")
            && trace.contains("[REDACTED]")
            && lifecycleTrace.contains("project_lifecycle_trace")
            && lifecycleTrace.contains("- event: completed")
            && lifecycleTrace.contains("Recovery policy")
            && lifecycleTrace.contains("[REDACTED]")
        let lines = [
            "project_agent_execution_selftest",
            ok ? "project_agent_execution_ok" : "project_agent_execution_failed",
            state.logSummary,
            "tool_trace_format=\(trace.contains("project_tool_trace") ? "ok" : "failed")",
            "lifecycle_trace_format=\(lifecycleTrace.contains("project_lifecycle_trace") ? "ok" : "failed")"
        ]
        return lines.joined(separator: "\n")
    }
}

enum ProjectToolFailureRecoverySelfTest {
    static func run() -> String {
        var plan = ProjectAgentPlanner.plan(
            // i18n-ignore: self-test fixture / expectation
            for: "帮我爬取 oilprice.com 三天新闻并写入 word 文档",
            iteration: 2,
            executedToolCalls: 3
        )
        plan.selectedMCPServers = [
            ProjectMCPSelection(serverName: MCPSettingsStore.builtin12306MCPName, reason: "selftest")
        ]
        let webFailure = ToolCall(
            id: "call_web",
            name: "web_browse",
            status: .error,
            inputJSON: #"{"url":"https://oilprice.com"}"#,
            output: "[tool error] NSURLErrorDomain timed out while loading the page"
        )
        let mcpFailure = ToolCall(
            id: "call_mcp",
            name: "mcp_call",
            status: .error,
            inputJSON: #"{"serverName":"12306-mcp","toolName":"get-tickets"}"#,
            // i18n-ignore: self-test fixture / expectation
            output: "[tool error] STDIO 输出中未找到 id=3 的 JSON-RPC 响应"
        )
        let instruction = ProjectToolFailureRecovery.instruction(
            failedCalls: [webFailure, mcpFailure],
            plan: plan,
            iteration: 2
        )
        let signatureA = ProjectToolFailureRecovery.signature(for: ToolCall(
            name: "web_browse",
            inputJSON: #"{"url":"https://oilprice.com","selector":"main"}"#
        ))
        let signatureB = ProjectToolFailureRecovery.signature(for: ToolCall(
            name: "web_browse",
            inputJSON: #"{"selector":"main","url":"https://oilprice.com"}"#
        ))
        let ok = instruction.contains("[Ogent tool failure recovery]")
            && instruction.contains("retry_policy=do_not_repeat_same_failed_call_without_changed_args_or_fallback")
            && instruction.contains("preserve_completed_tool_results=true")
            && instruction.contains("agent_reach")
            && instruction.contains("web_search")
            && instruction.contains("train_ticket_12306")
            // i18n-ignore: self-test fixture / expectation
            && instruction.contains("最终交付")
            && signatureA == signatureB
        return [
            "project_tool_failure_recovery_selftest",
            ok ? "project_tool_failure_recovery_ok" : "project_tool_failure_recovery_failed",
            "web_fallback=\(instruction.contains("agent_reach") && instruction.contains("web_search") ? "ok" : "failed")",
            "mcp_12306_fallback=\(instruction.contains("train_ticket_12306") ? "ok" : "failed")",
            "retry_policy=\(instruction.contains("do_not_repeat_same_failed_call") ? "ok" : "failed")",
            "repeat_guard_signature=\(signatureA == signatureB ? "ok" : "failed")"
        ].joined(separator: "\n")
    }
}

enum ProjectAgentContextCompactorSelfTest {
    static func persistenceFixture(marker: String) -> ProjectAgentContextCompactor.Result {
        let longUser = String(repeating: "\(marker) project compaction persistence context ", count: 420)
        let longTool = String(repeating: "tool transcript line without durable value\n", count: 260)
        var messages: [ChatAPIMessage] = []
        for index in 0..<10 {
            messages.append(ChatAPIMessage(role: "user", content: .text("older persistence goal \(index): \(longUser)")))
            // i18n-ignore: self-test fixture / expectation
            messages.append(ChatAPIMessage(role: "assistant", content: .text("阶段性压缩说明 \(index)。")))
            messages.append(ChatAPIMessage(
                role: "tool",
                content: .text("\(longTool)\nios=/tmp/Ogent Artifacts/compaction-\(index).docx\n[exit=0]")
            ))
        }
        messages.append(ChatAPIMessage(role: "user", content: .text("keep latest turn after compaction")))
        return ProjectAgentContextCompactor.compactIfNeeded(
            messages: messages,
            model: "deepseek-v4-pro",
            toolsJSON: String(repeating: "x", count: 4_000),
            overrideBudgetTokens: 2_000
        )
    }

    static func run() -> String {
        let longUser = String(repeating: "oilprice historical research context ", count: 420)
        let longTool = String(repeating: "tool transcript line without durable value\n", count: 260)
        var messages: [ChatAPIMessage] = []
        for index in 0..<10 {
            messages.append(ChatAPIMessage(role: "user", content: .text("older goal \(index): \(longUser)")))
            // i18n-ignore: self-test fixture / expectation
            messages.append(ChatAPIMessage(role: "assistant", content: .text("阶段性说明 \(index)。")))
            messages.append(ChatAPIMessage(
                role: "tool",
                content: .text("\(longTool)\nios=/tmp/Ogent Artifacts/older-\(index).docx\n[exit=0]")
            ))
        }

        let latestCall = WireToolCall(
            id: "call_latest_artifact",
            type: "function",
            function: .init(name: "artifact_bridge", arguments: #"{"action":"create_docx"}"#)
        )
        messages.append(ChatAPIMessage(
            role: "assistant",
            // i18n-ignore: self-test fixture / expectation
            content: .text("我已经生成了最新产物。"),
            toolCalls: [latestCall]
        ))
        messages.append(ChatAPIMessage(
            role: "tool",
            content: .text("""
            Created DOCX: latest-report.docx
            ios=/tmp/Ogent Artifacts/latest-report.docx
            [oases:open]/tmp/Ogent Artifacts/latest-report.docx
            """),
            toolCallId: "call_latest_artifact"
        ))

        let result = ProjectAgentContextCompactor.compactIfNeeded(
            messages: messages,
            model: "deepseek-v4-pro",
            toolsJSON: String(repeating: "x", count: 4_000),
            overrideBudgetTokens: 2_000
        )
        let firstContent: String
        if case .text(let text)? = result.messages.first?.content {
            firstContent = text
        } else {
            firstContent = ""
        }
        let preservedLatestTool = result.messages.contains { $0.toolCallId == "call_latest_artifact" }
        let keptSuffixStartsSafely = result.messages.dropFirst().first?.role != "tool"
        let ok = result.didCompact
            && result.beforeTokens > result.afterTokens
            // i18n-ignore: self-test fixture / expectation
            && firstContent.contains("工程模式自动上下文压缩")
            && firstContent.contains("older-")
            // i18n-ignore: self-test fixture / expectation
            && result.persistentSummary?.contains("工程模式自动上下文压缩") == true
            && preservedLatestTool
            && keptSuffixStartsSafely
        return [
            "project_context_compactor_selftest",
            ok ? "project_context_compactor_ok" : "project_context_compactor_failed",
            result.logSummary,
            "persistent_summary=\(result.persistentSummary?.isEmpty == false ? 1 : 0)",
            "preserved_latest_tool=\(preservedLatestTool ? 1 : 0)",
            "safe_suffix=\(keptSuffixStartsSafely ? 1 : 0)"
        ].joined(separator: "\n")
    }
}
