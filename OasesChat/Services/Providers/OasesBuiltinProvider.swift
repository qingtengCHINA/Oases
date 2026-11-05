import Foundation

/// Virtual Oases system provider. Never persisted, never synced.
///
/// Ogent (`AIChatViewModel`) can only send through a `ModelEntry` +
/// `ProviderInstance`. The built-in catalog used to die with “No model
/// configured” unless the user added their own key. This synthetic
/// instance points at `Secrets.apiBaseURL` so Oases Chat / Fast / Pro
/// (and the beta / image / voice ids) work out of the box.
enum OasesBuiltinProvider {
    static let instanceId = "oases-builtin"

    static var apiKey: String? {
        let key = Secrets.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    static var hasCredential: Bool { apiKey != nil }

    static var instance: ProviderInstance {
        let url = Secrets.apiBaseURL.absoluteString
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        let alreadyV1 = trimmed.hasSuffix("/v1")
        return ProviderInstance(
            id: instanceId,
            label: "Oases",
            providerType: .openAI,
            credentialType: .apiKey,
            createdAt: Date(timeIntervalSince1970: 0),
            customBaseURL: trimmed,
            appendV1Suffix: !alreadyV1
        )
    }

    static var catalogOptions: [Models.Option] {
        Models.chat + Models.betaChat + Models.imageModels + Models.options(for: .audio)
    }

    static var textEntries: [ModelEntry] {
        (Models.chat + Models.betaChat).map(makeEntry)
    }

    static var entries: [ModelEntry] {
        catalogOptions.map(makeEntry)
    }

    static var defaultTextEntry: ModelEntry {
        // `first` + a synthesized entry instead of `textEntries[0]`, which
        // trapped if the text catalog were ever empty.
        entry(forModelId: Models.defaultProject)
            ?? textEntries.first
            ?? ModelEntry(
                uuid: "\(instanceId)-\(Models.defaultProject)",
                providerInstanceId: instanceId,
                model: LLMModel(id: Models.defaultProject, displayName: Models.defaultProject, provider: "Oases")
            )
    }

    /// Resolve the request credential without persisting Secrets into Keychain.
    static func resolvedAPIKey(for instanceId: String) -> String? {
        if instanceId == Self.instanceId { return apiKey }
        return ProviderKeychainHelper.loadAPIKey(instanceId: instanceId)
    }

    private static func makeEntry(_ option: Models.Option) -> ModelEntry {
        ModelEntry(
            uuid: "\(instanceId)-\(option.id)",
            providerInstanceId: instanceId,
            model: option.asLLMModel
        )
    }

    static var defaultTextModel: LLMModel {
        defaultTextEntry.model
    }

    static func owns(_ id: String) -> Bool {
        id == instanceId || id.hasPrefix(instanceId + "/")
    }

    static func entry(for entryId: String) -> ModelEntry? {
        entries.first(where: { $0.id == entryId || $0.uuid == entryId })
    }

    static func entry(forModelId modelId: String) -> ModelEntry? {
        entries.first(where: { $0.baseModel.id == modelId })
    }
}
