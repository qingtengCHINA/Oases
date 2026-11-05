import Foundation

/// Canonical tool-call status — mirrors AionUI's `normalizeToolCall.ts`
/// five-state machine. A single shape across every agent surface
/// (built-in, MCP, user-defined SKILL.md, future iSH shell) so the UI
/// can render any tool's progress without branching on origin.
enum ToolCallStatus: String, Codable, Equatable {
    case pending     // queued, host hasn't started yet
    case running     // executing (streaming output OK)
    case completed   // finished cleanly with output
    case error       // execution raised
    case canceled    // user (or watchdog) aborted
}

/// One pending or completed invocation of a tool, captured in the
/// message stream so the chat surface can render a pill / card per
/// call. Persisted to SwiftData via the parent message.
struct ToolCall: Identifiable, Equatable, Codable {
    let id: String
    /// Stable registry key — `image_gen`, `web_browse`, `calendar_read`…
    let name: String
    /// Optional human label ("生成图片", "浏览网页") — UI hint only.
    var displayName: String?
    /// One-line description shown next to the pill while running.
    var description: String?
    var status: ToolCallStatus
    /// JSON-encoded input arguments captured at dispatch time.
    var inputJSON: String?
    /// Streaming or final output — may be truncated for UI; full body
    /// is kept on the underlying ToolResult.
    var output: String?
    var truncated: Bool = false
    /// Wall-clock timestamps in case the UI wants to surface duration.
    var startedAt: Date?
    var endedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        displayName: String? = nil,
        description: String? = nil,
        status: ToolCallStatus = .pending,
        inputJSON: String? = nil,
        output: String? = nil,
        truncated: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id; self.name = name; self.displayName = displayName
        self.description = description; self.status = status
        self.inputJSON = inputJSON; self.output = output
        self.truncated = truncated
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// Result returned by a tool. Either textual output (most tools), a
/// media URL (image-gen / TTS), or both. The chat layer decides
/// whether the assistant should narrate the result or render it
/// directly (e.g. an image bubble).
struct ToolResult: Equatable {
    var text: String?
    var mediaUrl: String?
    var mediaMime: String?
    var truncated: Bool = false

    static let empty = ToolResult()
    static func textOnly(_ s: String, truncated: Bool = false) -> ToolResult {
        ToolResult(text: s, truncated: truncated)
    }
    static func media(url: String, mime: String, caption: String? = nil) -> ToolResult {
        ToolResult(text: caption, mediaUrl: url, mediaMime: mime)
    }
}

/// Static description of a tool — name, JSON-schema-style input
/// arguments, and a one-line summary the model can read to decide
/// when to call it. Mirrors the OpenAI / Anthropic `tools` array
/// entry so any chat model can be told about the tool natively.
struct ToolDescriptor: Hashable, Codable {
    /// Registry key, e.g. `image_gen`. Lowercase + underscores.
    let name: String
    /// Brief description shown to the model in the tools manifest.
    let summary: String
    /// Source label ("生成图片"). Falls back to name. Not localized: the
    /// project planner, `ToolCatalog` routing and model-facing reports match
    /// on it. UI should show `localizedDisplayName`.
    let displayName: String
    /// Label for tool cards / pills in the current UI language. Falls back
    /// to `displayName` (MCP / skill tools carry their own names).
    var localizedDisplayName: String { uiDisplayName ?? displayName }
    private let uiDisplayName: String?
    /// JSON-Schema for the input arguments object. Stored as raw
    /// JSON string so we can hand it to the model verbatim and not
    /// be tied to a Swift JSON-schema lib.
    let inputSchemaJSON: String
    /// Which agent surfaces expose this tool — text chat,
    /// engineering / project mode, both, etc.
    let surfaces: [AgentSurface]
    /// Whether the tool requires user permission before running
    /// (file writes, shell exec, contacts read, etc.). Read-only
    /// internal tools can default to false.
    let requiresPermission: Bool

    init(
        name: String,
        summary: String,
        displayName: String? = nil,
        localizedDisplayName: String? = nil,
        inputSchemaJSON: String = "{\"type\":\"object\",\"properties\":{}}",
        surfaces: [AgentSurface] = [.chat],
        requiresPermission: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.displayName = displayName ?? name
        self.uiDisplayName = localizedDisplayName
        self.inputSchemaJSON = inputSchemaJSON
        self.surfaces = surfaces
        self.requiresPermission = requiresPermission
    }
}

/// Which agent loop / mode a tool is wired into. Lets a tool opt in
/// to the chat agent only, the project (engineering) agent only, or
/// both. Voice / image-gen modes don't currently host tools.
enum AgentSurface: String, Codable, Equatable, Sendable {
    case chat
    case project
}

/// Which agent loop is running the current tool call. The text-chat loop
/// binds `.chat` around `invoke`, so a tool both surfaces share can keep
/// text chat free of Ogent-only side effects (guest files in the Linux
/// rootfs, hints that point at Ogent tools). Unbound means an Ogent or
/// internal caller.
enum AgentToolContext {
    @TaskLocal static var surface: AgentSurface?

    static var isTextChat: Bool { surface == .chat }
}

/// The behaviour contract every tool implements. Tools own their
/// state (e.g. an HTTP client) and run async with a typed JSON
/// argument string. They are encouraged to stream output via the
/// `onProgress` callback so the UI's pill can update token-by-
/// token, but a single-shot completion is also fine.
protocol AgentTool: AnyObject, Sendable {
    var descriptor: ToolDescriptor { get }
    func invoke(
        argumentsJSON: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult
}
