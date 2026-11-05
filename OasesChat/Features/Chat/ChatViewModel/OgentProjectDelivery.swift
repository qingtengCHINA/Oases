// i18n-ignore-file: in-app self-tests and the model-facing iSH profile preflight prompt; no UI copy.

enum ProjectFinalDeliverySelfTest {
    @MainActor
    static func run() -> String {
        let call = ToolCall(
            id: "selftest-final-delivery",
            name: "artifact_bridge",
            displayName: "Artifacts",
            description: "Self-test deliverable",
            status: .completed,
            inputJSON: #"{"action":"create_docx"}"#,
            output: """
            Created DOCX: ogent-final-delivery-selftest.docx
            size=12 KB
            ios=/tmp/Ogent Artifacts/ogent-final-delivery-selftest.docx
            [oases:open]/tmp/Ogent Artifacts/ogent-final-delivery-selftest.docx
            """,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
        let text = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [call],
            existingText: "我已经生成了文件，但模型总结缺失。",
            failureMessage: "selftest"
        )
        let errorText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [call],
            existingText: "服务暂时不可用，请稍后再试。",
            failureMessage: "selftest stream error"
        )
        let noToolText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "",
            failureMessage: "工程任务模型请求失败：selftest quota"
        )
        let ok = text.contains("最终交付")
            && text.contains("ogent-final-delivery-selftest.docx")
            && text.contains("iOS Documents")
            && text.contains("已完成工具：1 个")
            && errorText.contains("最终交付")
            && errorText.contains("服务暂时不可用")
            && errorText.contains("ogent-final-delivery-selftest.docx")
            && noToolText.contains("最终交付")
            && noToolText.contains("未完成")
            && noToolText.contains("尚未形成任何工具执行")
            && noToolText.contains("已完成工具：0 个")
        let providerErrorCopy = ChatErrorCopy.projectMessage(
            for: APIError.badStatus(400, #"{"error":{"code":"insufficient_user_quota"}}"#)
        )
        let providerErrorOK = providerErrorCopy.contains("本机工具结果已保留")
            && providerErrorCopy.contains("工程执行层仍在本机")
        let routeNote = AIProviderRouting.projectPromptNote
        let providerRequiredOK = routeNote.contains("Oases 默认端点")
            && routeNote.contains("本机 iSH/Ogent")
        let resumeText = ChatViewModel.projectResumePromptForSelfTest(
            prompt: "继续",
            snapshot: "Ogent workspace snapshot\n--- plan ---\n- [ ] 继续下载并导出文件\n--- artifacts ---\nvideo.mp4"
        )
        let resumeOK = resumeText.contains("工程模式恢复上下文")
            && resumeText.contains("不要重新开始任务")
            && resumeText.contains("Ogent workspace snapshot")
            && resumeText.contains("用户请求：继续")
        let memoryQuery = ChatViewModel.projectMemoryQueryForSelfTest(
            prompt: "继续",
            snapshot: "Ogent workspace snapshot\n--- plan ---\n- [ ] 继续下载并导出文件\n--- artifacts ---\nvideo.mp4"
        )
        let memoryQueryOK = memoryQuery.contains("继续")
            && memoryQuery.contains("Ogent workspace snapshot")
            && memoryQuery.contains("video.mp4")
        let bootstrapText = OgentProjectMemoryContextLoader.bootstrapContextPromptForSelfTest(
            query: "oilprice report",
            status: "Ogent Agent Runtime\nmode=local-linux-ish\nartifacts=1",
            snapshot: "Ogent workspace snapshot\n--- artifacts ---\nreport.docx",
            wikiSummary: "Ogent wiki summary\ntopic_pages=2",
            searchResult: """
            Ogent RAG search
            --- score=2 file=/root/.ogent/memory/wiki/topics/oilprice.md line=8 ---
            prior oilprice workflow
            """
        )
        let bootstrapOK = bootstrapText.contains("工程模式本机状态")
            && bootstrapText.contains("Ogent Agent Runtime")
            && bootstrapText.contains("Ogent workspace snapshot")
            && bootstrapText.contains("Ogent wiki summary")
            && bootstrapText.contains("prior oilprice workflow")
        let weakFinalNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已处理完成。",
            toolCalls: [call]
        )
        let strongFinalOK = !ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已导出 ogent-final-delivery-selftest.docx，可在 iOS Documents 打开。",
            toolCalls: [call]
        )
        let missingArtifactSnapshot = """
        [Ogent finalizer local snapshot]
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        --- completion gates ---
        completion_contract=web_research_to_user_artifact
        expected_output=web_research_exported_artifact
        requires_artifact=true
        finalizer_gate=must_reference_exported_artifact_or_mark_missing
        artifact_count=0
        delivery_state=artifact_required_missing
        finalizer_snapshot_ok
        [/Ogent finalizer local snapshot]
        """
        let missingArtifactText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "我已经查看了页面。",
            failureMessage: "selftest finalizer failed",
            finalizerSnapshot: missingArtifactSnapshot
        )
        let missingArtifactOK = missingArtifactText.contains("未完成")
            && missingArtifactText.contains("artifact_required_missing")
            && missingArtifactText.contains("web_research_exported_artifact")
        let snapshotTrace = """
        [Ogent finalizer local snapshot]
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        --- completion gates ---
        completion_contract=project_result_or_failure
        expected_output=word_document
        requires_artifact=true
        finalizer_gate=must_reference_exported_artifact_or_mark_missing
        artifact_count=1
        delivery_state=ready_to_summarize
        --- recent session ---
        - kind: project_tool_trace
        - tool: artifact_bridge
        - status: completed
        - output_digest: Created DOCX snapshot-finalizer.docx ios=/tmp/Ogent Artifacts/snapshot-finalizer.docx [exit=0]
        --- task status ---
        artifact_count=1
        /root/.ogent/artifacts/snapshot-finalizer.docx
        [/Ogent finalizer local snapshot]
        """
        let snapshotTraceText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "",
            failureMessage: "selftest final model failed",
            finalizerSnapshot: snapshotTrace
        )
        let snapshotTraceOK = snapshotTraceText.contains("snapshot-finalizer.docx")
            && snapshotTraceText.contains("本机最近执行线索")
            && snapshotTraceText.contains("project_tool_trace")
            && snapshotTraceText.contains("已导出的产物")
            && snapshotTraceText.contains("下一步")
        let snapshotWeakNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已完成。",
            toolCalls: [],
            finalizerSnapshot: snapshotTrace
        )
        let snapshotStrongOK = !ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已导出 snapshot-finalizer.docx，可在 iOS Documents 打开。",
            toolCalls: [],
            finalizerSnapshot: snapshotTrace
        )
        let snapshotMissingNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已经完成。",
            toolCalls: [],
            finalizerSnapshot: missingArtifactSnapshot
        )
        let serviceUnavailableNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "⚠️ 服务暂时不可用，请稍后再试。",
            toolCalls: [call]
        )
        let serviceUnavailableNoToolNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "⚠️ 服务暂时不可用，请稍后再试。",
            toolCalls: []
        )
        let manifestFailedSnapshot = """
        [Ogent finalizer local snapshot]
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        --- completion gates ---
        completion_contract=project_result
        expected_output=project_result
        requires_artifact=false
        finalizer_gate=must_report_project_result_or_failure
        artifact_count=0
        project_manifest_status=tool_failed
        delivery_state=project_manifest_failed
        finalizer_snapshot_ok
        [/Ogent finalizer local snapshot]
        """
        let manifestFailedNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已经完成。",
            toolCalls: [],
            finalizerSnapshot: manifestFailedSnapshot
        )
        let manifestFailedText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "工具阶段结束。",
            failureMessage: "selftest manifest failed",
            finalizerSnapshot: manifestFailedSnapshot
        )
        let manifestFailedOK = manifestFailedText.contains("未完成")
            && manifestFailedText.contains("project_manifest_failed")
            && manifestFailedText.contains("project_manifest_status=tool_failed")
        let readyWithWarningsSnapshot = """
        [Ogent finalizer local snapshot]
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        --- completion gates ---
        completion_contract=web_research_to_user_artifact
        expected_output=web_research_exported_artifact
        requires_artifact=true
        finalizer_gate=must_reference_exported_artifact_or_mark_missing
        artifact_count=1
        project_manifest_status=tool_failed
        delivery_state=ready_with_warnings
        latest_artifact_path=/root/.ogent/artifacts/warn-finalizer.docx
        ios=/tmp/Ogent Artifacts/warn-finalizer.docx
        finalizer_snapshot_ok
        [/Ogent finalizer local snapshot]
        """
        let readyWarningsText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "",
            failureMessage: "selftest ready with warnings",
            finalizerSnapshot: readyWithWarningsSnapshot
        )
        let readyWarningsOK = readyWarningsText.contains("warn-finalizer.docx")
            && readyWarningsText.contains("ready_with_warnings")
            && readyWarningsText.contains("project_manifest_status=tool_failed")
        let readyWarningsStrongOK = !ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n已导出 warn-finalizer.docx，可在 iOS Documents 打开；但 project_manifest_status=tool_failed，需要复核失败步骤。",
            toolCalls: [],
            finalizerSnapshot: readyWithWarningsSnapshot
        )
        let localModelMissingSnapshot = """
        [Ogent finalizer local snapshot]
        Ogent finalizer checkpoint
        finalizer_snapshot_ok
        --- completion gates ---
        completion_contract=local_model_runtime_validation
        expected_output=local_model_runtime_report
        requires_artifact=false
        finalizer_gate=must_report_real_model_runtime_status
        artifact_count=0
        delivery_state=needs_final_explanation
        local_model_readiness_state=missing
        local_model_readiness_reason=deployment_plan_incomplete
        local_model_runner_state=missing
        local_model_gguf_state=missing
        local_model_runtime_state=missing_or_unreachable
        local_model_next_command=/bin/sh /usr/local/bin/ogent-agent model-build-llama --jobs 1
        model_doctor_status=incomplete
        model_doctor_next_command=/bin/sh /usr/local/bin/ogent-agent model-build-llama --jobs 1
        real_local_model_runtime=missing missing=llama_server_missing gguf_model
        subagent_real_model_gate=missing
        finalizer_snapshot_ok
        [/Ogent finalizer local snapshot]
        """
        let localModelMissingNeedsRepair = ChatViewModel.finalDeliveryNeedsRepairForSelfTest(
            text: "最终交付\n本机模型已经完成。",
            toolCalls: [],
            finalizerSnapshot: localModelMissingSnapshot
        )
        let localModelMissingText = ChatViewModel.localFinalDeliveryForSelfTest(
            toolCalls: [],
            existingText: "服务暂时不可用，请稍后再试。",
            failureMessage: "selftest local model gate",
            finalizerSnapshot: localModelMissingSnapshot
        )
        let localModelMissingOK = localModelMissingText.contains("未完成")
            && localModelMissingText.contains("real_local_model_runtime=missing")
            && localModelMissingText.contains("model_doctor_status=incomplete")
            && localModelMissingText.contains("model-build-llama --jobs 1")
            && localModelMissingText.contains("subagent_real_model_gate=missing")
        return ok && providerErrorOK && providerRequiredOK && resumeOK && memoryQueryOK && bootstrapOK
            && weakFinalNeedsRepair
            && strongFinalOK
            && missingArtifactOK
            && snapshotTraceOK
            && snapshotWeakNeedsRepair
            && snapshotStrongOK
            && snapshotMissingNeedsRepair
            && serviceUnavailableNeedsRepair
            && serviceUnavailableNoToolNeedsRepair
            && manifestFailedNeedsRepair
            && manifestFailedOK
            && readyWarningsOK
            && readyWarningsStrongOK
            && localModelMissingNeedsRepair
            && localModelMissingOK
            ? "final_delivery_fallback_ok"
            : "final_delivery_fallback_failed\n\(text)\nweakFinalNeedsRepair=\(weakFinalNeedsRepair) strongFinalOK=\(strongFinalOK) missingArtifactOK=\(missingArtifactOK) snapshotTraceOK=\(snapshotTraceOK) snapshotWeakNeedsRepair=\(snapshotWeakNeedsRepair) snapshotStrongOK=\(snapshotStrongOK) snapshotMissingNeedsRepair=\(snapshotMissingNeedsRepair) serviceUnavailableNeedsRepair=\(serviceUnavailableNeedsRepair) serviceUnavailableNoToolNeedsRepair=\(serviceUnavailableNoToolNeedsRepair) manifestFailedNeedsRepair=\(manifestFailedNeedsRepair) manifestFailedOK=\(manifestFailedOK) readyWarningsOK=\(readyWarningsOK) readyWarningsStrongOK=\(readyWarningsStrongOK) localModelMissingNeedsRepair=\(localModelMissingNeedsRepair) localModelMissingOK=\(localModelMissingOK)\n\(missingArtifactText)\n\(snapshotTraceText)\n\(manifestFailedText)\n\(readyWarningsText)\n\(localModelMissingText)\n\(providerErrorCopy)\n\(routeNote)\n\(resumeText)\n\(memoryQuery)\n\(bootstrapText)"
    }

    @MainActor
    static func runSnapshotSelfTest() async -> String {
        let snapshot = await ChatViewModel.projectFinalizerSnapshot()
        let ok = snapshot.contains("Ogent finalizer local snapshot")
            && (
                snapshot.contains("reason=ish_not_ready")
                    || (
                        snapshot.contains("Ogent finalizer checkpoint")
                            && snapshot.contains("--- completion gates ---")
                            && snapshot.contains("completion_contract=")
                            && snapshot.contains("requires_artifact=")
                            && snapshot.contains("delivery_state=")
                            && snapshot.contains("artifact_manifest_ok")
                            && snapshot.contains("project_manifest_ok")
                            && snapshot.contains("finalizer_snapshot_ok")
                    )
            )
        return ok
            ? "finalizer_snapshot_ok"
            : "finalizer_snapshot_failed\n\(snapshot)"
    }
}

