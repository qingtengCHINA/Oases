import SwiftUI
import UIKit
import SwiftData
import BackgroundTasks

/// Defers heavy / iSH work until AFTER the first UI frame so Xcode does not
/// sit on "Launching…" while the main thread (or the debugger) is blocked.
enum AppLaunchCoordinator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didStart = false

    #if DEBUG
    /// Retained for the process lifetime — `DebugServer` owns its accept loop.
    private static let debugServer = DebugServer()
    #endif

    /// Re-bind the debug port after a backgrounding killed the listen socket.
    /// No-op in Release.
    static func restartDebugServerIfNeeded() {
        #if DEBUG
        debugServer.restartIfDead(port: 8321)
        #endif
    }

    /// Unit-test hosts skip iSH and automations; UI tests (`-ui-test`) don't.
    static var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !CommandLine.arguments.contains("-ui-test") && (
            environment["OASES_SKIP_ISH_BOOTSTRAP"] == "1"
                || NSClassFromString("XCTestCase") != nil
                || (environment["XCTestConfigurationFilePath"] != nil
                    && environment["XCInjectBundleInto"] != nil)
        )
    }

    /// Whether `startIfNeeded` has run in this process.
    static var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    /// The user agreed to AI data sharing after this launch's bootstrap
    /// (Settings or the consent sheet): schedule the automations the
    /// bootstrap skipped. Before the bootstrap, it schedules them itself.
    /// Called by `AIConsentAutomationLifecycle`.
    static func resumeAutomationsAfterConsent() {
        guard AIDataSharingConsent.isAccepted, hasStarted, !isUnitTestHost else { return }
        OgentAutomationScheduler.scheduleRunDue(reason: "consent_accepted", delay: 2)
        OgentBackgroundAutomation.scheduleAppRefresh()
        NSLog("[OasesLaunch] automation_scheduled reason=consent_accepted")
    }

    /// Runs whether or not the user agreed to AI data sharing: everything
    /// here is local (logging, terminal/iSH, files, mounts, shortcuts) and
    /// limited mode needs it. Only the automation scheduling at the end is
    /// consent-gated, because automations send data to models.
    static func startIfNeeded() {
        lock.lock()
        if didStart {
            lock.unlock()
            return
        }
        didStart = true
        lock.unlock()

        NSLog("[OasesLaunch] post_ui_bootstrap_begin")

        // Re-check the existing APNs authorization once the UI is up (no
        // prompt here; the token stays on the device).
        Task { @MainActor in
            OasesAppDelegate.registerForRemoteNotificationsIfAuthorized()
        }

        // Capture stdout/stderr into Library/Logs when user enabled Logs in settings.
        LoggingManager.shared.startIfEnabled()
        // Engineering product identity: factory SOUL name -> Ogent.
        Task { @MainActor in
            SoulStore.ensureExists()
            SoulStore.migrateFactoryNameIfNeeded()
        }

        // [P2] Install POSIX signal handlers + the MetricKit subscriber before
        // anything heavy runs, so a crash during bootstrap still leaves a marker.
        Task { @MainActor in
            CrashReporter.shared.onAppLaunch()
            CrashReporter.shared.updateMarkerPhase(phase: "active")
        }

        // [P2] JSON-RPC debug server. Debug builds only — `DebugServer` is
        // wrapped in `#if DEBUG`, and the guest `oases-debug` CLI reaches the
        // same dispatcher in-process via `DebugLocalDispatch` without a socket.
        #if DEBUG
        try? debugServer.start(port: 8321)
        #endif

        // [Stage 0.2] Shared infra kickoff — pure Swift, no iSH. NetworkMonitor
        // tracks WiFi↔cellular transitions so LLM connection pools can be
        // evicted; DNS refresh itself is a Stage-4 stub (OasesDnsBridge).
        // QuickActionRouter is @MainActor (UIApplication.shared.shortcutItems);
        // hop explicitly so AppLaunchCoordinator stays nonisolated-safe.
        NetworkMonitor.shared.start()
        Task { @MainActor in
            QuickActionRouter.registerShortcutItems()
        }

        // [P0-3] Extensions handshake. The Share Extension writes a
        // PendingShare into the App Group and opens `oases://share`; the URL
        // can be lost on a cold start, so we also poll once here.
        // AppGroupChangeWatcher kqueues the three FileProvider roots so edits
        // made in iOS Files signal the extension to re-enumerate.
        ShareCoordinator.shared.checkForPendingShare()
        // Background keep-alive: the Live Activity plumbing, plus the
        // DEBUG-only silent-audio leg. Idempotent, and a no-op unless the user
        // has enabled enhanced background in settings.
        Task { @MainActor in
            BackgroundKeepAliveManager.shared.setup()
        }

        // No iCloud sync: the feature was removed (see `CloudSyncFeature`), so
        // neither sync engine, the dirty scanner nor the account observers
        // are started here any more.
        // Re-resolve the security-scoped bookmarks for user-mounted folders.
        // Bookmarks only survive as data, so the scopes have to be re-acquired
        // every launch. This only publishes the snapshot; the actual bind
        // happens after iSH boots (see ish_bootstrap_done below).
        Task { @MainActor in
            MountedFoldersManager.shared.activateAll()
        }
        FileProviderDomainRegistrar.register()
        Task { @MainActor in
            AppGroupChangeWatcher.shared.start()
        }

        // The welcome icon's Metal state and depth field are prewarmed from
        // didFinishLaunching (`MetallicPaintPrewarm`), before the first screen.

        if isUnitTestHost {
            NSLog("[OasesLaunch] skip_ish unit_test_host=1")
            return
        }

        // Give LLDB a beat to finish attach before iSH emits SIGUSR1.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
            NSLog("[OasesLaunch] ish_bootstrap_enqueue")
            ISHRuntimeQueue.async {
                let t0 = CFAbsoluteTimeGetCurrent()
                let ok = ISHRuntimeBootstrap.bootstrap()
                NSLog(
                    "[OasesLaunch] ish_bootstrap_done ok=%d ms=%.0f",
                    ok ? 1 : 0,
                    (CFAbsoluteTimeGetCurrent() - t0) * 1000
                )
                // Bind external mounts only once the runtime is up. The
                // snapshot was already published by `activateAll()` during
                // post-UI bootstrap, which runs well before this — applying it
                // there would always hit "runtime not ready" and the mounts
                // would never appear inside iSH.
                if ok {
                    OasesExternalMountsManager.shared.apply()
                }
            }
        }

        // BGTask handler registration happens in
        // `OasesAppDelegate.didFinishLaunching` (it must precede launch end).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard AIDataSharingConsent.isAccepted else {
                // Limited mode. A refresh submitted while consent was still
                // given (e.g. before a disclosure-version bump) is dropped.
                OgentBackgroundAutomation.cancelAppRefresh()
                NSLog("[OasesLaunch] automation_blocked consent_required=1")
                return
            }
            OgentAutomationScheduler.scheduleRunDue(reason: "app_launch", delay: 1)
            OgentBackgroundAutomation.scheduleAppRefresh()
            NSLog("[OasesLaunch] automation_scheduled")
        }
    }
}

