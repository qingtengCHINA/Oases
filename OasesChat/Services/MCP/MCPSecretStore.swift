import Foundation
import Security

protocol MCPKeychainStore: Sendable {
    func read(reference: String) throws -> String?
    func write(_ value: String, reference: String) throws
    func delete(reference: String) throws
}

private final class SystemMCPKeychainStore: MCPKeychainStore, @unchecked Sendable {
    private let service: String

    init(service: String) { self.service = service }

    func read(reference: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MCPSecretStoreError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MCPSecretStoreError.invalidKeychainValue
        }
        return value
    }

    func write(_ value: String, reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw MCPSecretStoreError.keychain(insertStatus) }
        } else if status != errSecSuccess {
            throw MCPSecretStoreError.keychain(status)
        }
    }

    func delete(reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPSecretStoreError.keychain(status)
        }
    }
}

final class MCPSecretStore: @unchecked Sendable {
    private let keychain: any MCPKeychainStore
    private let referencePrefix: String

    init(keychain: any MCPKeychainStore, referencePrefix: String = "mcp.secret.") {
        self.keychain = keychain
        self.referencePrefix = referencePrefix
    }

    convenience init(referencePrefix: String = "mcp.secret.") {
        self.init(
            keychain: SystemMCPKeychainStore(service: "dev.oases.chat.mcp"),
            referencePrefix: referencePrefix
        )
    }

    func store(_ value: String, forKey key: String) throws -> MCPEnvironmentBinding {
        let reference = referencePrefix + UUID().uuidString
        try keychain.write(value, reference: reference)
        return MCPEnvironmentBinding(key: key, source: .keychain(reference: reference))
    }

    func resolve(_ binding: MCPEnvironmentBinding) throws -> String {
        switch binding.source {
        case .literal(let value): return value
        case .keychain(let reference):
            guard let value = try keychain.read(reference: reference) else {
                throw MCPSecretStoreError.missingSecret(reference)
            }
            return value
        }
    }

    func resolve(_ bindings: [MCPEnvironmentBinding]) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: bindings.map { ($0.key, try resolve($0)) })
    }

    func migrate(_ bindings: [MCPEnvironmentBinding]) throws -> [MCPEnvironmentBinding] {
        try bindings.map { binding in
            guard case .literal(let value) = binding.source, Self.isSensitiveKey(binding.key) else {
                return binding
            }
            return try store(value, forKey: binding.key)
        }
    }

    func migrate(_ server: OasesMCPServerConfig) throws -> MCPConfiguration {
        let bindings = server.environment.map {
            MCPEnvironmentBinding(key: $0.key, source: .literal($0.value))
        }
        return try MCPConfiguration(server: server, environment: migrate(bindings))
    }

    func delete(_ binding: MCPEnvironmentBinding) throws {
        if case .keychain(let reference) = binding.source {
            try keychain.delete(reference: reference)
        }
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        let parts = upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let sensitive = ["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "COOKIE"]
        return parts.contains(where: sensitive.contains)
            || sensitive.contains(where: { upper == $0 || upper.hasSuffix("_\($0)") })
            || upper.contains("AUTH")
    }
}

enum MCPSecretStoreError: LocalizedError, Equatable, Sendable {
    case missingSecret(String)
    case invalidKeychainValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingSecret: return "MCP secret is not available in Keychain."
        case .invalidKeychainValue: return "MCP Keychain value is invalid."
        case .keychain(let status): return "Keychain operation failed with status \(status)."
        }
    }
}
