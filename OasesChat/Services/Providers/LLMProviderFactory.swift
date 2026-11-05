import Foundation

/// Shared factory for creating LLMProvider instances from a ModelEntry.
/// Stage 2: OpenAI (+ Responses / OpenRouter-compat via OpenAIProvider) + Anthropic.
/// Gemini / Antigravity / xAI OAuth / Kimi device-flow land in Stage 3.
@MainActor
enum LLMProviderFactory {

    enum FactoryError: Error, LocalizedError {
        case noInstance
        case noCredentials
        case voiceOnlyProvider
        case vendorNotPorted(ProviderType)

        var errorDescription: String? {
            switch self {
            case .noInstance: return String(localized: "未找到供应商实例", comment: "Error: the model's provider instance no longer exists")
            case .noCredentials: return String(localized: "未配置 API 凭证", comment: "Error: the provider has no API key / credentials configured")
            case .voiceOnlyProvider: return String(localized: "该供应商仅支持语音", comment: "Error: this provider only supports voice, not chat")
            case .vendorNotPorted(let t): return String(localized: "Provider \(t.displayName) is not supported yet", comment: "Error: this provider type is not available in the app yet; argument is the provider name")
            }
        }
    }

    // MARK: - AI data-sharing consent

    /// Every provider built here sends user content to its endpoint, so this
    /// is the choke point for the consent boundary: voice correction, the
    /// guest's `minis-model-use` (`ModelUseOffloadBridge`), the model quick
    /// test and the chat bridge all come through `makeProvider` /
    /// `makeAgentProvider`. Throws `APIError.dataSharingConsentRequired`
    /// unless the user agreed or the instance talks to a model on this
    /// device. A missing instance is refused too, so a stale entry can't
    /// slip past as "not found" later.
    nonisolated static func requireDataSharingConsent(for instance: ProviderInstance?) throws {
        if AIDataSharingConsent.isAccepted { return }
        if let instance, requestsStayOnDevice(instance) { return }
        throw APIError.dataSharingConsentRequired
    }

    /// Whether every request built for `instance` goes to a loopback server.
    /// Only API-key instances with a loopback custom base URL qualify: OAuth
    /// sign-ins and Antigravity always talk to the vendor's cloud, and an
    /// instance without a custom base URL uses the vendor's default host.
    nonisolated static func requestsStayOnDevice(_ instance: ProviderInstance) -> Bool {
        guard instance.credentialType == .apiKey else { return false }
        switch instance.providerType {
        case .antigravity, .unsupported:
            return false
        case .openAI, .anthropic, .gemini, .openRouter, .openAIResponses, .xAI, .kimiCode:
            guard let base = instance.effectiveCustomBaseURL else { return false }
            return AIDataSharingConsent.isOnDevice(URL(string: base))
        }
    }

    /// Create an LLMProvider for the given entry, looking up its ProviderInstance and credentials.
    static func makeProvider(for entry: ModelEntry) async throws -> any LLMProvider {
        let store = ProviderConfigStore.shared
        let instance = store.instance(for: entry.providerInstanceId)
        try requireDataSharingConsent(for: instance)
        guard let instance else {
            throw FactoryError.noInstance
        }
        switch instance.providerType {
        case .anthropic:
            return makeAnthropicProvider(instance: instance, model: entry.model)
        case .openAI:
            return try makeOpenAIProvider(instance: instance, model: entry.model)
        case .openAIResponses:
            return makeOpenAIResponsesProvider(instance: instance, model: entry.model)
        case .openRouter:
            return makeOpenRouterProvider(instance: instance, model: entry.model)
        case .xAI:
            // API-key path reuses OpenAIProvider; OAuth manager is Stage 3.
            return try makeXAIProvider(instance: instance, model: entry.model)
        case .kimiCode:
            return try makeKimiProvider(instance: instance, model: entry.model)
        case .gemini:
            return await makeGeminiProvider(instance: instance, model: entry.model)
        case .antigravity:
            return await makeAntigravityProvider(instance: instance, model: entry.model)
        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }
    }

    @discardableResult
    static func applyAzure(_ provider: OpenAIProvider, instance: ProviderInstance) -> OpenAIProvider {
        if instance.azureMode { provider.isAzure = true }
        return provider
    }