enum OgentProjectProfilePreflight {
    struct ProfileSelection: Equatable {
        let name: String
        let reason: String
    }

    static func contextPrompt(for plan: ProjectAgentPlan, autoInstallMissingProfiles: Bool = true) async -> String? {
        let selections = profileSelections(for: plan)
        let profiles = selections.map(\.name)
        guard !profiles.isEmpty else { return nil }
        let status = await prepareProfileStatus(
            profiles: profiles,
            autoInstallMissingProfiles: autoInstallMissingProfiles
        )
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return """
        [工程模式 iSH profile preflight]
        iOS host 已在发送模型请求前按本轮 planner 选择准备本机 iSH/Ogent rootfs profile。模型必须基于这个真实状态行动，不能猜测依赖是否存在。
        profiles_selected=\(profiles.joined(separator: ","))
        profile_prepare_mode=\(autoInstallMissingProfiles ? "auto_install_missing" : "status_only")
        profile_deployment_plan:
        \(selections.map { "- \($0.name): \($0.reason)" }.joined(separator: "\n"))

        \(String(status.prefix(5_000)))

        若最终仍显示 `profile_status=missing`，说明 iOS host 已尝试准备但受 iSH 网络/apk 源或系统环境限制；此时直接报告明确失败点和已保留日志，不要反复手写零散 `apk add`。
        [/工程模式 iSH profile preflight]
        """
    }

