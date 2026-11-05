import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Subordinate settings pages extracted from the legacy SettingsView.swift monolith.
// Root settings IA now lives in SettingsView.swift (OpenMinis-aligned).

struct AppearanceSettingsView: View {
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        List {
            Section("主题模式") {
                ForEach(ThemeManager.Mode.allCases) { mode in
                    Button {
                        theme.mode = mode
                        Haptics.select()
                    } label: {
                        HStack {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 14))
                                .foregroundStyle(OasesColor.primary)
                                .frame(width: 22)
                            Text(mode.label)
                                .font(.oasesBody())
                                .foregroundStyle(OasesColor.foreground)
                            Spacer()
                            if theme.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OasesColor.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("主题与外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelPrefsView: View {
    @AppStorage(Models.PreferenceKey.defaultChatModel) private var defaultChatModel = Models.defaultChat
    @AppStorage(Models.PreferenceKey.defaultEffort) private var defaultEffort = Models.Effort.high.rawValue

    var body: some View {
        List {
            Section("默认文本模型") {
                ForEach(Models.chat) { option in
                    defaultModelRow(option)
                }
            }

            Section {
                ForEach(Models.betaChat) { option in
                    defaultModelRow(option)
                }
            } header: {
                Text("Oases 尝鲜模型")
            } footer: {
                Text("Beta 模型能力与稳定性可能随时变化。")
            }

            Section("推理强度") {
                ForEach(Models.Effort.allCases) { effort in
                    Button {
                        defaultEffort = effort.rawValue
                        Haptics.select()
                    } label: {
                        HStack {
                            Text(effort.label)
                                .font(.oasesBody())
                                .foregroundStyle(OasesColor.foreground)
                            Spacer()
                            if defaultEffort == effort.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OasesColor.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("模型偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func defaultModelRow(_ option: Models.Option) -> some View {
        Button {
            defaultChatModel = option.id
            Haptics.select()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.oasesBody())
                            .foregroundStyle(OasesColor.foreground)
                        if option.isBeta {
                            Text("Beta")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OasesColor.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OasesColor.primary.opacity(0.12), in: Capsule())
                        }
                        if option.isPromoFree {
                            PromoFreeBadge()
                        }
                    }
                    Text(option.descriptionText)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                Spacer()
                if defaultChatModel == option.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OasesColor.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct AgentSettingsView: View {
    @State private var servers: [OasesMCPServerConfig] = []
    @State private var importText: String = ""
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var shellReady = false
    @State private var rootfsStatus = ISHRootfsManager.status()
    @State private var providerBaseURL = ""
    @State private var providerAPIKey = ""
    @State private var providerHasAPIKey = false
    @State private var providerMessage: String?
    @State private var providerError: String?
    @State private var providerIsTesting = false
    @State private var localModelEnabled = false
    @State private var localModelBaseURL = OgentLocalModelSettingsStore.defaultBaseURLString
    @State private var localModelID = ""
    @State private var localModelStartCommand = ""
    @State private var localModelRuntimeKind = "llama.cpp"
    @State private var localModelFile = ""
    @State private var localModelDownloadURL = ""
    @State private var localModelDownloadSHA256 = ""
    @State private var localModelRunnerDownloadURL = ""
    @State private var localModelRunnerDownloadSHA256 = ""
    @State private var localModelExtraArgs = "--ctx-size 4096"
    @State private var localModelMessage: String?
    @State private var localModelError: String?
    @State private var localModelIsTesting = false
    @State private var localModelScanOutput = ""
    @State private var showModelImporter = false
    @State private var showModelRunnerImporter = false
    @State private var capabilityReport = ""
    @State private var capabilityError: String?
    @State private var capabilityIsRunning = false

    var body: some View {
        List {
            Section("工程模式") {
                infoRow("terminal.fill", "iSH Alpine", shellReady ? String(localized: "运行中，本机执行 shell_execute") : String(localized: "启动中或未就绪"))
                infoRow("cpu.fill", "Ogent Runtime", String(localized: "本机代理框架 · 持久工作区"))
                infoRow("list.bullet.clipboard.fill", String(localized: "计划与会话"), "PLAN.md · sessions · checkpoints")
                infoRow("brain.head.profile", String(localized: "Wiki 记忆与 RAG"), String(localized: "Markdown 记忆 · 本地全文检索"))
                infoRow("person.2.wave.2.fill", String(localized: "技能与子代理"), String(localized: "SKILL.md · workspace 子代理指令"))
                infoRow("heart.text.square.fill", String(localized: "手机数据源"), String(localized: "日历 · 提醒 · 通讯录 · 照片 · 位置 · 天气"))
                infoRow("clock.arrow.circlepath", String(localized: "自动化"), "manual · hourly · daily · interval · on_boot")
                infoRow("shippingbox.fill", String(localized: "工作区与产物"), String(localized: "workspace · artifacts · iOS 导出"))
                NavigationLink {
                    RootfsManagementView()
                } label: {
                    infoRow("folder.fill", String(localized: "Rootfs 管理"), rootfsStatus.installed ? "\(rootfsStatus.dataSizeLabel) · Alpine \(rootfsStatus.alpineVersion ?? String(localized: "unknown"))" : String(localized: "未安装"))
                }
                infoRow("wrench.and.screwdriver.fill", String(localized: "工程工具"), String(localized: "\(ToolRegistry.shared.descriptors(for: .project).count) 个已注册"))
            }

            Section {
                infoRow("checkmark.seal.fill", String(localized: "目标状态"), capabilityHeadline)

                Button {
                    runCapabilityReport()
                } label: {
                    if capabilityIsRunning {
                        Label("检查中", systemImage: "hourglass")
                    } else {
                        Label("运行能力报告", systemImage: "checkmark.seal")
                    }
                }
                .disabled(capabilityIsRunning)

                if !capabilityReport.isEmpty {
                    Text(compactCapabilityReport(capabilityReport))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .textSelection(.enabled)
                }

                if let capabilityError {
                    Text(capabilityError)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.destructive)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Ogent 目标检查")
            } footer: {
                Text("用于验证 Ogent 是否达到本机 iSH 执行、MCP、技能、子代理、wiki/RAG、产物交付与模型端点完整可用。未配置自定义 Provider 时默认使用 Oases 系统模型。")
            }

            Section {
                infoRow(
                    "network",
                    String(localized: "当前模型路由"),
                    AIProviderRouting.projectRouteSummary
                )

                TextField("https://api.example.com/v1", text: $providerBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField(providerHasAPIKey ? "已保存 API Key，留空则保持不变" : "API Key", text: $providerAPIKey)
                    // [T-provider-label-keyboard] A credential, not a saveable
                    // account password: without this iOS offers to save the
                    // key and pairs the base-URL field above as its username.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        saveProviderSettings()
                    } label: {
                        Label("保存", systemImage: "checkmark.circle")
                    }
                    .disabled(providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button {
                        testProviderConnection()
                    } label: {
                        if providerIsTesting {
                            Label("测试中", systemImage: "hourglass")
                        } else {
                            Label("测试", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(providerIsTesting || AIProviderRouting.projectRoute == nil)

                    Spacer()

                    Button(role: .destructive) {
                        clearProviderSettings()
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                    .disabled(providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !providerHasAPIKey)
                }

                if let providerMessage {
                    Text(providerMessage)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.emerald)
                        .textSelection(.enabled)
                }
                if let providerError {
                    Text(providerError)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.destructive)
                        .textSelection(.enabled)
                }
            } header: {
                Text("自定义 Ogent AI Provider（可选）")
            } footer: {
                Text("Ogent 默认使用内置 Oases 系统模型端点，无需配置 Provider。这里仅供高级用户覆盖为自定义的兼容格式（Chat Completions）端点或本机 iSH 模型。工具执行、workspace、产物与 wiki/RAG 仍在本机。API Key 保存在系统 Keychain。")
            }

            Section {
                Toggle(isOn: $localModelEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用本机模型路由")
                            .font(.oasesBody())
                            .foregroundStyle(OasesColor.foreground)
                        Text("开启后工程模式模型请求会优先发往下方真实 iSH 模型 endpoint；兼容 harness 只用于路由测试，不会被启动按钮当作真实模型。")
                            .font(.oasesCaption())
                            .foregroundStyle(OasesColor.mutedForeground)
                    }
                }

                TextField("http://127.0.0.1:11434/v1", text: $localModelBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("模型 ID，例如 llama-local", text: $localModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Runtime，例如 llama.cpp", text: $localModelRuntimeKind)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("GGUF 路径，例如 /root/.ogent/models/model.gguf", text: $localModelFile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("启动参数，例如 --ctx-size 4096", text: $localModelExtraArgs)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("可选启动命令，例如 ollama serve", text: $localModelStartCommand)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        showModelImporter = true
                    } label: {
                        Label("导入 GGUF", systemImage: "square.and.arrow.down")
                    }
                    .disabled(localModelIsTesting)

                    Spacer()

                    Button {
                        scanLocalModelRuntime()
                    } label: {
                        Label("扫描 runtime", systemImage: "magnifyingglass")
                    }
                    .disabled(localModelIsTesting)
                }

                Button {
                    planLocalModelRuntime()
                } label: {
                    if localModelIsTesting {
                        Label("审计中", systemImage: "hourglass")
                    } else {
                        Label("生成本机模型部署计划", systemImage: "list.bullet.clipboard")
                    }
                }
                .disabled(localModelIsTesting)

                Button {
                    doctorLocalModelRuntime()
                } label: {
                    if localModelIsTesting {
                        Label("诊断中", systemImage: "hourglass")
                    } else {
                        Label("运行本机模型 Doctor", systemImage: "stethoscope")
                    }
                }
                .disabled(localModelIsTesting)

                TextField("GGUF 下载 URL（https://.../*.gguf）", text: $localModelDownloadURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("SHA-256（可选）", text: $localModelDownloadSHA256)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    downloadLocalModelGGUF()
                } label: {
                    if localModelIsTesting {
                        Label("下载中", systemImage: "hourglass")
                    } else {
                        Label("下载 GGUF 到 iSH", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(localModelIsTesting || localModelDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                TextField("llama-server 下载 URL（iSH aarch64 Linux ELF）", text: $localModelRunnerDownloadURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("Runner SHA-256（可选）", text: $localModelRunnerDownloadSHA256)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    downloadLocalModelRunner()
                } label: {
                    if localModelIsTesting {
                        Label("下载中", systemImage: "hourglass")
                    } else {
                        Label("下载 llama-server 到 iSH", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(localModelIsTesting || localModelRunnerDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showModelRunnerImporter = true
                } label: {
                    Label("导入 llama-server", systemImage: "terminal")
                }
                .disabled(localModelIsTesting)

                Button {
                    buildLocalModelRunner()
                } label: {
                    if localModelIsTesting {
                        Label("构建中", systemImage: "hourglass")
                    } else {
                        Label("在 iSH 构建 llama-server", systemImage: "hammer")
                    }
                }
                .disabled(localModelIsTesting)

                Button {
                    provisionLocalModelRuntime()
                } label: {
                    if localModelIsTesting {
                        Label("Provision 中", systemImage: "hourglass")
                    } else {
                        Label("一键 Provision 真实本机模型", systemImage: "checkmark.seal")
                    }
                }
                .disabled(localModelIsTesting)

                if !localModelScanOutput.isEmpty {
                    Text(localModelScanOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        saveLocalModelSettings()
                    } label: {
                        Label("保存", systemImage: "checkmark.circle")
                    }

                    Spacer()

                    Button {
                        testLocalModelRuntime()
                    } label: {
                        if localModelIsTesting {
                            Label("探测中", systemImage: "hourglass")
                        } else {
                            Label("探测", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(localModelIsTesting)

                    Spacer()

                    Button(role: .destructive) {
                        clearLocalModelSettings()
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                }

                Button {
                    bootstrapLocalModelRuntime()
                } label: {
                    if localModelIsTesting {
                        Label("启动中", systemImage: "hourglass")
                    } else {
                        Label("启动并探测真实本机模型", systemImage: "play.circle")
                    }
                }
                .disabled(localModelIsTesting)

                if let localModelMessage {
                    Text(localModelMessage)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.emerald)
                        .textSelection(.enabled)
                }
                if let localModelError {
                    Text(localModelError)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.destructive)
                        .textSelection(.enabled)
                }
            } header: {
                Text("本机 iSH 模型 Runtime（高级 / Ogent）")
            } footer: {
                Text("这是 Hermes/Halo 式“模型也在设备端”的严格 gate。默认不启用；不启用时工程模式走 Oases 模型端点，本机 iSH 仍负责工具、workspace、MCP、技能、子代理、wiki/RAG 和产物。真实本机推理需要 iSH 里存在当前 guest 架构可执行的 aarch64 Linux ELF 版 llama-server 和 GGUF；可以导入 GGUF、从 URL 下载 GGUF、导入已编译 iSH runner，也可以在 iSH 内构建 llama.cpp。未填写启动命令时，兼容 harness 只用于验证 /models 与流式路由，不代表真实本地大模型推理。")
            }

            Section {
                if servers.isEmpty {
                    infoRow("point.3.connected.trianglepath.dotted", String(localized: "未配置 MCP"), String(localized: "可粘贴 Claude Desktop JSON 导入"))
                } else {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: Binding(
                                get: { server.isEnabled },
                                set: { next in
                                    MCPSettingsStore.setEnabled(id: server.id, isEnabled: next)
                                    reloadServers()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(server.name)
                                            .font(.oasesBodyBold())
                                            .foregroundStyle(OasesColor.foreground)
                                        Text(server.transport.label)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(OasesColor.primary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(OasesColor.primary.opacity(0.12)))
                                    }
                                    Text(server.endpointSummary)
                                        .font(.oasesCaption())
                                        .foregroundStyle(OasesColor.mutedForeground)
                                        .lineLimit(2)
                                    Text(server.redactedEnvironmentSummary)
                                        .font(.oasesCaption())
                                        .foregroundStyle(OasesColor.mutedForeground.opacity(0.8))
                                }
                            }

                            Button(role: .destructive) {
                                MCPSettingsStore.delete(id: server.id)
                                reloadServers()
                            } label: {
                                Label("删除 server", systemImage: "trash")
                                    .font(.oasesCaptionBold())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("MCP Servers")
            } footer: {
                Text("这里只保留你自己添加的 MCP。粘贴 Claude Desktop 的 JSON 即可导入。")
            }

            Section("导入 Claude Desktop JSON") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $importText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 150)
                    if importText.isEmpty {
                        Text(#"{"mcpServers":{"filesystem":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],"env":{"TOKEN":"..."}}}}"#)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OasesColor.mutedForeground.opacity(0.55))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

                Button {
                    importClaudeJSON()
                } label: {
                    Label("导入 mcpServers", systemImage: "square.and.arrow.down")
                }
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let importMessage {
                    Text(importMessage)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.emerald)
                }
                if let importError {
                    Text(importError)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.destructive)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ogent Runtime")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showModelImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            importLocalModelFile(result)
        }
        .fileImporter(
            isPresented: $showModelRunnerImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            importLocalModelRunner(result)
        }
        .onAppear {
            reloadServers()
            loadProviderSettings()
            loadLocalModelSettings()
            shellReady = ish_runtime_is_ready() != 0
            rootfsStatus = ISHRootfsManager.status()
        }
        .task {
            await refreshShellStatus()
        }
    }

    private func reloadServers() {
        servers = MCPSettingsStore.load()
    }

    private func loadProviderSettings() {
        let snapshot = AIProviderSettingsStore.snapshot()
        providerBaseURL = snapshot.baseURLString
        providerAPIKey = ""
        providerHasAPIKey = snapshot.hasAPIKey
    }

    private func loadLocalModelSettings() {
        let snapshot = OgentLocalModelSettingsStore.snapshot()
        localModelEnabled = snapshot.isEnabled
        localModelBaseURL = snapshot.baseURLString
        localModelID = snapshot.modelID
        localModelRuntimeKind = snapshot.runtimeKind
        localModelFile = snapshot.modelFile
        localModelExtraArgs = snapshot.extraArgs
        localModelStartCommand = snapshot.startCommand
    }

    private var capabilityHeadline: String {
        if capabilityIsRunning {
            return String(localized: "正在检查本机执行层和验收 gate")
        }
        if capabilityReport.contains("halo_target_complete=1") {
            return String(localized: "完整目标已达成")
        }
        if capabilityReport.contains("halo_target_complete=0") {
            if capabilityReport.contains("- subagent_real_model_gate=missing")
                || capabilityReport.contains("subagent_real_model_gate=missing") {
                return String(localized: "本机执行层可用 · 子代理真实推理未完成")
            }
            if capabilityReport.contains("real_local_model_runtime=missing") {
                if capabilityReport.contains("local_model_endpoint=achieved") {
                    return String(localized: "本机 endpoint 可用 · 真实本机模型未完成")
                }
                return String(localized: "本机执行层可用 · 本机模型 endpoint 未完成")
            }
            if capabilityReport.contains("model_endpoint=missing") {
                return String(localized: "本机执行层可用 · 模型端点未完成")
            }
            return String(localized: "仍有验收 gate 未完成")
        }
        return String(localized: "尚未运行")
    }

    private func saveProviderSettings() {
        providerMessage = nil
        providerError = nil
        do {
            try AIProviderSettingsStore.save(
                baseURLString: providerBaseURL,
                apiKey: providerAPIKey.isEmpty ? nil : providerAPIKey
            )
            loadProviderSettings()
            providerMessage = String(localized: "自定义工程模式 AI Provider 已保存。请点“测试”确认 /models 可访问。")
            Haptics.success()
        } catch {
            providerError = error.localizedDescription
            Haptics.error()
        }
    }

    private func testProviderConnection() {
        providerMessage = nil
        providerError = nil
        providerIsTesting = true
        Task {
            do {
                let result = try await AIProviderSettingsStore.testProjectProviderConnection()
                await MainActor.run {
                    providerIsTesting = false
                    providerMessage = result
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    providerIsTesting = false
                    providerError = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }

    private func runCapabilityReport() {
        capabilityIsRunning = true
        capabilityError = nil
        capabilityReport = ""

        Task {
            do {
                let result = try await OgentCapabilityReportTool().invoke(argumentsJSON: "{}", onProgress: { _ in })
                await MainActor.run {
                    capabilityIsRunning = false
                    capabilityReport = result.text ?? ""
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    capabilityIsRunning = false
                    capabilityError = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }

    private func compactCapabilityReport(_ text: String) -> String {
        let interestingPrefixes = [
            "ogent_capability_report_",
            "halo_target_complete=",
            "execution=",
            "model_provider_note=",
            "provider_probe=",
            "- model_endpoint=",
            "- local_linux_ish=",
            "- ai_provider_routing=",
            "- provider_live_probe=",
            "- local_model_runtime=",
            "- local_model_deployment_plan=",
            "- local_model_endpoint=",
            "- real_local_model_runtime=",
            "- subagent_real_model_gate=",
            "subagent_real_model_gate=",
            "local_model_probe=",
            "model_deployment_next_command=",
            "model_deployment_plan=",
            "- mcp_bridge=",
            "- native_ios_skills=",
            "- wiki_memory_rag=",
            "- wiki_link_graph=",
            "- skills_subagents_automations=",
            "- task_status_delivery_guard=",
            "- artifact_delivery=",
            "- persistent_browser=",
            "- web_discovery=",
            "- metal_host_bridge="
        ]
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                interestingPrefixes.contains { line.hasPrefix($0) }
            }
        return lines.isEmpty ? String(text.prefix(1_500)) : lines.joined(separator: "\n")
    }

    private func clearProviderSettings() {
        providerMessage = nil
        providerError = nil
        AIProviderSettingsStore.clear()
        loadProviderSettings()
        providerMessage = String(localized: "已恢复默认模型路由。")
        Haptics.success()
    }

    private func importLocalModelFile(_ result: Result<[URL], Error>) {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        do {
            guard let source = try result.get().first else { return }
            let imported = try ISHRootfsManager.importModelFile(from: source)
            localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
            localModelFile = imported.guestPath
            if localModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                localModelID = (imported.filename as NSString).deletingPathExtension
            }
            rootfsStatus = ISHRootfsManager.status()
            localModelMessage = String(localized: "已导入 GGUF：\(imported.filename) · \(imported.sizeLabel)\n路径：\(imported.guestPath)")
            Haptics.success()
            do {
                try OgentLocalModelSettingsStore.save(
                    isEnabled: localModelEnabled,
                    baseURLString: localModelBaseURL,
                    modelID: localModelID,
                    runtimeKind: localModelRuntimeKind,
                    modelFile: localModelFile,
                    extraArgs: localModelExtraArgs,
                    startCommand: localModelStartCommand
                )
            } catch {
                localModelError = error.localizedDescription
            }
            scanLocalModelRuntime(prefixMessage: localModelMessage)
        } catch {
            localModelError = error.localizedDescription
            Haptics.error()
        }
    }

    private func importLocalModelRunner(_ result: Result<[URL], Error>) {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        do {
            guard let source = try result.get().first else { return }
            let imported = try ISHRootfsManager.importLocalModelRunner(from: source)
            rootfsStatus = ISHRootfsManager.status()
            localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
            let importMessage = String(localized: "已导入 llama-server：\(imported.filename) · \(imported.sizeLabel)\n路径：\(imported.guestPath)")
            localModelMessage = importMessage
            Haptics.success()
            do {
                try OgentLocalModelSettingsStore.save(
                    isEnabled: localModelEnabled,
                    baseURLString: localModelBaseURL,
                    modelID: localModelID,
                    runtimeKind: localModelRuntimeKind,
                    modelFile: localModelFile,
                    extraArgs: localModelExtraArgs,
                    startCommand: localModelStartCommand
                )
            } catch {
                localModelError = error.localizedDescription
            }
            scanLocalModelRuntime(prefixMessage: importMessage)
        } catch {
            localModelError = error.localizedDescription
            Haptics.error()
        }
    }

    private func scanLocalModelRuntime(prefixMessage: String? = nil) {
        localModelMessage = prefixMessage
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let pendingBaseURL = localModelBaseURL
        let pendingModelID = localModelID
        let pendingRuntimeKind = localModelRuntimeKind
        let pendingModelFile = localModelFile
        let pendingExtraArgs = localModelExtraArgs
        let pendingStartCommand = localModelStartCommand

        Task {
            let syncText = await syncLocalModelRuntimeConfig(
                baseURL: pendingBaseURL,
                modelID: pendingModelID,
                startCommand: pendingStartCommand,
                runtimeKind: pendingRuntimeKind,
                modelFile: pendingModelFile,
                extraArgs: pendingExtraArgs
            )
            let scanText = await runOgentCommand(OgentLinuxRuntime.localModelScanCommand, timeout: 12)
            await MainActor.run {
                localModelIsTesting = false
                localModelScanOutput = scanText
                let prefixLines = prefixMessage.map { [$0] } ?? []
                if scanText.contains("real_local_model_runtime=ready") {
                    localModelMessage = (prefixLines + [
                        syncText,
                        String(localized: "真实本机模型 runtime 已就绪：llama-server 和 GGUF 都已找到；下一步可启动并探测真实本机模型。")
                    ]).joined(separator: "\n")
                    Haptics.success()
                } else {
                    localModelMessage = prefixMessage
                    localModelError = [
                        syncText,
                        String(localized: "真实本机模型 runtime 尚未就绪。需要同时具备 iSH 可执行的 aarch64 Linux ELF llama-server 和 GGUF 模型文件；可将 iSH 内构建出的 llama-server 放到 /root/.ogent/bin 或 /root/.ogent/models/bin，并通过“导入 GGUF”导入模型。")
                    ].joined(separator: "\n")
                    if prefixMessage == nil {
                        Haptics.error()
                    }
                }
            }
        }
    }

    private func buildLocalModelRunner() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelBuildLlamaCommand(
                    jobs: 1,
                    clean: false,
                    installDependencies: true
                ),
                timeout: 1800
            )
            await MainActor.run {
                localModelIsTesting = false
                rootfsStatus = ISHRootfsManager.status()
                localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
                localModelScanOutput = output
                if output.contains("model_build_llama=ok") {
                    localModelMessage = String(localized: "llama-server 已在 iSH 内构建完成，并安装到 /root/.ogent/models/bin/llama-server。下一步导入 GGUF 后可启动并探测真实本机模型。")
                    Haptics.success()
                } else {
                    localModelError = String(localized: "iSH 内构建 llama-server 未完成。请查看输出中的 model_build_llama 阶段、apk 网络或 cmake 编译错误。")
                    Haptics.error()
                }
            }
        }
    }

    private func planLocalModelRuntime() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let url = localModelDownloadURL
        let sha256 = localModelDownloadSHA256
        let pendingModelID = localModelID
        let pendingModelFile = localModelFile
        let runnerURL = localModelRunnerDownloadURL
        let runnerSHA256 = localModelRunnerDownloadSHA256
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelPlanCommand(
                    modelURL: url,
                    sha256: sha256,
                    modelID: pendingModelID,
                    modelFile: pendingModelFile,
                    runnerURL: runnerURL,
                    runnerSHA256: runnerSHA256
                ),
                timeout: 30
            )
            await MainActor.run {
                localModelIsTesting = false
                localModelScanOutput = output
                if output.contains("model_deployment_plan=ready") {
                    localModelMessage = String(localized: "真实本机模型部署计划已达成；可启动并探测真实 runtime。")
                    Haptics.success()
                } else if let command = lineValue(prefix: "model_provision_command=", in: output),
                          let arch = lineValue(prefix: "expected_runner_arch=", in: output) {
                    localModelError = String(localized: "真实本机模型部署尚未完成。目标 runner 架构：\(arch)。可执行：\(command)")
                    Haptics.error()
                } else if let next = lineValue(prefix: "model_deployment_next_command=", in: output) {
                    localModelError = String(localized: "真实本机模型部署尚未完成。下一步：\(next)")
                    Haptics.error()
                } else {
                    localModelError = String(localized: "真实本机模型部署计划未返回下一步命令，请查看输出。")
                    Haptics.error()
                }
            }
        }
    }

    private func doctorLocalModelRuntime() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let url = localModelDownloadURL
        let sha256 = localModelDownloadSHA256
        let pendingModelID = localModelID
        let pendingModelFile = localModelFile
        let runnerURL = localModelRunnerDownloadURL
        let runnerSHA256 = localModelRunnerDownloadSHA256
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelDoctorCommand(
                    modelURL: url,
                    sha256: sha256,
                    modelID: pendingModelID,
                    modelFile: pendingModelFile,
                    runnerURL: runnerURL,
                    runnerSHA256: runnerSHA256
                ),
                timeout: 35
            )
            await MainActor.run {
                localModelIsTesting = false
                localModelScanOutput = output
                if output.contains("model_doctor_status=ready") {
                    localModelMessage = String(localized: "本机模型 Doctor 已确认真实 runtime 就绪；可启动并探测真实本机模型。")
                    Haptics.success()
                } else if let command = lineValue(prefix: "model_provision_command=", in: output),
                          let blockers = lineValue(prefix: "model_deployment_blockers=", in: output) {
                    localModelError = String(localized: "本机模型 Doctor：尚未完成。阻塞项：\(blockers)。可执行：\(command)")
                    Haptics.error()
                } else if let next = lineValue(prefix: "model_doctor_next_command=", in: output) {
                    localModelError = String(localized: "本机模型 Doctor：尚未完成。下一步：\(next)")
                    Haptics.error()
                } else {
                    localModelError = String(localized: "本机模型 Doctor 未返回下一步命令，请查看输出。")
                    Haptics.error()
                }
            }
        }
    }

    private func downloadLocalModelRunner() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let url = localModelRunnerDownloadURL
        let sha256 = localModelRunnerDownloadSHA256
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelInstallRunnerCommand(
                    url: url,
                    sha256: sha256
                ),
                timeout: 1800
            )
            await MainActor.run {
                localModelIsTesting = false
                rootfsStatus = ISHRootfsManager.status()
                localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
                localModelScanOutput = output
                if output.contains("model_install_runner=ok") {
                    localModelMessage = String(localized: "llama-server 已下载到 iSH，并通过当前 guest 架构 Linux ELF 校验。下一步导入或下载 GGUF 后可启动真实本机模型。")
                    Haptics.success()
                } else if output.contains("reason=wrong_guest_arch_linux_elf")
                    || output.contains("reason=not_32bit_x86_linux_elf") {
                    localModelError = String(localized: "下载的 runner 不是当前 iSH guest 可执行的 aarch64 Linux ELF。请换成 iSH/Alpine aarch64 兼容的 llama-server。")
                    Haptics.error()
                } else {
                    localModelError = String(localized: "llama-server 下载或校验未完成。请查看输出中的 model_install_runner 阶段、URL、网络或 SHA-256 错误。")
                    Haptics.error()
                }
            }
        }
    }

    private func downloadLocalModelGGUF() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let url = localModelDownloadURL
        let sha256 = localModelDownloadSHA256
        let pendingModelID = localModelID
        let pendingExtraArgs = localModelExtraArgs
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelInstallGGUFCommand(
                    url: url,
                    sha256: sha256,
                    modelID: pendingModelID,
                    setDefault: true,
                    extraArgs: pendingExtraArgs
                ),
                timeout: 7200
            )
            await MainActor.run {
                localModelIsTesting = false
                rootfsStatus = ISHRootfsManager.status()
                localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
                localModelScanOutput = output
                if output.contains("model_install_gguf=ok") {
                    if let modelFile = lineValue(prefix: "model_file=", in: output) {
                        localModelFile = modelFile
                    }
                    if let modelID = lineValue(prefix: "model_id=", in: output),
                       !modelID.isEmpty {
                        localModelID = modelID
                    }
                    do {
                        try OgentLocalModelSettingsStore.save(
                            isEnabled: localModelEnabled,
                            baseURLString: localModelBaseURL,
                            modelID: localModelID,
                            runtimeKind: localModelRuntimeKind,
                            modelFile: localModelFile,
                            extraArgs: localModelExtraArgs,
                            startCommand: localModelStartCommand
                        )
                    } catch {
                        localModelError = error.localizedDescription
                    }
                    localModelMessage = String(localized: "GGUF 已下载到 iSH 并写入 llama.cpp 配置。下一步可启动并探测真实本机模型。")
                    Haptics.success()
                } else {
                    localModelError = String(localized: "GGUF 下载或校验未完成。请查看输出中的 model_install_gguf 阶段、URL、网络、GGUF magic 或 SHA-256 错误。")
                    Haptics.error()
                }
            }
        }
    }

    private func provisionLocalModelRuntime() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        localModelIsTesting = true
        let url = localModelDownloadURL
        let sha256 = localModelDownloadSHA256
        let pendingModelID = localModelID
        let pendingModelFile = localModelFile
        let pendingExtraArgs = localModelExtraArgs
        let runnerURL = localModelRunnerDownloadURL
        let runnerSHA256 = localModelRunnerDownloadSHA256
        Task {
            let output = await runOgentCommand(
                OgentLinuxRuntime.localModelProvisionCommand(
                    modelURL: url,
                    sha256: sha256,
                    modelID: pendingModelID,
                    modelFile: pendingModelFile,
                    extraArgs: pendingExtraArgs,
                    runnerURL: runnerURL,
                    runnerSHA256: runnerSHA256,
                    jobs: 1,
                    clean: false,
                    installDependencies: true,
                    buildRunner: true,
                    startServer: true
                ),
                timeout: 7200
            )
            await MainActor.run {
                localModelIsTesting = false
                rootfsStatus = ISHRootfsManager.status()
                localModelRuntimeKind = OgentLocalModelSettingsStore.defaultRuntimeKind
                localModelScanOutput = output
                if let modelFile = lineValue(prefix: "model_file=", in: output) {
                    localModelFile = modelFile
                }
                if let modelID = lineValue(prefix: "model_id=", in: output),
                   !modelID.isEmpty {
                    localModelID = modelID
                }
                if output.contains("model_provision=ok"),
                   output.contains("local_model_probe=ok") {
                    do {
                        try OgentLocalModelSettingsStore.save(
                            isEnabled: true,
                            baseURLString: localModelBaseURL,
                            modelID: localModelID,
                            runtimeKind: localModelRuntimeKind,
                            modelFile: localModelFile,
                            extraArgs: localModelExtraArgs,
                            startCommand: localModelStartCommand
                        )
                        localModelEnabled = true
                    } catch {
                        localModelError = error.localizedDescription
                    }
                    localModelMessage = String(localized: "真实本机模型 provisioning 已完成，并已启动/探测通过。工程模式可优先使用 iSH 内 llama.cpp endpoint。")
                    Haptics.success()
                } else if output.contains("model_provision=missing_model_url") {
                    let arch = lineValue(prefix: "model_provision_expected_runner_arch=", in: output) ?? "aarch64"
                    localModelError = String(localized: "Provision 已完成可自动执行的部分，目标 runner 架构：\(arch)，但缺少 GGUF 下载 URL。请输入 GGUF URL，或先导入 GGUF 后重试。")
                    Haptics.error()
                } else {
                    localModelError = String(localized: "真实本机模型 provisioning 未完成。请查看输出中的 model_provision/model_build_llama/model_install_gguf/local_model_probe 阶段。")
                    Haptics.error()
                }
            }
        }
    }

    private func saveLocalModelSettings() {
        localModelMessage = nil
        localModelError = nil
        let pendingBaseURL = localModelBaseURL
        let pendingModelID = localModelID
        let pendingRuntimeKind = localModelRuntimeKind
        let pendingModelFile = localModelFile
        let pendingExtraArgs = localModelExtraArgs
        let pendingStartCommand = localModelStartCommand
        do {
            try OgentLocalModelSettingsStore.save(
                isEnabled: localModelEnabled,
                baseURLString: pendingBaseURL,
                modelID: pendingModelID,
                runtimeKind: pendingRuntimeKind,
                modelFile: pendingModelFile,
                extraArgs: pendingExtraArgs,
                startCommand: pendingStartCommand
            )
            loadLocalModelSettings()
            Task {
                let syncText = await syncLocalModelRuntimeConfig(
                    baseURL: pendingBaseURL,
                    modelID: pendingModelID,
                    startCommand: pendingStartCommand,
                    runtimeKind: pendingRuntimeKind,
                    modelFile: pendingModelFile,
                    extraArgs: pendingExtraArgs
                )
                await MainActor.run {
                    localModelMessage = syncText
                    Haptics.success()
                }
            }
        } catch {
            localModelError = error.localizedDescription
            Haptics.error()
        }
    }

    private func lineValue(prefix: String, in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func testLocalModelRuntime() {
        localModelMessage = nil
        localModelError = nil
        localModelIsTesting = true
        let pendingBaseURL = localModelBaseURL
        let pendingModelID = localModelID
        let pendingRuntimeKind = localModelRuntimeKind
        let pendingModelFile = localModelFile
        let pendingExtraArgs = localModelExtraArgs
        let pendingStartCommand = localModelStartCommand
        Task {
            _ = await syncLocalModelRuntimeConfig(
                baseURL: pendingBaseURL,
                modelID: pendingModelID,
                startCommand: pendingStartCommand,
                runtimeKind: pendingRuntimeKind,
                modelFile: pendingModelFile,
                extraArgs: pendingExtraArgs
            )
            let probe = await OgentLocalModelRuntime.probe()
            await MainActor.run {
                localModelIsTesting = false
                if probe.ok {
                    localModelMessage = probe.summary
                    Haptics.success()
                } else {
                    localModelError = probe.summary
                    Haptics.error()
                }
            }
        }
    }

    private func bootstrapLocalModelRuntime() {
        localModelMessage = nil
        localModelError = nil
        localModelIsTesting = true
        let pendingBaseURL = localModelBaseURL
        let pendingModelID = localModelID
        let pendingRuntimeKind = localModelRuntimeKind
        let pendingModelFile = localModelFile
        let pendingExtraArgs = localModelExtraArgs
        let pendingStartCommand = localModelStartCommand
        Task {
            _ = await syncLocalModelRuntimeConfig(
                baseURL: pendingBaseURL,
                modelID: pendingModelID,
                startCommand: pendingStartCommand,
                runtimeKind: pendingRuntimeKind,
                modelFile: pendingModelFile,
                extraArgs: pendingExtraArgs
            )
            let result = await OgentLocalModelRuntime.bootstrap(requireReal: true)
            await MainActor.run {
                localModelIsTesting = false
                if result.ok {
                    localModelEnabled = true
                    if let base = result.baseURLString {
                        localModelBaseURL = base
                    }
                    if let model = result.modelID {
                        localModelID = model
                    }
                    try? OgentLocalModelSettingsStore.save(
                        isEnabled: true,
                        baseURLString: result.baseURLString ?? localModelBaseURL,
                        modelID: result.modelID ?? localModelID,
                        runtimeKind: pendingRuntimeKind,
                        modelFile: pendingModelFile,
                        extraArgs: pendingExtraArgs,
                        startCommand: pendingStartCommand
                    )
                    localModelMessage = result.summary
                    Haptics.success()
                } else {
                    localModelError = result.summary
                    Haptics.error()
                }
            }
        }
    }

    private func clearLocalModelSettings() {
        localModelMessage = nil
        localModelError = nil
        localModelScanOutput = ""
        OgentLocalModelSettingsStore.clear()
        loadLocalModelSettings()
        localModelMessage = String(localized: "已恢复 Oases 默认模型端点；本机 iSH 模型路由已关闭。")
        Haptics.success()
    }

    private func syncLocalModelRuntimeConfig(
        baseURL: String,
        modelID: String,
        startCommand: String,
        runtimeKind: String,
        modelFile: String,
        extraArgs: String
    ) async -> String {
        let command = OgentLinuxRuntime.localModelConfigCommand(
            baseURL: baseURL,
            modelID: modelID,
            apiKey: "",
            startCommand: startCommand,
            runtimeKind: runtimeKind,
            modelFile: modelFile,
            extraArgs: extraArgs
        )
        let output = await runOgentCommand(command, timeout: 10)
        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.contains("model_config_saved") || $0.contains("local_model") })
            ?? String(localized: "本机模型配置已保存。")
        return firstLine
    }

    private func runOgentCommand(_ command: String, timeout: TimeInterval) async -> String {
        // Off the main thread (the bootstrap waits for the runtime thread) and off the runtime
        // thread (local model installs run for minutes).
        let result = await withCheckedContinuation { (cont: CheckedContinuation<ToolResult?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard ISHRuntimeQueue.sync({ ISHRuntimeBootstrap.bootstrap() }) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: ShellTool.runOnQueue(command: command, timeout: timeout, onProgress: { _ in }))
            }
        }
        guard let result else { return String(localized: "iSH 暂未就绪，稍后重试。") }
        return result.text ?? ""
    }

    private func refreshShellStatus() async {
        if ish_runtime_is_ready() != 0 {
            await MainActor.run {
                shellReady = true
                rootfsStatus = ISHRootfsManager.status()
            }
            return
        }

        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ISHRuntimeQueue.async {
                continuation.resume(returning: ISHRuntimeBootstrap.bootstrap())
            }
        }
        await MainActor.run {
            shellReady = ready
            rootfsStatus = ISHRootfsManager.status()
        }
    }

    private func importClaudeJSON() {
        importMessage = nil
        importError = nil
        do {
            let count = try MCPSettingsStore.importClaudeDesktopJSON(importText)
            reloadServers()
            importText = ""
            importMessage = String(localized: "已导入 \(count) 个 MCP server。")
            Haptics.success()
        } catch {
            importError = error.localizedDescription
            Haptics.error()
        }
    }

    @ViewBuilder
    private func infoRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: OasesSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(OasesColor.primary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                Text(detail)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DataPrivacyView: View {
    @Environment(ThemeManager.self) private var theme
    /// Observed so the row updates the moment the choice changes.
    @AppStorage(AIDataSharingConsent.versionKey) private var consentVersion: String = ""
    @AppStorage(AIDataSharingConsent.statusKey) private var consentStatus: String = ""
    @State private var confirmsWithdrawal = false

    private var isAccepted: Bool {
        _ = consentVersion
        _ = consentStatus
        return AIDataSharingConsent.isAccepted
    }

    var body: some View {
        List {
            // The one-page consent: one row. Withdrawing turns AI and the QingTeng account off
            // (limited mode); an AI action or sign-in shows the page again.
            Section {
                Button(role: .destructive) {
                    confirmsWithdrawal = true
                } label: {
                    Text(QT("consent.withdraw"))
                        .font(.oasesBody())
                }
                .disabled(!isAccepted)
                .accessibilityIdentifier("oases.settings.privacy.withdraw")
            }
            Section("数据存储") {
                infoRow("lock.fill", String(localized: "对话与附件"), String(localized: "对话、草稿和应用设置默认保存在本机。提交请求时，相关消息、会话上下文以及你选择的附件会发送给当前模型服务"))
                infoRow("iphone", String(localized: "只存在本机"), String(localized: "Oases Chat 不提供 iCloud 同步，也没有 App 内的 iCloud 备份，对话、会话文件和设置不会被本 App 上传到 iCloud。如果你打开了 iPhone 的「iCloud 云备份」，iOS 的整机备份可能包含这些数据"))
            }
            Section("网络与密钥") {
                infoRow("network", String(localized: "请求路由"), String(localized: "内置模型请求会发送至 Oases 网关（api.oases.dev），再按所选模型路由；最终下游服务商由该服务决定。自行添加的服务商请求发送到你配置的具体端点，请先确认其运营方"))
                infoRow("key.fill", String(localized: "密钥管理"), String(localized: "API Key 与登录凭据保存在系统钥匙串（Keychain）中，并随请求发送给你选择的端点用于身份验证。打开「iCloud 钥匙串」时，API Key 和环境变量里的密钥会由 iOS 同步到你的其他 Apple 设备；OAuth 登录凭据只留在本机"))
            }
            Section("隐私声明") {
                infoRow("arrow.up.right.square", String(localized: "AI 数据共享"), String(localized: "提交请求会将消息、会话上下文以及你提交的文件、图片或音频发送给 Oases 网关或所选 Provider；接收方可能依据自己的隐私政策收集和处理这些数据"))
                infoRow("trash", String(localized: "删除与撤回"), String(localized: "可在历史记录中删除本地对话，在服务商设置中移除凭据，并在此处撤回 AI 数据共享同意"))
                infoRow("eye.slash.fill", String(localized: "广告追踪"), String(localized: "不含任何广告追踪 SDK"))
            }
            // The QingTeng account (optional): what its server keeps, and QingTeng Studio's own
            // policy and terms (the account's operator).
            Section {
                infoRow("person.crop.circle", QT("account.rowTitle"), QT("privacy.account"))
                Link(destination: ConsentLinks.privacyPolicy) {
                    Label(QT("privacy.qtPolicy"), systemImage: "doc.text")
                        .font(.oasesBody())
                }
                Link(destination: ConsentLinks.terms) {
                    Label(QT("privacy.qtTerms"), systemImage: "signature")
                        .font(.oasesBody())
                }
            }
            Section {
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    Label(SettingsCopy.t("开源许可", "Open Source Licenses"), systemImage: "doc.text")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("数据与隐私")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            QT("consent.withdrawTitle"),
            isPresented: $confirmsWithdrawal,
            titleVisibility: .visible
        ) {
            Button(QT("consent.withdrawBtn"), role: .destructive) {
                // Limited mode, not the onboarding: the app stays open. The account signs out
                // and AI requests under way stop (the consent's change notification).
                AIDataSharingConsent.decline()
            }
        } message: {
            Text(verbatim: QT("consent.withdrawMsg"))
        }
    }

    @ViewBuilder
    private func infoRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: OasesSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(OasesColor.primary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                Text(detail)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("常见问题") {
                faqRow(String(localized: "为什么回复有时候很慢？"), String(localized: "当使用 Ultra 或 Pro 模型时，推理时间较长属正常现象。可切换到 Fast 或 Lite 模型获得即时回复。"))
                faqRow(String(localized: "如何切换对话模式？"), String(localized: "点击左上角菜单，从侧边栏选择「文本」「音频」「图像」任一功能模块。"))
                faqRow(String(localized: "历史对话保存在哪里？"), String(localized: "对话记录保存在本机，可在侧栏「最近记录」查看。提交请求时，相关内容会发送给 Oases 网关或你选择的模型服务。Oases Chat 不提供 iCloud 同步或 App 内的 iCloud 备份。"))
                faqRow(String(localized: "图像生成需要多长时间？"), String(localized: "通常 10–30 秒，取决于所选模型。生成期间请勿离开页面。"))
            }
            Section("联系我们") {
                Link(destination: URL(string: "mailto:hi@oases.dev")!) {
                    HStack {
                        Image(systemName: "envelope")
                            .font(.system(size: 14))
                            .foregroundStyle(OasesColor.primary)
                            .frame(width: 22)
                        Text("发送邮件")
                            .font(.oasesBody())
                            .foregroundStyle(OasesColor.foreground)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                            .foregroundStyle(OasesColor.mutedForeground)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("帮助与反馈")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func faqRow(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q)
                .font(.custom(OasesTypography.serifBold, size: 15, relativeTo: .body))
                .foregroundStyle(OasesColor.foreground)
            Text(a)
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
        }
        .padding(.vertical, 4)
    }
}

struct LegalTextView: View {
    let title: String
    let content: String
    var body: some View {
        ScrollView {
            Text(content)
                .font(.oasesBody())
                .foregroundStyle(OasesColor.foreground)
                .padding(OasesSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ThemeManager.Mode helpers

extension ThemeManager.Mode {
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }
}
