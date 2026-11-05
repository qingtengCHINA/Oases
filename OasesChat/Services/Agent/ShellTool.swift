import Foundation

/// Bridge to iSH's `ISHShellExecutor`, exposed to Swift through the
/// project's bridging header. Every kernel call runs on
/// `ISHRuntimeQueue`'s dedicated thread so iSH's thread-local
/// `current` task pointer stays alive across init + every shell
/// invocation.
///
/// Uses the executor's `lineCallback` to stream stdout / stderr to
/// the agent's `onProgress` channel — the UI consumes the streaming
/// transcript in `ShellLiveTerminalView` while the command is still
/// running.
final class ShellTool: AgentTool, @unchecked Sendable {
    /// OpenMinis-aligned primary name. `shell_local` remains an invoke alias
    /// via `ToolRegistry.register(..., aliases:)`.
    let descriptor = ToolDescriptor(
        name: "shell_execute",
        summary: """
        Execute a command in an isolated Linux process (iSH/Alpine ARM64). The command runs via /bin/sh -c \
        with stdout and stderr captured. Use for package installs (apk), scripts, git, python/node, and any \
        Unix terminal work. Default timeout 900s. Working tree for agent files: /var/oases/workspace \
        (alias /var/minis/workspace). Prefer file_read/file_write/file_edit for text file I/O.
        Guest CLI `oases-config` reads or changes app settings — run `oases-config --help` for subcommands \
        and `oases-config topic-help <topic>` for one area. On `get`, array-valued fields accept \
        `--filter <keywords>` and `--page N --page-size N`; use those instead of dumping full lists. \
        Every write opens an in-app confirmation sheet and is logged to a revertable audit — relay the \
        response's `user_message` so the user knows how to review or revert. On `permission_denied` the \
        user disabled it in Settings → Permissions; relay that and don't retry. API keys and OAuth tokens \
        are write-only: `get` never echoes them.
        """,
        displayName: "Shell 执行", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "Shell 执行", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["command"],"properties":{"tool_title":{"type":"string","description":"Concise 5-10 word summary shown to the user (e.g. 'Install Python data packages')."},"command":{"type":"string","description":"The /bin/sh -c command line. Multi-line OK. Keep under 1000 chars; for longer scripts use file_write then run the file."},"timeout":{"type":"number","description":"Timeout in seconds (default 900). Use larger values for package installs."},"delay":{"type":"integer","description":"Optional delay in seconds before execution begins (does not hold the shell while waiting)."}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let command = (args["command"] as? String) ?? ""
        let timeoutNumber = (args["timeout"] as? Double) ?? 900
        let delaySeconds = max(0, (args["delay"] as? Int) ?? (args["delay"] as? Double).map { Int($0) } ?? 0)
        guard !command.isEmpty else {
            return .textOnly("Error: Missing required 'command' parameter for shell_execute.")
        }

        if delaySeconds > 0 {
            onProgress("[delay] waiting \(delaySeconds)s before shell_execute\n")
            try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
        }

        // Ensure the runtime is up before we touch the kernel.
        // Bootstrap is idempotent so the warm-call path is a single
        // boolean check.
        let ready: Bool = ISHRuntimeQueue.sync { ISHRuntimeBootstrap.bootstrap() }
        guard ready else {
            return .textOnly(Self.notReadyMessage)
        }

        // Prefer the concurrent ISHRuntimeService so multi-tool turns can
        // fan out; falls back to legacy queue path if the service is unavailable.
        let sessionId = OasesPathResolver.ActiveSession.id
        let ishCommand = ISHCommand(
            command: command,
            timeout: timeoutNumber,
            sessionId: sessionId
        )
        let result = await ISHRuntimeService.shared.execute(ishCommand)
        return Self.toolResult(from: result, onProgress: onProgress)
    }

    private static func toolResult(
        from result: ISHCommandResult,
        onProgress: @escaping @Sendable (String) -> Void
    ) -> ToolResult {
        let combined: String = {
            var parts: [String] = []
            if !result.stdout.isEmpty { parts.append(result.stdout) }
            if !result.stderr.isEmpty { parts.append("[stderr]\n\(result.stderr)") }
            return parts.joined(separator: "\n")
        }()
        if !combined.isEmpty {
            onProgress(combined.hasSuffix("\n") ? combined : combined + "\n")
        }
        switch result.termination {
        case .exited:
            let code = result.exitCode ?? -1
            let body = combined.isEmpty ? "(no output)" : combined
            return .textOnly("exit=\(code)\n\(body)")
        case .timedOut:
            // i18n-ignore: tool result the model reads
            return .textOnly("[shell_execute] 命令超时。\n\(combined)")
        case .cancelled:
            // i18n-ignore: tool result the model reads
            return .textOnly("[shell_execute] 已取消。\n\(combined)")
        case .runtimeNotReady:
            return .textOnly(notReadyMessage)
        default:
            // i18n-ignore: tool result the model reads
            return .textOnly("[shell_execute] 失败: \(result.termination)\n\(combined)")
        }
    }

    /// Invoke iSH's executor sync API while we're already on the
    /// dedicated runtime thread. The line callback fires from the
    /// reader thread iSH owns, so we relay each line straight into
    /// the agent's progress channel and accumulate a transcript for
    /// the final ToolResult.
    static func runOnQueue(
        command: String,
        timeout: TimeInterval,
        onProgress: @escaping @Sendable (String) -> Void
    ) -> ToolResult {
        // Buffer streamed lines into a transcript so the final
        // ToolResult always carries the full output, even if the
        // executor's `output` blob is empty (some commands emit only
        // through the line callback).
        let transcriptLock = NSLock()
        var transcript = ""
        let lineCallback: (String, Bool) -> Void = { line, isStderr in
            let prefix = isStderr ? "[stderr] " : ""
            let row = "\(prefix)\(line)\n"
            transcriptLock.lock()
            CommandOutputCap.append(row, to: &transcript)
            transcriptLock.unlock()
            onProgress(row)
        }

        func transcriptIsEmpty() -> Bool {
            transcriptLock.lock()
            let empty = transcript.isEmpty
            transcriptLock.unlock()
            return empty
        }

        func execute() -> ISHShellExecutionResult {
            // Only the launch runs on the iSH runtime thread; the wait is on this thread. Called
            // from the runtime thread itself (most callers), that is the old behaviour; called
            // from any other thread, a long command leaves the runtime thread free for other
            // sessions' shells and for its own kill.
            let callback = UncheckedLineCallback(lineCallback)
            let result = ISHShellExecutor.waitForCommandStarted(by: { completion in
                let done = UncheckedCompletion(completion)
                return ISHRuntimeQueue.sync {
                    ISHShellExecutor.executeCommand(
                        command,
                        lineCallback: { line, isStderr in callback.value(line, isStderr) },
                        completion: { done.value($0) }
                    )
                }
            }, timeout: timeout)
            ISHRuntimeQueue.async { _ = ISHShellExecutor.reapInitChildren() }
            return result
        }

        // Retry only when the process was never created. A timeout also
        // reports exit -1 with no output, but the command DID run — re-running
        // a silent long job would execute it up to five times.
        var result = execute()
        var retryCount = 0
        while isRetryableSpawnFailure(errorCode: Int(result.error.rawValue)),
              transcriptIsEmpty(),
              result.output.isEmpty,
              result.errorOutput.isEmpty,
              retryCount < 4 {
            let delay = min(1.2, 0.20 * pow(2.0, Double(retryCount)))
            Thread.sleep(forTimeInterval: delay)
            retryCount += 1
            result = execute()
        }

        let exitCode = Int(result.exitCode)
        let duration = result.duration
        let errorCode = Int(result.error.rawValue)

        if exitCode == -1, errorCode == ISHShellExecutorError.timeout.rawValue {
            // i18n-ignore: tool result the model reads
            return .textOnly("""
            [shell_execute] 命令超时（timeout=\(String(format: "%.0fs", timeout))）。
            进程可能已经退出但仍有后台子进程持有 stdout/stderr；iSH executor 会尝试回收 PID1 子进程。请缩小命令范围或提高 timeout 后重试。
            """)
        }

        // Diagnose the "exit=-1 instantly" failure mode the user hit:
        // ISHShellExecutorErrorProcessCreationFailed indicates
        // become_new_init_child returned negative. Surface a clear
        // hint instead of a bare "exit=-1".
        if exitCode == -1,
           errorCode == ISHShellExecutorError.processCreationFailed.rawValue,
           duration < 0.01,
           transcript.isEmpty {
            // i18n-ignore: tool result the model reads
            return .textOnly("""
            [shell_execute] 进程创建失败（become_new_init_child < 0）。
            可能原因：
              • iSH runtime 还未初始化完毕（首次冷启可能需要几秒，重试一次）
              • iSH dedicated runtime thread 未保持同一 pthread（thread pinning 失效）
            """)
        }

        var body = ""
        if !transcript.isEmpty {
            body += transcript
        } else if !result.output.isEmpty {
            body += result.output
        }
        if !result.errorOutput.isEmpty {
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            body += "[stderr]\n" + result.errorOutput
        }
        body += "\n[exit=\(exitCode), duration=\(String(format: "%.2fs", duration))]"

        return ToolResult(text: body, truncated: body.count > 24_000)
    }

    /// Whether a `runOnQueue` attempt failed before any guest process
    /// existed (transient `become_new_init_child` failure while the runtime
    /// warms up), so running it again cannot duplicate side effects. Timeouts,
    /// cancellations and exec failures are not retried.
    static func isRetryableSpawnFailure(errorCode: Int) -> Bool {
        errorCode == ISHShellExecutorError.processCreationFailed.rawValue
    }

    // i18n-ignore: tool result the model reads
    private static let notReadyMessage = """
    [shell_execute] iSH 沙箱未就绪。
    检查 console log 里 `[ISHRuntime]` 行，看哪一步退出码不为 0。
    """
}

// MARK: - Ogent Linux runtime

/// Thin Swift command builder for the rootfs-local `/usr/local/bin/ogent-agent`
/// runtime. The durable agent logic lives inside iSH; Swift only writes
/// payload files and invokes a stable CLI.
enum OgentLinuxRuntime {
    static let cliPath = "/usr/local/bin/ogent-agent"