    static func runSelfTest() async -> String {
        var plan = ProjectAgentPlan(
            kind: .mcp,
            toolNames: ["ogent_agent", "mcp_status", "mcp_tools", "mcp_call"],
            contextPolicy: .bootstrap,
            isContinuation: false
        )
        plan.selectedMCPServers = [
            ProjectMCPSelection(serverName: MCPSettingsStore.builtin12306MCPName, reason: "selftest")
        ]
        guard let context = await contextPrompt(for: plan, autoInstallMissingProfiles: false) else {
            return "profile_preflight_failed empty_context"
        }
        var localModelPlan = ProjectAgentPlan(
            kind: .localModel,
            toolNames: ["ogent_agent", "shell_execute"],
            contextPolicy: .bootstrap,
            isContinuation: false
        )
        localModelPlan.selectedMCPServers = []
        let localModelContext = await contextPrompt(for: localModelPlan, autoInstallMissingProfiles: false) ?? ""

        var metalPlan = ProjectAgentPlan(
            kind: .metal,
            toolNames: ["metal_bridge"],
            contextPolicy: .bootstrap,
            isContinuation: false
        )
        metalPlan.selectedMCPServers = []
        let metalContext = await contextPrompt(for: metalPlan, autoInstallMissingProfiles: false) ?? ""

        var documentPlan = ProjectAgentPlan(
            kind: .artifact,
            toolNames: ["artifact_bridge", "ogent_agent"],
            contextPolicy: .none,
            isContinuation: false
        )
        documentPlan.selectedMCPServers = []
        let documentContext = await contextPrompt(for: documentPlan, autoInstallMissingProfiles: false) ?? ""

        var mediaPlan = ProjectAgentPlan(
            kind: .media,
            toolNames: ["video_downloader", "youtube_downloader", "ogent_agent"],
            contextPolicy: .none,
            isContinuation: false
        )
        mediaPlan.selectedMCPServers = []
        let mediaContext = await contextPrompt(for: mediaPlan, autoInstallMissingProfiles: false) ?? ""

        let ok = context.contains("工程模式 iSH profile preflight")
            && context.contains("profiles_selected=core,12306")
            && context.contains("profile_deployment_plan:")
            && context.contains("- 12306:")
            && context.contains("profile_prepare_mode=status_only")
            && context.contains("profile_prepare profile=core phase=initial")
            && context.contains("profile_prepare profile=12306 phase=initial")
            && context.contains("profile_status profile=core")
            && context.contains("profile_status profile=12306")
            && localModelContext.contains("profiles_selected=core,local-model")
            && localModelContext.contains("profile_status profile=local-model")
            && documentContext.contains("profiles_selected=core,document")
            && documentContext.contains("profile_status profile=document")
            && mediaContext.contains("profiles_selected=core,media")
            && mediaContext.contains("profile_status profile=media")
            && metalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let markerLines = [
            ok ? "profile_preflight_ok" : "profile_preflight_failed",
            "profile_deployment_plan=\(context.contains("profile_deployment_plan:") ? "ok" : "missing")",
            "profile_router_12306=\(context.contains("profiles_selected=core,12306") ? "ok" : "failed")",
            "profile_router_local_model=\(localModelContext.contains("profiles_selected=core,local-model") ? "ok" : "failed")",
            "profile_router_document=\(documentContext.contains("profiles_selected=core,document") ? "ok" : "failed")",
            "profile_router_media=\(mediaContext.contains("profiles_selected=core,media") ? "ok" : "failed")",
            "profile_router_metal=\(metalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "skipped" : "failed")"
        ]
        if ok {
            return markerLines.joined(separator: "\n")
        }
        return markerLines.joined(separator: "\n") + "\n\(context)\n\nlocal_model_context:\n\(localModelContext)\n\ndocument_context:\n\(documentContext)\n\nmedia_context:\n\(mediaContext)\n\nmetal_context:\n\(metalContext)"
    }

