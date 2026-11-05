import SwiftUI
import UniformTypeIdentifiers

/// Flow to add a new provider instance: pick type → credential → enter key/OAuth → done.
struct AddProviderView: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: ProviderType?
    @State private var selectedCredential: ProviderCredential?
    @State private var apiKeyInput = ""
    @State private var showApiKeyPlaintext = false
    @State private var labelInput = ""
    /// True once the user has manually edited the label. We use this to
    /// stop `defaultLabel(for:)` from clobbering a label the user just
    /// typed (often a Chinese / non-ASCII name) when they go back and
    /// re-tap the provider-type row. The Telegram report
    /// `T-provider-name-chinese-34602` originated from this footgun:
    /// users perceived the new-instance label as "ASCII only" because
    /// re-touching the provider type silently overwrote whatever they
    /// had typed.
    @State private var labelEdited = false
    /// True when the configure step was entered via a Voice Chat Provider
    /// template (credential picker was skipped). Back should then return
    /// straight to the type list, not to a credential step the user never saw.
    @State private var enteredViaVoiceTemplate = false
    @State private var customBaseURLInput = ""
    @State private var appendV1SuffixInput = true
    @State private var useResponsesAPI = false
    @State private var manualOAuthTokenInput = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingInstanceId = UUID().uuidString
    @State private var pendingOAuthDone = false
    @State private var oauthMaskedToken: String?
    // [T-kimi-oauth] Present the device-code login sheet (user code +
    // verification URL + polling) for Kimi's RFC 8628 flow.
    @State private var showKimiLogin = false
    @State private var oauthAuthTime: Date?
    @State private var showImportFile = false
    @State private var importMessage: String?
    @State private var showImportResult = false
    @State private var importSucceeded = false

    private enum Step: Int { case type = 0, credential = 1, configure = 2 }
    private var currentStep: Step {
        if selectedType == nil { return .type }
        if selectedCredential == nil { return .credential }
        return .configure
    }

    @ViewBuilder
    private var steppedContent: some View {
        Group {
            if selectedType == nil {
                typePickerSection
            } else if selectedCredential == nil {
                credentialPickerSection
            } else {
                configureSection
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .id(currentStep)
    }

    var body: some View {
        Group {
            if currentStep == .type {
                providerPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                List {
                    steppedContent
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: currentStep)
        .navigationTitle(currentStep == .type ? "" : navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectedType != nil {
                    Button("Back") { goBack() }
                } else {
                    Button("Cancel") { cleanupAndDismiss() }
                }
            }
        }
        .sheet(isPresented: $showKimiLogin) {
            // [T-kimi-oauth] RFC 8628 device-code login. On success, mark the
            // OAuth step done + surface the masked token, matching startOAuth().
            KimiDeviceLoginSheet(instanceId: pendingInstanceId) { success in
                if success {
                    oauthAuthTime = Date()
                    oauthMaskedToken = loadMaskedToken(type: .kimiCode)
                    pendingOAuthDone = true
                }
            }
        }
        .fileImporter(isPresented: $showImportFile, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert(String(localized: "Import"), isPresented: $showImportResult) {
            Button("OK") {
                if importSucceeded { dismiss() }
            }
        } message: {
            if let msg = importMessage { Text(msg) }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        importSucceeded = false
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                importMessage = String(localized: "Cannot access the selected file.")
                showImportResult = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let json = String(data: data, encoding: .utf8) else {
                importMessage = String(localized: "Failed to read file.")
                showImportResult = true
                return
            }
            if let label = store.importInstanceJSON(json) {
                importMessage = String(localized: "Imported provider \"\(label)\" successfully.")
                importSucceeded = true
            } else {
                importMessage = String(localized: "Invalid provider configuration file.")
            }
            showImportResult = true
        case .failure:
            break
        }
    }

    private var navigationTitle: String {
        if let type = selectedType, selectedCredential != nil {
            return String(localized: "Configure \(type.displayName)")
        } else if selectedType != nil {
            return String(localized: "Auth Method")
        }
        return String(localized: "Add Provider")
    }

    // MARK: - Step 1: Pick Provider Type (page)

    /// The first step as a page of its own: a short intro, then one row per service with its
    /// real logo, then voice services, then import.
    private var providerPickerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("添加供应商", comment: "Add provider page: title")
                        .font(.oasesTitle())
                        .foregroundStyle(OasesColor.foreground)
                    Text("用你自己的 API Key 或账号接入更多模型。同一家可以添加多个，比如工作和个人各一个。", comment: "Add provider page: intro under the title")
                        .font(.oasesCallout())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                pickerSection(title: String(localized: "对话模型", comment: "Add provider page: section of chat model providers")) {
                    ForEach(Array(visibleProviderTypes.enumerated()), id: \.element) { index, type in
                        pickerRow(
                            logo: ProviderBrand.logo(for: type),
                            title: providerPickerLabel(type),
                            subtitle: type.pickerSubtitle,
                            showsDivider: index < visibleProviderTypes.count - 1
                        ) {
                            selectedType = type
                            if !labelEdited { labelInput = defaultLabel(for: type) }
                        }
                    }
                }

                let templates = VoiceProviderTemplate.all
                pickerSection(title: String(localized: "语音识别与朗读", comment: "Add provider page: section of speech-to-text and text-to-speech providers")) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        pickerRow(
                            logo: ProviderBrand.logo(forVoiceTemplate: template.id),
                            title: template.name,
                            subtitle: template.capability,
                            showsDivider: index < templates.count - 1
                        ) {
                            applyVoiceTemplate(template)
                        }
                    }
                }

                pickerSection(title: String(localized: "其他", comment: "Add provider page: section with the import row")) {
                    pickerRow(
                        logo: ProviderBrand.Logo(asset: nil, symbol: "square.and.arrow.down", isTemplate: true),
                        title: String(localized: "从文件导入", comment: "Add provider page: import a provider exported from another device"),
                        subtitle: String(localized: "导入在另一台设备上导出的供应商配置。", comment: "Add provider page: what importing does"),
                        showsDivider: false
                    ) {
                        showImportFile = true
                    }
                }

                Text("兼容接口也能接第三方服务：选好对应的协议，再填写自定义的 API Base URL。", comment: "Add provider page: footnote about compatible endpoints")
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .scrollContentBackground(.hidden)
        .background(OasesColor.background.ignoresSafeArea())
    }

    private func pickerSection<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.oasesCaptionBold())
                .foregroundStyle(OasesColor.mutedForeground)
            VStack(spacing: 0) {
                rows()
            }
        }
    }

    private func pickerRow(logo: ProviderBrand.Logo, title: String, subtitle: String,
                           showsDivider: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ProviderLogoTile(logo: logo, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.oasesBodyBold())
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.6))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProviderRowButtonStyle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(OasesColor.border.opacity(0.6))
                    .frame(height: 0.5)
                    .padding(.leading, 54)
            }
        }
    }

    // MARK: - Step 1: Pick Provider Type

    private var visibleProviderTypes: [ProviderType] {
        ProviderType.allCases.filter {
            $0 != .openAIResponses && $0 != .antigravity
                && !$0.isUnsupported
        }
    }

    @ViewBuilder
    private var typePickerSection: some View {
        Section {
            ForEach(visibleProviderTypes, id: \.self) { type in
                Button {
                    selectedType = type
                    // Only seed the label when the user hasn't typed
                    // their own. Without this guard, switching back and
                    // forth between provider types silently overwrites
                    // a Chinese / custom label the user just entered.
                    if !labelEdited {
                        labelInput = defaultLabel(for: type)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ProviderLogoTile(logo: ProviderBrand.logo(for: type), size: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(providerPickerLabel(type))
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color(UIColor.label))
                            Text(type.pickerSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Choose Provider")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("You can add multiple instances of the same provider (e.g. work and personal accounts).")
                Text("The Compatible API options also work with third-party endpoints — set a custom API Base URL after choosing the matching protocol.")
            }
        }

        voiceProviderSection

        Section {
            Button {
                showImportFile = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.body)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Or Import Provider from File")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(UIColor.label))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("Import a provider configuration that was exported from another device.")
        }
    }

    /// Voice-specialised vendor templates. Tapping one preseeds the standard
    /// add-provider flow (underlying type + base URL) and jumps to the key step.
    @ViewBuilder
    private var voiceProviderSection: some View {
        let templates = VoiceProviderTemplate.all
        let notes = templates.compactMap { $0.note }
        Section {
            ForEach(templates) { template in
                Button {
                    applyVoiceTemplate(template)
                } label: {
                    HStack(spacing: 12) {
                        ProviderLogoTile(logo: ProviderBrand.logo(forVoiceTemplate: template.id), size: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color(UIColor.label))
                            Text(template.capability)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Voice Chat Providers")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech-to-text and text-to-speech vendors. The provider type and base URL are prefilled — just add your API key.")
                ForEach(notes, id: \.self) { note in
                    Text(note)
                }
            }
        }
    }

    /// Preseed the flow from a voice template: pick the underlying protocol,
    /// prefill the base URL / label, and advance straight to the configure step.
    private func applyVoiceTemplate(_ template: VoiceProviderTemplate) {
        selectedType = template.providerType
        customBaseURLInput = template.baseURL
        appendV1SuffixInput = template.appendV1
        if !labelEdited {
            labelInput = template.name
            labelEdited = true   // keep the vendor name from being overwritten by defaultLabel
        }
        selectedCredential = .apiKey
        enteredViaVoiceTemplate = true
    }

    // MARK: - Step 2: Pick Credential Type

    private var credentialPickerSection: some View {
        Group {
            Section {
                if let type = selectedType {
                    let creds = availableCredentials(for: type)
                    ForEach(creds, id: \.self) { cred in
                        Button {
                            selectedCredential = cred
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: cred == .apiKey ? "key" : "person.badge.shield.checkmark")
                                    .font(.body)
                                    .frame(width: 28)
                                    .foregroundStyle(Color(UIColor.label))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cred == .apiKey ? "API Key" : "OAuth")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color(UIColor.label))
                                    Text(credentialDescription(type: type, credential: cred))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }

            // "Responses API" is now integrated as API Format picker in Step 3
        }
    }

    // MARK: - Step 3: Configure

    private var configureSection: some View {
        Group {
            Section("Label") {
                TextField("Provider label", text: $labelInput)
                    // [T-provider-label-keyboard] A positive non-credential
                    // marker. `.none` compiles to nil - the same as declaring
                    // nothing - so AutoFill could still take this field as the
                    // "username" of the API key / bearer token field below and
                    // hang its password bar here. The credential fields'
                    // `.oneTimeCode` is the load-bearing half.
                    .textContentType(.nickname)
                    .onChange(of: labelInput) {
                        // Mark the field as user-edited so subsequent
                        // provider-type taps no longer clobber it.
                        labelEdited = true
                    }
            }

            if let destinationNotice = providerDataDestinationNotice {
                Section("Data destination") {
                    Label {
                        Text(destinationNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if selectedCredential == .apiKey {
                apiKeySection
            } else {
                oauthSection
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// The provider and endpoint shown here are the destination for content
    /// submitted through this provider. This is intentionally repeated in the
    /// configure step so a custom endpoint is visible before the credential is
    /// saved; the app-wide AI data notice handles consent separately.
    private var providerDataDestinationNotice: String? {
        guard let selectedType else { return nil }

        let name = selectedType.displayName
        let configuredURL = customBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination: String
        if !configuredURL.isEmpty {
            destination = configuredURL
        } else {
            switch selectedType {
            case .anthropic:
                destination = "https://api.anthropic.com"
            case .openAI, .openAIResponses:
                destination = "https://api.openai.com"
            case .gemini:
                destination = "https://generativelanguage.googleapis.com/v1beta"
            case .openRouter:
                destination = "https://openrouter.ai/api/v1"
            case .xAI:
                destination = "https://api.x.ai/v1"
            case .kimiCode:
                destination = "https://api.kimi.com/coding"
            case .antigravity:
                return String(localized: "Requests using \(name) may send your messages, conversation context, and any files or images you submit to the Antigravity sign-in service. That service may collect or otherwise process the data under its own privacy policy.")
            case .unsupported:
                return String(localized: "Requests using \(name) may send your messages, conversation context, and any files or images you submit to the provider service configured for this instance. That service may collect or otherwise process the data under its own privacy policy.")
            }
        }

        return String(localized: "Requests using \(name) may send your messages, conversation context, and any files or images you submit to \(destination). That service may collect or otherwise process the data under its own privacy policy.", comment: "Second %@ is an endpoint URL")
    }

    private var apiKeySection: some View {
        Group {
            Section {
                    HStack {
                        if showApiKeyPlaintext {
                            TextField(keyPlaceholder, text: $apiKeyInput)
                                .font(.system(.body, design: .monospaced))
                                // [T-provider-label-keyboard] Same AutoFill
                                // opt-out as the SecureField below: this is the
                                // same field, revealed.
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(keyPlaceholder, text: $apiKeyInput)
                                // [T-provider-label-keyboard] An undeclared
                                // SecureField carries password semantics: iOS
                                // treats the form as a login, offers to save
                                // the key as an account password and pairs it
                                // with the Label field as the username.
                                // `.oneTimeCode` marks a credential that is not
                                // a saveable account password.
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            showApiKeyPlaintext.toggle()
                        } label: {
                            Image(systemName: showApiKeyPlaintext ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Your key is stored securely in the iOS Keychain and is used to authenticate requests to the destination shown above. If iCloud Keychain is on, it syncs to your other Apple devices.")
                }

            if selectedType != .antigravity {
                customBaseURLSection
            }

            // API Format picker for OpenAI provider (hidden for voice-only templates)
            if !enteredViaVoiceTemplate, selectedType == .openAI || selectedType == .openAIResponses {
                Section {
                    Picker("API Format", selection: $useResponsesAPI) {
                        Text("Chat Completions").tag(false)
                        Text("Responses API").tag(true)
                    }
                } footer: {
                    Text(useResponsesAPI
                        ? "Uses /v1/responses endpoint format. Required for some Responses-API-only services."
                        : "Standard /v1/chat/completions format. Works with most compatible services.")
                }
            }

            Section {
                Button {
                    saveApiKeyInstance()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Add Provider")
                                .font(.body.weight(.semibold))
                        }
                        Spacer()
                    }
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    @ViewBuilder
    private var oauthSection: some View {
        Section {
            if pendingOAuthDone {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Authenticated")
                        .font(.body.weight(.medium))
                }

                if let masked = oauthMaskedToken {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(masked)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if let authTime = oauthAuthTime {
                    HStack {
                        Text("Authorized")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(authTime, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(authTime, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    // Kimi uses a device-code sheet (RFC 8628); every other
                    // provider drives its redirect/PKCE flow inline via startOAuth.
                    if selectedType == .kimiCode {
                        showKimiLogin = true
                    } else {
                        Task { await startOAuth() }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(oauthSignInLabel)
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                }
                .disabled(!oauthSignInAvailable)
                if !oauthSignInAvailable {
                    Text("Sign-in isn't available for this provider in this build. Use an API key or configure a bearer token manually below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("OAuth")
        }

        // Manual OAuth entry — available for all providers (supports proxy services, Coding Plan tokens, etc.)
        if selectedType != .antigravity && !pendingOAuthDone {
            Section {
                TextField(defaultBaseURL, text: $customBaseURLInput)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("Bearer Token", text: $manualOAuthTokenInput)
                    .font(.system(.body, design: .monospaced))
                    // [T-provider-label-keyboard] Same AutoFill opt-out as the
                    // API Key field.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    saveManualOAuthInstance()
                } label: {
                    HStack {
                        Spacer()
                        Text("Add Provider")
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                }
                .disabled(manualOAuthTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Or Configure Manually")
            } footer: {
                Text("For third-party Coding Plans (e.g. MiniMax, Kimi) or compatible proxy endpoints, enter the API base URL and bearer token manually.")
            }
        }

        if pendingOAuthDone {
            Section {
                Button {
                    saveOAuthInstance()
                } label: {
                    HStack {
                        Spacer()
                        Text("Save Provider")
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Custom Base URL Section

    private var customBaseURLSection: some View {
        Section {
            TextField(defaultBaseURL, text: $customBaseURLInput)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            if !enteredViaVoiceTemplate, selectedType != .gemini {
                Toggle("Auto Append \"/v1\"", isOn: $appendV1SuffixInput)
            }
        } header: {
            Text("Custom API Base (Optional)")
        } footer: {
            if enteredViaVoiceTemplate {
                Text("The voice service endpoint URL.")
            } else if selectedType == .gemini {
                Text("Leave empty to use the default Google endpoint. Enter the full base URL including version path.")
            } else {
                Text(appendV1SuffixInput
                     ? "Leave empty to use the default endpoint. \"/v1\" is appended automatically — enter the base host only."
                     : "The URL is used verbatim. Include the full path up to (but not including) the endpoint.")
            }
        }
    }

    private var defaultBaseURL: String {
        switch selectedType {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAIResponses: return "https://api.openai.com"
        case .xAI: return "https://api.x.ai/v1"
        case .kimiCode: return "https://api.kimi.com/coding"
        default: return "https://api.example.com"
        }
    }

    // MARK: - Actions

    private func saveApiKeyInstance() {
        guard let type = selectedType else { return }
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = labelInput.trimmingCharacters(in: .whitespaces)
        let trimmedBase = customBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        if let baseError = URLBuilding.baseURLValidationError(trimmedBase) {
            errorMessage = baseError
            return
        }

        // Map OpenAI + Responses API format to .openAIResponses provider type
        let effectiveType: ProviderType = (type == .openAI && useResponsesAPI) ? .openAIResponses : type

        isSaving = true
        let base = trimmedBase.isEmpty ? nil : trimmedBase
        let instance = ProviderInstance(
            label: trimmedLabel.isEmpty ? defaultLabel(for: effectiveType) : trimmedLabel,
            providerType: effectiveType,
            credentialType: .apiKey,
            customBaseURL: base,
            appendV1Suffix: appendV1SuffixInput
        )
        ProviderKeychainHelper.saveAPIKey(trimmedKey, instanceId: instance.id)
        store.addInstance(instance)
        isSaving = false
        dismiss()
    }

    private func saveOAuthInstance() {
        guard let type = selectedType else { return }
        let trimmedLabel = labelInput.trimmingCharacters(in: .whitespaces)

        let instance = ProviderInstance(
            id: pendingInstanceId,
            label: trimmedLabel.isEmpty ? defaultLabel(for: type) : trimmedLabel,
            providerType: type,
            credentialType: .oauth
        )
        store.addInstance(instance)
        dismiss()
    }

    private func saveManualOAuthInstance() {
        guard let type = selectedType else { return }
        let trimmedToken = manualOAuthTokenInput.components(separatedBy: .whitespacesAndNewlines).joined()
        let trimmedLabel = labelInput.trimmingCharacters(in: .whitespaces)
        let trimmedBase = customBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }
        if let baseError = URLBuilding.baseURLValidationError(trimmedBase) {
            errorMessage = baseError
            return
        }

        let instance = ProviderInstance(
            id: pendingInstanceId,
            label: trimmedLabel.isEmpty ? defaultLabel(for: type) : trimmedLabel,
            providerType: type,
            credentialType: .oauth,
            customBaseURL: trimmedBase.isEmpty ? nil : trimmedBase,
            appendV1Suffix: appendV1SuffixInput
        )
        ProviderKeychainHelper.saveOAuthString(trimmedToken, instanceId: instance.id, account: "manual-oauth-token")
        store.addInstance(instance)
        dismiss()
    }

    @MainActor
    private func startOAuth() async {
        guard let type = selectedType else { return }
        errorMessage = nil
        do {
            switch type {
            case .anthropic: try await ClaudeOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .gemini: try await GeminiOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .openAI: try await CodexOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .antigravity: try await AntigravityOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .openRouter: try await OpenRouterOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .openAIResponses: break // API key only, no OAuth
            case .xAI: try await XAIOAuthManager.shared.login(instanceId: pendingInstanceId)
            case .kimiCode: break // device-code flow runs in KimiDeviceLoginSheet, not here
            case .unsupported: break // free / unsupported — no OAuth
            }
            oauthAuthTime = Date()
            oauthMaskedToken = loadMaskedToken(type: type)
            pendingOAuthDone = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the access token from Keychain and masks the middle third.
    private func loadMaskedToken(type: ProviderType) -> String? {
        let token: String?
        switch type {
        case .anthropic:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: ClaudeTokenStorage.self)?.accessToken
        case .gemini:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: GeminiTokenStorage.self)?.accessToken
        case .openAI:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: CodexTokenStorage.self)?.accessToken
        case .antigravity:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: AntigravityTokenStorage.self)?.accessToken
        case .openRouter:
            // OpenRouter OAuth produces a permanent API key, not an OAuth token
            token = ProviderKeychainHelper.loadAPIKey(instanceId: pendingInstanceId)
        case .openAIResponses:
            token = nil // API key only, no OAuth
        case .xAI:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: XAITokenStorage.self)?.accessToken
        case .kimiCode:
            token = ProviderKeychainHelper.loadOAuthToken(instanceId: pendingInstanceId, as: KimiTokenStorage.self)?.accessToken
        case .unsupported:
            token = nil // free / unsupported — no token
        }
        guard let t = token, !t.isEmpty else { return nil }
        return ClaudeOAuthManager.maskToken(t)
    }

    private func goBack() {
        // Voice-template entry skipped the credential step, so Back returns
        // all the way to the type list (and clears the prefilled fields) rather
        // than dropping the user onto a credential picker they never saw.
        if enteredViaVoiceTemplate {
            enteredViaVoiceTemplate = false
            selectedType = nil
            selectedCredential = nil
            apiKeyInput = ""
            customBaseURLInput = ""
            appendV1SuffixInput = true
            labelInput = ""
            labelEdited = false
            errorMessage = nil
            return
        }
        if selectedCredential != nil {
            // If we started OAuth but haven't saved, clean up the pending token
            if selectedCredential == .oauth && pendingOAuthDone {
                ProviderKeychainHelper.deleteOAuthToken(instanceId: pendingInstanceId)
                ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "oauth-email")
                ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "oauth-gcp-project")
                ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "manual-oauth-token")
                // OpenRouter OAuth stores a permanent API key, not an OAuth token
                if selectedType == .openRouter {
                    ProviderKeychainHelper.deleteAPIKey(instanceId: pendingInstanceId)
                }
                pendingOAuthDone = false
                oauthMaskedToken = nil
                oauthAuthTime = nil
                pendingInstanceId = UUID().uuidString
            }
            selectedCredential = nil
            useResponsesAPI = false
            apiKeyInput = ""
            customBaseURLInput = ""
            manualOAuthTokenInput = ""
            errorMessage = nil
        } else {
            selectedType = nil
            selectedCredential = nil
        }
    }

    private func cleanupAndDismiss() {
        // If we started OAuth but never saved, clean up
        if pendingOAuthDone {
            ProviderKeychainHelper.deleteOAuthToken(instanceId: pendingInstanceId)
            ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "oauth-email")
            ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "oauth-gcp-project")
            if selectedType == .openRouter {
                ProviderKeychainHelper.deleteAPIKey(instanceId: pendingInstanceId)
            }
            ProviderKeychainHelper.deleteOAuthString(instanceId: pendingInstanceId, account: "manual-oauth-token")
        }
        dismiss()
    }

    // MARK: - Helpers

    /// [T-oauth-placeholder-secret] Google flows ship without a client secret,
    /// so their token exchange can never succeed in this build.
    private var oauthSignInAvailable: Bool {
        switch selectedType {
        case .gemini: return GeminiOAuthManager.shared.isSignInAvailable
        case .antigravity: return AntigravityOAuthManager.shared.isSignInAvailable
        default: return true
        }
    }

    private var oauthSignInLabel: String {
        guard let type = selectedType else { return String(localized: "Sign In") }
        switch type {
        case .anthropic: return String(localized: "Sign in with Claude")
        case .gemini: return String(localized: "Sign in with Google")
        case .openAI: return SettingsCopy.t("使用 AI 供应商账号登录", "Sign in with AI provider account")
        case .antigravity: return String(localized: "Sign in with Google")
        case .openRouter: return String(localized: "Sign in with OpenRouter")
        case .openAIResponses: return String(localized: "Sign In") // Not reachable — API key only
        case .xAI: return String(localized: "Sign in with xAI")
        case .kimiCode: return String(localized: "Sign in with Kimi Code")
        case .unsupported: return String(localized: "Sign In")
        }
    }

    private var keyPlaceholder: String {
        guard let type = selectedType else { return String(localized: "API Key") }
        switch type {
        case .anthropic: return "sk-ant-..."
        case .gemini: return String(localized: "Gemini API Key...", comment: "API key field placeholder")
        case .openAI: return "sk-..."
        case .antigravity: return String(localized: "API Key...", comment: "API key field placeholder")
        case .openRouter: return "sk-or-..."
        case .openAIResponses: return "sk-..."
        case .xAI: return "xai-..."
        case .kimiCode: return "" // OAuth only
        case .unsupported: return ""
        }
    }

    private func providerPickerLabel(_ type: ProviderType) -> String {
        switch type {
        case .anthropic: return String(localized: "Anthropic / Compatible API")
        case .openAI:    return SettingsCopy.t("AI 供应商 / 兼容接口", "AI provider / Compatible API")
        case .gemini:    return type.displayName
        case .antigravity: return type.displayName
        case .openRouter: return "OpenRouter"
        case .openAIResponses: return "Responses API"
        case .xAI: return "xAI (Grok)"
        case .kimiCode: return "Kimi Code"
        case .unsupported: return String(localized: "Unsupported")
        }
    }

    private func defaultLabel(for type: ProviderType) -> String {
        let existingCount = store.instances.filter { $0.providerType == type }.count
        if existingCount == 0 {
            return type.displayName
        }
        return "\(type.displayName) \(existingCount + 1)"
    }

    private func availableCredentials(for type: ProviderType) -> [ProviderCredential] {
        switch type {
        case .antigravity:
            return [.oauth]
        case .openAIResponses, .gemini:
            return [.apiKey]
        default:
            return [.apiKey, .oauth]
        }
    }

    private func credentialDescription(type: ProviderType, credential: ProviderCredential) -> String {
        switch (type, credential) {
        case (.openAI, .apiKey):
            return String(localized: "Supports the official API and compatible third-party services like OpenRouter, MiniMax, etc.")
        case (.openAIResponses, .apiKey):
            return String(localized: "Use an API key for a Responses API endpoint")
        case (_, .apiKey):
            return String(localized: "Use an API key from your \(type.displayName) account")
        case (.anthropic, .oauth):
            return String(localized: "Sign in with your Claude account")
        case (.gemini, .oauth):
            return String(localized: "Sign in with Google for Cloud Code Assist")
        case (.openAI, .oauth):
            return SettingsCopy.t("使用 AI 供应商账号登录", "Sign in with your AI provider account")
        case (.antigravity, .oauth):
            return String(localized: "Sign in with Google for Antigravity Cloud Code")
        case (.openRouter, .oauth):
            return String(localized: "Sign in with your OpenRouter account")
        case (.openAIResponses, .oauth):
            return "" // Not reachable — API key only
        case (.xAI, .oauth):
            return String(localized: "Sign in with your SuperGrok / X Premium+ subscription. xAI may restrict API access on some plans — if you hit HTTP 403, switch to an API key.")
        case (.kimiCode, .oauth):
            return String(localized: "Sign in with your Kimi Code / Coding Plan subscription.")
        case (.kimiCode, .apiKey):
            return String(localized: "Use a Kimi Coding API key.")
        case (.unsupported, _):
            return String(localized: "This provider isn't supported in this app version.")
        }
    }

    @ViewBuilder
    private func providerIcon(_ type: ProviderType) -> some View {
        switch type {
        case .anthropic:
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
        case .gemini:
            Image(systemName: "diamond")
                .foregroundStyle(.blue)
        case .openAI:
            Image(systemName: "circle.hexagongrid")
                .foregroundStyle(.green)
        case .antigravity:
            Image(systemName: "ant")
                .foregroundStyle(.orange)
        case .openRouter:
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.cyan)
        case .openAIResponses:
            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                .foregroundStyle(.mint)
        case .xAI:
            Image(systemName: "x.circle")
                .foregroundStyle(.gray)
        case .kimiCode:
            Image(systemName: "moon.stars")
                .foregroundStyle(.indigo)
        case .unsupported:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.gray)
        }
    }

    private func providerColor(_ type: ProviderType) -> Color {
        switch type {
        case .anthropic: return .purple
        case .gemini: return .blue
        case .openAI: return .green
        case .antigravity: return .orange
        case .openRouter: return .cyan
        case .openAIResponses: return .mint
        case .xAI: return .gray
        case .kimiCode: return .indigo
        case .unsupported: return .gray
        }
    }
}

/// Background highlight on press for the provider rows (rows highlight, they don't scale).
private struct ProviderRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OasesColor.foreground.opacity(configuration.isPressed ? 0.05 : 0))
                    .padding(.horizontal, -8)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
