import Foundation

/// [Stage 3] GroupsCollection — depends on ProviderConfigStore (model groups).
@MainActor
struct GroupsCollection: ConfigCollection {
    let basePath = "groups"
    let displayName = "Model groups"
    let description = "Named groups of model entries with a routing strategy (fallback / load-balance)."
    let addable = true
    let removable = true
    let risk: ConfigRisk = .sensitive
    let addPayloadSchema: ConfigValueSchema = .json

    func childIds() -> [String] { [] }
    func fields(for id: String) -> [ConfigField] { [] }
    func add(_ payload: ConfigValue) throws -> String {
        throw ConfigError.permissionDenied(reason: "Model groups not yet available — Stage 3")
    }
    func remove(id: String) throws {
        throw ConfigError.permissionDenied(reason: "Model groups not yet available — Stage 3")
    }
}
