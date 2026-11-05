import Foundation

/// [Stage 2/3] ModelsCollection — depends on ProviderConfigStore.
@MainActor
struct ModelsCollection: ConfigCollection {
    let basePath = "models"
    let displayName = "LLM models"
    let description = "Per-model overrides (display name, max output tokens, hidden flag) and custom-model add/remove."
    let addable = true
    let removable = true
    let risk: ConfigRisk = .sensitive
    let addPayloadSchema: ConfigValueSchema = .json

    func childIds() -> [String] { [] }
    func fields(for id: String) -> [ConfigField] { [] }
    func add(_ payload: ConfigValue) throws -> String {
        throw ConfigError.permissionDenied(reason: "Model config not yet available — Stage 2")
    }
    func remove(id: String) throws {
        throw ConfigError.permissionDenied(reason: "Model config not yet available — Stage 2")
    }
}
