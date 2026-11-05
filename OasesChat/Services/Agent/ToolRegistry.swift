import Foundation

/// Singleton registry that owns every tool the app exposes to the
/// agent loop. Built-ins are registered eagerly at app boot;
/// native skill bridges (Calendar, Contacts, …) and user-defined
/// SKILL.md tools register later as their permission gates are
/// passed. The registry's lookup is `O(1)` so the agent loop can
/// dispatch tool calls by name during a streaming turn without
/// holding the actor.
final class ToolRegistry: @unchecked Sendable {
    static let shared = ToolRegistry()
    init() {}

    private var tools: [String: any AgentTool] = [:]
    /// Invoke-only aliases (e.g. `shell_local` → `shell_execute`). Aliases are
    /// not advertised in the model schema unless also registered as tools.
    private var aliases: [String: String] = [:]
    private let lock = NSLock()

    func register(_ tool: any AgentTool, aliases aliasNames: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.descriptor.name] = tool
        for alias in aliasNames where alias != tool.descriptor.name {
            aliases[alias] = tool.descriptor.name
        }
    }

    func unregister(name: String) {
        lock.lock(); defer { lock.unlock() }
        tools.removeValue(forKey: name)
        aliases = aliases.filter { $0.value != name && $0.key != name }
    }

    func tool(named name: String) -> (any AgentTool)? {
        lock.lock(); defer { lock.unlock() }
        if let direct = tools[name] { return direct }
        if let primary = aliases[name] { return tools[primary] }
        return nil
    }

    /// Resolve a tool name (including aliases) to the canonical registry key.
    func canonicalName(for name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if tools[name] != nil { return name }
        return aliases[name] ?? name
    }

    /// Descriptors for every tool currently exposed on the given
    /// surface — handed to the model in the system prompt so it
    /// can decide which to call. Sorted by name for stable wire
    /// payload (matters for proxy caching).
    func descriptors(for surface: AgentSurface, allowedNames: Set<String>? = nil) -> [ToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return tools.values
            .map(\.descriptor)
            .filter { $0.surfaces.contains(surface) }
            .filter { descriptor in
                guard let allowedNames else { return true }
                return allowedNames.contains(descriptor.name)
            }
            .sorted { $0.name < $1.name }
    }

    /// OpenAI-compatible `tools` array — direct JSON snippet you can
    /// embed in the chat-completions request. Tools without input
    /// args still get a `{}` schema so the proxy doesn't reject the
    /// payload.
    func openAIToolsJSON(for surface: AgentSurface, allowedNames: Set<String>? = nil) -> String? {
        let descs = descriptors(for: surface, allowedNames: allowedNames)
        guard !descs.isEmpty else { return nil }
        var entries: [String] = []
        for d in descs {
            entries.append("""
            {"type":"function","function":{"name":"\(d.name)","description":"\(escape(d.summary))","parameters":\(d.inputSchemaJSON)}}
            """)
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
