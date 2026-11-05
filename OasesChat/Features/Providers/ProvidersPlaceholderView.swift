import SwiftUI

/// Stage 2 Providers landing pad.
/// Lists configured instances from `ProviderConfigStore` and offers a minimal
/// API-key add form for OpenAI / Anthropic. Full OpenMinis
/// `AddProviderView` / `ProviderInstanceDetailView` / OAuth login sheets land
/// as follow-ups within Stage 2/3.
struct ProvidersPlaceholderView: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var showAdd = false

    var body: some View {
        List {
            Section("已配置") {
                if store.config.instances.isEmpty {
                    Text("还没有 Provider 实例。添加 AI 供应商或 Anthropic 的 API Key，或等待 Secrets 默认 Oases 端点自动种子。")
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                } else {
                    ForEach(store.config.instances) { instance in
                        NavigationLink {
                            ProviderInstanceDetailSkeleton(instanceId: instance.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(instance.label)
                                        .font(.oasesBody())
                                    Spacer()
                                    if !instance.isEnabled {
                                        Text("已禁用")
                                            .font(.oasesCaption())
                                            .foregroundStyle(OasesColor.mutedForeground)
                                    }
                                }
                                Text("\(instance.providerType.displayName) · \(instance.credentialType.rawValue) · \(store.visibleEntries(for: instance.id).count) 模型")
                                    .font(.oasesCaption())
                                    .foregroundStyle(OasesColor.mutedForeground)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            let id = store.config.instances[idx].id
                            store.removeInstance(id)
                        }
                    }
                }
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加 Provider（API Key）", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Stage 2：AI 供应商 / Anthropic API Key 可用。Claude Code / AI 供应商账号 OAuth 管理器已移植，登录 UI 与其余厂商（Gemini / xAI / Kimi / …）在 Stage 3 补齐。聊天主路径仍兼容 Secrets 默认 Oases 端点。")
                    .font(.oasesCaption())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddProviderAPIKeySheet()
        }
    }
}

// MARK: - Minimal add sheet

private struct AddProviderAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProviderConfigStore.shared

    @State private var label = ""
    @State private var providerType: ProviderType = .openAI
    @State private var apiKey = ""
    @State private var customBaseURL = ""
    @State private var errorMessage: String?

    private let supported: [ProviderType] = [.openAI, .anthropic, .openRouter, .openAIResponses]

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("Provider", selection: $providerType) {
                        ForEach(supported, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("显示名称", text: $label)
                        .textInputAutocapitalization(.words)
                }
                Section("凭证") {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("自定义 Base URL（可选）", text: $customBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(OasesColor.destructive)
                            .font(.oasesCaption())
                    }
                }
            }
            .navigationTitle("添加 Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = String(localized: "API Key 不能为空")
            return
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? providerType.displayName
            : label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // The full ProviderConfigStore takes a built ProviderInstance and reads
        // the credential from the Keychain (the simple store used to accept the
        // key inline). Save first: addInstance inspects the stored credential to
        // decide whether to seed built-in models.
        let instance = ProviderInstance(
            label: name,
            providerType: providerType,
            credentialType: .apiKey,
            customBaseURL: base.isEmpty ? nil : base,
            appendV1Suffix: true
        )
        ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)
        store.addInstance(instance)
        dismiss()
    }
}

// MARK: - Instance detail skeleton

private struct ProviderInstanceDetailSkeleton: View {
    let instanceId: String
    @ObservedObject private var store = ProviderConfigStore.shared

    private var instance: ProviderInstance? {
        store.instance(for: instanceId)
    }

    var body: some View {
        List {
            if let instance {
                Section("实例") {
                    LabeledContent("名称", value: instance.label)
                    LabeledContent("类型", value: instance.providerType.displayName)
                    LabeledContent("凭证", value: instance.credentialType.rawValue)
                    LabeledContent("已启用", value: instance.isEnabled ? "是" : "否")
                    if let base = instance.customBaseURL, !base.isEmpty {
                        LabeledContent("Base URL", value: base)
                    }
                    LabeledContent("凭证状态", value: instance.hasAnyCredential ? "已配置" : "缺失")
                }
                Section("模型 (\(store.visibleEntries(for: instanceId).count))") {
                    ForEach(store.visibleEntries(for: instanceId)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.model.displayName)
                                .font(.oasesBody())
                            Text(entry.model.id)
                                .font(.oasesCaption())
                                .foregroundStyle(OasesColor.mutedForeground)
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        store.removeInstance(instanceId)
                    } label: {
                        Label("删除实例", systemImage: "trash")
                    }
                } footer: {
                    Text("完整编辑、OAuth 登录、模型刷新与 ModelGroup 路由 UI 在 Stage 2 后续 / Stage 3 补齐。当前可经 LLMProviderFactory 用此实例发请求。")
                        .font(.oasesCaption())
                }
            } else {
                Text("实例已删除")
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(instance?.label ?? String(localized: "Provider"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
