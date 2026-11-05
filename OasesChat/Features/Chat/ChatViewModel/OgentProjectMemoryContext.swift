// i18n-ignore-file: model-facing memory/bootstrap context prompts and self-tests; no UI copy.

enum OgentProjectMemoryContextLoader {
    private static let nativeRepository = MemoryRepository.shared
    private static let nativeRetriever = MemoryRetriever(repository: MemoryRepository.shared)
    private static let nativeWikiRepository = MemoryWikiRepository.shared

    static func memoryContextPromptForSelfTest(query: String, searchResult: String) -> String {
        memoryContextPrompt(query: query, searchResult: searchResult)
    }

    static func bootstrapContextPromptForSelfTest(
        query: String,
        status: String,
        snapshot: String,
        wikiSummary: String,
        searchResult: String
    ) -> String {
        bootstrapContextPrompt(
            query: query,
            status: status,
            snapshot: snapshot,
            wikiSummary: wikiSummary,
            searchResult: searchResult,
            includeSnapshot: true
        )
    }

    static func loadRelevantMemory(query: String) async -> String? {
        let cleanQuery = normalizedQuery(query)
        guard cleanQuery.count >= 2 else { return nil }
        let searchResult = await combinedSearchResult(query: cleanQuery)
        guard isUsefulSearchResult(searchResult) else { return nil }
        return memoryContextPrompt(query: cleanQuery, searchResult: searchResult)
    }

    static func loadBootstrapContext(query: String, snapshot: String? = nil, includeSnapshot: Bool = true) async -> String? {
        let cleanQuery = normalizedQuery(query)
        guard cleanQuery.count >= 2 else { return nil }

        let status = await runOgentCommand(OgentLinuxRuntime.statusCommand, timeout: 8, limit: 1_400)
        let snapshotText: String
        if let snapshot,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotText = snapshot
        } else if includeSnapshot {
            snapshotText = await runOgentCommand(OgentLinuxRuntime.workspaceSnapshotCommand, timeout: 12, limit: 3_500)
        } else {
            snapshotText = ""
        }
        let nativeSummary = await nativeWikiSummary()
        let wikiSummary = nativeSummary.isEmpty
            ? await runOgentCommand(OgentLinuxRuntime.wikiSummaryCommand, timeout: 10, limit: 1_800)
            : nativeSummary
        let searchResult = await combinedSearchResult(query: cleanQuery)

