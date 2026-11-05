import Foundation

enum OgentLocalModelRuntime {
    struct ProbeResult: Equatable {
        let configured: Bool
        let ok: Bool
        let summary: String
        let baseURLString: String?
        let modelID: String?

        var isCompatibilityHarness: Bool {
            summary.contains("model_kind=compatibility_harness")
                || modelID == "ogent-local-echo"
        }

        var isRealInferenceReady: Bool {
            ok && !isCompatibilityHarness
        }
    }

    static func status(onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> String {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_status=unavailable reason=ish_not_ready"
        }
        let result = await run(command: OgentLinuxRuntime.localModelStatusCommand, timeout: 10, onProgress: onProgress)
        return result.text ?? ""
    }

    static func readiness(onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> String {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_readiness=unavailable reason=ish_not_ready"
        }
        let result = await run(command: OgentLinuxRuntime.localModelReadinessCommand, timeout: 10, onProgress: onProgress)
        return result.text ?? ""
    }

    static func probe(onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> ProbeResult {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return ProbeResult(
                configured: false,
                ok: false,
                summary: "local_model_probe=unavailable reason=ish_not_ready",
                baseURLString: nil,
                modelID: nil
            )
        }

        let statusText = await run(command: OgentLinuxRuntime.localModelStatusCommand, timeout: 10, onProgress: onProgress).text ?? ""
        let configured = value(after: "configured=", in: statusText) == "1"
        let baseURL = nonEmptyConfiguredValue(value(after: "base_url=", in: statusText))
        let modelID = nonEmptyConfiguredValue(value(after: "model_id=", in: statusText))

        let probeText = await run(command: OgentLinuxRuntime.localModelProbeCommand, timeout: 12, onProgress: onProgress).text ?? ""
        let ok = probeText.contains("local_model_probe=ok") && probeText.contains("[exit=0")
        let probeLine = probeText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.contains("local_model_probe=") })
            ?? oneLine(probeText)

        return ProbeResult(
            configured: configured,
            ok: ok,
            summary: ok
                ? probeLine
                : "\(probeLine); \(configured ? "configured_but_not_reachable" : "not_configured")",
            baseURLString: baseURL,
            modelID: modelID
        )
    }

    static func bootstrap(
        requireReal: Bool = false,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ProbeResult {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return ProbeResult(
                configured: false,
                ok: false,
                summary: "local_model_bootstrap=unavailable reason=ish_not_ready",
                baseURLString: nil,
                modelID: nil
            )
        }

        let bootstrapText = await run(
            command: OgentLinuxRuntime.localModelBootstrapCommand(requireReal: requireReal),
            timeout: 45,
            onProgress: onProgress
        ).text ?? ""
        let ok = bootstrapText.contains("local_model_probe=ok") && bootstrapText.contains("[exit=0")
        let statusText = await status(onProgress: onProgress)
        let baseURL = nonEmptyConfiguredValue(value(after: "base_url=", in: statusText))
        let modelID = nonEmptyConfiguredValue(value(after: "model_id=", in: statusText))
        let line = bootstrapText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.contains("local_model_probe=") || $0.contains("local_model_start=") })
            ?? oneLine(bootstrapText)
        return ProbeResult(
            configured: baseURL != nil,
            ok: ok,
            summary: ok ? "local_model_bootstrap=ok \(line)" : "local_model_bootstrap=failed \(line)",
            baseURLString: baseURL,
            modelID: modelID
        )
    }

    static func prepareForProjectInference(
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ProbeResult {
        let syncText = await syncConfiguredRouteToRuntime(onProgress: onProgress)
        onProgress("[local-model] \(oneLine(syncText))\n")

        let initial = await probe(onProgress: onProgress)
        if initial.isRealInferenceReady {
            return ProbeResult(
                configured: initial.configured,
                ok: true,
                summary: "local_model_project_prepare=ok already_ready \(initial.summary)",
                baseURLString: initial.baseURLString,
                modelID: initial.modelID
            )
        }

        let bootstrapped = await bootstrap(requireReal: true, onProgress: onProgress)
        if bootstrapped.isRealInferenceReady {
            return ProbeResult(
                configured: bootstrapped.configured,
                ok: true,
                summary: "local_model_project_prepare=ok bootstrapped_real \(bootstrapped.summary)",
                baseURLString: bootstrapped.baseURLString,
                modelID: bootstrapped.modelID
            )
        }

        let reason = bootstrapped.isCompatibilityHarness
            ? "compatibility_harness_not_allowed"
            : "real_runtime_unavailable"
        return ProbeResult(
            configured: bootstrapped.configured || initial.configured,
            ok: false,
            summary: "local_model_project_prepare=failed reason=\(reason) \(bootstrapped.summary)",
            baseURLString: bootstrapped.baseURLString ?? initial.baseURLString,
            modelID: bootstrapped.modelID ?? initial.modelID
        )
    }

    static func automaticProjectRouteIfReady(
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> (route: AIProviderRouting.Route?, summary: String) {
        let readinessText = await readiness(onProgress: onProgress)
        let readinessState = value(after: "local_model_readiness_state=", in: readinessText) ?? "unknown"
        let candidateStates: Set<String> = ["ready", "ready_to_start", "starting"]
        guard candidateStates.contains(readinessState) else {
            return (
                nil,
                "auto_local_model_route=skipped state=\(readinessState) \(oneLine(readinessText, limit: 280))"
            )
        }

        let prepared = await prepareForProjectInference(onProgress: onProgress)
        guard prepared.isRealInferenceReady,
              let baseURLString = prepared.baseURLString
                ?? nonEmptyConfiguredValue(value(after: "local_model_base_url=", in: readinessText)),
              let baseURL = URL(string: baseURLString) else {
            return (
                nil,
                "auto_local_model_route=blocked \(prepared.summary)"
            )
        }
        let modelID = prepared.modelID
            ?? nonEmptyConfiguredValue(value(after: "local_model_id=", in: readinessText))
        return (
            AIProviderRouting.Route(
                baseURL: baseURL,
                apiKey: nil,
                kind: .localISHModel,
                modelOverride: modelID
            ),
            "auto_local_model_route=ok state=\(readinessState) base_url=\(baseURLString) model_id=\(modelID ?? "none")"
        )
    }

    static func runSelfTest() async -> String {
        let statusText = await status()
        guard statusText.contains("mode=local-ish-model") else {
            return "local_model_runtime_selftest_failed status_missing"
        }

        let result = await probe()
        let probeHarnessOK = result.summary.contains("local_model_probe=")
        guard probeHarnessOK else {
            return "local_model_runtime_selftest_failed probe_missing"
        }

        let probeState: String
        if result.ok {
            probeState = "probe=ok"
        } else if result.configured {
            probeState = "probe=configured_unreachable"
        } else {
            probeState = "probe=not_configured"
        }
        return "local_model_runtime_selftest_ok configured=\(result.configured ? 1 : 0) \(probeState)"
    }

    static func runBootstrapSelfTest() async -> String {
        let result = await bootstrap()
        guard result.ok else {
            return "local_model_bootstrap_selftest_failed \(result.summary)"
        }
        let isHarness = result.summary.contains("model_kind=compatibility_harness")
            || result.modelID == "ogent-local-echo"
        return "local_model_bootstrap_selftest_ok endpoint=ok model_kind=\(isHarness ? "compatibility_harness" : "real_or_external") base_url=\(result.baseURLString ?? "unknown") model_id=\(result.modelID ?? "unknown")"
    }

    static func runRealLocalModelSelfTest() async -> String {
        let runnerValidation = await run(
            command: OgentLinuxRuntime.localModelRunnerValidationSelfTestCommand,
            timeout: 10,
            onProgress: { _ in }
        ).text ?? ""
        guard runnerValidation.contains("model_runner_validation_selftest_ok") else {
            return "real_local_model_runtime_failed runner_validation \(oneLine(runnerValidation))"
        }
        let runnerValidationDetail = oneLine(runnerValidation, limit: 240)
        let result = await bootstrap(requireReal: true)
        let isHarness = result.summary.contains("model_kind=compatibility_harness")
            || result.modelID == "ogent-local-echo"
        if result.ok, !isHarness {
            return "real_local_model_runtime_ok runner_validation=ok runner_validation_detail=\(runnerValidationDetail) base_url=\(result.baseURLString ?? "unknown") model_id=\(result.modelID ?? "unknown") \(result.summary)"
        }
        if result.summary.contains("real_runtime_required") || result.summary.contains("real_local_model_runtime=missing") {
            return "real_local_model_runtime_missing runner_validation=ok runner_validation_detail=\(runnerValidationDetail) \(result.summary)"
        }
        if isHarness {
            return "real_local_model_runtime_failed runner_validation=ok runner_validation_detail=\(runnerValidationDetail) harness_started \(result.summary)"
        }
        return "real_local_model_runtime_failed runner_validation=ok runner_validation_detail=\(runnerValidationDetail) \(result.summary)"
    }

    static func runProvisionSelfTest() async -> String {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_provision_selftest_failed reason=ish_not_ready"
        }
        let importedModelPath = "/root/.ogent/models/imported-selftest.gguf"
        let text = await run(
            command: OgentLinuxRuntime.localModelProvisionCommand(
                jobs: 1,
                clean: false,
                installDependencies: false,
                buildRunner: false,
                startServer: false
            ),
            timeout: 20,
            onProgress: { _ in }
        ).text ?? ""
        let hasStart = text.contains("model_provision=start")
        let reportedState = text.contains("model_provision=missing_model_url")
            || text.contains("model_provision=ready start=skipped")
            || text.contains("model_provision=ok")
        guard hasStart, reportedState else {
            return "local_model_provision_selftest_failed \(oneLine(text))"
        }
        let fileText = await run(
            command: OgentLinuxRuntime.localModelProvisionCommand(
                modelFile: importedModelPath,
                jobs: 1,
                clean: false,
                installDependencies: false,
                buildRunner: false,
                startServer: false
            ),
            timeout: 20,
            onProgress: { _ in }
        ).text ?? ""
        let modelFileProvisionOK = fileText.contains("model_provision_model_file=\(importedModelPath)")
            && (
                fileText.contains("model_provision=missing_model_file path=\(importedModelPath)")
                    || fileText.contains("model_provision=invalid_model_file path=\(importedModelPath)")
                    || fileText.contains("model_provision=model_ready path=\(importedModelPath)")
                    || fileText.contains("model_provision=missing_runner")
            )
        guard modelFileProvisionOK else {
            return "local_model_provision_selftest_failed reason=model_file_path_missing \(oneLine(fileText, limit: 420))"
        }
        if text.contains("model_provision=missing_model_url") {
            return "local_model_provision_selftest_ok state=missing_model_url model_file_path=ok"
        }
        if text.contains("model_provision=ok") {
            return "local_model_provision_selftest_ok state=ready_or_started model_file_path=ok"
        }
        return "local_model_provision_selftest_ok state=ready_start_skipped"
    }

    static func runDeploymentPlanSelfTest() async -> String {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_deployment_plan_selftest_failed reason=ish_not_ready"
        }
        let text = await run(
            command: OgentLinuxRuntime.localModelPlanCommand(),
            timeout: 20,
            onProgress: { _ in }
        ).text ?? ""
        let hasPlan = text.contains("model_deployment_plan=start")
            && text.contains("stage_dependencies=")
            && text.contains("stage_runner=")
            && text.contains("stage_model=")
            && text.contains("stage_runtime=")
            && text.contains("expected_runner_arch=")
            && text.contains("runner_build_supported=1")
            && text.contains("model_provision_command=")
            && text.contains("model_build_runner_command=")
            && text.contains("model_deployment_blockers=")
            && text.contains("model_deployment_next_command=")
            && text.contains("readiness_manifest=")
            && text.contains("local_model_readiness_state=")
            && text.contains("local_model_next_command=")
        guard hasPlan else {
            return "local_model_deployment_plan_selftest_failed \(oneLine(text, limit: 420))"
        }
        let urlPlanText = await run(
            command: OgentLinuxRuntime.localModelPlanCommand(
                modelURL: "https://example.invalid/ogent-test.gguf",
                modelID: "ogent-test",
                runnerURL: "https://example.invalid/llama-server"
            ),
            timeout: 20,
            onProgress: { _ in }
        ).text ?? ""
        let runnerURLPlanOK = urlPlanText.contains("runner_url=https://example.invalid/llama-server")
            && urlPlanText.contains("model_url=https://example.invalid/ogent-test.gguf")
            && (
                urlPlanText.contains("model_install_runner")
                || urlPlanText.contains("--runner-url 'https://example.invalid/llama-server'")
                || urlPlanText.contains("stage_runner=ready")
            )
            && urlPlanText.contains("model_provision_command=")
        guard runnerURLPlanOK else {
            return "local_model_deployment_plan_selftest_failed reason=runner_url_plan_missing \(oneLine(urlPlanText, limit: 420))"
        }
        let importedModelPath = "/root/.ogent/models/imported-selftest.gguf"
        let filePlanText = await run(
            command: OgentLinuxRuntime.localModelPlanCommand(
                modelID: "ogent-test",
                modelFile: importedModelPath
            ),
            timeout: 20,
            onProgress: { _ in }
        ).text ?? ""
        let modelFilePlanOK = filePlanText.contains("model_file=\(importedModelPath)")
            && (
                filePlanText.contains("stage_model=missing path=\(importedModelPath)")
                    || filePlanText.contains("stage_model=invalid_gguf_magic path=\(importedModelPath)")
                    || filePlanText.contains("stage_model=ready path=\(importedModelPath)")
            )
            && (
                filePlanText.contains("--model-file '\(importedModelPath)'")
                    || filePlanText.contains("import_valid_gguf_or_fix_model_file:\(importedModelPath)")
                    || filePlanText.contains("model_deployment_next_command=")
            )
            && filePlanText.contains("model_provision_command=")
        guard modelFilePlanOK else {
            return "local_model_deployment_plan_selftest_failed reason=model_file_plan_missing \(oneLine(filePlanText, limit: 420))"
        }
        let state = text.contains("model_deployment_plan=ready") ? "ready" : "incomplete"
        let next = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("model_deployment_next_command=") })
            ?? "model_deployment_next_command=missing"
        let readiness = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("local_model_readiness_state=") })
            ?? "local_model_readiness_state=missing"
        return "local_model_deployment_plan_selftest_ok state=\(state) runner_url_plan=ok model_file_plan=ok \(oneLine(next, limit: 320)) \(readiness)"
    }

    static func runDoctorSelfTest() async -> String {
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_doctor_selftest_failed reason=ish_not_ready"
        }
        let text = await run(
            command: OgentLinuxRuntime.localModelDoctorCommand(
                modelURL: "https://example.invalid/ogent-test.gguf",
                modelID: "ogent-test",
                modelFile: "/root/.ogent/models/imported-selftest.gguf",
                runnerURL: "https://example.invalid/llama-server"
            ),
            timeout: 25,
            onProgress: { _ in }
        ).text ?? ""
        let hasDoctor = text.contains("model_doctor_start")
            && text.contains("profile_dependencies_state=")
            && text.contains("runner_state=")
            && text.contains("expected_runner_arch=")
            && text.contains("gguf_state=")
            && text.contains("endpoint_state=")
            && text.contains("subagent_inference_gate=")
            && text.contains("model_provision_command=")
            && text.contains("model_deployment_blockers=")
            && text.contains("model_doctor_next_command=")
            && text.contains("model_doctor_status=")
            && text.contains("gguf_detail=stage_model=")
            && text.contains("imported-selftest.gguf")
        guard hasDoctor else {
            return "local_model_doctor_selftest_failed \(oneLine(text, limit: 420))"
        }
        let status = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("model_doctor_status=") })
            ?? "model_doctor_status=missing"
        let next = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("model_doctor_next_command=") })
            ?? "model_doctor_next_command=missing"
        return "local_model_doctor_selftest_ok \(oneLine(status, limit: 160)) \(oneLine(next, limit: 320))"
    }

    static func runProjectInferenceGateSelfTest() async -> String {
        let probeResult = await probe()
        let readinessText = await readiness()
        let readinessSummary = oneLine(readinessText, limit: 300)
        let autoRoute = await automaticProjectRouteIfReady()
        if probeResult.isRealInferenceReady {
            return "local_model_project_gate_ok state=real_ready auto_route=\(autoRoute.route == nil ? "missing" : "ok") \(probeResult.summary) readiness=\(readinessSummary)"
        }
        if probeResult.ok, probeResult.isCompatibilityHarness {
            return "local_model_project_gate_ok state=blocked_compatibility_harness auto_route_skipped=1 \(probeResult.summary) readiness=\(readinessSummary) \(autoRoute.summary)"
        }
        let scan = await run(command: OgentLinuxRuntime.localModelScanCommand, timeout: 12, onProgress: { _ in }).text ?? ""
        let reportedReadiness = scan.contains("real_local_model_runtime=ready")
            || scan.contains("real_local_model_runtime=missing")
        let manifestReady = scan.contains("readiness_manifest=")
            && scan.contains("local_model_readiness_state=")
            && scan.contains("local_model_next_command=")
        return reportedReadiness
            ? "local_model_project_gate_ok state=needs_real_runtime manifest=\(manifestReady ? "ok" : "missing") \(oneLine(scan, limit: 360))"
            : "local_model_project_gate_failed \(oneLine(scan, limit: 360))"
    }

    private static func syncConfiguredRouteToRuntime(onProgress: @escaping @Sendable (String) -> Void) async -> String {
        let snapshot = OgentLocalModelSettingsStore.snapshot()
        guard snapshot.isConfigured else {
            return "local_model_config_sync=skipped reason=local_route_disabled_or_invalid"
        }
        guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
            return "local_model_config_sync=failed reason=ish_not_ready"
        }
        let result = await run(
            command: OgentLinuxRuntime.localModelConfigCommand(
                baseURL: snapshot.baseURLString,
                modelID: snapshot.modelID,
                apiKey: "",
                startCommand: snapshot.startCommand,
                runtimeKind: snapshot.runtimeKind,
                modelFile: snapshot.modelFile,
                extraArgs: snapshot.extraArgs
            ),
            timeout: 10,
            onProgress: onProgress
        )
        let text = result.text ?? ""
        if text.contains("model_config_saved") && text.contains("[exit=0") {
            return "local_model_config_sync=ok"
        }
        return "local_model_config_sync=failed \(oneLine(text))"
    }

    private static func run(
        command: String,
        timeout: TimeInterval,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> ToolResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ToolResult, Never>) in
            ISHRuntimeQueue.async {
                let result = ShellTool.runOnQueue(command: command, timeout: timeout, onProgress: onProgress)
                cont.resume(returning: result)
            }
        }
    }

    private static func value(after prefix: String, in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func nonEmptyConfiguredValue(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty,
              clean != "not-configured" else {
            return nil
        }
        return clean
    }

    private static func oneLine(_ value: String, limit: Int = 220) -> String {
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(limit))
    }
}