    private static func profileSelections(for plan: ProjectAgentPlan) -> [ProfileSelection] {
        var profiles: [ProfileSelection] = []
        func append(_ name: String, reason: String) {
            guard !profiles.contains(where: { $0.name == name }) else { return }
            profiles.append(ProfileSelection(name: name, reason: reason))
        }

        if plan.toolNames.contains("ogent_agent")
            || plan.toolNames.contains("shell_execute")
            || plan.toolNames.contains("shell_local")
            || plan.toolNames.contains("file_write")
            || plan.toolNames.contains("file_read") {
            append("core", reason: "Ogent workspace、shell_execute、/var/oases 文件读写和基础 Linux 命令")
        }
        if plan.toolNames.contains("artifact_bridge") || plan.toolNames.contains("nano_pdf") {
            append("document", reason: "DOCX/PPTX/PDF/ZIP 产物生成与导出")
        }
        if plan.toolNames.contains("youtube_downloader") || plan.toolNames.contains("video_downloader") {
            append("media", reason: "视频/音频下载、转码和媒体处理依赖")
        }
        if plan.toolNames.contains("mcp_status")
            || plan.toolNames.contains("mcp_tools")
            || plan.toolNames.contains("mcp_call")
            || plan.toolNames.contains("train_ticket_12306")
            || !plan.selectedMCPServers.isEmpty {
            if plan.toolNames.contains("train_ticket_12306")
                || plan.selectedMCPServers.contains(where: { $0.serverName.localizedCaseInsensitiveContains("12306") }) {
                append("12306", reason: "内置 12306 MCP wrapper 和站点码查询")
            } else {
                append("mcp", reason: "通用 STDIO MCP server 需要 node/npm/npx")
            }
        }
        if plan.kind == .localModel {
            append("local-model", reason: "真实本机模型需要构建工具、curl、llama-server 和 GGUF readiness 检查")
        }
        return profiles
    }

