#if DEBUG
import Foundation

/// [T-debug-provider-rpc] Debug JSON-RPC surface for the Providers stack.
///
/// Ported from OpenMinis `Debug/DebugRPCProviderChat.swift` (1625L). OasesChat
/// happens to *have* the same symbol shape (`ProviderType.allCases`,
/// `ProviderConfigStore.shared.instances`, `ProviderCredential`, `ModelEntry`,
/// `ProviderInstance`) — the OasesChat port reuses these symbols directly,
/// only narrowing to the methods that make sense without an agent loop running.
///
/// Methods that depend on streaming/sending paths (compactBefore,
/// compactRevert, simulateLongMessage, sessionCancel-while-sending,
/// modelsRefresh driving an async refresh) are deliberately omitted; they live
/// behind the agent / SSE stack in OpenMinis and don't have OasesChat
/// counterparts today. The methods here cover CRUD on
/// types/instances/entries/groups — enough to write a test harness that
/// stages a Providers configuration, then drives a real `chat.prompt` from
/// the same RPC connection.
@MainActor
enum DebugRPCProviderChat {

    // MARK: - Types

    /// `provider.types` → every ProviderType with its supported credentials
    /// and built-in model ids. Matches OpenMinis' shape.
    static func types() -> [String: Any] {
        let allTypes = ProviderType.allCases.map { type -> [String: Any] in
            let supportedCreds: [String]
            switch type {
            case .openAI, .anthropic: supportedCreds = ["apiKey", "oauth"]
            case .gemini, .antigravity: supportedCreds = ["oauth"]
            case .openRouter: supportedCreds = ["apiKey", "oauth"]
            case .openAIResponses: supportedCreds = ["apiKey"]
            case .xAI: supportedCreds = ["apiKey", "oauth"]
            case .kimiCode: supportedCreds = ["oauth"]
            case .unsupported: supportedCreds = []
            }
            let customBaseSupported: Bool
            switch type {
            case .openAI, .openRouter, .openAIResponses, .gemini, .xAI, .kimiCode:
                customBaseSupported = true
            case .anthropic, .antigravity, .unsupported:
                customBaseSupported = false
            }
            return [
                "id": type.rawValue,
                "displayName": type.displayName,
                "supportedCredentials": supportedCreds,
                "customBaseURLSupported": customBaseSupported,
                "appendV1SuffixConfigurable": customBaseSupported,
                "defaultModality": type.defaultModality.rawValue,
                "builtInModelIds": type.builtInModels.map(\.id),
            ]
        }
        return ["types": allTypes]
    }

    // MARK: - Instances

    /// `provider.instances.list` → all instances (or enabled-only when
    /// `includeDisabled=false`). Matches OpenMinis' dict shape.
    /// Params: { includeDisabled?: bool (default true) }
    static func instancesList(params: [String: Any]) -> [String: Any] {
        let includeDisabled = (params["includeDisabled"] as? Bool) ?? true
        let store = ProviderConfigStore.shared
        let all = store.instances
        let filtered = includeDisabled ? all : all.filter(\.isEnabled)
        let dicts = filtered.map { instanceDict($0) }
        return ["count": dicts.count, "instances": dicts]
    }

    /// `provider.instances.create` → add an instance. The credential payload
    /// (API key / OAuth token) is written via `ProviderKeychainHelper`.
    /// Params: {
    ///   providerType: string,
    ///   label: string,
    ///   credentialType?: "apiKey"|"oauth" (default apiKey),
    ///   apiKey?: string,        // required when credentialType=apiKey
    ///   isEnabled?: bool (default true),
    ///   customBaseURL?: string,
    ///   appendV1Suffix?: bool (default true),
    ///   azureMode?: bool (default false),
    ///   customUserAgent?: string
    /// }
    static func instancesCreate(params: [String: Any]) throws -> [String: Any] {
        let providerTypeRaw = try require(params["providerType"] as? String, "providerType")
        guard let providerType = ProviderType(rawValue: providerTypeRaw) else {
            throw DebugRPCErr(-32602, "Unknown providerType: \(providerTypeRaw)")
        }
        let label = try require(params["label"] as? String, "label")
        let credentialRaw = (params["credentialType"] as? String) ?? "apiKey"
        guard let credentialType = ProviderCredential(rawValue: credentialRaw) else {
            throw DebugRPCErr(-32602, "Unknown credentialType: \(credentialRaw)")
        }

        var instance = ProviderInstance(
            label: label,
            providerType: providerType,
            credentialType: credentialType,
            isEnabled: (params["isEnabled"] as? Bool) ?? true
        )
        if let url = params["customBaseURL"] as? String, !url.isEmpty {
            instance.customBaseURL = url
        }
        if let v1 = params["appendV1Suffix"] as? Bool {
            instance.appendV1Suffix = v1
        }
        if let azure = params["azureMode"] as? Bool {
            instance.azureMode = azure
        }
        if let ua = params["customUserAgent"] as? String, !ua.isEmpty {
            instance.customUserAgent = ua
        }

        let store = ProviderConfigStore.shared
        store.addInstance(instance)

        // Persist API key when provided (apiKey flow only).
        if credentialType == .apiKey, let key = params["apiKey"] as? String, !key.isEmpty {
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)
            ProviderCredentialCache.shared.invalidate(instance.id)
        }