    static var statusCommand: String {
        invoke("status")
    }

    static var rootfsDoctorCommand: String {
        invoke("rootfs-doctor")
    }

    static func rootfsRepairCommand(checkOnly: Bool = false) -> String {
        invoke("rootfs-repair\(checkOnly ? " --check-only" : "")")
    }

    static var rootfsOverlayStatusCommand: String {
        invoke("rootfs-overlay-status")
    }

    static var planReadCommand: String {
        invoke("plan-read")
    }

    static func planWriteCommand(title: String, steps: [String]) -> String {
        let body = steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, step in "- [ ] \(index + 1). \(step)" }
            .joined(separator: "\n")
        return withPayload(body) { file in
            invoke("plan-write --title \(shellQuote(title)) --file \(shellQuote(file))")
        }
    }

    static func noteAppendCommand(note: String) -> String {
        withPayload(note) { file in
            invoke("note-append --file \(shellQuote(file))")
        }
    }

    static func inboxAddCommand(message: String) -> String {
        withPayload(message) { file in
            invoke("inbox-add --file \(shellQuote(file))")
        }
    }

    static var inboxReadCommand: String {
        invoke("inbox-read")
    }

    static var workspaceSnapshotCommand: String {
        invoke("workspace-snapshot")
    }

    static var artifactListCommand: String {
        invoke("artifact-list")
    }

    static var artifactManifestCommand: String {
        invoke("artifact-manifest")
    }

    static func artifactExportCommand(path: String) -> String {
        invoke("artifact-list >/dev/null; printf '%s\\n' \(shellQuote(path))")
    }

    static func rememberCommand(key: String, value: String) -> String {
        withPayload(value) { file in
            invoke("memory-set --key \(shellQuote(key)) --file \(shellQuote(file))")
        }
    }

    static func memoryAddCommand(title: String, body: String, tags: String) -> String {
        withPayload(body) { file in
            let tagArg = tags.isEmpty ? "" : " --tags \(shellQuote(tags))"
            // i18n-ignore: default title passed to the Ogent runtime (shell argument)
            return invoke("memory-add --title \(shellQuote(title.isEmpty ? "工程记忆" : title))\(tagArg) --file \(shellQuote(file))")
        }
    }

    static func wikiUpsertCommand(topic: String, title: String, body: String, tags: String, related: String) -> String {
        withPayload(body) { file in
            // i18n-ignore: default title passed to the Ogent runtime (shell argument)
            let safeTopic = topic.isEmpty ? (title.isEmpty ? "工程记忆" : title) : topic
            let titleArg = title.isEmpty ? "" : " --title \(shellQuote(title))"
            let tagArg = tags.isEmpty ? "" : " --tags \(shellQuote(tags))"
            let relatedArg = related.isEmpty ? "" : " --related \(shellQuote(related))"
            return invoke("wiki-upsert --topic \(shellQuote(safeTopic))\(titleArg)\(tagArg)\(relatedArg) --file \(shellQuote(file))")
        }
    }

    static func recallCommand(key: String) -> String {
        let suffix = key.isEmpty ? "" : " \(shellQuote(key))"
        return invoke("memory-get\(suffix)")
    }

    static func memorySearchCommand(query: String) -> String {
        let suffix = query.isEmpty ? "" : " \(shellQuote(query))"
        return invoke("memory-search\(suffix)")
    }

    static var wikiSummaryCommand: String {
        invoke("wiki-summary")
    }

    static var wikiGraphCommand: String {
        invoke("wiki-graph")
    }

    static var ragRebuildCommand: String {
        invoke("rag-rebuild")
    }

    static func ragSearchCommand(query: String) -> String {
        invoke("rag-search \(shellQuote(query))")
    }