    private static func prepareProfileStatus(
        profiles: [String],
        autoInstallMissingProfiles: Bool
    ) async -> String {
        return await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "profile_preflight=unavailable reason=ish_not_ready")
                    return
                }
                var sections: [String] = []
                for profile in profiles {
                    let initial = runProfileCommand(
                        title: "initial",
                        profile: profile,
                        command: OgentLinuxRuntime.profileStatusCommand(profile: profile),
                        timeout: 45
                    )
                    sections.append("""
                    profile_prepare profile=\(profile) phase=initial
                    \(initial)
                    """)

                    guard autoInstallMissingProfiles,
                          initial.contains("profile_status=missing profile=\(profile)"),
                          initial.contains("profile_install_needed=1") else {
                        continue
                    }

                    let install = runProfileCommand(
                        title: "install",
                        profile: profile,
                        command: OgentLinuxRuntime.profileInstallCommand(profile: profile),
                        timeout: 300
                    )
                    sections.append("""
                    profile_prepare profile=\(profile) phase=install
                    \(install)
                    """)

                    let final = runProfileCommand(
                        title: "final",
                        profile: profile,
                        command: OgentLinuxRuntime.profileStatusCommand(profile: profile),
                        timeout: 45
                    )
                    sections.append("""
                    profile_prepare profile=\(profile) phase=final
                    \(final)
                    """)
                }
                continuation.resume(returning: sections.joined(separator: "\n\n"))
            }
        }
    }

    private static func runProfileCommand(
        title: String,
        profile: String,
        command: String,
        timeout: TimeInterval
    ) -> String {
        let result = ShellTool.runOnQueue(
            command: command,
            timeout: timeout,
            onProgress: { _ in }
        )
        let output = (result.text ?? "")
            .replacingOccurrences(of: #"\n?\[exit=[^\n]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return "profile_prepare_output=empty profile=\(profile) phase=\(title)"
        }
        return output
    }
}

