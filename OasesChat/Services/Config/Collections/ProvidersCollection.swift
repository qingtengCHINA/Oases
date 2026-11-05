import Foundation

/// [Stage 2] ProvidersCollection — depends on ProviderConfigStore.
///
/// Stub that satisfies the ConfigCollection protocol so the file compiles.
/// Stage 2 will replace this body with the full OpenMinis implementation
/// once ProviderConfigStore is ported.
@MainActor
struct ProvidersCollection: ConfigCollection {
    let basePath = "providers"
    let displayName = "LLM provider instances"
    let description = "Configured AI provider accounts (Anthropic, compatible APIs, …). Credentials can be written but are never read back."
    let addable = true
    let removable = false
    let risk: ConfigRisk = .sensitive
    let addPayloadSchema: ConfigValueSchema = .json

    func childIds() -> [String] { [] }   // [Stage 2] ProviderConfigStore.shared.config.instances.map(\.id)
    func fields(for id: String) -> [ConfigField] { [] }
    func add(_ payload: ConfigValue) throws -> String {
        throw ConfigError.permissionDenied(reason: "Provider config not yet available — Stage 2")
    }
    func remove(id: String) throws {
        throw ConfigError.permissionDenied(reason: "Provider config not yet available — Stage 2")
    }
}
