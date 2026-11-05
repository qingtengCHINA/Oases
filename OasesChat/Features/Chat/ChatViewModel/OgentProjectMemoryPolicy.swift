// i18n-ignore-file: Ogent wiki/RAG memory records (persisted agent data, titles string-matched) and self-tests; no UI copy.

enum OgentProjectMemoryPolicy {
    static func shouldLoadRelevantMemory(for plan: ProjectAgentPlan) -> Bool {
        guard plan.exposesTools, plan.kind != .conversation else { return false }
        guard !plan.isContinuation else { return false }
        return plan.contextPolicy == .none
    }

    static func runSelfTest() -> String {
        let deliveryPlan = ProjectAgentPlanner.plan(
            for: "帮我爬取 oilprice.com 的三天新闻信息，并写入 word 文档",
            iteration: 1,
            executedToolCalls: 0
        )
        let plainPlan = ProjectAgentPlanner.plan(
            for: "你好",
            iteration: 1,
            executedToolCalls: 0
        )
        let continuationPlan = ProjectAgentPlanner.plan(
            for: "继续",
            iteration: 1,
            executedToolCalls: 0
        )
        let memoryKeywordPlan = ProjectAgentPlanner.plan(
            for: "根据以前的 wiki 记忆继续整理",
            iteration: 1,
            executedToolCalls: 0
        )
        let deliveryOK = shouldLoadRelevantMemory(for: deliveryPlan)
        let plainOK = !shouldLoadRelevantMemory(for: plainPlan)
        let continuationOK = !shouldLoadRelevantMemory(for: continuationPlan)
        let memoryKeywordOK = !shouldLoadRelevantMemory(for: memoryKeywordPlan)
        let ok = deliveryOK && plainOK && continuationOK && memoryKeywordOK
        return [
            "project_memory_policy_selftest",
            ok ? "project_memory_policy_ok" : "project_memory_policy_failed",
            "delivery_auto_memory=\(deliveryOK ? 1 : 0) kind=\(deliveryPlan.kind.rawValue) context=\(deliveryPlan.contextPolicy.rawValue)",
            "plain_skipped=\(plainOK ? 1 : 0) kind=\(plainPlan.kind.rawValue) context=\(plainPlan.contextPolicy.rawValue)",
            "continuation_skipped=\(continuationOK ? 1 : 0) kind=\(continuationPlan.kind.rawValue) context=\(continuationPlan.contextPolicy.rawValue)",
            "memory_keyword_skipped=\(memoryKeywordOK ? 1 : 0) kind=\(memoryKeywordPlan.kind.rawValue) context=\(memoryKeywordPlan.contextPolicy.rawValue)"
        ].joined(separator: "\n")
    }
}

enum OgentConversationMemoryIngestor {
    private static func commandSucceeded(_ text: String, markers: [String] = []) -> Bool {
        if text.contains("[exit=0") {
            return true
        }
        return markers.contains { marker in
            !marker.isEmpty && text.contains(marker)
        }
    }