        return [
            "ok": true,
            "instance": instanceDict(instance),
            "allInstanceIds": store.instances.map(\.id),
        ]
    }

    /// `provider.instances.update` → patch an existing instance. Only fields
    /// supplied in `params` are changed.
    /// Params: { instanceId: string, ...same optional fields as create }
    static func instancesUpdate(params: [String: Any]) throws -> [String: Any] {
        let instanceId = try require(params["instanceId"] as? String, "instanceId")
        let store = ProviderConfigStore.shared
        guard var current = store.instance(for: instanceId) else {
            throw DebugRPCErr(-32004, "Instance '\(instanceId)' not found.")
        }

        if let label = params["label"] as? String, !label.isEmpty { current.label = label }
        if let enabled = params["isEnabled"] as? Bool { current.isEnabled = enabled }
        if let url = params["customBaseURL"] as? String { current.customBaseURL = url.isEmpty ? nil : url }
        if let v1 = params["appendV1Suffix"] as? Bool { current.appendV1Suffix = v1 }
        if let azure = params["azureMode"] as? Bool { current.azureMode = azure }
        if let ua = params["customUserAgent"] as? String { current.customUserAgent = ua.isEmpty ? nil : ua }

        store.updateInstance(current)

        if let key = params["apiKey"] as? String, !key.isEmpty {
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instanceId)
            ProviderCredentialCache.shared.invalidate(instanceId)
        }

        return [
            "ok": true,
            "instance": instanceDict(current),
        ]
    }

    /// `provider.instances.delete` → remove an instance (cascades to its
    /// entries + drops Keychain secrets).
    /// Params: { instanceId: string }
    static func instancesDelete(params: [String: Any]) throws -> [String: Any] {
        let instanceId = try require(params["instanceId"] as? String, "instanceId")
        let store = ProviderConfigStore.shared
        let existed = store.instance(for: instanceId) != nil
        guard existed else {
            throw DebugRPCErr(-32004, "Instance '\(instanceId)' not found.")
        }
        store.removeInstance(instanceId)
        ProviderKeychainHelper.deleteAPIKey(instanceId: instanceId)
        ProviderCredentialCache.shared.invalidate(instanceId)
        return [
            "ok": true,
            "deleted": existed,
            "id": instanceId,
            "allInstanceIds": store.instances.map(\.id),
        ]
    }

    // MARK: - Models

    /// `provider.models.list` → all ModelEntry rows for the instance (or all
    /// instances when `instanceId` omitted). Includes hidden entries when
    /// `includeHidden=true`.
    /// Params: { instanceId?: string, includeHidden?: bool (default false) }
    static func modelsList(params: [String: Any]) -> [String: Any] {
        let store = ProviderConfigStore.shared
        let includeHidden = (params["includeHidden"] as? Bool) ?? false
        let instanceFilter = params["instanceId"] as? String

        var entries: [ModelEntry]
        if let iid = instanceFilter, !iid.isEmpty {
            entries = store.entries(for: iid)
        } else {
            entries = store.modelEntries
        }
        if !includeHidden { entries = entries.filter { !$0.isHidden } }

        let dicts = entries.map { entry -> [String: Any] in
            var d: [String: Any] = [
                "id": entry.id,
                "instanceId": entry.providerInstanceId,
                "modelId": entry.baseModel.id,
                "displayName": entry.model.displayName,
                "provider": entry.model.provider,
                "isCustom": entry.isCustom,
                "isHidden": entry.isHidden,
            ]
            if let modality = entry.baseModel.modalityOverride {
                d["modalityRaw"] = modality.rawValue
            }
            return d
        }
        return [
            "count": dicts.count,
            "entries": dicts,
        ]
    }

    // MARK: - Helpers

    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let v = value else {
            throw DebugRPCErr(-32602, "Missing required param: \(name)")
        }
        return v
    }

    private static func instanceDict(_ inst: ProviderInstance) -> [String: Any] {
        var d: [String: Any] = [
            "id": inst.id,
            "label": inst.label,
            "providerType": inst.providerType.rawValue,
            "credentialType": inst.credentialType.rawValue,
            "isEnabled": inst.isEnabled,
            "createdAt": iso8601(inst.createdAt),
            "hasAnyCredential": inst.hasAnyCredential,
        ]
        if let url = inst.effectiveCustomBaseURL { d["customBaseURL"] = url }
        d["appendV1Suffix"] = inst.appendV1Suffix
        if inst.azureMode { d["azureMode"] = true }
        if let ua = inst.effectiveCustomUserAgent { d["customUserAgent"] = ua }
        if let raw = inst.unknownProviderTypeRaw { d["unknownProviderTypeRaw"] = raw }
        return d
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
#endif
