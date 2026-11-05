import Foundation

/// Stage 2.3 bridge between the ported Providers stack and the existing
/// `ChatService` / `APIClient` streaming path.
///
/// The full OpenMinis agent loop consumes `AgentProvider` / `AgentStreamEvent`;
/// OasesChat's loop still speaks OpenAI-compatible `chat/completions` through
/// `APIClient`. Rather than rewrite the loop now (Stage 3), user-configured
/// **OpenAI-compatible** instances are surfaced as `AIProviderRouting.Route`s so
/// a picked model routes to that instance's base URL + Keychain credential.
///
/// Anthropic and Gemini can't ride that path — they speak their own wire
/// formats. They're reachable through `AgentProviderChatBridge`, which adapts
/// their `AgentProvider` implementations onto the same `StreamEvent` contract.
@MainActor
enum ProviderChatRouting {

    /// Model ids selected through the picker are namespaced with the owning
    /// entry's composite key so `ChatViewModel.currentModel` (a plain String)
    /// can still round-trip provider selection through SwiftData.
    static let entryPrefix = "entry:"

    /// True when a `ChatViewModel.currentModel` value points at a store entry
    /// rather than a built-in `Models.Option`. Pure string check — callable
    /// from the `ChatService` actor without hopping to the main actor.
    nonisolated static func isEntryId(_ modelId: String) -> Bool {
        modelId.hasPrefix(entryPrefix)
    }

    nonisolated static func entryId(from modelId: String) -> String? {
        guard isEntryId(modelId) else { return nil }
        return String(modelId.dropFirst(entryPrefix.count))
    }

    nonisolated static func modelId(for entry: ModelEntry) -> String {
        entryPrefix + entry.id
    }

    /// Provider types that can ride the existing OpenAI-compatible request path.
    static func isOpenAICompatible(_ type: ProviderType) -> Bool {
        switch type {
        case .openAI, .openAIResponses, .openRouter, .xAI, .kimiCode:
            return true
        case .anthropic, .gemini, .antigravity, .unsupported:
            return false
        }
    }

    /// True when a picked entry can reach chat at all — either by base-URL
    /// swap (OpenAI-compatible) or via `AgentProviderChatBridge`.
    static func isChatReachable(_ type: ProviderType) -> Bool {
        isOpenAICompatible(type) || AgentProviderChatBridge.requiresBridge(type)
    }