    @discardableResult
    static func applyCustomUserAgent(_ provider: OpenAIProvider, instance: ProviderInstance) -> OpenAIProvider {
        guard !provider.isOAuth else { return provider }
        if instance.supportsCustomUserAgent, let ua = instance.effectiveCustomUserAgent {
            provider.extraHeaders["User-Agent"] = ua
            return provider
        }
        if provider.extraHeaders["User-Agent"] == nil {
            provider.extraHeaders["User-Agent"] = AppUserAgent.default
        }
        return provider
    }

    // MARK: - Per-Provider Builders

    /// [T-provider-base-url-validation] SwiftAnthropic force-unwraps
    /// `URLComponents(string: base)!`, so a malformed base saved before save-time
    /// validation existed would crash. Swap it for a reserved `.invalid` host
    /// (RFC 6761 — never resolves): the request fails with a visible network
    /// error and the key is never sent anywhere.
    nonisolated static func sdkSafeBaseURL(_ base: String?) -> String? {
        guard let base, URLBuilding.baseURLValidationError(base) != nil else { return base }
        AppLogger(category: "LLMProviderFactory").warning("Anthropic base URL is invalid — requests will fail until it is corrected")
        return "https://invalid-base-url.invalid"
    }

    static func makeAnthropicProvider(instance: ProviderInstance, model: LLMModel) -> AnthropicProvider {
        let customBase = sdkSafeBaseURL(instance.effectiveCustomBaseURL)
        let appendV1 = instance.appendV1Suffix
        let ua = instance.supportsCustomUserAgent ? instance.effectiveCustomUserAgent : nil
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return AnthropicProvider(
                apiKey: key,
                model: model,
                basePath: customBase,
                appendV1Suffix: appendV1,
                customUserAgent: ua ?? AppUserAgent.default
            )
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return AnthropicProvider(
                    manualToken: manualToken,
                    model: model,
                    basePath: customBase,
                    appendV1Suffix: appendV1,
                    customUserAgent: ua
                )
            }
            let iid = instance.id
            return AnthropicProvider(
                oauthTokenProvider: { try await ClaudeOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model,
                basePath: customBase,
                appendV1Suffix: appendV1
            )
        }
    }

    static func makeOpenAIProvider(instance: ProviderInstance, model: LLMModel) throws -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        let isMistral = (customBase ?? "").lowercased().contains("mistral.ai")
        func configure(_ p: OpenAIProvider) -> OpenAIProvider {
            if isMistral {
                p.useOpenRouterCompat = true
                p.isMistral = true
            }
            return p
        }
        switch instance.credentialType {
        case .apiKey:
            guard let key = OasesBuiltinProvider.resolvedAPIKey(for: instance.id), !key.isEmpty else {
                throw FactoryError.noCredentials
            }
            return applyAzure(
                applyCustomUserAgent(
                    configure(OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)),
                    instance: instance
                ),
                instance: instance
            )
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyCustomUserAgent(
                    configure(OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)),
                    instance: instance
                )
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            return provider
        }
    }

    static func makeOpenRouterProvider(instance: ProviderInstance, model: LLMModel) -> OpenAIProvider {
        let key: String
        if instance.credentialType == .oauth,
           let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
            key = manualToken
        } else {
            key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
        }
        let customBase = instance.effectiveCustomBaseURL
        let provider = OpenAIProvider(
            apiKey: key,
            model: model,
            customBaseURL: customBase ?? "https://openrouter.ai/api",
            appendV1Suffix: customBase == nil
        )
        provider.extraHeaders = [
            "HTTP-Referer": "https://github.com/oases-chat/oaseschat",
            "X-Title": "Oases Chat",
        ]
        provider.useOpenRouterCompat = true
        return applyCustomUserAgent(provider, instance: instance)
    }

    static func makeOpenAIResponsesProvider(instance: ProviderInstance, model: LLMModel) -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
            provider.forceResponsesAPI = true
            return applyAzure(applyCustomUserAgent(provider, instance: instance), instance: instance)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
                provider.forceResponsesAPI = true
                return applyCustomUserAgent(provider, instance: instance)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.forceResponsesAPI = true
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            return provider
        }
    }

    /// Gemini — ported verbatim from OpenMinis `LLMProviderFactory`.
    /// The OAuth path needs the GCP project id resolved before the first
    /// request, hence the `async` discovery hop.
    static func makeGeminiProvider(instance: ProviderInstance, model: LLMModel) async -> GeminiProvider {
        let customBase = instance.effectiveCustomBaseURL
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return GeminiProvider(apiKey: key, model: model, customBasePath: customBase)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return GeminiProvider(apiKey: manualToken, model: model, customBasePath: customBase)
            }
            let iid = instance.id
            if GeminiOAuthManager.shared.gcpProjectID(instanceId: iid) == nil {
                await GeminiOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
            }
            let provider = GeminiProvider(
                oauthTokenProvider: { try await GeminiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model,
                customBasePath: customBase
            )
            provider.gcpProjectID = GeminiOAuthManager.shared.gcpProjectID(instanceId: iid)
            return provider
        }
    }

    /// Antigravity — OAuth only; the project id and regional base URL must be
    /// resolved before the first request, hence the `async` discovery hop.
    static func makeAntigravityProvider(instance: ProviderInstance, model: LLMModel) async -> AntigravityProvider {
        let iid = instance.id
        if AntigravityOAuthManager.shared.projectID(instanceId: iid) == nil {
            await AntigravityOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
        }
        let provider = AntigravityProvider(
            oauthTokenProvider: { try await AntigravityOAuthManager.shared.validAccessToken(instanceId: iid) },
            model: model
        )
        provider.projectID = AntigravityOAuthManager.shared.projectID(instanceId: iid)
        if let baseURL = AntigravityOAuthManager.shared.resolvedBaseURL(instanceId: iid) {
            provider.activeBaseURL = baseURL
        }
        return provider
    }

    /// Kimi Code — API key, manual token, or device-flow OAuth via `KimiOAuthManager`.
    static func makeKimiProvider(instance: ProviderInstance, model: LLMModel) throws -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.kimi.com/coding"
        let appendV1 = instance.effectiveCustomBaseURL == nil ? true : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyCustomUserAgent(
                OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1),
                instance: instance
            )
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyCustomUserAgent(
                    OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1),
                    instance: instance
                )
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await KimiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            return provider
        }
    }

    /// xAI — API key, manual token, or SuperGrok OAuth via `XAIOAuthManager`.
    static func makeXAIProvider(instance: ProviderInstance, model: LLMModel) throws -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.x.ai/v1"
        let appendV1 = instance.effectiveCustomBaseURL == nil ? false : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyCustomUserAgent(
                OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1),
                instance: instance
            )
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyCustomUserAgent(
                    OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1),
                    instance: instance
                )
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await XAIOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            return provider
        }
    }
}


