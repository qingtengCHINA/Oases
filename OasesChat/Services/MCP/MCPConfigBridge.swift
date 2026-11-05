import Foundation

/// Bidirectional mapping between the OpenMinis engineering MCP model
/// (`MCPServerConfig` / `MCPStore` Claude-Desktop `servers.json`) and the
/// Oases agent-tool model (`OasesMCPServerConfig` / `MCPSettingsStore`).
///
/// Both surfaces now share the same on-disk source of truth:
/// `MCPStore.syncFileURL` → `{minisConfig}/mcp-servers/servers.json`.
enum MCPConfigBridge {
    /// Stable id for the bundled 12306 server (Oases agent tools).
    static let builtin12306ID = "builtin-12306-mcp"
    static let builtin12306Name = "12306-mcp"

    // MARK: - Conversion

    nonisolated static func toOases(_ server: MCPServerConfig) -> OasesMCPServerConfig {
        let env: [MCPEnvironmentVariable] = (server.env ?? [:])
            .map { MCPEnvironmentVariable(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }

        let transport: MCPTransport = server.isHTTP ? .http : .stdio
        let created = Date(timeIntervalSince1970: server.createdAt ?? Date().timeIntervalSince1970)
        let updated = Date(timeIntervalSince1970: server.updatedAt ?? server.createdAt ?? Date().timeIntervalSince1970)

        var config = OasesMCPServerConfig(
            name: server.id,
            transport: transport,
            isEnabled: server.enabled,
            command: server.command,
            arguments: server.args ?? [],
            urlString: server.url,
            environment: env,
            createdAt: created,
            updatedAt: updated
        )
        // Sent by the app's own MCP client (`MCPConfiguration`): they used to be dropped here,
        // so a server that needs an Authorization header listed its tools (through the guest
        // daemon) but every call from the app got 401.
        config.headers = server.isHTTP ? server.headers : nil
        // Preserve the well-known builtin id so agent tools keep matching.
        if server.id.caseInsensitiveCompare(builtin12306Name) == .orderedSame
            || server.id == builtin12306ID {
            config.id = builtin12306ID
            config.name = builtin12306Name
        } else {
            // Prefer stable name-based ids so import/export round-trips.
            config.id = server.id
        }
        return config
    }

    nonisolated static func toOpenMinis(_ server: OasesMCPServerConfig) -> MCPServerConfig {
        var env: [String: String] = [:]
        for item in server.environment {
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            env[key] = item.value
        }
        // Claude-Desktop keys the map by server name.
        let name: String = {
            if server.id == builtin12306ID
                || server.name.caseInsensitiveCompare(builtin12306Name) == .orderedSame {
                return builtin12306Name
            }
            let trimmed = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? server.id : trimmed
        }()

        // note/headers/oauth/startupTimeout have no Oases counterpart; the
        // disk writer merges them back from the existing entry.
        return MCPServerConfig(
            id: name,
            note: nil,
            enabled: server.isEnabled,
            createdAt: server.createdAt.timeIntervalSince1970,
            updatedAt: server.updatedAt.timeIntervalSince1970,
            url: server.transport == .http ? server.urlString : nil,
            headers: nil,
            oauth: nil,
            command: server.transport == .stdio ? server.command : nil,
            args: server.transport == .stdio ? server.arguments : nil,
            env: env.isEmpty ? nil : env,
            startupTimeoutSeconds: nil
        )
    }

    // MARK: - Disk (Claude Desktop mcpServers object)

    private struct DiskEntry: Codable {
        var note: String?
        var enabled: Bool?
        var createdAt: Double?
        var updatedAt: Double?
        var url: String?
        var headers: [String: String]?
        var oauth: MCPOAuthConfig?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var startupTimeoutSeconds: Int?
    }

    /// Shared path with `MCPStore.syncFileURL`.
    nonisolated static var serversFileURL: URL {
        MCPStore.syncFileURL
    }

    nonisolated static func readOpenMinisServersFromDisk() -> [MCPServerConfig] {
        let url = serversFileURL
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["mcpServers"] as? [String: Any] else {
            return []
        }
        let decoder = JSONDecoder()
        let now = Date().timeIntervalSince1970
        var configs: [MCPServerConfig] = []
        for (name, rawEntry) in rawServers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            guard let entryData = try? JSONSerialization.data(withJSONObject: rawEntry),
                  let entry = try? decoder.decode(DiskEntry.self, from: entryData) else {
                continue
            }
            configs.append(MCPServerConfig(
                id: name,
                note: entry.note,
                enabled: entry.enabled ?? true,
                createdAt: entry.createdAt ?? now,
                updatedAt: entry.updatedAt,
                url: entry.url,
                headers: entry.headers,
                oauth: entry.oauth,
                command: entry.command,
                args: entry.args,
                env: entry.env,
                startupTimeoutSeconds: entry.startupTimeoutSeconds
            ))
        }
        return configs
    }

