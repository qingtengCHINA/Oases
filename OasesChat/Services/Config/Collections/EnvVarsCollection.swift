import Foundation

/// [Stage 3] EnvVarsCollection — depends on EnvVarStore (Keychain-backed env var store).
@MainActor
struct EnvVarsCollection: ConfigCollection {
    let basePath = "envvars"
    let displayName = "Environment variables"
    let description = "Named key-value pairs stored in the Keychain, injected as shell environment variables."
    let addable = true
    let removable = true
    let risk: ConfigRisk = .sensitive
    let addPayloadSchema: ConfigValueSchema = .json

    func childIds() -> [String] { [] }
    func fields(for id: String) -> [ConfigField] { [] }
    func add(_ payload: ConfigValue) throws -> String {
        throw ConfigError.permissionDenied(reason: "EnvVar store not yet available — Stage 3")
    }
    func remove(id: String) throws {
        throw ConfigError.permissionDenied(reason: "EnvVar store not yet available — Stage 3")
    }
}