@main
struct OasesChatApp: App {
    @UIApplicationDelegateAdaptor(OasesAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme = ThemeManager()
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage(AIDataSharingConsent.versionKey) private var aiConsentVersion: String = ""
    @AppStorage(AIDataSharingConsent.statusKey) private var aiConsentStatus: String = ""

    init() {
        // A guest process that outlives a timed-out command can still write to a pipe whose
        // reader has closed (ISHShellExecutor finalises timed-out contexts); without this the
        // write kills the app with SIGPIPE instead of failing with EPIPE. The debug server
        // only sets it in DEBUG builds.
        signal(SIGPIPE, SIG_IGN)
        // The one-page consent replaces the older consents: migrate before anything reads it.
        AIDataSharingConsent.migrateLegacy()
        // Swap in a staged two-phase iCloud-backup restore before anything
        // opens the stores it replaces (`ConversationContainer`,
        // `ProviderConfigStore`, …). No-op without a staged restore.
        // iCloud backup itself is gone, but an older build may already have
        // staged a restore on this device (the chat-store half is applied by
        // `ChatStore.init`); finishing it is local-only and avoids leaving a
        // half-applied restore behind. Nothing can stage a new one.
        PendingBackupRestore.applyIfNeeded(scope: .appLaunch)
        // Clear the sync toggles an older build may have left on so no
        // leftover `@AppStorage` mirror shows a sync affordance.
        CloudSyncFeature.retireStoredToggles()

        Bundle.enableLanguageOverride()
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        Bundle.setLanguage(lang.isEmpty ? nil : lang)

        // KEEP THIS INIT FAST. Physical-device Xcode debug sessions hang on
        // "Launching…" if App.init blocks the main thread or starts iSH
        // (SIGUSR1) before LLDB finishes attach. Heavy work (MetallicPaint
        // prewarm, iSH Alpine bootstrap, automations) runs in
        // AppLaunchCoordinator after the first UI frame.
        NSLog("[OasesLaunch] app_init_begin")

        // App Attest device identity for the Oases gateway — configure before
        // any api.oases.dev request goes out. apiKey nil → unconfigured, and
        // every request degrades to unsigned per 接入指南 §7.
        if let apiKey = Secrets.apiKey, !apiKey.isEmpty {
            var gatewayBase = Secrets.apiBaseURL.absoluteString
            while gatewayBase.hasSuffix("/") { gatewayBase.removeLast() }
            if gatewayBase.hasSuffix("/v1") { gatewayBase.removeLast(3) }
            AttestationClient.shared.configure(.init(
                baseURL: gatewayBase,
                apiKey: apiKey,
                appId: AttestationClient.appID
            ))
        }

        // Lightweight pure-Swift tool registration — no iSH, no Metal.
        BuiltInTools.registerAll(chatService: ChatService())
        let webBrowse = WebBrowseTool()
        ToolRegistry.shared.register(webBrowse)
        ToolRegistry.shared.register(BrowserUseAliasTool(underlying: webBrowse))
        ToolRegistry.shared.register(WebReadTool())
        MCPSettingsStore.seedBundledMCPServersIfNeeded()
        // Config registry — must run on MainActor; wrap in a Task so App.init
        // stays non-actor-isolated (OasesChatApp struct is not @MainActor).
        Task { @MainActor in
            ConfigRegistry.shared.registerBuiltinsIfNeeded()
            // Warm ProviderConfigStore. Built-in Oases models resolve through
            // OasesBuiltinProvider (virtual, never persisted).
            _ = ProviderConfigStore.shared
        }
        OgentNativeSkills.registerAll()
        _ = SkillImporter.loadAndRegister()

        #if DEBUG
        IntegrationTestBootstrap.runPlanningSelfTestsIfRequested()
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_HOST_PREFLIGHT_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let hostPreflight = await OgentProjectSessionRecorder.runHostPreflightSelfTest()
                NSLog("[ISHSelfTest] host_preflight_result %@", hostPreflight)
                let toolTrace = await OgentProjectSessionRecorder.runToolTraceSelfTest()
                NSLog("[ISHSelfTest] tool_trace_result %@", toolTrace)
                let lifecycleTrace = await OgentProjectSessionRecorder.runLifecycleTraceSelfTest()
                NSLog("[ISHSelfTest] lifecycle_trace_result %@", lifecycleTrace)
                let profilePreflight = await OgentProjectProfilePreflight.runSelfTest()
                NSLog("[ISHSelfTest] profile_preflight_result %@", profilePreflight)
                let finalDeliveryFallback = await ProjectFinalDeliverySelfTest.run()
                NSLog("[ISHSelfTest] final_delivery_fallback_result %@", finalDeliveryFallback)
                let finalizerSnapshot = await ProjectFinalDeliverySelfTest.runSnapshotSelfTest()
                NSLog("[ISHSelfTest] finalizer_snapshot_result %@", finalizerSnapshot)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_12306_MCP_SELFTEST"] == "1"
            && ProcessInfo.processInfo.environment["OASES_12306_MCP_UPSTREAM_SELFTEST"] != "1" {
            Task.detached(priority: .utility) {
                NSLog("[ISHSelfTest] train_ticket_12306_selftest_start")
                do {
                    let payload: [String: Any] = [
                        "action": "station_code_by_name",
                        "stationNames": "北京南|上海虹桥" // i18n-ignore: DEBUG self-test tool input
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    let result = try await TrainTicket12306Tool().invoke(argumentsJSON: json, onProgress: { line in
                        NSLog("[ISHSelfTest] train_ticket_12306 %@", line.trimmingCharacters(in: .newlines))
                    })
                    NSLog("[ISHSelfTest] train_ticket_12306_selftest_result %@", result.text ?? "")
                } catch {
                    NSLog("[ISHSelfTest] train_ticket_12306_selftest_failed %@", error.localizedDescription)
                }
            }
        }
        if ProcessInfo.processInfo.environment["OASES_12306_MCP_UPSTREAM_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let profile = await ISHRuntimeService.shared.execute(
                    ISHCommand(command: "/bin/sh /usr/local/bin/ogent-agent profile-status 12306", timeout: 15)
                )
                let profileResult = [profile.stdout, profile.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let upstreamReady = profileResult.contains("mcp_12306_upstream=available")
                let bundlePresent = profileResult.contains("mcp_12306_bundle=present")
                guard upstreamReady else {
                    NSLog(
                        "[ISHSelfTest] 12306_upstream_selftest_result 12306_upstream_selftest_missing installed=%@ server_started=0 reason=%@\\n%@",
                        bundlePresent ? "1" : "0",
                        bundlePresent ? "nodejs_missing" : "bundle_missing",
                        profileResult
                    )
                    return
                }

                let configuration = MCPConfiguration(
                    id: "12306-upstream-selftest",
                    name: "12306-mcp",
                    transport: .stdio,
                    command: "/usr/local/bin/ogent-agent",
                    arguments: ["mcp-12306-server"]
                )
                let manager = MCPClientManager()
                do {
                    NSLog("[ISHSelfTest] 12306_upstream_tools_list_start")
                    let tools = try await manager.toolsList(server: configuration)
                    NSLog("[ISHSelfTest] 12306_upstream_tools_list_done")
                    let info = await manager.sessionInfo(serverID: configuration.id)
                    NSLog("[ISHSelfTest] 12306_upstream_session_info_done name=%@ version=%@", info?.serverName ?? "unknown", info?.serverVersion ?? "unknown")
                    let upstreamVerified = info?.serverName == "12306-mcp"
                        && info?.serverVersion == ISHOgentAgentRuntime.upstream12306Version
                    let toolSummary = tools.objectValue?["tools"] == nil ? "tools=list_unknown" : "tools=list_ok"
                    await manager.shutdown()
                    NSLog("[ISHSelfTest] 12306_upstream_shutdown_done")
                    NSLog(
                        "[ISHSelfTest] 12306_upstream_selftest_result %@ installed=1 server_started=1 upstream_verified=%@ server_info_name=%@ server_info_version=%@ %@",
                        upstreamVerified ? "12306_upstream_selftest_ok" : "12306_upstream_selftest_fallback",
                        upstreamVerified ? "1" : "0",
                        info?.serverName ?? "unknown",
                        info?.serverVersion ?? "unknown",
                        toolSummary
                    )
                } catch {
                    await manager.shutdown()
                    NSLog("[ISHSelfTest] 12306_upstream_selftest_result 12306_upstream_selftest_missing installed=1 server_started=0 reason=%@", error.localizedDescription)
                }
            }
        }
        if ProcessInfo.processInfo.environment["OASES_12306_MCP_UPSTREAM_INSTALL_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                NSLog("[ISHSelfTest] 12306_upstream_install_start")
                let install = await ISHRuntimeService.shared.execute(
                    ISHCommand(
                        command: "/bin/sh /usr/local/bin/ogent-agent profile-install 12306",
                        timeout: 300,
                        environment: [
                            "OASES_PROFILE_INSTALL_TIMEOUT": ProcessInfo.processInfo.environment["OASES_PROFILE_INSTALL_TIMEOUT"] ?? "240",
                            "OASES_APK_UPDATE_TIMEOUT": ProcessInfo.processInfo.environment["OASES_APK_UPDATE_TIMEOUT"] ?? "45",
                            "OASES_APK_ADD_TIMEOUT": ProcessInfo.processInfo.environment["OASES_APK_ADD_TIMEOUT"] ?? "120"
                        ]
                    )
                )
                let installOutput = [install.stdout, install.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                NSLog(
                    "[ISHSelfTest] 12306_upstream_install_result %@",
                    String(installOutput.prefix(5_000))
                )

                let profile = await ISHRuntimeService.shared.execute(
                    ISHCommand(command: "/bin/sh /usr/local/bin/ogent-agent profile-status 12306", timeout: 20)
                )
                let profileResult = [profile.stdout, profile.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                NSLog("[ISHSelfTest] 12306_upstream_install_profile %@", profileResult)
                guard profileResult.contains("mcp_12306_upstream=available") else {
                    NSLog("[ISHSelfTest] 12306_upstream_install_selftest_result missing_upstream")
                    return
                }

                let configuration = MCPConfiguration(
                    id: "12306-upstream-install-selftest",
                    name: "12306-mcp",
                    transport: .stdio,
                    command: "/usr/local/bin/ogent-agent",
                    arguments: ["mcp-12306-server"]
                )
                let manager = MCPClientManager()
                do {
                    let tools = try await manager.toolsList(server: configuration)
                    let info = await manager.sessionInfo(serverID: configuration.id)
                    let verified = info?.serverName == "12306-mcp"
                        && info?.serverVersion == ISHOgentAgentRuntime.upstream12306Version
                    let toolSummary = tools.objectValue?["tools"] == nil ? "tools=list_unknown" : "tools=list_ok"
                    await manager.shutdown()
                    NSLog(
                        "[ISHSelfTest] 12306_upstream_install_selftest_result %@ server_info_name=%@ server_info_version=%@ %@",
                        verified ? "upstream_verified" : "server_identity_mismatch",
                        info?.serverName ?? "unknown",
                        info?.serverVersion ?? "unknown",
                        toolSummary
                    )
                } catch {
                    await manager.shutdown()
                    NSLog(
                        "[ISHSelfTest] 12306_upstream_install_selftest_result server_start_failed reason=%@",
                        error.localizedDescription
                    )
                }
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_ISH_INTERACTIVE_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let result = await ISHInteractiveSessionSelfTest.run()
                NSLog("[ISHSelfTest] %@", result)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_CAPABILITY_REPORT_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                NSLog("[ISHSelfTest] ogent_capability_report_start")
                do {
                    let reportResult = try await OgentCapabilityReportTool().invoke(argumentsJSON: "{}", onProgress: { line in
                        NSLog("[ISHSelfTest] capability %@", line.trimmingCharacters(in: .newlines))
                    })
                    NSLog("[ISHSelfTest] ogent_capability_report_result %@", reportResult.text ?? "")
                } catch {
                    NSLog("[ISHSelfTest] ogent_capability_report_failed %@", error.localizedDescription)
                }
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_METAL_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                do {
                    let status = try await MetalBridgeTool().invoke(argumentsJSON: "{\"action\":\"status\"}", onProgress: { line in
                        NSLog("[ISHSelfTest] metal %@", line.trimmingCharacters(in: .newlines))
                    })
                    NSLog("[ISHSelfTest] metal_bridge_status %@", status.text ?? "")
                    let vector = try await MetalBridgeTool().invoke(argumentsJSON: "{\"action\":\"vector_add_selftest\",\"length\":1024}", onProgress: { line in
                        NSLog("[ISHSelfTest] metal %@", line.trimmingCharacters(in: .newlines))
                    })
                    NSLog("[ISHSelfTest] metal_bridge_vector_result %@", vector.text ?? "")
                } catch {
                    NSLog("[ISHSelfTest] metal_bridge_failed %@", error.localizedDescription)
                }
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_MEMORY_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let autoWikiMemory = await OgentConversationMemorySelfTest.run()
                NSLog("[ISHSelfTest] auto_wiki_memory_result %@", autoWikiMemory)
                let compactionMemory = await OgentConversationMemorySelfTest.runCompactionSelfTest()
                NSLog("[ISHSelfTest] compaction_memory_result %@", compactionMemory)
                let ragContext = await OgentProjectMemoryContextLoader.runSelfTest()
                NSLog("[ISHSelfTest] rag_context_result %@", ragContext)
                let bootstrapContext = await OgentProjectMemoryContextLoader.runBootstrapSelfTest()
                NSLog("[ISHSelfTest] bootstrap_context_result %@", bootstrapContext)
                let opportunisticMemory = await OgentProjectMemoryContextLoader.runOpportunisticMemorySelfTest()
                NSLog("[ISHSelfTest] opportunistic_memory_result %@", opportunisticMemory)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_COMPACTION_MEMORY_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let compactionMemory = await OgentConversationMemorySelfTest.runCompactionSelfTest()
                NSLog("[ISHSelfTest] compaction_memory_result %@", compactionMemory)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_LOCAL_MODEL_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let localModelStatus = await OgentLocalModelRuntime.status()
                NSLog("[ISHSelfTest] local_model_status_result %@", localModelStatus)
                let localModelBootstrap = await OgentLocalModelRuntime.runBootstrapSelfTest()
                NSLog("[ISHSelfTest] local_model_bootstrap_result %@", localModelBootstrap)
                let realLocalModel = await OgentLocalModelRuntime.runRealLocalModelSelfTest()
                NSLog("[ISHSelfTest] real_local_model_runtime_result %@", realLocalModel)
                let deploymentPlan = await OgentLocalModelRuntime.runDeploymentPlanSelfTest()
                NSLog("[ISHSelfTest] local_model_deployment_plan_result %@", deploymentPlan)
                let modelDoctor = await OgentLocalModelRuntime.runDoctorSelfTest()
                NSLog("[ISHSelfTest] local_model_doctor_result %@", modelDoctor)
                let localModelProvision = await OgentLocalModelRuntime.runProvisionSelfTest()
                NSLog("[ISHSelfTest] local_model_provision_result %@", localModelProvision)
                let importValidation = ISHRootfsManager.runImportValidationSelfTest()
                NSLog("[ISHSelfTest] rootfs_import_validation_result %@", importValidation)
                let projectGate = await OgentLocalModelRuntime.runProjectInferenceGateSelfTest()
                NSLog("[ISHSelfTest] local_model_project_gate_result %@", projectGate)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_SUBAGENT_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let modelBootstrap = await OgentLocalModelRuntime.runBootstrapSelfTest()
                NSLog("[ISHSelfTest] subagent_model_bootstrap %@", modelBootstrap)
                let output = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    ISHRuntimeQueue.async {
                        guard ISHRuntimeBootstrap.bootstrap() else {
                            cont.resume(returning: "subagent_selftest_failed bootstrap=false")
                            return
                        }
                        let script = """
                        SELFTEST_TMP=/root/.ogent/tmp
                        mkdir -p "$SELFTEST_TMP"
                        cat > "$SELFTEST_TMP/subagent-worker.md" <<'OGENT_SUBAGENT_WORKER'
                        # Selftest Worker
                        You are a concise local worker. Return the marker subagent_run_selftest_ok.
                        OGENT_SUBAGENT_WORKER
                        cat > "$SELFTEST_TMP/subagent-task.md" <<'OGENT_SUBAGENT_TASK'
                        Produce a short result containing subagent_run_selftest_ok and explain whether the model endpoint is a compatibility harness or real runtime.
                        OGENT_SUBAGENT_TASK
                        /bin/sh /usr/local/bin/ogent-agent subagent-create --name selftest-runner --file "$SELFTEST_TMP/subagent-worker.md"
                        /bin/sh /usr/local/bin/ogent-agent subagent-task --name selftest-runner --file "$SELFTEST_TMP/subagent-task.md"
                        /bin/sh /usr/local/bin/ogent-agent subagent-run --name selftest-runner --task latest > "$SELFTEST_TMP/subagent-strict.txt" 2>&1 || true
                        if grep -q 'reason=local_model_not_real' "$SELFTEST_TMP/subagent-strict.txt"; then
                          echo subagent_strict_harness_block=ok
                        else
                          grep -q 'subagent_run=ok' "$SELFTEST_TMP/subagent-strict.txt" && echo subagent_strict_real_model=ok
                        fi
                        /bin/sh /usr/local/bin/ogent-agent subagent-run --name selftest-runner --task latest --allow-harness
                        /bin/sh /usr/local/bin/ogent-agent subagent-list | sed -n '1,12p'
                        """
                        let result = ShellTool.runOnQueue(command: script, timeout: 90, onProgress: { _ in })
                        let text = result.text ?? ""
                        let strictGateOK = text.contains("subagent_strict_harness_block=ok")
                            || text.contains("subagent_strict_real_model=ok")
                        let ok = strictGateOK
                            && text.contains("subagent_run=ok")
                            && text.contains("completed=")
                            && text.contains("runs=")
                        cont.resume(returning: ok ? "subagent_selftest_ok\n\(text)" : "subagent_selftest_failed\n\(text)")
                    }
                }
                NSLog("[ISHSelfTest] subagent_result %@", output)
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_ROOTFS_PROFILE_SELFTEST"] == "1" {
            Task.detached(priority: .utility) {
                let installLocalModelProfile = ProcessInfo.processInfo.environment["OASES_ROOTFS_PROFILE_INSTALL_LOCAL_MODEL"] == "1"
                let profileText = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    ISHRuntimeQueue.async {
                        guard ISHRuntimeBootstrap.bootstrap() else {
                            cont.resume(returning: "rootfs_profile_selftest_failed bootstrap=false")
                            return
                        }
                        let installLine = installLocalModelProfile
                            ? "/bin/sh /usr/local/bin/ogent-agent profile-install local-model\n"
                            : ""
                        let result = ShellTool.runOnQueue(
                            command: """
                            /bin/sh /usr/local/bin/ogent-agent rootfs-doctor
                            /bin/sh /usr/local/bin/ogent-agent rootfs-repair --check-only
                            /bin/sh /usr/local/bin/ogent-agent rootfs-doctor
                            /bin/sh /usr/local/bin/ogent-agent profile-status core
                            /bin/sh /usr/local/bin/ogent-agent profile-status 12306
                            \(installLine)\
                            /bin/sh /usr/local/bin/ogent-agent profile-status local-model
                            """,
                            timeout: 420,
                            onProgress: { _ in }
                        )
                        let text = result.text ?? ""
                        let ok = text.contains("agent_executable=ok")
                            && text.contains("rootfs_doctor_structure_ok")
                            && text.contains("rootfs_repair_ok")
                            && text.contains("profile_status profile=core")
                            && text.contains("profile_status profile=12306")
                            && text.contains("profile_status profile=local-model")
                            && text.contains("mcp_12306_shim=available")
                            && (text.contains("real_local_model_runtime=ready") || text.contains("real_local_model_runtime=missing"))
                        cont.resume(returning: ok ? "rootfs_profile_selftest_ok\n\(text)" : "rootfs_profile_selftest_missing\n\(text)")
                    }
                }
                NSLog("[ISHSelfTest] rootfs_profile_result %@", profileText)
            }
        }
        #endif

        NSLog("[OasesLaunch] app_init_end")

        #if DEBUG
        if ProcessInfo.processInfo.environment["OASES_ISH_SELFTEST"] == "1" {
            ISHRuntimeQueue.async {
                guard ISHRuntimeBootstrap.bootstrap() else {
                    NSLog("[ISHSelfTest] bootstrap failed")
                    return
                }
                // i18n-ignore: DEBUG self-test shell script
                let command = """
                SELFTEST_TMP=/root/.ogent/tmp
                mkdir -p "$SELFTEST_TMP"
                printf 'selftest=ok\\n' 2>"$SELFTEST_TMP/ish-selftest.err"
                printf_status=$?
                echo 'echo=ok'
                echo_status=$?
                /bin/echo 'bin_echo=ok'
                bin_echo_status=$?
                cat /etc/alpine-release
                cat_status=$?
                printf 'pwd=%s\\n' "$(pwd 2>/dev/null)"
                {
                  printf 'selftest-file=ok\\n'
                  printf 'printf_status=%s\\n' "$printf_status"
                  printf 'echo_status=%s\\n' "$echo_status"
                  printf 'bin_echo_status=%s\\n' "$bin_echo_status"
                  printf 'cat_status=%s\\n' "$cat_status"
                  test -t 1
                  printf 'test_t_1=%s\\n' "$?"
                  ls -l /proc/self/fd > "$SELFTEST_TMP/ish-selftest-fd.txt" 2>&1
                } > "$SELFTEST_TMP/ish-selftest.txt"
                /bin/sh /usr/local/bin/ogent-agent status | sed -n '1,8p'
                /bin/sh /usr/local/bin/ogent-agent rootfs-overlay-status | sed -n '1,20p'
                cat > "$SELFTEST_TMP/ogent-run-script-selftest.sh" <<'OGENT_RUN_SCRIPT_SELFTEST'
                set -eu
                echo run_script_ok
                mkdir -p "$OGENT_ARTIFACTS"
                echo "artifact_ok=$(date +%s 2>/dev/null || echo now)" > "$OGENT_ARTIFACTS/selftest-artifact.txt"
                OGENT_RUN_SCRIPT_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent run-script --title selftest --script-file "$SELFTEST_TMP/ogent-run-script-selftest.sh" --timeout 10 | sed -n '1,20p'
                /bin/sh /usr/local/bin/ogent-agent artifact-list | sed -n '1,12p'
                cat > "$SELFTEST_TMP/ogent-memory-selftest.md" <<'OGENT_MEMORY_SELFTEST'
                Ogent auto memory selftest marker: ogent_auto_memory_ok
                OGENT_MEMORY_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent memory-add --title selftest-auto-memory --tags auto,selftest --file "$SELFTEST_TMP/ogent-memory-selftest.md" | sed -n '1,12p'
                /bin/sh /usr/local/bin/ogent-agent rag-search ogent_auto_memory_ok | sed -n '1,18p'
                cat > "$SELFTEST_TMP/ogent-wiki-upsert-selftest.md" <<'OGENT_WIKI_UPSERT_SELFTEST'
                Ogent stable topic wiki selftest marker: ogent_wiki_upsert_ok
                This verifies that reusable project knowledge is updated into a stable topic page instead of only creating timestamped memory pages.
                OGENT_WIKI_UPSERT_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent wiki-upsert --topic project-mode-memory --title "Project Mode Memory" --tags selftest,wiki,rag --related project-e2e-delivery,ogent-agent --file "$SELFTEST_TMP/ogent-wiki-upsert-selftest.md" | sed -n '1,14p'
                /bin/sh /usr/local/bin/ogent-agent rag-search ogent_wiki_upsert_ok | sed -n '1,18p'
                cat > "$SELFTEST_TMP/ogent-skill-selftest.md" <<'OGENT_SKILL_SELFTEST'
                ---
                name: selftest-skill
                description: Selftest Linux-side skill.
                ---
                # Selftest Skill
                skill_selftest_ok
                OGENT_SKILL_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent skill-install --name selftest-skill --file "$SELFTEST_TMP/ogent-skill-selftest.md" | sed -n '1,8p'
                /bin/sh /usr/local/bin/ogent-agent skill-list | sed -n '1,12p'
                cat > "$SELFTEST_TMP/ogent-subagent-selftest.md" <<'OGENT_SUBAGENT_SELFTEST'
                # Selftest Worker
                subagent_selftest_ok
                OGENT_SUBAGENT_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent subagent-create --name selftest-worker --file "$SELFTEST_TMP/ogent-subagent-selftest.md" | sed -n '1,8p'
                /bin/sh /usr/local/bin/ogent-agent subagent-task --name selftest-worker --file "$SELFTEST_TMP/ogent-memory-selftest.md" | sed -n '1,8p'
                /bin/sh /usr/local/bin/ogent-agent subagent-run --name selftest-worker --task latest --allow-harness | sed -n '1,28p'
                /bin/sh /usr/local/bin/ogent-agent subagent-list | sed -n '1,12p'
                cat > "$SELFTEST_TMP/ogent-automation-selftest.sh" <<'OGENT_AUTOMATION_SELFTEST'
                set -eu
                echo automation_ok
                mkdir -p "$OGENT_ARTIFACTS"
                echo "automation_artifact_ok=$(date +%s 2>/dev/null || echo now)" > "$OGENT_ARTIFACTS/selftest-automation.txt"
                OGENT_AUTOMATION_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent automation-create --name selftest-auto --trigger manual --file "$SELFTEST_TMP/ogent-automation-selftest.sh" | tee "$SELFTEST_TMP/ogent-automation-create.out"
                auto_id="$(sed -n 's/.*id=\\([^ ]*\\).*/\\1/p' "$SELFTEST_TMP/ogent-automation-create.out" | tail -n 1)"
                /bin/sh /usr/local/bin/ogent-agent automation-list | sed -n '1,12p'
                if [ -n "$auto_id" ]; then
                  /bin/sh /usr/local/bin/ogent-agent automation-run "$auto_id" | sed -n '1,24p'
                fi
                cat > "$SELFTEST_TMP/ogent-automation-on-boot-selftest.sh" <<'OGENT_AUTOMATION_ON_BOOT_SELFTEST'
                set -eu
                echo automation_scheduler_on_boot_ok
                mkdir -p "$OGENT_ARTIFACTS"
                echo "automation_scheduler_on_boot_ok=$(date +%s 2>/dev/null || echo now)" > "$OGENT_ARTIFACTS/selftest-automation-on-boot.txt"
                OGENT_AUTOMATION_ON_BOOT_SELFTEST
                /bin/sh /usr/local/bin/ogent-agent automation-create --name selftest-on-boot --trigger on_boot --file "$SELFTEST_TMP/ogent-automation-on-boot-selftest.sh" | sed -n '1,8p'
                /bin/sh /usr/local/bin/ogent-agent artifact-list | sed -n '1,20p'
                cat > "$SELFTEST_TMP/ogent-project-e2e-plan.md" <<'OGENT_PROJECT_E2E_PLAN'
                - [x] 1. Restore Ogent workspace context
                - [x] 2. Create a user-facing engineering report artifact
                - [x] 3. Save the result into wiki memory and refresh local RAG
                - [x] 4. Export the artifact to iOS Documents
                OGENT_PROJECT_E2E_PLAN
                /bin/sh /usr/local/bin/ogent-agent plan-write --title project-e2e-delivery --file "$SELFTEST_TMP/ogent-project-e2e-plan.md" | sed -n '1,12p'
                cat > "$SELFTEST_TMP/ogent-project-e2e.sh" <<'OGENT_PROJECT_E2E_SCRIPT'
                set -eu
                mkdir -p "$OGENT_WORKSPACE" "$OGENT_ARTIFACTS"
                cat > "$OGENT_WORKSPACE/project-e2e-source.md" <<'OGENT_PROJECT_E2E_SOURCE'
                project_e2e_source_ok
                This source note proves the task used the persistent Ogent workspace before exporting a deliverable.
                OGENT_PROJECT_E2E_SOURCE
                cat > "$OGENT_ARTIFACTS/ogent-project-e2e-report.md" <<'OGENT_PROJECT_E2E_REPORT'
                # Ogent 工程模式 E2E 交付自测

                project_e2e_report_ok

                - runtime: iSH Alpine local Linux sandbox
                - workspace: persistent Ogent workspace
                - delivery: exported through iOS Documents/Ogent Artifacts
                - memory: saved into Ogent wiki and searchable through local RAG
                OGENT_PROJECT_E2E_REPORT
                echo "project_e2e_report_ok"
                echo "artifact=$OGENT_ARTIFACTS/ogent-project-e2e-report.md"
                OGENT_PROJECT_E2E_SCRIPT
                /bin/sh /usr/local/bin/ogent-agent run-script --title project-e2e-delivery --script-file "$SELFTEST_TMP/ogent-project-e2e.sh" --timeout 10 | sed -n '1,30p'
                /bin/sh /usr/local/bin/ogent-agent memory-add --title project-e2e-delivery --tags e2e,delivery,selftest --file "/root/.ogent/artifacts/ogent-project-e2e-report.md" | sed -n '1,12p'
                /bin/sh /usr/local/bin/ogent-agent rag-search project_e2e_report_ok | sed -n '1,18p'
                /bin/sh /usr/local/bin/ogent-agent artifact-list | sed -n '1,28p'
                """
                let result = ISHShellExecutor.executeCommandSync(
                    command,
                    timeout: 120,
                    lineCallback: { line, isStderr in
                        NSLog("[ISHSelfTest] %@%@", isStderr ? "stderr " : "", line)
                    }
                )
                NSLog("[ISHSelfTest] completed exit=%d duration=%.3f output=%@ stderr=%@",
                      result.exitCode,
                      result.duration,
                      result.output,
                      result.errorOutput)
                do {
                    let exported = try ISHRootfsManager.exportArtifact(
                        guestPath: "/root/.ogent/artifacts/selftest-artifact.txt",
                        destinationRelativePath: "ogent-selftest-artifact.txt"
                    )
                    let exportedText = (try? String(contentsOf: exported.destinationURL, encoding: .utf8)) ?? ""
                    NSLog("[ISHSelfTest] artifact_export_ok guest=%@ ios=%@ bytes=%lld content=%@",
                          exported.sourceGuestPath,
                          exported.destinationURL.path,
                          exported.byteCount,
                          exportedText.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    NSLog("[ISHSelfTest] artifact_export_failed %@", error.localizedDescription)
                }
                do {
                    let exported = try ISHRootfsManager.exportArtifact(
                        guestPath: "/root/.ogent/artifacts/ogent-project-e2e-report.md",
                        destinationRelativePath: "ogent-project-e2e-report.md"
                    )
                    let exportedText = (try? String(contentsOf: exported.destinationURL, encoding: .utf8)) ?? ""
                    if exportedText.contains("project_e2e_report_ok") {
                        NSLog("[ISHSelfTest] project_e2e_delivery_ok guest=%@ ios=%@ bytes=%lld",
                              exported.sourceGuestPath,
                              exported.destinationURL.path,
                              exported.byteCount)
                    } else {
                        NSLog("[ISHSelfTest] project_e2e_delivery_failed missing marker ios=%@",
                              exported.destinationURL.path)
                    }
                } catch {
                    NSLog("[ISHSelfTest] project_e2e_delivery_failed %@", error.localizedDescription)
                }
                Task.detached(priority: .utility) {
                    NSLog("[ISHSelfTest] web_cookie_start")
                    do {
                        let payload: [String: Any] = [
                            "action": "set_cookie",
                            "session": "selftest",
                            "name": "ogent_cookie_selftest",
                            "value": "ok",
                            "domain": "ogent.local",
                            "path": "/",
                            "expiresDays": 1
                        ]
                        let data = try JSONSerialization.data(withJSONObject: payload)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let cookieResult = try await WebBrowseTool().invoke(argumentsJSON: json, onProgress: { line in
                            NSLog("[ISHSelfTest] web %@", line.trimmingCharacters(in: .newlines))
                        })
                        let cookieText = cookieResult.text ?? ""
                        if cookieText.contains("ogent_cookie_selftest") {
                            NSLog("[ISHSelfTest] web_cookie_result web_cookie_ok\n%@", cookieText)
                        } else {
                            NSLog("[ISHSelfTest] web_cookie_failed missing marker\n%@", cookieText)
                        }
                    } catch {
                        NSLog("[ISHSelfTest] web_cookie_failed %@", error.localizedDescription)
                    }

                    let webSearchParser = WebSearchTool.runParserSelfTest()
                    NSLog("[ISHSelfTest] web_search_parser_result %@", webSearchParser)

                    NSLog("[ISHSelfTest] web_to_docx_start")
                    do {
                        let html = """
                        <!doctype html>
                        <html>
                          <head><title>Ogent Web Research Selftest</title></head>
                          <body>
                            <main>
                              <h1>Oil market briefing</h1>
                              <article>
                                <p>web_to_docx_source_ok</p>
                                <p>This deterministic browser page stands in for a crawled article before Ogent creates a Word deliverable.</p>
                                <a href="https://example.com/source">Source link</a>
                              </article>
                            </main>
                          </body>
                        </html>
                        """
                        let browsePayload: [String: Any] = [
                            "action": "load_html",
                            "session": "web-to-docx-selftest",
                            "html": html,
                            "baseURL": "https://example.com/research/",
                            "selector": "main"
                        ]
                        let browseData = try JSONSerialization.data(withJSONObject: browsePayload)
                        let browseJSON = String(data: browseData, encoding: .utf8) ?? "{}"
                        let browseResult = try await WebBrowseTool().invoke(argumentsJSON: browseJSON, onProgress: { line in
                            NSLog("[ISHSelfTest] web_to_docx %@", line.trimmingCharacters(in: .newlines))
                        })
                        let webText = browseResult.text ?? ""

                        let docxPayload: [String: Any] = [
                            "action": "create_docx",
                            "title": "Ogent Web Research Selftest",
                            "filename": "ogent-web-research-selftest.docx",
                            "content": """
                            # Ogent Web Research Selftest

                            web_to_docx_docx_ok

                            \(webText)
                            """
                        ]
                        let docxData = try JSONSerialization.data(withJSONObject: docxPayload)
                        let docxJSON = String(data: docxData, encoding: .utf8) ?? "{}"
                        let docxResult = try await ArtifactBridgeTool().invoke(argumentsJSON: docxJSON, onProgress: { line in
                            NSLog("[ISHSelfTest] web_to_docx %@", line.trimmingCharacters(in: .newlines))
                        })
                        let docxText = docxResult.text ?? ""
                        if webText.contains("web_to_docx_source_ok"),
                           docxText.contains("Created DOCX"),
                           docxText.contains("[oases:open]") {
                            NSLog("[ISHSelfTest] web_to_docx_delivery_ok\n%@", docxText)
                        } else {
                            NSLog("[ISHSelfTest] web_to_docx_failed web_has_marker=%d docx=%@",
                                  webText.contains("web_to_docx_source_ok") ? 1 : 0,
                                  docxText)
                        }
                    } catch {
                        NSLog("[ISHSelfTest] web_to_docx_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] docx_bridge_start")
                    do {
                        let payload: [String: Any] = [
                            "action": "create_docx",
                            "title": "Ogent DOCX Selftest",
                            "filename": "ogent-docx-selftest.docx",
                            "sections": [
                                [
                                    "heading": "Selftest",
                                    "body": "docx_bridge_ok",
                                    "bullets": ["created locally", "exported to iOS Documents"]
                                ]
                            ]
                        ]
                        let data = try JSONSerialization.data(withJSONObject: payload)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let docxResult = try await ArtifactBridgeTool().invoke(argumentsJSON: json, onProgress: { line in
                            NSLog("[ISHSelfTest] docx %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] docx_bridge_result %@", docxResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] docx_bridge_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] mcp_selftest_start")
                    do {
                        let mcpResult = try await MCPSelfTestTool().invoke(argumentsJSON: "{}", onProgress: { line in
                            NSLog("[ISHSelfTest] mcp %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] mcp_selftest_result %@", mcpResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] mcp_selftest_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] mcp_http_selftest_start")
                    do {
                        let mcpHTTPResult = try await MCPHTTPSelfTestTool().invoke(argumentsJSON: "{}", onProgress: { line in
                            NSLog("[ISHSelfTest] mcp_http %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] mcp_http_selftest_result %@", mcpHTTPResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] mcp_http_selftest_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] mcp_config_selftest_start")
                    do {
                        let mcpConfigResult = try await MCPConfigSelfTestTool().invoke(argumentsJSON: "{}", onProgress: { line in
                            NSLog("[ISHSelfTest] mcp_config %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] mcp_config_selftest_result %@", mcpConfigResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] mcp_config_selftest_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] ogent_health_check_start")
                    do {
                        let healthResult = try await OgentHealthCheckTool().invoke(argumentsJSON: "{\"includeMCP\":true}", onProgress: { line in
                            NSLog("[ISHSelfTest] health %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] ogent_health_check_result %@", healthResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] ogent_health_check_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] ogent_agent_wiki_upsert_start")
                    do {
                        let payload: [String: Any] = [
                            "action": "wiki_upsert",
                            "topic": "swift-tool-wiki-upsert",
                            "title": "Swift Tool Wiki Upsert",
                            "memoryValue": "ogent_tool_wiki_upsert_ok\nThis verifies the model-facing ogent_agent tool can update stable topic wiki pages.",
                            "memoryTags": "selftest,wiki,tool",
                            "related": "project-mode-memory,ogent-capability-report"
                        ]
                        let data = try JSONSerialization.data(withJSONObject: payload)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let toolResult = try await OgentAgentTool().invoke(argumentsJSON: json, onProgress: { line in
                            NSLog("[ISHSelfTest] ogent_agent_wiki_upsert %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] ogent_agent_wiki_upsert_result %@", toolResult.text ?? "")

                        let searchPayload: [String: Any] = [
                            "action": "rag_search",
                            "query": "ogent_tool_wiki_upsert_ok"
                        ]
                        let searchData = try JSONSerialization.data(withJSONObject: searchPayload)
                        let searchJSON = String(data: searchData, encoding: .utf8) ?? "{}"
	                        let searchResult = try await OgentAgentTool().invoke(argumentsJSON: searchJSON, onProgress: { line in
	                            NSLog("[ISHSelfTest] ogent_agent_wiki_rag %@", line.trimmingCharacters(in: .newlines))
	                        })
	                        NSLog("[ISHSelfTest] ogent_agent_wiki_rag_result %@", searchResult.text ?? "")

	                        let graphPayload: [String: Any] = [
	                            "action": "wiki_graph"
	                        ]
	                        let graphData = try JSONSerialization.data(withJSONObject: graphPayload)
	                        let graphJSON = String(data: graphData, encoding: .utf8) ?? "{}"
	                        let graphResult = try await OgentAgentTool().invoke(argumentsJSON: graphJSON, onProgress: { line in
	                            NSLog("[ISHSelfTest] ogent_agent_wiki_graph %@", line.trimmingCharacters(in: .newlines))
	                        })
	                        NSLog("[ISHSelfTest] ogent_agent_wiki_graph_result %@", graphResult.text ?? "")
	                    } catch {
	                        NSLog("[ISHSelfTest] ogent_agent_wiki_upsert_failed %@", error.localizedDescription)
	                    }

                    NSLog("[ISHSelfTest] ogent_capability_report_start")
                    do {
                        let reportResult = try await OgentCapabilityReportTool().invoke(argumentsJSON: "{}", onProgress: { line in
                            NSLog("[ISHSelfTest] capability %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] ogent_capability_report_result %@", reportResult.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] ogent_capability_report_failed %@", error.localizedDescription)
                    }

                    NSLog("[ISHSelfTest] metal_bridge_start")
                    do {
                        let status = try await MetalBridgeTool().invoke(argumentsJSON: "{\"action\":\"status\"}", onProgress: { line in
                            NSLog("[ISHSelfTest] metal %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] metal_bridge_status %@", status.text ?? "")

                        let vector = try await MetalBridgeTool().invoke(argumentsJSON: "{\"action\":\"vector_add_selftest\",\"length\":1024}", onProgress: { line in
                            NSLog("[ISHSelfTest] metal %@", line.trimmingCharacters(in: .newlines))
                        })
                        NSLog("[ISHSelfTest] metal_bridge_vector_result %@", vector.text ?? "")
                    } catch {
                        NSLog("[ISHSelfTest] metal_bridge_failed %@", error.localizedDescription)
                    }

                    let finalDeliveryFallback = await ProjectFinalDeliverySelfTest.run()
                    NSLog("[ISHSelfTest] final_delivery_fallback_result %@", finalDeliveryFallback)

                    let finalizerSnapshot = await ProjectFinalDeliverySelfTest.runSnapshotSelfTest()
                    NSLog("[ISHSelfTest] finalizer_snapshot_result %@", finalizerSnapshot)

                    let autoWikiMemory = await OgentConversationMemorySelfTest.run()
                    NSLog("[ISHSelfTest] auto_wiki_memory_result %@", autoWikiMemory)

                    let compactionMemory = await OgentConversationMemorySelfTest.runCompactionSelfTest()
                    NSLog("[ISHSelfTest] compaction_memory_result %@", compactionMemory)

                    let providerSettings = AIProviderSettingsStore.runSelfTest()
                    NSLog("[ISHSelfTest] ai_provider_settings_result %@", providerSettings)

                    let localModelSettings = OgentLocalModelSettingsStore.runSelfTest()
                    NSLog("[ISHSelfTest] local_model_settings_result %@", localModelSettings)

                    let localModelRuntime = await OgentLocalModelRuntime.runSelfTest()
                    NSLog("[ISHSelfTest] local_model_runtime_result %@", localModelRuntime)

                    let localModelBootstrap = await OgentLocalModelRuntime.runBootstrapSelfTest()
                    NSLog("[ISHSelfTest] local_model_bootstrap_result %@", localModelBootstrap)

                    let realLocalModel = await OgentLocalModelRuntime.runRealLocalModelSelfTest()
                    NSLog("[ISHSelfTest] real_local_model_runtime_result %@", realLocalModel)

                    let localModelProvision = await OgentLocalModelRuntime.runProvisionSelfTest()
                    NSLog("[ISHSelfTest] local_model_provision_result %@", localModelProvision)

                    let importValidation = ISHRootfsManager.runImportValidationSelfTest()
                    NSLog("[ISHSelfTest] rootfs_import_validation_result %@", importValidation)

                    let projectGate = await OgentLocalModelRuntime.runProjectInferenceGateSelfTest()
                    NSLog("[ISHSelfTest] local_model_project_gate_result %@", projectGate)

                    let autoSession = await OgentProjectSessionRecorder.runSelfTest()
                    NSLog("[ISHSelfTest] auto_session_result %@", autoSession)

                    let hostPreflight = await OgentProjectSessionRecorder.runHostPreflightSelfTest()
                    NSLog("[ISHSelfTest] host_preflight_result %@", hostPreflight)
                    let toolTrace = await OgentProjectSessionRecorder.runToolTraceSelfTest()
                    NSLog("[ISHSelfTest] tool_trace_result %@", toolTrace)

                    let profilePreflight = await OgentProjectProfilePreflight.runSelfTest()
                    NSLog("[ISHSelfTest] profile_preflight_result %@", profilePreflight)

                    let ragContext = await OgentProjectMemoryContextLoader.runSelfTest()
                    NSLog("[ISHSelfTest] rag_context_result %@", ragContext)

                    let bootstrapContext = await OgentProjectMemoryContextLoader.runBootstrapSelfTest()
                    NSLog("[ISHSelfTest] bootstrap_context_result %@", bootstrapContext)

                    let opportunisticMemory = await OgentProjectMemoryContextLoader.runOpportunisticMemorySelfTest()
                    NSLog("[ISHSelfTest] opportunistic_memory_result %@", opportunisticMemory)

                    let automationScheduler = await OgentAutomationScheduler.runDueForSelfTest(reason: "selftest")
                    NSLog("[ISHSelfTest] automation_scheduler_result %@", automationScheduler)
                }
            }
        }
        #endif

        NSLog("[OasesLaunch] app_init_end")
    }

    /// Created by the app delegate at launch, so a launch without a window has it too.
    private var account: AccountStore { appDelegate.account }

    var body: some Scene {
        WindowGroup {
            // One container (not a Group, which would hand every modifier below to each branch and
            // run the account work again when onboarding gives way to the app).
            ZStack {
                appRoot
            }
            .environment(account)
            // QingTeng account: with the one-page consent, restore the session, refresh it near
            // expiry (under 7 days left) and read the profile. Declining or withdrawing signs out
            // (`AccountStore.followConsent`); chat and everything else stay as they are.
            .task(id: allowsQingTengAccount) {
                if allowsQingTengAccount { await account.launch() }
            }
        }
        // Shared with App Intents — see `ConversationContainer`.
        .modelContainer(ConversationContainer.shared)
    }

    @ViewBuilder
    private var appRoot: some View {
        if hasAIDataSharingDecision {
            RootView()
                .id(appLanguage.isEmpty ? "system" : appLanguage)
                .environment(theme)
                .environmentObject(ShareCoordinator.shared)
                .preferredColorScheme(theme.colorScheme)
                .tint(OasesColor.primary)
                .onAppear {
                    AppLaunchCoordinator.startIfNeeded()
                }
                // `oases://` deep links (open_terminal / open / share / …).
                // The scheme is declared in Resources/Info.plist.
                // Navigation only, so it works in limited mode; anything a
                // link leads to that sends to AI is gated where it sends.
                .onOpenURL { url in
                    // `qtc-oases://oauth` belongs to the QingTeng sign-in under way, which gets it
                    // from its own browser session. One reaching the app any other way is dropped
                    // here; `DeepLinkRouter.handle` applies the same guard for every other entry
                    // point (notification `url`, in-app links). A result code must never reach a log.
                    guard url.scheme?.lowercased() != OAuthSignIn.callbackScheme else { return }
                    DeepLinkRouter.handle(url: url, shareCoordinator: ShareCoordinator.shared)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        AppLaunchCoordinator.startIfNeeded()
                        CrashReporter.shared.updateMarkerPhase(phase: "active")
                        AppLaunchCoordinator.restartDebugServerIfNeeded()
                        // Automations send data to models: consent only.
                        guard AIDataSharingConsent.isAccepted else { return }
                        OgentAutomationScheduler.scheduleRunDue(reason: "scene_active", delay: 2)
                    case .background:
                        CrashReporter.shared.updateMarkerPhase(phase: "background")
                        if AIDataSharingConsent.isAccepted {
                            OgentBackgroundAutomation.scheduleAppRefresh()
                        }
                    case .inactive:
                        CrashReporter.shared.updateMarkerPhase(phase: "inactive")
                    @unknown default:
                        break
                    }
                }
        } else {
            // First run: splash → welcome → privacy. Agreeing or
            // declining both store a decision, which swaps in RootView.
            OnboardingFlowView()
                .environment(theme)
                .preferredColorScheme(theme.colorScheme)
                .tint(OasesColor.primary)
        }
    }

    /// Observe both version and decision keys so the root swaps live when
    /// onboarding stores a decision. Declining is a decision too: the app
    /// opens in limited mode. Request and lifecycle guards keep reading
    /// `AIDataSharingConsent.isAccepted`.
    private var hasAIDataSharingDecision: Bool {
        _ = aiConsentVersion
        _ = aiConsentStatus
        return AIDataSharingConsent.hasDecision
    }

    /// The one-page consent is given (observed, so the account follows it live).
    private var allowsQingTengAccount: Bool {
        _ = aiConsentVersion
        _ = aiConsentStatus
        return AIDataSharingConsent.isAccepted
    }
}

enum OgentBackgroundAutomation {
    static let refreshIdentifier = "dev.oases.chat.ios.ogent.refresh"
    private static let earliestRefresh: TimeInterval = 15 * 60
    nonisolated(unsafe) private static var didRegister = false

    static func register() {
        guard !didRegister else { return }
        didRegister = true
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            guard AIDataSharingConsent.isAccepted else {
                NSLog("[OgentAutomation] background_refresh_ignored consent_required=1")
                refreshTask.setTaskCompleted(success: false)
                return
            }
            let taskBox = BackgroundRefreshTaskBox(refreshTask)
            let worker = Task.detached(priority: .utility) {
                await runAppRefreshTask()
                taskBox.setCompleted(success: true)
            }
            taskBox.setExpirationHandler {
                worker.cancel()
                taskBox.setCompleted(success: false)
            }
        }
        NSLog("[OgentAutomation] background_refresh_registered=%d", ok ? 1 : 0)
    }

    /// Drops a submitted, not-yet-run refresh (limited mode: declined or
    /// withdrawn consent). A refresh that still fires is ignored by the
    /// consent check in the handler.
    static func cancelAppRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        NSLog("[OgentAutomation] background_refresh_cancelled")
    }

    static func scheduleAppRefresh(earliest: TimeInterval = earliestRefresh) {
        guard AIDataSharingConsent.isAccepted else {
            NSLog("[OgentAutomation] background_refresh_blocked consent_required=1")
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[OgentAutomation] background_refresh_scheduled earliest=%.0fs", earliest)
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("not available") {
                NSLog("[OgentAutomation] background_refresh_unavailable %@", message)
            } else {
                NSLog("[OgentAutomation] background_refresh_submit_error %@", message)
            }
        }
    }

    static func runAppRefreshTask() async {
        guard AIDataSharingConsent.isAccepted else {
            NSLog("[OgentAutomation] background_refresh_blocked consent_required=1")
            return
        }
        NSLog("[OgentAutomation] background_refresh_start")
        let summary = await OgentAutomationScheduler.runDueForBackgroundTask(reason: "background_app_refresh")
        NSLog("[OgentAutomation] background_refresh_result %@", summary)
        scheduleAppRefresh()
    }
}

private final class BackgroundRefreshTaskBox: @unchecked Sendable {
    private let task: BGAppRefreshTask
    private let lock = NSLock()
    private var completed = false

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func setCompleted(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