    /// Entries the model picker should offer alongside the built-in Oases list:
    /// non-hidden entries of instances that can actually serve chat.
    static func selectableEntries() -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        let routable = Set(
            store.config.instances
                .filter { canServeChat($0) }
                .map(\.id)
        )
        return store.config.modelEntries
            .filter { routable.contains($0.providerInstanceId) && !$0.isHidden }
            .sorted { lhs, rhs in
                lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
            }
    }

    /// Resolve a picker selection back into an entry + its instance.
    static func resolve(modelId: String) -> (entry: ModelEntry, instance: ProviderInstance)? {
        guard let id = entryId(from: modelId) else { return nil }
        let store = ProviderConfigStore.shared
        guard let entry = store.entry(for: id),
              let instance = store.instance(for: entry.providerInstanceId) else { return nil }
        return (entry, instance)
    }

    /// Build an `APIClient.Route` for a picked entry, or nil when the selection
    /// isn't a routable store entry (built-in Oases model, Anthropic, missing
    /// credential, unparsable base URL).
    static func route(for modelId: String) -> AIProviderRouting.Route? {
        guard let (entry, instance) = resolve(modelId: modelId) else { return nil }
        guard isOpenAICompatible(instance.providerType) else { return nil }
        guard let url = baseURL(for: instance) else { return nil }
        guard let key = credential(for: instance), !key.isEmpty else { return nil }
        return AIProviderRouting.Route(
            baseURL: url,
            apiKey: key,
            kind: .globalDirectProvider,
            modelOverride: entry.model.id
        )
    }

    /// True when a persisted selection can still actually serve a request:
    /// the entry resolves, its instance is enabled and credentialed, and the
    /// vendor is reachable (route swap or `AgentProviderChatBridge`).
    static func isSelectionUsable(_ modelId: String) -> Bool {
        guard let (_, instance) = resolve(modelId: modelId) else { return false }
        return canServeChat(instance)
    }

    /// [T-oauth-route-alignment] Single predicate behind the picker and
    /// `isSelectionUsable`, kept in step with what `route(for:)` /
    /// `AgentProviderChatBridge` can really send. `hasAnyCredential` also
    /// counts OAuth logins, but the OpenAI-wire route can only use a login
    /// token that is a plain Bearer for the same base (xAI, Kimi Code — see
    /// `credential(for:)`). A Codex (ChatGPT) login talks to a different
    /// backend, so an OpenAI instance with only that login is NOT usable here;
    /// accepting it made chat silently fall back to the default Oases route.
    static func canServeChat(_ instance: ProviderInstance) -> Bool {
        guard instance.isEnabled,
              isChatReachable(instance.providerType),
              instance.hasAnyCredential else { return false }
        guard isOpenAICompatible(instance.providerType),
              instance.credentialType == .oauth,
              !routeAcceptsOAuthLogin(instance.providerType) else { return true }
        // OAuth instance whose login token can't ride the route: only an API key
        // or a manual bearer token makes it routable.
        return credential(for: instance)?.isEmpty == false
    }

    /// Vendors whose OAuth access token works as the route's Bearer key (same
    /// OpenAI-compatible base as the API-key path). OpenRouter's "OAuth" mints
    /// a regular API key, which `credential(for:)` already reads.
    private static func routeAcceptsOAuthLogin(_ type: ProviderType) -> Bool {
        switch type {
        case .xAI, .kimiCode, .openRouter: return true
        case .openAI, .openAIResponses, .anthropic, .gemini, .antigravity, .unsupported: return false
        }
    }

    /// Underlying vendor model id for a picker selection (what goes in the
    /// request body), or nil for built-in Oases models.
    static func vendorModelId(for modelId: String) -> String? {
        resolve(modelId: modelId)?.entry.model.id
    }

    /// Display label for a picker selection, falling back to the raw id.
    static func label(for modelId: String) -> String? {
        resolve(modelId: modelId)?.entry.model.displayName
    }

    /// Present a routable store entry as a picker row using the existing
    /// `Models.Option` shape, so `ModelPickerSheet` needs no new row type.
    static func option(for entry: ModelEntry, category: Models.Category = .text) -> Models.Option {
        let model = entry.model
        let instanceLabel = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label
        let subtitle = [instanceLabel, model.id].compactMap { $0 }.joined(separator: " · ")
        return Models.Option(
            id: modelId(for: entry),
            label: model.displayName,
            descriptionText: subtitle,
            supportsEffort: model.supportsReasoning ?? false,
            supportsImageInput: model.capabilities.supportedModalities.contains(.imageInput),
            category: category
        )
    }

    /// Picker rows for every routable user-configured entry.
    static func selectableOptions() -> [Models.Option] {
        selectableOptions(matching: .text)
    }

    /// Filter user-configured entries to the current mode's output modality.
    static func selectableOptions(matching category: Models.Category) -> [Models.Option] {
        selectableEntries().compactMap { entry in
            let modalities = entry.model.capabilities.supportedModalities
            switch category {
            case .image:
                guard modalities.contains(.imageOutput) else { return nil }
            case .audio:
                guard modalities.contains(.audioOutput) else { return nil }
            case .text, .project:
                if modalities.contains(.imageOutput) && !modalities.contains(.textOutput) {
                    return nil
                }
                if modalities.contains(.audioOutput) && !modalities.contains(.textOutput) {
                    return nil
                }
            }
            return option(for: entry, category: category)
        }
    }

    /// `Models.Option` for an already-selected entry id, so the picker can show
    /// the current selection even if the instance was since disabled.
    static func selectedOption(for modelId: String) -> Models.Option? {
        resolve(modelId: modelId).map { option(for: $0.entry) }
    }

    // MARK: - Private

    /// `chat/completions` is appended by `APIClient`, so the route base must
    /// already include the `/v1` (or vendor equivalent) path segment.
    private static func baseURL(for instance: ProviderInstance) -> URL? {
        let defaultBase: String
        switch instance.providerType {
        case .openRouter: defaultBase = "https://openrouter.ai/api"
        case .xAI: defaultBase = "https://api.x.ai/v1"
        case .kimiCode: defaultBase = "https://api.kimi.com/coding"
        default: defaultBase = "https://api.openai.com"
        }
        var base = instance.effectiveCustomBaseURL ?? defaultBase
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        let hasV1 = base.hasSuffix("/v1")
        let shouldAppendV1: Bool
        if instance.effectiveCustomBaseURL == nil {
            // Defaults above already carry their correct suffix except OpenAI /
            // OpenRouter, which need `/v1` appended.
            shouldAppendV1 = !hasV1 && instance.providerType != .kimiCode
        } else {
            shouldAppendV1 = instance.appendV1Suffix && !hasV1
        }
        if shouldAppendV1 { base += "/v1" }
        return URL(string: base)
    }

    private static func credential(for instance: ProviderInstance) -> String? {
        if let key = OasesBuiltinProvider.resolvedAPIKey(for: instance.id), !key.isEmpty {
            return key
        }
        if let manual = ProviderKeychainHelper.loadOAuthString(
            instanceId: instance.id,
            account: "manual-oauth-token"
        ), !manual.isEmpty {
            return manual
        }
        return oauthLoginToken(for: instance)
    }

    /// [T-oauth-route-alignment] Access token from an OAuth login for vendors
    /// whose token is a plain Bearer on the route's base (xAI, Kimi Code).
    /// `route(for:)` is synchronous, so it can't await a refresh: a token
    /// close to expiry is still returned (the server accepts it until it
    /// actually expires; an expired one surfaces as a visible 401 rather than
    /// a silent fallback) and a refresh is kicked off for the next request.
    private static func oauthLoginToken(for instance: ProviderInstance) -> String? {
        guard instance.credentialType == .oauth else { return nil }
        let iid = instance.id
        let refreshSoon: (Date?) -> Bool = { expiry in
            expiry.map { $0.timeIntervalSinceNow <= 5 * 60 } ?? false
        }
        switch instance.providerType {
        case .xAI:
            guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: iid, as: XAITokenStorage.self),
                  !storage.accessToken.isEmpty else { return nil }
            if refreshSoon(storage.expireDate) {
                Task { _ = try? await XAIOAuthManager.shared.validAccessToken(instanceId: iid) }
            }
            return storage.accessToken
        case .kimiCode:
            guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: iid, as: KimiTokenStorage.self),
                  !storage.accessToken.isEmpty else { return nil }
            if refreshSoon(storage.expireDate) {
                Task { _ = try? await KimiOAuthManager.shared.validAccessToken(instanceId: iid) }
            }
            return storage.accessToken
        default:
            return nil
        }
    }
}