// MARK: - AgentProvider construction (P1)

extension LLMProviderFactory {
    /// Wrap a vendor provider in its `AgentProvider` adapter.
    ///
    /// Mirrors OpenMinis `AIChatViewModel.makeAgentProvider(for:)`. Note this
    /// covers ALL eight vendors, not just the three that need
    /// `AgentProviderChatBridge` — the OpenAI family reaches *chat* through
    /// `ProviderChatRouting`'s base-URL swap, but callers that want the agent
    /// protocol directly (voice correction, title generation) need an adapter
    /// for every vendor.
    static func makeAgentProvider(for entry: ModelEntry) async throws -> any AgentProvider {
        let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)
        try requireDataSharingConsent(for: instance)
        guard let instance else {
            throw FactoryError.noInstance
        }
        switch instance.providerType {
        case .anthropic:
            return AnthropicAgentProvider(
                provider: makeAnthropicProvider(instance: instance, model: entry.model)
            )
        case .gemini:
            return GeminiAgentProvider(
                provider: await makeGeminiProvider(instance: instance, model: entry.model)
            )
        case .antigravity:
            return AntigravityAgentProvider(
                provider: await makeAntigravityProvider(instance: instance, model: entry.model)
            )
        case .openAI:
            return OpenAIAgentProvider(
                provider: try makeOpenAIProvider(instance: instance, model: entry.model)
            )
        case .openAIResponses:
            return OpenAIAgentProvider(
                provider: makeOpenAIResponsesProvider(instance: instance, model: entry.model)
            )
        case .openRouter:
            return OpenAIAgentProvider(
                provider: makeOpenRouterProvider(instance: instance, model: entry.model)
            )
        case .xAI:
            return OpenAIAgentProvider(
                provider: try makeXAIProvider(instance: instance, model: entry.model)
            )
        case .kimiCode:
            return OpenAIAgentProvider(
                provider: try makeKimiProvider(instance: instance, model: entry.model)
            )
        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }
    }
}