    static func runSelfTest() async -> String {
        let marker = "ogent_auto_memory_selftest_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let wikiMarker = "\(marker)_wiki"
        let snapshotMarker = "\(marker)_snapshot"
        let conversationID = "auto-wiki-selftest"
        let title = "自动记忆 living wiki 自测"
        let finalizerSnapshot = """
        Ogent finalizer checkpoint
        delivery_state=ready_to_summarize
        artifact_count=1
        --- recent session ---
        - kind: project_tool_trace
        - tool: artifact_bridge
        - status: completed
        - output_digest: Created DOCX \(snapshotMarker).docx ios=/tmp/Ogent Artifacts/\(snapshotMarker).docx [exit=0]
        """
        let body = memoryBody(
            conversationTitle: title,
            conversationID: conversationID,
            model: "selftest",
            userPrompt: "验证工程模式自动记忆会更新稳定 wiki topic",
            assistantText: "auto_wiki_memory_selftest_delivery_ok",
            toolCalls: [],
            finalizerSnapshot: finalizerSnapshot,
            marker: marker
        )
        let wikiBody = livingWikiBody(
            conversationTitle: title,
            conversationID: conversationID,
            model: "selftest",
            userPrompt: "验证工程模式自动记忆会更新稳定 wiki topic",
            assistantText: "auto_wiki_memory_selftest_delivery_ok",
            toolCalls: [],
            finalizerSnapshot: finalizerSnapshot,
            marker: marker,
            wikiMarker: wikiMarker
        )
        guard body.contains(snapshotMarker),
              body.contains("project_tool_trace"),
              wikiBody.contains(snapshotMarker),
              wikiBody.contains("Local Finalizer / Session Clues") else {
            return "auto_wiki_memory_failed snapshot_body=false marker=\(snapshotMarker)"
        }
        let topic = memoryTopic(conversationID: conversationID, userPrompt: "", fallback: title)

        return await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "auto_wiki_memory_failed bootstrap=false")
                    return
                }
                let memory = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.memoryAddCommand(title: title, body: body, tags: "selftest,auto,project"),
                    timeout: 20,
                    onProgress: { _ in }
                )
                let memoryText = memory.text ?? ""
                guard commandSucceeded(memoryText, markers: ["memory page saved"]) else {
                    continuation.resume(returning: "auto_wiki_memory_failed memory_add=false output=\(String(memoryText.prefix(180)))")
                    return
                }
                let wiki = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.wikiUpsertCommand(
                        topic: topic,
                        title: title,
                        body: wikiBody,
                        tags: "selftest,auto,living-wiki",
                        related: "project-turns,auto-memory"
                    ),
                    timeout: 20,
                    onProgress: { _ in }
                )
                let wikiText = wiki.text ?? ""
                guard commandSucceeded(wikiText, markers: ["wiki_upsert_ok"]), wikiText.contains("wiki_upsert_ok") else {
                    continuation.resume(returning: "auto_wiki_memory_failed wiki_upsert=false output=\(String(wikiText.prefix(180)))")
                    return
                }
                let verify = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.ragVerifyCommand(query: wikiMarker),
                    timeout: 45,
                    onProgress: { _ in }
                )
                let verifyText = verify.text ?? ""
                let ok = commandSucceeded(verifyText, markers: ["rag_index_marker_ok", wikiMarker])
                    && verifyText.contains(wikiMarker)
                let snapshotVerify = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.ragVerifyCommand(query: snapshotMarker),
                    timeout: 45,
                    onProgress: { _ in }
                )
                let snapshotVerifyText = snapshotVerify.text ?? ""
                let snapshotOK = commandSucceeded(snapshotVerifyText, markers: ["rag_index_marker_ok", snapshotMarker])
                    && snapshotVerifyText.contains(snapshotMarker)
                continuation.resume(returning: ok
                    && snapshotOK
                    ? "auto_wiki_memory_ok marker=\(wikiMarker) topic=\(topic) snapshot=\(snapshotMarker)"
                    : "auto_wiki_memory_failed rag=false marker=\(wikiMarker) snapshot=\(snapshotMarker) output=\(String((verifyText + "\n" + snapshotVerifyText).prefix(240)))")
            }
        }
    }

    static func runCompactionSelfTest() async -> String {
        let marker = "ogent_compaction_selftest_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let result = ProjectAgentContextCompactorSelfTest.persistenceFixture(marker: marker)
        guard result.didCompact,
              let summary = result.persistentSummary,
              summary.contains(marker) else {
            return "compaction_memory_failed compact=false marker=\(marker)"
        }

        let title = "上下文压缩记忆自测"
        let conversationID = "compaction-memory-selftest"
        let topic = memoryTopic(conversationID: conversationID, userPrompt: marker, fallback: title)
        let body = compactionMemoryBody(
            conversationTitle: title,
            conversationID: conversationID,
            model: "selftest",
            userPrompt: "验证 90% 自动上下文压缩摘要会持久化到 Ogent wiki/RAG \(marker)",
            stage: "selftest",
            result: result,
            summary: summary,
            marker: marker
        )

        return await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "compaction_memory_failed bootstrap=false")
                    return
                }

                let session = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionNoteCommand(sessionID: "", note: body),
                    timeout: 20,
                    onProgress: { _ in }
                )
                let sessionText = session.text ?? ""
                guard commandSucceeded(sessionText, markers: ["session note appended"]) else {
                    continuation.resume(returning: "compaction_memory_failed session=false output=\(String(sessionText.prefix(180)))")
                    return
                }

                let memory = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.memoryAddCommand(
                        title: title,
                        body: body,
                        tags: "selftest,context-compaction,project"
                    ),
                    timeout: 20,
                    onProgress: { _ in }
                )
                let memoryText = memory.text ?? ""
                guard commandSucceeded(memoryText, markers: ["memory page saved"]) else {
                    continuation.resume(returning: "compaction_memory_failed memory=false output=\(String(memoryText.prefix(180)))")
                    return
                }

                let wiki = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.wikiUpsertCommand(
                        topic: topic,
                        title: title,
                        body: body,
                        tags: "selftest,living-wiki,context-compaction",
                        related: "project-turns,context-compaction"
                    ),
                    timeout: 20,
                    onProgress: { _ in }
                )
                let wikiText = wiki.text ?? ""
                guard commandSucceeded(wikiText, markers: ["wiki_upsert_ok"]), wikiText.contains("wiki_upsert_ok") else {
                    continuation.resume(returning: "compaction_memory_failed wiki=false output=\(String(wikiText.prefix(180)))")
                    return
                }

                let verify = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.ragVerifyCommand(query: marker),
                    timeout: 45,
                    onProgress: { _ in }
                )
                let verifyText = verify.text ?? ""
                let ok = commandSucceeded(verifyText, markers: ["rag_index_marker_ok", marker])
                    && verifyText.contains(marker)
                let finalizerSnapshot = awaitFinalizerSnapshotOnQueue()
                let finalizerOK = finalizerSnapshot.contains(marker)
                    && finalizerSnapshot.contains("project_context_compaction_memory")
                    && finalizerSnapshot.contains("Recovery Contract")
                continuation.resume(returning: ok
                    && finalizerOK
                    ? "compaction_memory_ok marker=\(marker) topic=\(topic) finalizer_snapshot=ok"
                    : "compaction_memory_failed rag=\(ok) finalizer=\(finalizerOK) marker=\(marker) output=\(String((verifyText + "\n" + finalizerSnapshot).prefix(360)))")
            }
        }
    }

    static func recordProjectTurn(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        assistantText: String,
        toolCalls: [ToolCall],
        sessionID: String? = nil
    ) {
        let title = memoryTitle(userPrompt: userPrompt, fallback: conversationTitle)
        let marker = "ogent_auto_memory_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let wikiMarker = "\(marker)_wiki"
        let topic = memoryTopic(conversationID: conversationID, userPrompt: userPrompt, fallback: conversationTitle)

        ISHRuntimeQueue.async {
            guard ISHRuntimeBootstrap.bootstrap() else {
                NSLog("[OgentMemory] bootstrap failed; skipped auto memory")
                return
            }
            let snapshotResult = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.finalizerSnapshotCommand,
                timeout: 15,
                onProgress: { _ in }
            )
            let finalizerSnapshot = snapshotResult.text ?? ""
            let body = memoryBody(
                conversationTitle: conversationTitle,
                conversationID: conversationID,
                model: model,
                userPrompt: userPrompt,
                assistantText: assistantText,
                toolCalls: toolCalls,
                finalizerSnapshot: finalizerSnapshot,
                marker: marker
            )
            let wikiBody = livingWikiBody(
                conversationTitle: conversationTitle,
                conversationID: conversationID,
                model: model,
                userPrompt: userPrompt,
                assistantText: assistantText,
                toolCalls: toolCalls,
                finalizerSnapshot: finalizerSnapshot,
                marker: marker,
                wikiMarker: wikiMarker
            )
            Task {
                let saved = await OgentProjectMemoryContextLoader.persistNativeMemory(
                    title: title,
                    body: body,
                    tags: ["auto", "project", "conversation"]
                )
                if !saved {
                    NSLog("[OgentMemory] native repository rejected project turn")
                }
                let savedWiki = await OgentProjectMemoryContextLoader.persistNativeWiki(
                    topic: topic,
                    title: title,
                    body: wikiBody,
                    tags: ["auto", "project", "living-wiki"],
                    relatedTopics: ["project-turns", "auto-memory"]
                )
                if !savedWiki {
                    NSLog("[OgentMemory] native wiki repository rejected project turn")
                }
            }
            if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let session = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.sessionNoteCommand(sessionID: sessionID, note: body),
                    timeout: 20,
                    onProgress: { line in
                        NSLog("[OgentMemory] project turn session %@", line.trimmingCharacters(in: .newlines))
                    }
                )
                let sessionOutput = session.text ?? ""
                if !commandSucceeded(sessionOutput, markers: ["session note appended"]) {
                    NSLog("[OgentMemory] project turn session note may have failed: %@", String(sessionOutput.prefix(1_000)))
                }
            }
            let result = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.memoryAddCommand(
                    title: title,
                    body: body,
                    tags: "auto,project,conversation"
                ),
                timeout: 20,
                onProgress: { line in
                    NSLog("[OgentMemory] %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let output = result.text ?? ""
            if !commandSucceeded(output, markers: ["memory page saved"]) {
                NSLog("[OgentMemory] auto memory write may have failed: %@", String(output.prefix(1_000)))
                return
            }

            let wiki = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.wikiUpsertCommand(
                    topic: topic,
                    title: title,
                    body: wikiBody,
                    tags: "auto,project,living-wiki",
                    related: "project-turns,auto-memory"
                ),
                timeout: 20,
                onProgress: { line in
                    NSLog("[OgentMemory] wiki %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let wikiOutput = wiki.text ?? ""
            if !commandSucceeded(wikiOutput, markers: ["wiki_upsert_ok"]) || !wikiOutput.contains("wiki_upsert_ok") {
                NSLog("[OgentMemory] auto wiki upsert may have failed: %@", String(wikiOutput.prefix(1_000)))
            }

            let verify = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.ragVerifyCommand(query: marker),
                timeout: 45,
                onProgress: { line in
                    NSLog("[OgentMemory] verify %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let verifyOutput = verify.text ?? ""
            if commandSucceeded(verifyOutput, markers: ["rag_index_marker_ok", marker]), verifyOutput.contains(marker) {
                NSLog("[OgentMemory] auto memory rag verified marker=%@", marker)
            } else {
                NSLog("[OgentMemory] auto memory rag verification failed marker=%@ output=%@",
                      marker,
                      String(verifyOutput.prefix(1_000)))
            }

            let wikiVerify = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.ragVerifyCommand(query: wikiMarker),
                timeout: 45,
                onProgress: { line in
                    NSLog("[OgentMemory] wiki verify %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let wikiVerifyOutput = wikiVerify.text ?? ""
            if commandSucceeded(wikiVerifyOutput, markers: ["rag_index_marker_ok", wikiMarker]), wikiVerifyOutput.contains(wikiMarker) {
                NSLog("[OgentMemory] auto wiki rag verified marker=%@ topic=%@", wikiMarker, topic)
            } else {
                NSLog("[OgentMemory] auto wiki rag verification failed marker=%@ output=%@",
                      wikiMarker,
                      String(wikiVerifyOutput.prefix(1_000)))
            }
        }
    }

    static func recordContextCompaction(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        stage: String,
        result: ProjectAgentContextCompactor.Result
    ) {
        guard result.didCompact,
              let summary = result.persistentSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return }

        let marker = "ogent_compaction_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let topic = memoryTopic(conversationID: conversationID, userPrompt: userPrompt, fallback: conversationTitle)
        let title = "上下文压缩 - \(memoryTitle(userPrompt: userPrompt, fallback: conversationTitle).replacingOccurrences(of: "自动记忆 - ", with: ""))"
        let body = compactionMemoryBody(
            conversationTitle: conversationTitle,
            conversationID: conversationID,
            model: model,
            userPrompt: userPrompt,
            stage: stage,
            result: result,
            summary: summary,
            marker: marker
        )

        Task {
            let saved = await OgentProjectMemoryContextLoader.persistNativeMemory(
                title: title,
                body: body,
                tags: ["auto", "project", "context-compaction"]
            )
            if !saved {
                NSLog("[OgentMemory] native repository rejected compaction")
            }
            let savedWiki = await OgentProjectMemoryContextLoader.persistNativeWiki(
                topic: topic,
                title: title,
                body: body,
                tags: ["auto", "project", "living-wiki", "context-compaction"],
                relatedTopics: ["project-turns", "context-compaction", "auto-memory"]
            )
            if !savedWiki {
                NSLog("[OgentMemory] native wiki repository rejected compaction")
            }
        }

        ISHRuntimeQueue.async {
            guard ISHRuntimeBootstrap.bootstrap() else {
                NSLog("[OgentMemory] bootstrap failed; skipped compaction memory")
                return
            }
            let session = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.sessionNoteCommand(sessionID: "", note: body),
                timeout: 20,
                onProgress: { line in
                    NSLog("[OgentMemory] compaction session %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let sessionOutput = session.text ?? ""
            if !commandSucceeded(sessionOutput, markers: ["session note appended"]) {
                NSLog("[OgentMemory] compaction session note may have failed: %@", String(sessionOutput.prefix(1_000)))
            }

            let memory = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.memoryAddCommand(
                    title: title,
                    body: body,
                    tags: "auto,project,context-compaction"
                ),
                timeout: 20,
                onProgress: { line in
                    NSLog("[OgentMemory] compaction memory %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let memoryOutput = memory.text ?? ""
            if !commandSucceeded(memoryOutput, markers: ["memory page saved"]) {
                NSLog("[OgentMemory] compaction memory write may have failed: %@", String(memoryOutput.prefix(1_000)))
                return
            }

            let wiki = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.wikiUpsertCommand(
                    topic: topic,
                    title: title,
                    body: body,
                    tags: "auto,project,living-wiki,context-compaction",
                    related: "project-turns,context-compaction,auto-memory"
                ),
                timeout: 20,
                onProgress: { line in
                    NSLog("[OgentMemory] compaction wiki %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let wikiOutput = wiki.text ?? ""
            if !commandSucceeded(wikiOutput, markers: ["wiki_upsert_ok"]) || !wikiOutput.contains("wiki_upsert_ok") {
                NSLog("[OgentMemory] compaction wiki upsert may have failed: %@", String(wikiOutput.prefix(1_000)))
            }

            let verify = ShellTool.runOnQueue(
                command: OgentLinuxRuntime.ragVerifyCommand(query: marker),
                timeout: 45,
                onProgress: { line in
                    NSLog("[OgentMemory] compaction verify %@", line.trimmingCharacters(in: .newlines))
                }
            )
            let verifyOutput = verify.text ?? ""
            if commandSucceeded(verifyOutput, markers: ["rag_index_marker_ok", marker]), verifyOutput.contains(marker) {
                NSLog("[OgentMemory] compaction rag verified marker=%@", marker)
            } else {
                NSLog("[OgentMemory] compaction rag verification failed marker=%@ output=%@",
                      marker,
                      String(verifyOutput.prefix(1_000)))
            }
        }
    }

    private static func awaitFinalizerSnapshotOnQueue() -> String {
        let result = ShellTool.runOnQueue(
            command: OgentLinuxRuntime.finalizerSnapshotCommand,
            timeout: 15,
            onProgress: { _ in }
        )
        return result.text ?? ""
    }

    private static func memoryTopic(conversationID: String, userPrompt: String, fallback: String) -> String {
        let id = conversationID
            .replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        if !id.isEmpty {
            return "conversation-\(String(id.prefix(48)))"
        }
        let source = userPrompt.isEmpty ? fallback : userPrompt
        let slug = source
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return "conversation-\(slug.isEmpty ? "project-turns" : String(slug.prefix(48)))"
    }

    private static func memoryTitle(userPrompt: String, fallback: String) -> String {
        let source = userPrompt.isEmpty ? fallback : userPrompt
        let collapsed = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = collapsed.isEmpty ? "工程模式回合" : String(collapsed.prefix(42))
        return "自动记忆 - \(head)"
    }

    private static func memoryBody(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        assistantText: String,
        toolCalls: [ToolCall],
        finalizerSnapshot: String = "",
        marker: String
    ) -> String {
        var lines: [String] = [
            "## 来源",
            "- kind: project_turn_auto_memory",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- conversation_title: \(conversationTitle)",
            "- conversation_id: \(conversationID)",
            "- model: \(model)",
            "- memory_marker: \(marker)",
            "",
            "## 用户目标",
            truncate(userPrompt.isEmpty ? "(empty)" : userPrompt, limit: 1_500),
            "",
            "## 最终交付 / 回答",
            truncate(assistantText, limit: 4_000)
        ]

        if !toolCalls.isEmpty {
            lines.append("")
            lines.append("## 工具与产物线索")
            for call in toolCalls.prefix(12) {
                lines.append("- \(call.displayName ?? call.name) (`\(call.name)`) status=\(call.status.rawValue)\(durationSuffix(call))")
                if let output = call.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    lines.append(indent(truncate(extractUsefulToolOutput(output), limit: 900)))
                }
            }
        }
        let snapshotClues = snapshotMemoryClues(from: finalizerSnapshot)
        if !snapshotClues.isEmpty {
            lines.append("")
            lines.append("## 本机 finalizer / session 线索")
            lines.append(contentsOf: snapshotClues.prefix(24).map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private static func compactionMemoryBody(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        stage: String,
        result: ProjectAgentContextCompactor.Result,
        summary: String,
        marker: String
    ) -> String {
        [
            "## Context Compaction Checkpoint",
            "",
            "- kind: project_context_compaction_memory",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- conversation_title: \(conversationTitle)",
            "- conversation_id: \(conversationID)",
            "- model: \(model)",
            "- stage: \(stage)",
            "- compaction_marker: \(marker)",
            "- before_tokens: \(result.beforeTokens)",
            "- after_tokens: \(result.afterTokens)",
            "- budget_tokens: \(result.budgetTokens)",
            "- compacted_messages: \(result.compactedMessages)",
            "",
            "## Recovery Contract",
            "- recovery_policy: continue_from_current_ogent_session",
            "- resume_source: session_note + living_wiki + local_rag",
            "- preserved_suffix: latest tool-call protocol block stays in model context",
            "- no_restart_rule: reuse completed tool results and artifacts before running new tools",
            "",
            "## User Goal At Compaction",
            truncate(userPrompt.isEmpty ? "(empty)" : userPrompt, limit: 1_200),
            "",
            "## Persisted Summary",
            truncate(summary, limit: 4_000)
        ].joined(separator: "\n")
    }

    private static func livingWikiBody(
        conversationTitle: String,
        conversationID: String,
        model: String,
        userPrompt: String,
        assistantText: String,
        toolCalls: [ToolCall],
        finalizerSnapshot: String = "",
        marker: String,
        wikiMarker: String
    ) -> String {
        var lines: [String] = [
            "## Latest Engineering Turn",
            "",
            "- kind: project_turn_living_wiki",
            "- recorded_at: \(ISO8601DateFormatter().string(from: Date()))",
            "- conversation_title: \(conversationTitle)",
            "- conversation_id: \(conversationID)",
            "- model: \(model)",
            "- memory_marker: \(marker)",
            "- wiki_marker: \(wikiMarker)",
            "",
            "### User Goal",
            truncate(userPrompt.isEmpty ? "(empty)" : userPrompt, limit: 1_200),
            "",
            "### Delivery State",
            truncate(assistantText.isEmpty ? "(empty)" : assistantText, limit: 2_400)
        ]
        let completedArtifacts = toolCalls
            .compactMap { $0.output }
            .flatMap { output in
                output
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { $0.contains("[oases:open]") || $0.contains("ios=") || $0.localizedCaseInsensitiveContains("artifact") }
            }
            .prefix(12)
        if !completedArtifacts.isEmpty {
            lines.append("")
            lines.append("### Artifact Links")
            lines.append(contentsOf: completedArtifacts.map { "- \($0)" })
        }
        let snapshotClues = snapshotMemoryClues(from: finalizerSnapshot)
        if !snapshotClues.isEmpty {
            lines.append("")
            lines.append("### Local Finalizer / Session Clues")
            lines.append(contentsOf: snapshotClues.prefix(18).map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func durationSuffix(_ call: ToolCall) -> String {
        guard let started = call.startedAt, let ended = call.endedAt else { return "" }
        let seconds = max(0, ended.timeIntervalSince(started))
        return String(format: " duration=%.1fs", seconds)
    }

    private static func extractUsefulToolOutput(_ output: String) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let important = lines.filter { line in
            line.contains("[oases:open]")
                || line.contains("ios=")
                || line.contains("guest=")
                || line.localizedCaseInsensitiveContains("artifact")
                || line.localizedCaseInsensitiveContains("export")
                || line.localizedCaseInsensitiveContains("error")
                || line.localizedCaseInsensitiveContains("exit=")
        }
        let selected = important.isEmpty ? Array(lines.prefix(12)) : Array(important.prefix(18))
        return selected.joined(separator: "\n")
    }

    private static func snapshotMemoryClues(from snapshot: String) -> [String] {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needles = [
            "delivery_state=",
            "artifact_count=",
            "project_manifest_status=",
            "project_manifest_state=",
            "local_model_readiness_state=",
            "local_model_readiness_reason=",
            "local_model_next_command=",
            "completion_contract=",
            "expected_output=",
            "requires_artifact=",
            "latest_task_exit=",
            "project_tool_trace",
            "- tool:",
            "- status:",
            "- output_digest:",
            "- recovery_hint:",
            "[oases:open]",
            "ios=",
            "guest=",
            "[exit=",
            "error",
            "failed"
        ]
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in snapshot.split(separator: "\n", omittingEmptySubsequences: false) {
            let clean = String(rawLine)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            guard needles.contains(where: { clean.localizedCaseInsensitiveContains($0) }) else { continue }
            let line = String(clean.prefix(300))
            guard !seen.contains(line) else { continue }
            seen.insert(line)
            result.append(line)
            if result.count >= 32 { break }
        }
        return result
    }

    private static func indent(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n...[truncated \(text.count - limit) chars]"
    }
}

