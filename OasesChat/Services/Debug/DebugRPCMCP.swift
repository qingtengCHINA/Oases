#if DEBUG
import Foundation

/// [T-debug-mcp-rpc] Debug JSON-RPC surface for MCP server configuration.
///
/// Ported from OpenMinis `Debug/DebugRPCMCP.swift` (73L), remapped to
/// OasesChat's MCP architecture:
/// - OpenMinis: `MCPStore.shared.servers` / `.importJSON(_:)` / `.delete(id:)`
///   on a `@MainActor` `MCPStore` `ObservableObject`.
/// - OasesChat: `MCPSettingsStore.load()` / `.importClaudeDesktopJSON(_:)` /
///   `.delete(id:)` — a pure-value `enum` persisting `mcp-servers.json`.
///
/// All three methods are synchronous because `MCPSettingsStore` doesn't need
/// the main actor; the dispatcher hops onto `MainActor.run` only for
/// uniformity with the rest of the `chat.*` family. Going through the
/// settings store (instead of the live `MCPClientManager` actor) means writes
/// take effect on the next `MCPClientManager.reload()` — same semantics as
/// OpenMinis' note about the file-writing path needing a screen onAppear.
@MainActor
enum DebugRPCMCP {

    /// `mcp.list` → the current on-disk server list, each with transport +
    /// enabled state. Matches OpenMinis' shape: id / enabled / transport /
    /// command / args / env / url / createdAt.
    static func list() -> [String: Any] {
        let servers = MCPSettingsStore.load().map { serverDict($0) }
        return ["count": servers.count, "servers": servers]
    }

    /// `mcp.import` → import server(s) from a Claude Desktop-style JSON blob
    /// (`{"mcpServers": {...}}`). Upserts by name and persists. Returns the
    /// count of imported ids + the full post-import id list.
    /// Params: { json: string }  (the raw config text)
    static func importJSON(params: [String: Any]) throws -> [String: Any] {
        guard let json = params["json"] as? String, !json.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'json' (string): the MCP config text, e.g. {\"mcpServers\": {...}}.")
        }
        let imported: Int
        do {
            imported = try MCPSettingsStore.importClaudeDesktopJSON(json)
        } catch {
            throw DebugRPCErr(-32602, "Failed to import MCP config: \(error.localizedDescription)")
        }
        return [
            "ok": true,
            "importedCount": imported,
            "allServerIds": MCPSettingsStore.load().map { $0.id },
        ]
    }

    /// `mcp.delete` → remove a server by id from the persisted list.
    /// Params: { id: string }
    static func delete(params: [String: Any]) throws -> [String: Any] {
        guard let id = params["id"] as? String, !id.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'id' (string): the server id to delete.")
        }
        let existed = MCPSettingsStore.load().contains { $0.id == id }
        MCPSettingsStore.delete(id: id)
        return [
            "ok": true,
            "deleted": existed,
            "id": id,
            "allServerIds": MCPSettingsStore.load().map { $0.id },
        ]
    }

    // MARK: - Helpers

    private static func serverDict(_ s: OasesMCPServerConfig) -> [String: Any] {
        var d: [String: Any] = [
            "id": s.id,
            "name": s.name,
            "enabled": s.isEnabled,
            "transport": transportString(s.transport),
            "createdAt": iso8601(s.createdAt),
            "updatedAt": iso8601(s.updatedAt),
        ]
        if let cmd = s.command { d["command"] = cmd }
        if !s.arguments.isEmpty { d["args"] = s.arguments }
        if let url = s.urlString { d["url"] = url }
        if !s.environment.isEmpty {
            d["env"] = Dictionary(uniqueKeysWithValues: s.environment.map { ($0.key, $0.value) })
        }
        return d
    }

    private static func transportString(_ t: MCPTransport) -> String {
        switch t {
        case .http: return "http"
        case .stdio: return "stdio"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
#endif