    static func ragVerifyCommand(query: String) -> String {
        let quoted = shellQuote(query)
        return """
        \(invoke("rag-rebuild >/dev/null 2>&1 || true"))
        \(invoke("rag-search \(quoted)"))
        search_status=$?
        if grep -F -- \(quoted) /root/.ogent/memory/rag.tsv >/dev/null 2>&1; then
          echo "rag_index_marker_ok"
          grep -F -- \(quoted) /root/.ogent/memory/rag.tsv | sed -n '1p'
          exit 0
        fi
        exit "$search_status"
        """
    }

    static var skillListCommand: String {
        invoke("skill-list")
    }

    static func subagentCreateCommand(name: String, instructions: String) -> String {
        withPayload(instructions) { file in
            invoke("subagent-create --name \(shellQuote(name.isEmpty ? "worker" : name)) --file \(shellQuote(file))")
        }
    }

    static var subagentListCommand: String {
        invoke("subagent-list")
    }

    static func subagentTaskCommand(name: String, task: String) -> String {
        withPayload(task) { file in
            invoke("subagent-task --name \(shellQuote(name.isEmpty ? "worker" : name)) --file \(shellQuote(file))")
        }
    }

    static func subagentRunCommand(name: String, taskID: String, allowHarness: Bool = false) -> String {
        let task = taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "latest" : taskID
        return invoke("subagent-run --name \(shellQuote(name.isEmpty ? "worker" : name)) --task \(shellQuote(task))\(allowHarness ? " --allow-harness" : "")")
    }

    static func automationCreateCommand(name: String, trigger: String, script: String) -> String {
        withPayload(script, fileExtension: "sh") { file in
            invoke("automation-create --name \(shellQuote(name.isEmpty ? "automation" : name)) --trigger \(shellQuote(trigger.isEmpty ? "manual" : trigger)) --file \(shellQuote(file))")
        }
    }

    static var automationListCommand: String {
        invoke("automation-list")
    }

    static var automationDueCommand: String {
        invoke("automation-due")
    }

    static var automationRunDueCommand: String {
        invoke("automation-run-due")
    }

    static func automationRunCommand(id: String) -> String {
        invoke("automation-run \(shellQuote(id))")
    }

    static func taskLogCommand(taskID: String) -> String {
        invoke("task-log \(shellQuote(taskID))")
    }

    static var taskStatusCommand: String {
        invoke("task-status")
    }

    static var finalizerSnapshotCommand: String {
        invoke("finalizer-snapshot")
    }

    static func runScriptCommand(title: String, script: String, timeout: TimeInterval) -> String {
        withPayload(script, fileExtension: "sh") { file in
            invoke("run-script --title \(shellQuote(title)) --script-file \(shellQuote(file)) --timeout \(max(0, Int(timeout)))")
        }
    }

    static func sessionStartCommand(title: String) -> String {
        invoke("session-start --title \(shellQuote(title))")
    }

    static func sessionNoteCommand(sessionID: String, note: String) -> String {
        withPayload(note) { file in
            let id = sessionID.isEmpty ? "" : " --id \(shellQuote(sessionID))"
            return invoke("session-note\(id) --file \(shellQuote(file))")
        }
    }

    static func sessionReadCommand(sessionID: String, tailLines: Int? = nil) -> String {
        let id = sessionID.isEmpty ? "" : " --id \(shellQuote(sessionID))"
        let tail = tailLines.map { " --tail \(max(1, $0))" } ?? ""
        return invoke("session-read\(id)\(tail)")
    }

    static func projectManifestStartCommand(title: String, sessionID: String, body: String) -> String {
        withPayload(body) { file in
            let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : " --session-id \(shellQuote(sessionID))"
            // i18n-ignore: default title passed to the Ogent runtime (shell argument)
            return invoke("project-manifest-start --title \(shellQuote(title.isEmpty ? "工程任务" : title))\(session) --file \(shellQuote(file))")
        }
    }

    static func projectManifestUpdateCommand(projectID: String, status: String, event: String, body: String) -> String {
        withPayload(body) { file in
            let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : " --id \(shellQuote(projectID))"
            let statusArg = status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : " --status \(shellQuote(status))"
            let eventArg = event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? " --event update"
                : " --event \(shellQuote(event))"
            return invoke("project-manifest-update\(id)\(statusArg)\(eventArg) --file \(shellQuote(file))")
        }
    }

    static func projectManifestReadCommand(projectID: String, tailLines: Int? = nil) -> String {
        let id = projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : " --id \(shellQuote(projectID))"
        let tail = tailLines.map { " --tail \(max(1, $0))" } ?? ""
        return invoke("project-manifest-read\(id)\(tail)")
    }

    static func skillInstallCommand(name: String, content: String) -> String {
        withPayload(content) { file in
            invoke("skill-install --name \(shellQuote(name)) --file \(shellQuote(file))")
        }
    }

    static func checkpointCreateCommand(name: String) -> String {
        invoke("checkpoint-create --name \(shellQuote(name.isEmpty ? "checkpoint" : name))")
    }

    static var checkpointListCommand: String {
        invoke("checkpoint-list")
    }

    static func checkpointRestoreCommand(id: String) -> String {
        invoke("checkpoint-restore \(shellQuote(id))")
    }