        let context = bootstrapContextPrompt(
            query: cleanQuery,
            status: status,
            snapshot: snapshotText,
            wikiSummary: wikiSummary,
            searchResult: searchResult,
            includeSnapshot: includeSnapshot
        )
        let hasRuntimeContext = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !snapshotText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !wikiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isUsefulSearchResult(searchResult)
        return hasRuntimeContext ? context : nil
    }

    static func runSelfTest() async -> String {
        let marker = "ogent_rag_context_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let body = """
        # Ogent RAG Context Selftest

        \(marker)

        This page proves project mode can retrieve a wiki memory and inject it as local context before the model runs.
        """
        let wrote = await writeMemory(title: "rag-context-selftest", body: body)
        guard wrote else {
            return "rag_context_failed: memory write failed"
        }
        let result = await searchRAG(query: marker)
        guard isUsefulSearchResult(result), result.contains(marker) else {
            return "rag_context_failed: marker missing"
        }
        let prompt = memoryContextPrompt(query: marker, searchResult: result)
        let ok = prompt.contains("工程模式本机记忆")
            && prompt.contains(marker)
            && prompt.contains("Ogent RAG search")
        return ok ? "rag_context_ok marker=\(marker)" : "rag_context_failed: prompt missing marker"
    }

    static func runBootstrapSelfTest() async -> String {
        let marker = "ogent_bootstrap_context_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let body = """
        # Ogent Bootstrap Context Selftest

        \(marker)

        This page proves project mode injects local runtime status, workspace, wiki summary, and relevant RAG before the model runs.
        """
        guard await writeMemory(title: "bootstrap-context-selftest", body: body) else {
            return "bootstrap_context_failed: memory write failed"
        }
        guard let context = await loadBootstrapContext(query: marker, includeSnapshot: true) else {
            return "bootstrap_context_failed: context unavailable"
        }
        let ok = context.contains("工程模式本机状态")
            && context.contains("Ogent Agent Runtime")
            && context.contains("Ogent workspace snapshot")
            && context.contains("Ogent wiki summary")
            && context.contains(marker)
        return ok ? "bootstrap_context_ok marker=\(marker)" : "bootstrap_context_failed: prompt missing marker"
    }

    static func runOpportunisticMemorySelfTest() async -> String {
        let marker = "ogent_opportunistic_ctx_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let prompt = "帮我制作一个 word 文档，主题包含 \(marker)"
        let body = """
        # Ogent Opportunistic Memory Selftest

        \(marker)

        This page proves ordinary project tasks auto-query local wiki/RAG even when the user did not explicitly ask for memory.
        """
        guard await writeMemory(title: "opportunistic-memory-selftest", body: body) else {
            return "opportunistic_memory_failed: memory write failed"
        }
        let plan = ProjectAgentPlanner.plan(for: prompt, iteration: 1, executedToolCalls: 0)
        guard OgentProjectMemoryPolicy.shouldLoadRelevantMemory(for: plan) else {
            return "opportunistic_memory_failed: policy skipped kind=\(plan.kind.rawValue) context=\(plan.contextPolicy.rawValue)"
        }
        let query = ProjectAgentPlanner.memoryQuery(prompt: prompt, snapshot: nil)
        guard let context = await loadRelevantMemory(query: query) else {
            return "opportunistic_memory_failed: context unavailable"
        }
        let ok = context.contains("工程模式本机记忆")
            && context.contains(marker)
            && context.contains("Ogent RAG search")
        return ok ? "opportunistic_memory_ok marker=\(marker)" : "opportunistic_memory_failed: marker missing"
    }

    private static func writeMemory(title: String, body: String) async -> Bool {
        guard await persistNativeMemory(title: title, body: body, tags: ["selftest", "rag", "context"]) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: false)
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.memoryAddCommand(title: title, body: body, tags: "selftest,rag,context"),
                    timeout: 45,
                    onProgress: { _ in }
                )
                let text = result.text ?? ""
                continuation.resume(returning: commandSucceeded(text, markers: ["memory page saved"]))
            }
        }
    }

    static func persistNativeMemory(title: String, body: String, tags: Set<String>) async -> Bool {
        let document = MemoryDocument(
            title: title,
            body: body,
            tags: tags,
            provenance: MemoryProvenance(source: "oases.project")
        )
        do {
            _ = try await nativeRepository.save(document)
            try await nativeRetriever.rebuildIndex()
            return true
        } catch {
            NSLog("[OgentMemory] native repository error: %@", error.localizedDescription)
            return false
        }
    }

    static func persistNativeWiki(
        topic: String,
        title: String,
        body: String,
        tags: [String],
        relatedTopics: [String]
    ) async -> Bool {
        do {
            _ = try await nativeWikiRepository.upsert(
                topic: topic,
                title: title,
                body: body,
                tags: tags,
                relatedTopics: relatedTopics,
                provenance: MemoryProvenance(source: "oases.project.living-wiki")
            )
            return true
        } catch {
            NSLog("[OgentMemory] native wiki repository error: %@", error.localizedDescription)
            return false
        }
    }

    private static func commandSucceeded(_ text: String, markers: [String] = []) -> Bool {
        if text.contains("[exit=0") {
            return true
        }
        return markers.contains { marker in
            !marker.isEmpty && text.contains(marker)
        }
    }

    private static func runOgentCommand(_ command: String, timeout: TimeInterval, limit: Int) async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: command,
                    timeout: timeout,
                    onProgress: { _ in }
                )
                let output = cleanCommandOutput(result.text ?? "")
                continuation.resume(returning: truncate(output, limit: limit))
            }
        }
    }

    private static func searchRAG(query: String) async -> String {
        await withCheckedContinuation { continuation in
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    continuation.resume(returning: "")
                    return
                }
                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.ragSearchCommand(query: query),
                    timeout: 25,
                    onProgress: { _ in }
                )
                let output = (result.text ?? "")
                continuation.resume(returning: truncate(cleanCommandOutput(output), limit: 2_400))
            }
        }
    }

    private static func nativeWikiSummary() async -> String {
        do {
            let pages = try await nativeWikiRepository.all()
            guard !pages.isEmpty else { return "" }
            var lines = [
                "Ogent wiki summary (native iOS repository)",
                "topic_pages=\(pages.count)",
                ""
            ]
            for page in pages.reversed().prefix(24) {
                lines.append("- \(page.topic) | \(page.title) | revision=\(page.revision)")
            }
            return lines.joined(separator: "\n")
        } catch {
            NSLog("[OgentMemory] native wiki summary error: %@", error.localizedDescription)
            return ""
        }
    }

    private static func nativeSearch(query: String) async -> String {
        do {
            let results = try await nativeRetriever.search(query)
            guard !results.isEmpty else { return "" }
            var lines = ["Oases native memory search", "query=\(query)", ""]
            for result in results {
                lines.append("--- score=\(String(format: "%.2f", result.score)) source=ios-memory title=\(result.document.title) ---")
                lines.append(result.document.body)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            NSLog("[OgentMemory] native search error: %@", error.localizedDescription)
            return ""
        }
    }

    private static func nativeWikiSearch(query: String) async -> String {
        do {
            let results = try await nativeWikiRepository.search(query, limit: 6)
            guard !results.isEmpty else { return "" }
            var lines = ["Oases native living wiki search", "query=\(query)", ""]
            for result in results {
                lines.append("--- score=\(result.score) source=ios-wiki revision=\(result.page.revision) topic=\(result.page.topic) title=\(result.page.title) ---")
                lines.append(result.page.body)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        } catch {
            NSLog("[OgentMemory] native wiki search error: %@", error.localizedDescription)
            return ""
        }
    }

    private static func combinedSearchResult(query: String) async -> String {
        let nativeWiki = await nativeWikiSearch(query: query)
        let native = await nativeSearch(query: query)
        let nativeResult = [nativeWiki, native]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if isUsefulSearchResult(nativeResult) {
            return nativeResult
        }

        let shell = await searchRAG(query: query)
        guard isUsefulSearchResult(shell) else { return "" }
        return "Oases iSH RAG mirror fallback\nquery=\(query)\n\n\(shell)"
    }

    private static func isUsefulSearchResult(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.localizedCaseInsensitiveContains("no rag matches") { return false }
        if text.localizedCaseInsensitiveContains("no rag index yet") { return false }
        if text.localizedCaseInsensitiveContains("usage: ogent-agent rag-search") { return false }
        return text.contains("--- score=")
    }

    private static func memoryContextPrompt(query: String, searchResult: String) -> String {
        """
        [工程模式本机记忆]
        下面是 iPhone 本机原生 Memory/Wiki 索引针对当前用户目标检索到的相关记忆。只有在原生索引没有命中时，才会出现标记为 iSH mirror fallback 的来宾系统结果。请把它当作可用上下文，但不要机械复述；如果它和用户当前目标冲突，以当前目标为准。

        query=\(query)

        \(searchResult)
        [/工程模式本机记忆]
        """
    }

    private static func bootstrapContextPrompt(
        query: String,
        status: String,
        snapshot: String,
        wikiSummary: String,
        searchResult: String,
        includeSnapshot: Bool
    ) -> String {
        let relevantMemory = isUsefulSearchResult(searchResult)
                ? truncate(searchResult, limit: 1_800)
            : "no matching RAG memory for this exact query"
        let snapshotBlock: String
        if includeSnapshot {
            snapshotBlock = snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "workspace snapshot unavailable; call `ogent_agent workspace_snapshot` if needed"
                : truncate(snapshot, limit: 2_400)
        } else {
            snapshotBlock = "resume snapshot already provided in [工程模式恢复上下文]; call `ogent_agent workspace_snapshot` only if that snapshot is insufficient"
        }
        return """
        [工程模式本机状态]
        下面是模型启动前自动读取的 iPhone 本机状态。原生 Memory/Wiki 是长期记忆主数据源，iSH/Ogent 是执行环境与必要时的镜像回退。先按这些状态接续任务：如果已有计划、会话、日志或 artifacts，优先复用并交付，不要从零重跑；如果 latest status 或 artifacts 已显示可交付成果，先总结并交付。

        user_goal=\(query)

        -- runtime status --
        \(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "status unavailable" : truncate(status, limit: 1_200))

        -- workspace / delivery state --
        \(snapshotBlock)

        -- living wiki map --
        \(wikiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "wiki summary unavailable" : truncate(wikiSummary, limit: 1_400))

        -- relevant wiki/RAG --
        \(relevantMemory)
        [/工程模式本机状态]
        """
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func cleanCommandOutput(_ output: String) -> String {
        output
            .replacingOccurrences(of: #"\n?\[exit=[^\n]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit)) + "\n...[truncated \(clean.count - limit) chars]"
    }
}