    nonisolated static func readOasesServersFromDisk() -> [OasesMCPServerConfig] {
        readOpenMinisServersFromDisk().map(toOases)
    }

    /// Read-modify-write: the Oases model only knows name/transport/enabled/
    /// command/args/url/env/timestamps, so every other key already on disk
    /// (headers, oauth, note, startupTimeoutSeconds, anything a newer build or
    /// the CLI wrote) is carried over from the existing entry instead of being
    /// wiped by a toggle/delete/import from the agent-tool side.
    nonisolated static func writeOasesServersToDisk(_ servers: [OasesMCPServerConfig]) {
        let url = serversFileURL
        guard let data = mergedServersFileData(
            existing: try? Data(contentsOf: url),
            servers: servers
        ) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        // Keep live MCPStore in sync when UI / agent tools mutate the file.
        Task { @MainActor in
            MCPStore.shared.load()
        }
    }

    /// Keys `OasesMCPServerConfig` owns; everything else on an entry
    /// (headers, oauth, note, startupTimeoutSeconds, …) is passthrough.
    nonisolated static let oasesManagedKeys: Set<String> = [
        "enabled", "disabled", "createdAt", "updatedAt", "url", "command", "args", "env",
    ]

    /// After an import, copies the passthrough keys of each imported entry
    /// onto the entry just written for that server name, so a newly imported
    /// HTTP server keeps its headers and OAuth settings.
    nonisolated static func applyImportedExtras(_ imported: [String: [String: Any]]) {
        let url = serversFileURL
        guard !imported.isEmpty,
              let data = mergedImportedExtras(existing: try? Data(contentsOf: url), imported: imported) else { return }
        try? data.write(to: url, options: .atomic)
        Task { @MainActor in
            MCPStore.shared.load()
        }
    }

    /// Pure part of `applyImportedExtras` (unit-tested).
    nonisolated static func mergedImportedExtras(existing: Data?, imported: [String: [String: Any]]) -> Data? {
        guard let existing,
              var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              var entries = root["mcpServers"] as? [String: Any] else { return nil }
        for (name, raw) in imported {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var entry = entries[key] as? [String: Any] else { continue }
            for (field, value) in raw where !oasesManagedKeys.contains(field) {
                entry[field] = value
            }
            entries[key] = entry
        }
        root["mcpServers"] = entries
        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
    }

    /// Pure merge used by `writeOasesServersToDisk` (and unit tests). Servers
    /// absent from `servers` are dropped (delete); top-level keys other than
    /// `mcpServers` are kept.
    nonisolated static func mergedServersFileData(
        existing: Data?,
        servers: [OasesMCPServerConfig]
    ) -> Data? {
        var root = existing
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let oldEntries = root["mcpServers"] as? [String: Any] ?? [:]
        var entries: [String: Any] = [:]
        for server in servers {
            let managed = toOpenMinis(server)
            // A rename keeps the old key in `server.id`; fall back to it so the
            // renamed entry still inherits its headers/oauth.
            let previous = (oldEntries[managed.id] as? [String: Any])
                ?? (oldEntries[server.id] as? [String: Any])
                ?? [:]
            entries[managed.id] = mergedEntry(previous: previous, managed: managed)
        }
        root["mcpServers"] = entries
        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
    }

    /// Overwrites only the keys the Oases model owns; `nil` removes the key.
    nonisolated private static func mergedEntry(
        previous: [String: Any],
        managed: MCPServerConfig
    ) -> [String: Any] {
        var entry = previous
        func set(_ key: String, _ value: Any?) {
            if let value { entry[key] = value } else { entry.removeValue(forKey: key) }
        }
        set("enabled", managed.enabled)
        set("createdAt", managed.createdAt)
        set("updatedAt", managed.updatedAt)
        set("url", managed.url)
        set("command", managed.command)
        set("args", managed.args)
        set("env", managed.env)
        // Claude-Desktop `disabled` would contradict the `enabled` we just set.
        entry.removeValue(forKey: "disabled")
        return entry
    }

    /// One-shot migration: if the legacy Application Support `mcp-servers.json`
    /// array exists and the OpenMinis file is empty, import it.
    nonisolated static func migrateLegacyOasesFileIfNeeded() {
        let openMinis = readOpenMinisServersFromDisk()
        guard openMinis.isEmpty else { return }

        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let legacyURL = dir.appendingPathComponent("mcp-servers.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([OasesMCPServerConfig].self, from: data),
              !legacy.isEmpty else {
            return
        }
        writeOasesServersToDisk(legacy)
        AppLogger(category: "MCPBridge").info(
            "Migrated \(legacy.count) MCP server(s) from legacy Application Support file"
        )
    }
}