    static func localModelConfigCommand(
        baseURL: String,
        modelID: String,
        apiKey: String,
        startCommand: String,
        runtimeKind: String = "",
        modelFile: String = "",
        extraArgs: String = ""
    ) -> String {
        var arguments = "model-config --base-url \(shellQuote(baseURL))"
        if !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --model \(shellQuote(modelID))"
        }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --api-key \(shellQuote(apiKey))"
        }
        if !startCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --start-command \(shellQuote(startCommand))"
        }
        if !runtimeKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --runtime-kind \(shellQuote(runtimeKind))"
        }
        if !modelFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --model-file \(shellQuote(modelFile))"
        }
        if !extraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += " --extra-args \(shellQuote(extraArgs))"
        }
        return invoke(arguments)
    }

    static var localModelStatusCommand: String {
        invoke("model-status")
    }

    static var localModelReadinessCommand: String {
        invoke("model-readiness")
    }

    static var localModelScanCommand: String {
        invoke("model-scan")
    }

    static func localModelPlanCommand(
        modelURL: String = "",
        sha256: String = "",
        filename: String = "",
        modelID: String = "",
        modelFile: String = "",
        runnerURL: String = "",
        runnerSHA256: String = "",
        repoURL: String = "",
        ref: String = ""
    ) -> String {
        var arguments = "model-deployment-plan"
        let trimmedURL = modelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            arguments += " --url \(shellQuote(trimmedURL))"
        }
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSHA.isEmpty {
            arguments += " --sha256 \(shellQuote(trimmedSHA))"
        }
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilename.isEmpty {
            arguments += " --name \(shellQuote(trimmedFilename))"
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += " --model \(shellQuote(trimmedModel))"
        }
        let trimmedModelFile = modelFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelFile.isEmpty {
            arguments += " --model-file \(shellQuote(trimmedModelFile))"
        }
        let trimmedRunnerURL = runnerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerURL.isEmpty {
            arguments += " --runner-url \(shellQuote(trimmedRunnerURL))"
        }
        let trimmedRunnerSHA = runnerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerSHA.isEmpty {
            arguments += " --runner-sha256 \(shellQuote(trimmedRunnerSHA))"
        }
        let trimmedRepo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRepo.isEmpty {
            arguments += " --repo \(shellQuote(trimmedRepo))"
        }
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRef.isEmpty {
            arguments += " --ref \(shellQuote(trimmedRef))"
        }
        return invoke(arguments)
    }

    static func localModelDoctorCommand(
        modelURL: String = "",
        sha256: String = "",
        filename: String = "",
        modelID: String = "",
        modelFile: String = "",
        runnerURL: String = "",
        runnerSHA256: String = "",
        repoURL: String = "",
        ref: String = ""
    ) -> String {
        var arguments = "model-doctor"
        let trimmedURL = modelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            arguments += " --url \(shellQuote(trimmedURL))"
        }
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSHA.isEmpty {
            arguments += " --sha256 \(shellQuote(trimmedSHA))"
        }
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilename.isEmpty {
            arguments += " --name \(shellQuote(trimmedFilename))"
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += " --model \(shellQuote(trimmedModel))"
        }
        let trimmedModelFile = modelFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelFile.isEmpty {
            arguments += " --model-file \(shellQuote(trimmedModelFile))"
        }
        let trimmedRunnerURL = runnerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerURL.isEmpty {
            arguments += " --runner-url \(shellQuote(trimmedRunnerURL))"
        }
        let trimmedRunnerSHA = runnerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerSHA.isEmpty {
            arguments += " --runner-sha256 \(shellQuote(trimmedRunnerSHA))"
        }
        let trimmedRepo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRepo.isEmpty {
            arguments += " --repo \(shellQuote(trimmedRepo))"
        }
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRef.isEmpty {
            arguments += " --ref \(shellQuote(trimmedRef))"
        }
        return invoke(arguments)
    }

    static var localModelProbeCommand: String {
        invoke("model-probe")
    }

    static func localModelStartCommand(requireReal: Bool = false) -> String {
        invoke("model-start\(requireReal ? " --require-real" : "")")
    }

    static var localModelStopCommand: String {
        invoke("model-stop")
    }

    static func localModelBootstrapCommand(requireReal: Bool = false) -> String {
        invoke("model-bootstrap\(requireReal ? " --require-real" : "")")
    }

    static func localModelBuildLlamaCommand(
        repoURL: String = "",
        ref: String = "",
        jobs: Int = 1,
        clean: Bool = false,
        installDependencies: Bool = false
    ) -> String {
        var arguments = "model-build-llama"
        if installDependencies {
            arguments += " --install-deps"
        }
        let trimmedRepo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRepo.isEmpty {
            arguments += " --repo \(shellQuote(trimmedRepo))"
        }
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRef.isEmpty {
            arguments += " --ref \(shellQuote(trimmedRef))"
        }
        arguments += " --jobs \(max(1, min(jobs, 4)))"
        if clean {
            arguments += " --clean"
        }
        return invoke(arguments)
    }

    static func localModelInstallGGUFCommand(
        url: String,
        sha256: String = "",
        filename: String = "",
        modelID: String = "",
        setDefault: Bool = true,
        extraArgs: String = ""
    ) -> String {
        var arguments = "model-install-gguf --url \(shellQuote(url))"
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSHA.isEmpty {
            arguments += " --sha256 \(shellQuote(trimmedSHA))"
        }
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilename.isEmpty {
            arguments += " --name \(shellQuote(trimmedFilename))"
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += " --model \(shellQuote(trimmedModel))"
        }
        let trimmedExtraArgs = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtraArgs.isEmpty {
            arguments += " --extra-args \(shellQuote(trimmedExtraArgs))"
        }
        if !setDefault {
            arguments += " --no-default"
        }
        return invoke(arguments)
    }

    static func localModelInstallRunnerCommand(
        url: String,
        sha256: String = ""
    ) -> String {
        var arguments = "model-install-runner --url \(shellQuote(url))"
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSHA.isEmpty {
            arguments += " --sha256 \(shellQuote(trimmedSHA))"
        }
        return invoke(arguments)
    }

    static func localModelProvisionCommand(
        modelURL: String = "",
        sha256: String = "",
        filename: String = "",
        modelID: String = "",
        modelFile: String = "",
        extraArgs: String = "",
        runnerURL: String = "",
        runnerSHA256: String = "",
        repoURL: String = "",
        ref: String = "",
        jobs: Int = 1,
        clean: Bool = false,
        installDependencies: Bool = false,
        buildRunner: Bool = true,
        startServer: Bool = true
    ) -> String {
        var arguments = "model-provision"
        let trimmedURL = modelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty {
            arguments += " --url \(shellQuote(trimmedURL))"
        }
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSHA.isEmpty {
            arguments += " --sha256 \(shellQuote(trimmedSHA))"
        }
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFilename.isEmpty {
            arguments += " --name \(shellQuote(trimmedFilename))"
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += " --model \(shellQuote(trimmedModel))"
        }
        let trimmedModelFile = modelFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModelFile.isEmpty {
            arguments += " --model-file \(shellQuote(trimmedModelFile))"
        }
        let trimmedExtraArgs = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtraArgs.isEmpty {
            arguments += " --extra-args \(shellQuote(trimmedExtraArgs))"
        }
        let trimmedRunnerURL = runnerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerURL.isEmpty {
            arguments += " --runner-url \(shellQuote(trimmedRunnerURL))"
        }
        let trimmedRunnerSHA = runnerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRunnerSHA.isEmpty {
            arguments += " --runner-sha256 \(shellQuote(trimmedRunnerSHA))"
        }
        let trimmedRepo = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRepo.isEmpty {
            arguments += " --repo \(shellQuote(trimmedRepo))"
        }
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRef.isEmpty {
            arguments += " --ref \(shellQuote(trimmedRef))"
        }
        arguments += " --jobs \(max(1, min(jobs, 4)))"
        if clean {
            arguments += " --clean"
        }
        if installDependencies {
            arguments += " --install-deps"
        }
        if buildRunner {
            arguments += " --build-runner"
        } else {
            arguments += " --no-build-runner"
        }
        if !startServer {
            arguments += " --no-start"
        }
        return invoke(arguments)
    }

    static var localModelRunnerValidationSelfTestCommand: String {
        invoke("model-runner-validation-selftest")
    }

    static func profileStatusCommand(profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? "core" : trimmed
        return invoke("profile-status \(shellQuote(selected))")
    }

    static func profileInstallCommand(profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? "core" : trimmed
        return invoke("profile-install \(shellQuote(selected))")
    }

    static var envListCommand: String {
        invoke("env-list")
    }

    static var toolInventoryCommand: String {
        invoke("tool-inventory")
    }

    private static func invoke(_ arguments: String) -> String {
        "/bin/sh \(shellQuote(cliPath)) \(arguments)"
    }

    private static func withPayload(_ payload: String, fileExtension ext: String = "txt", command: (String) -> String) -> String {
        let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let marker = "OGENT_PAYLOAD_\(nonce)_EOF"
        let path = "/root/.ogent/tmp/\(nonce).\(ext)"
        return """
        mkdir -p /root/.ogent/tmp
        cat > \(shellQuote(path)) <<'\(marker)'
        \(payload)
        \(marker)
        \(command(path))
        """
    }

    private static func shellQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Higher-level entrypoint for the project model. `shell_local` is
/// still the raw terminal, while this tool records multi-step work as
/// Ogent tasks inside the local iSH runtime, making the agent's Linux-side state
/// inspectable and durable across chat turns.
final class OgentAgentTool: AgentTool, @unchecked Sendable {
    private let toolName: String

    init(name: String = "ogent_agent") {
        self.toolName = name
    }

    var descriptor: ToolDescriptor {
        ToolDescriptor(
        name: toolName,
        summary: """
        Run and inspect the persistent Ogent Linux agent runtime inside the local iSH Alpine sandbox. \
        Use this before shell_local for multi-step engineering work because it records task logs under \
        the Ogent workspace, runs scripts from the Ogent workspace, and provides durable plan, notes, inbox, \
        sessions, checkpoints, wiki memory/RAG, artifact, skill, subagent and automation slots. Use plan_write before complex work, \
        session_start for a durable work thread, run_script for execution, checkpoint_create before risky \
        changes, wiki_upsert for reusable living wiki knowledge, memory_add for timestamped memory snapshots, wiki_summary/wiki_graph to inspect the local living-memory map and backlinks, memory_search/recall/rag_search for retrieval, \
        subagent_create/subagent_task/subagent_run for role-specific local work briefs executed through the iSH local model endpoint; subagent_run requires a real local model by default and blocks the compatibility harness unless allowHarness is explicitly true for diagnostics, \
        automation_create/automation_list/automation_due/automation_run for repeatable local actions, \
        rootfs_doctor/rootfs_repair/rootfs_overlay_status for iSH deployment health, RootfsPatch overlay visibility and repair, \
        note_append/session_note for observations, project_manifest_start/project_manifest_update/project_manifest_read for durable task-level delivery state, task_status/finalizer_snapshot before final delivery or resume checks, artifact_export when a user-facing file is ready, \
        and workspace_snapshot before resuming work. \
        Actions: status, rootfs_doctor, rootfs_repair, rootfs_overlay_status, workspace_snapshot, plan_write, plan_read, run_script, note_append, inbox_add, \
        inbox_read, artifact_list, artifact_manifest, remember, recall, memory_add, memory_search, wiki_upsert, wiki_summary, wiki_graph, rag_rebuild, rag_search, skill_list, skill_install, subagent_create, subagent_list, subagent_task, subagent_run, automation_create, automation_list, automation_due, automation_run, automation_run_due, task_log, session_start, \
        task_status, finalizer_snapshot, session_note, session_read, project_manifest_start, project_manifest_update, project_manifest_read, checkpoint_create, checkpoint_list, checkpoint_restore, artifact_export, \
        model_status, model_readiness, model_scan, model_plan, model_doctor, model_probe, model_config, model_start, model_stop, model_bootstrap, model_build_llama, model_install_runner, model_install_gguf, model_provision, profile_status, profile_install, env_list, tool_inventory.
        """,
        displayName: "工程代理", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "工程代理", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["action"],"properties":{"action":{"type":"string","description":"Ogent runtime action, e.g. status, rootfs_doctor, rootfs_repair, rootfs_overlay_status, workspace_snapshot, plan_write, run_script, task_status, finalizer_snapshot, artifact_list, artifact_manifest, artifact_export, project_manifest_start, project_manifest_update, project_manifest_read, memory_search, wiki_upsert, rag_search, skill_list, subagent_task, subagent_run, automation_run, model_readiness, model_plan, model_doctor, model_probe, model_bootstrap, model_build_llama, model_install_runner, model_install_gguf, model_provision, profile_status, profile_install."},"title":{"type":"string"},"steps":{"type":"array","items":{"type":"string"}},"script":{"type":"string","description":"POSIX /bin/sh script. Use $OGENT_WORKSPACE and $OGENT_ARTIFACTS."},"timeout":{"type":"number","default":300},"artifactPath":{"type":"string"},"query":{"type":"string"},"note":{"type":"string"},"message":{"type":"string"},"topic":{"type":"string"},"related":{"type":"string"},"memoryKey":{"type":"string"},"memoryValue":{"type":"string"},"memoryTags":{"type":"string"},"taskID":{"type":"string"},"sessionID":{"type":"string"},"projectID":{"type":"string"},"status":{"type":"string","description":"Project manifest lifecycle status, e.g. running, tool_completed, tool_failed, finalizing, completed."},"automationID":{"type":"string"},"trigger":{"type":"string"},"checkpointID":{"type":"string"},"skillName":{"type":"string"},"skillContent":{"type":"string"},"baseURL":{"type":"string","description":"Local iSH model OpenAI-compatible base URL, e.g. http://127.0.0.1:11434/v1."},"modelID":{"type":"string"},"apiKey":{"type":"string"},"startCommand":{"type":"string","description":"Optional iSH command for starting a local model server."},"runtimeKind":{"type":"string","description":"Optional real local runtime kind, e.g. llama.cpp."},"modelFile":{"type":"string","description":"Optional existing GGUF model path inside iSH for model_config/model_plan/model_doctor/model_provision, e.g. /root/.ogent/models/model.gguf."},"modelURL":{"type":"string","description":"HTTPS URL of a GGUF file to download into /root/.ogent/models for model_install_gguf/model_plan/model_doctor/model_provision."},"filename":{"type":"string","description":"Optional destination filename for model_install_gguf."},"sha256":{"type":"string","description":"Optional SHA-256 checksum for model_install_gguf."},"runnerURL":{"type":"string","description":"Optional HTTPS URL of an iSH-compatible llama-server binary for model_doctor/model_plan/model_install_runner/model_provision."},"runnerSHA256":{"type":"string","description":"SHA-256 (64 hex) of the runnerURL binary. Required whenever runnerURL is used; installs are refused without it."},"setDefaultModel":{"type":"boolean","description":"For model_install_gguf, update local model config to use the downloaded GGUF.","default":true},"buildRunner":{"type":"boolean","description":"For model_provision, build llama-server in iSH when it is missing.","default":true},"startServer":{"type":"boolean","description":"For model_provision, start and probe the real local model after provisioning.","default":true},"extraArgs":{"type":"string","description":"Optional extra args for real local runtime startup."},"requireRealModel":{"type":"boolean","description":"For model_start/model_bootstrap, require llama.cpp + GGUF and fail instead of starting the compatibility harness.","default":false},"allowHarness":{"type":"boolean","description":"For diagnostics-only subagent_run, allow the compatibility harness. Leave false for real project work so subagents require real local inference.","default":false},"repoURL":{"type":"string","description":"Optional llama.cpp git repository URL for model_build_llama/model_plan/model_doctor/model_provision."},"llamaRef":{"type":"string","description":"Optional llama.cpp git ref/tag/commit for model_build_llama/model_plan/model_doctor/model_provision. gitRef/ref are also accepted."},"buildJobs":{"type":"integer","description":"Parallel build jobs for model_build_llama; clamped to 1...4.","default":1},"cleanBuild":{"type":"boolean","description":"Remove the previous llama.cpp build directory before model_build_llama.","default":false},"installDependencies":{"type":"boolean","description":"Run profile_install local-model before model_build_llama.","default":false},"checkOnly":{"type":"boolean","description":"For rootfs_repair, only verify repair readiness without installing packages.","default":false},"profile":{"type":"string","description":"Ogent rootfs deployment profile: core, mcp, 12306, media, document, local-model, or all."}}}
        """,
        surfaces: [.project],
        requiresPermission: true
        )
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "status").trimmingCharacters(in: .whitespacesAndNewlines)
        let providedTitle = (args["title"] as? String) ?? ""
        // i18n-ignore: default task title stored in the Ogent runtime
        let title = providedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "工程任务" : providedTitle
        let script = (args["script"] as? String) ?? ""
        let timeout = (args["timeout"] as? Double) ?? 300
        let artifactPath = (args["artifactPath"] as? String) ?? ""
        let steps = Self.stringArray(args["steps"])
        let note = (args["note"] as? String) ?? ""
        let message = (args["message"] as? String) ?? ""
        let topic = (args["topic"] as? String) ?? ""
        let related = (args["related"] as? String) ?? ""
        let memoryKey = (args["memoryKey"] as? String) ?? ""
        let memoryValue = (args["memoryValue"] as? String) ?? ""
        let memoryTags = (args["memoryTags"] as? String) ?? ""
        let query = (args["query"] as? String) ?? ""
        let taskID = (args["taskID"] as? String) ?? ""
        let projectID = (args["projectID"] as? String) ?? ""
        let status = (args["status"] as? String) ?? ""
        let automationID = (args["automationID"] as? String) ?? ""
        let trigger = (args["trigger"] as? String) ?? "manual"
        let sessionID = (args["sessionID"] as? String) ?? ""
        let checkpointID = (args["checkpointID"] as? String) ?? ""
        let skillName = (args["skillName"] as? String) ?? ""
        let skillContent = (args["skillContent"] as? String) ?? ""
        let baseURL = (args["baseURL"] as? String) ?? ""
        let modelID = (args["modelID"] as? String) ?? ""
        let apiKey = (args["apiKey"] as? String) ?? ""
        let startCommand = (args["startCommand"] as? String) ?? ""
        let runtimeKind = (args["runtimeKind"] as? String) ?? ""
        let modelFile = (args["modelFile"] as? String) ?? ""
        let modelURL = (args["modelURL"] as? String) ?? ""
        let filename = (args["filename"] as? String) ?? ""
        let sha256 = (args["sha256"] as? String) ?? ""
        let runnerURL = (args["runnerURL"] as? String) ?? ""
        let runnerSHA256 = (args["runnerSHA256"] as? String) ?? ""
        let extraArgs = (args["extraArgs"] as? String) ?? ""
        let profile = (args["profile"] as? String) ?? ""
        let requireRealModel = (args["requireRealModel"] as? Bool) ?? false
        let allowHarness = (args["allowHarness"] as? Bool) ?? false
        let setDefaultModel = (args["setDefaultModel"] as? Bool) ?? true
        let buildRunner = (args["buildRunner"] as? Bool) ?? true
        let startServer = (args["startServer"] as? Bool) ?? true
        let repoURL = (args["repoURL"] as? String) ?? ""
        let llamaRef = (args["llamaRef"] as? String)
            ?? (args["gitRef"] as? String)
            ?? (args["ref"] as? String)
            ?? ""
        let buildJobs: Int = {
            if let number = args["buildJobs"] as? NSNumber { return number.intValue }
            if let int = args["buildJobs"] as? Int { return int }
            return 1
        }()
        let cleanBuild = (args["cleanBuild"] as? Bool) ?? false
        let installDependencies = (args["installDependencies"] as? Bool) ?? false
        let checkOnly = (args["checkOnly"] as? Bool) ?? false

        let ready: Bool = ISHRuntimeQueue.sync { ISHRuntimeBootstrap.bootstrap() }
        guard ready else {
            // i18n-ignore: tool result the model reads
            return .textOnly("""
            [\(toolName)] iSH 沙箱未就绪。
            请稍后重试，或查看 console log 中的 `[ISHRuntime]` 行。
            """)
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<ToolResult, Never>) in
            // Off the iSH runtime thread: these commands run for up to two hours (model
            // provisioning), and every `runOnQueue` below now launches on the runtime thread
            // and waits here, so other sessions' shells and Stop keep working meanwhile.
            DispatchQueue.global(qos: .userInitiated).async {
                let result: ToolResult
                switch action {
                case "status":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.statusCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "rootfs_doctor", "rootfs-doctor":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.rootfsDoctorCommand,
                        timeout: 30,
                        onProgress: onProgress
                    )
                case "rootfs_repair", "rootfs-repair":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.rootfsRepairCommand(checkOnly: checkOnly),
                        timeout: checkOnly ? 30 : max(timeout, 300),
                        onProgress: onProgress
                    )
                case "rootfs_overlay_status", "rootfs-overlay-status":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.rootfsOverlayStatusCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "workspace_snapshot":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.workspaceSnapshotCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "plan_write":
                    guard !steps.isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) plan_write 需要 steps 数组。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.planWriteCommand(title: title, steps: steps),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "plan_read":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.planReadCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "run_script":
                    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) run_script 需要 script 参数。"))
                        return
                    }
                    let startedAt = Date()
                    let outerTimeout = timeout <= 0 ? 0 : max(timeout + 5, 10)
                    let raw = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.runScriptCommand(title: title, script: script, timeout: timeout),
                        timeout: outerTimeout,
                        onProgress: onProgress
                    )
                    result = Self.appendingAutoExports(to: raw, modifiedAfter: startedAt)
                case "note_append":
                    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) note_append 需要 note。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.noteAppendCommand(note: note),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "inbox_add":
                    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) inbox_add 需要 message。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.inboxAddCommand(message: message),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "inbox_read":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.inboxReadCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "artifact_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.artifactListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "artifact_manifest":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.artifactManifestCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "artifact_export":
                    guard !artifactPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) artifact_export 需要 artifactPath。"))
                        return
                    }
                    do {
                        let exported = try ISHRootfsManager.exportArtifact(guestPath: artifactPath)
                        // i18n-ignore: tool result the model reads
                        result = .textOnly(Self.exportSummary([exported], title: "导出完成"))
                    } catch {
                        result = .textOnly("[artifact_export error] \(error.localizedDescription)")
                    }
                case "remember":
                    guard !memoryKey.isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) remember 需要 memoryKey。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.rememberCommand(key: memoryKey, value: memoryValue),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "recall":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.recallCommand(key: memoryKey),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "memory_add":
                    let body = !memoryValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? memoryValue : note
                    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) memory_add 需要 memoryValue 或 note。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.memoryAddCommand(title: title, body: body, tags: memoryTags),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "wiki_upsert":
                    let body = !memoryValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? memoryValue
                        : (!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : message)
                    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) wiki_upsert 需要 memoryValue、note 或 message。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.wikiUpsertCommand(
                            topic: topic,
                            title: providedTitle,
                            body: body,
                            tags: memoryTags,
                            related: related
                        ),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "memory_search":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.memorySearchCommand(query: query.isEmpty ? memoryKey : query),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "wiki_summary":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.wikiSummaryCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "wiki_graph":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.wikiGraphCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "rag_rebuild":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.ragRebuildCommand,
                        timeout: 20,
                        onProgress: onProgress
                    )
                case "rag_search":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.ragSearchCommand(query: query.isEmpty ? memoryKey : query),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "skill_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.skillListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "skill_install":
                    guard !skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !skillContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) skill_install 需要 skillName 和 skillContent。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.skillInstallCommand(name: skillName, content: skillContent),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "subagent_create":
                    let instructions = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : message
                    guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) subagent_create 需要 note 或 message 作为子代理说明。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.subagentCreateCommand(name: title, instructions: instructions),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "subagent_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.subagentListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "subagent_task":
                    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) subagent_task 需要 message。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.subagentTaskCommand(name: title, task: message),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "subagent_run":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.subagentRunCommand(name: title, taskID: taskID, allowHarness: allowHarness),
                        timeout: max(timeout, 120),
                        onProgress: onProgress
                    )
                case "automation_create":
                    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) automation_create 需要 script。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.automationCreateCommand(name: title, trigger: trigger, script: script),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "automation_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.automationListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "automation_due":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.automationDueCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "automation_run":
                    guard !automationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) automation_run 需要 automationID。"))
                        return
                    }
                    let startedAt = Date()
                    let raw = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.automationRunCommand(id: automationID),
                        timeout: 5 * 60,
                        onProgress: onProgress
                    )
                    result = Self.appendingAutoExports(to: raw, modifiedAfter: startedAt)
                case "automation_run_due":
                    let startedAt = Date()
                    let raw = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.automationRunDueCommand,
                        timeout: 10 * 60,
                        onProgress: onProgress
                    )
                    result = Self.appendingAutoExports(to: raw, modifiedAfter: startedAt)
                case "task_log":
                    guard !taskID.isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) task_log 需要 taskID。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.taskLogCommand(taskID: taskID),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "task_status":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.taskStatusCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "finalizer_snapshot", "finalizer-snapshot":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.finalizerSnapshotCommand,
                        timeout: 15,
                        onProgress: onProgress
                    )
                case "session_start":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.sessionStartCommand(title: title),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "session_note":
                    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) session_note 需要 note。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.sessionNoteCommand(sessionID: sessionID, note: note),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "session_read":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.sessionReadCommand(sessionID: sessionID),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "project_manifest_start", "project-manifest-start":
                    let body = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : message
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.projectManifestStartCommand(title: title, sessionID: sessionID, body: body),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "project_manifest_update", "project-manifest-update":
                    let body = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : message
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.projectManifestUpdateCommand(
                            projectID: projectID,
                            status: status,
                            event: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "update" : title,
                            body: body
                        ),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "project_manifest_read", "project-manifest-read":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.projectManifestReadCommand(projectID: projectID),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "checkpoint_create":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.checkpointCreateCommand(name: title),
                        timeout: 60,
                        onProgress: onProgress
                    )
                case "checkpoint_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.checkpointListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "checkpoint_restore":
                    guard !checkpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) checkpoint_restore 需要 checkpointID。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.checkpointRestoreCommand(id: checkpointID),
                        timeout: 60,
                        onProgress: onProgress
                    )
                case "model_config":
                    guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) model_config 需要 baseURL。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelConfigCommand(
                            baseURL: baseURL,
                            modelID: modelID,
                            apiKey: apiKey,
                            startCommand: startCommand,
                            runtimeKind: runtimeKind,
                            modelFile: modelFile,
                            extraArgs: extraArgs
                        ),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_status":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelStatusCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_readiness", "model-readiness":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelReadinessCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_scan":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelScanCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_plan", "model-plan", "model_deployment_plan", "model-deployment-plan":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelPlanCommand(
                            modelURL: modelURL,
                            sha256: sha256,
                            filename: filename,
                            modelID: modelID,
                            modelFile: modelFile,
                            runnerURL: runnerURL,
                            runnerSHA256: runnerSHA256,
                            repoURL: repoURL,
                            ref: llamaRef
                        ),
                        timeout: 20,
                        onProgress: onProgress
                    )
                case "model_doctor", "model-doctor":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelDoctorCommand(
                            modelURL: modelURL,
                            sha256: sha256,
                            filename: filename,
                            modelID: modelID,
                            modelFile: modelFile,
                            runnerURL: runnerURL,
                            runnerSHA256: runnerSHA256,
                            repoURL: repoURL,
                            ref: llamaRef
                        ),
                        timeout: 25,
                        onProgress: onProgress
                    )
                case "model_probe":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelProbeCommand,
                        timeout: 12,
                        onProgress: onProgress
                    )
                case "model_start":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelStartCommand(requireReal: requireRealModel),
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_stop":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelStopCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "model_bootstrap":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelBootstrapCommand(requireReal: requireRealModel),
                        timeout: 30,
                        onProgress: onProgress
                    )
                case "model_build_llama", "model-build-llama":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelBuildLlamaCommand(
                            repoURL: repoURL,
                            ref: llamaRef,
                            jobs: buildJobs,
                            clean: cleanBuild,
                            installDependencies: installDependencies
                        ),
                        timeout: max(timeout, 1800),
                        onProgress: onProgress
                    )
                case "model_install_gguf", "model-install-gguf":
                    guard !modelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) model_install_gguf 需要 modelURL。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelInstallGGUFCommand(
                            url: modelURL,
                            sha256: sha256,
                            filename: filename,
                            modelID: modelID,
                            setDefault: setDefaultModel,
                            extraArgs: extraArgs
                        ),
                        timeout: max(timeout, 3600),
                        onProgress: onProgress
                    )
                case "model_install_runner", "model-install-runner":
                    guard !runnerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // i18n-ignore: tool result the model reads
                        cont.resume(returning: .textOnly("⚠️ \(self.toolName) model_install_runner 需要 runnerURL。"))
                        return
                    }
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelInstallRunnerCommand(
                            url: runnerURL,
                            sha256: runnerSHA256
                        ),
                        timeout: max(timeout, 1800),
                        onProgress: onProgress
                    )
                case "model_provision", "model-provision":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.localModelProvisionCommand(
                            modelURL: modelURL,
                            sha256: sha256,
                            filename: filename,
                            modelID: modelID,
                            modelFile: modelFile,
                            extraArgs: extraArgs,
                            runnerURL: runnerURL,
                            runnerSHA256: runnerSHA256,
                            repoURL: repoURL,
                            ref: llamaRef,
                            jobs: buildJobs,
                            clean: cleanBuild,
                            installDependencies: installDependencies,
                            buildRunner: buildRunner,
                            startServer: startServer
                        ),
                        timeout: max(timeout, 7200),
                        onProgress: onProgress
                    )
                case "profile_status", "profile-status":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.profileStatusCommand(profile: profile),
                        timeout: 15,
                        onProgress: onProgress
                    )
                case "profile_install", "profile-install":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.profileInstallCommand(profile: profile),
                        timeout: max(timeout, 300),
                        onProgress: onProgress
                    )
                case "env_list":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.envListCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                case "tool_inventory":
                    result = ShellTool.runOnQueue(
                        command: OgentLinuxRuntime.toolInventoryCommand,
                        timeout: 10,
                        onProgress: onProgress
                    )
                default:
                    // i18n-ignore: tool result the model reads
                    result = .textOnly("⚠️ 未知 \(self.toolName) action：\(action)")
                }
                cont.resume(returning: result)
            }
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                if let string = item as? String { return string }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        }
        if let string = value as? String {
            return string
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private static func appendingAutoExports(to result: ToolResult, modifiedAfter: Date) -> ToolResult {
        let exports = ISHRootfsManager.exportGeneratedArtifacts(modifiedAfter: modifiedAfter)
        guard !exports.isEmpty else { return result }

        var text = result.text ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        // i18n-ignore: tool result the model reads (export summary)
        text += "\n" + exportSummary(exports, title: "自动导出产物")
        return ToolResult(text: text, mediaUrl: result.mediaUrl, mediaMime: result.mediaMime, truncated: result.truncated)
    }

    private static func exportSummary(_ exports: [ISHExportedArtifact], title: String) -> String {
        var lines = ["[\(title)]"]
        for item in exports {
            let size = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
            lines.append("- \(item.filename) · \(size)")
            lines.append("  guest=\(displayGuestPath(item.sourceGuestPath))")
            lines.append("  ios=\(item.destinationURL.path)")
        }
        if let first = exports.first {
            lines.append("[oases:open]\(first.destinationURL.path)")
        }
        return lines.joined(separator: "\n")
    }

    private static func displayGuestPath(_ path: String) -> String {
        if path.hasPrefix("/root/.minis/") {
            return "/root/.ogent/" + String(path.dropFirst("/root/.minis/".count))
        }
        return path
    }
}

enum OgentAutomationScheduler {
    private static let minimumInterval: TimeInterval = 60
    private static let state = AutomationState()

    private actor AutomationState {
        private var isRunning = false
        private var lastRunAt: Date?

        func begin(reason: String, force: Bool, minimumInterval: TimeInterval) -> String? {
            let now = Date()
            if isRunning {
                return "automation_scheduler_skipped reason=\(reason) already_running=true"
            }
            if !force, let lastRunAt, now.timeIntervalSince(lastRunAt) < minimumInterval {
                return "automation_scheduler_skipped reason=\(reason) throttled=true"
            }
            isRunning = true
            lastRunAt = now
            return nil
        }

        func finish() {
            isRunning = false
        }
    }

    static func scheduleRunDue(reason: String, delay: TimeInterval = 2, force: Bool = false) {
        Task.detached(priority: .utility) {
            if delay > 0 {
                let nanos = UInt64(max(0, delay) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
            _ = await runDue(reason: reason, force: force)
        }
    }

    static func runDueForSelfTest(reason: String) async -> String {
        await runDue(reason: reason, force: true)
    }

    /// A background app refresh gets about 30 seconds: the due automations run only when the
    /// Linux runtime is already up (a cold boot alone can take longer), and the run is killed
    /// after 25 seconds; what did not finish runs at the next opportunity.
    static func runDueForBackgroundTask(reason: String) async -> String {
        guard ish_runtime_is_ready() != 0 else {
            let skipped = "automation_scheduler_skipped reason=\(reason) runtime_cold=1"
            NSLog("[OgentAutomation] %@", skipped)
            return skipped
        }
        return await runDue(reason: reason, force: true, timeout: 25)
    }

    private static func runDue(reason: String, force: Bool, timeout: TimeInterval = 10 * 60) async -> String {
        // Automations send data to models. `scheduleRunDue` sleeps before
        // getting here, so consent can have been withdrawn since the call was
        // scheduled: check at the moment the run would start.
        guard AIDataSharingConsent.isAccepted else {
            let skipped = "automation_scheduler_skipped reason=\(reason) consent_required=1"
            NSLog("[OgentAutomation] %@", skipped)
            return skipped
        }
        if let skipped = await state.begin(reason: reason, force: force, minimumInterval: minimumInterval) {
            NSLog("[OgentAutomation] %@", skipped)
            return skipped
        }

        let summary = await withCheckedContinuation { continuation in
            // The run takes up to 10 minutes: wait off the iSH runtime thread (see OgentAgentTool).
            DispatchQueue.global(qos: .utility).async {
                let summary: String
                guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
                    summary = "automation_scheduler_failed reason=\(reason) bootstrap=false"
                    NSLog("[OgentAutomation] %@", summary)
                    continuation.resume(returning: summary)
                    return
                }

                let result = ShellTool.runOnQueue(
                    command: OgentLinuxRuntime.automationRunDueCommand,
                    timeout: timeout,
                    onProgress: { line in
                        NSLog("[OgentAutomation] %@", line.trimmingCharacters(in: .newlines))
                    }
                )
                let text = result.text ?? ""
                if text.contains("[exit=0") {
                    if text.localizedCaseInsensitiveContains("no automations due") {
                        summary = "automation_scheduler_ok reason=\(reason) due=0"
                    } else {
                        summary = "automation_scheduler_ok reason=\(reason) due=ran"
                    }
                } else {
                    summary = "automation_scheduler_failed reason=\(reason) output=\(String(text.prefix(500)))"
                }
                NSLog("[OgentAutomation] %@", summary)
                continuation.resume(returning: summary)
            }
        }
        await state.finish()
        return summary
    }
}

/// Callbacks handed across to the iSH runtime thread. The executor calls them from its own
/// threads; their state is lock-protected where they are created.
private struct UncheckedLineCallback: @unchecked Sendable {
    let value: (String, Bool) -> Void
    init(_ value: @escaping (String, Bool) -> Void) { self.value = value }
}

private struct UncheckedCompletion: @unchecked Sendable {
    let value: (ISHShellExecutionResult) -> Void
    init(_ value: @escaping (ISHShellExecutionResult) -> Void) { self.value = value }
}
