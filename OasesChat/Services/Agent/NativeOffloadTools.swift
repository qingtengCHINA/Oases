import Foundation
import UIKit

/// Host-side offload: read/write UIPasteboard. Gated like `apple-clipboard`
/// (Settings → Permissions; Ask Once by default).
final class ClipboardOffloadTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "apple_clipboard",
        // i18n-ignore: model-facing tool description
        summary: """
        Read or write the iOS system clipboard (pasteboard). Actions: get (default) returns plain text; \
        set writes text. Asks the user once per session unless they changed Clipboard in Settings → Permissions.
        """,
        displayName: "剪贴板", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "剪贴板", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{"tool_title":{"type":"string"},"action":{"type":"string","enum":["get","set"],"default":"get"},"text":{"type":"string","description":"Text to set when action=set"}}}
        """,
        surfaces: [.project, .chat],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "get").lowercased()
        if let denied = await NativeToolPermission.denial(
            command: "apple-clipboard",
            arguments: [action == "set" ? "set" : "get"]
        ) {
            return .textOnly("Error: \(denied)")
        }

        if action == "set" {
            let text = (args["text"] as? String) ?? ""
            await MainActor.run {
                UIPasteboard.general.string = text
            }
            return .textOnly("✓ clipboard set (\(text.utf8.count) bytes)")
        }

        let value = await MainActor.run { UIPasteboard.general.string ?? "" }
        // Ogent gets the full text in its guest filesystem. Text chat has no
        // guest filesystem: it gets a longer slice instead.
        let spill = "\(OasesPathResolver.offloads)/clipboard_last.txt"
        let spills = !AgentToolContext.isTextChat
        if spills {
            try? OasesPathResolver.writeGuestFile(path: spill, content: value)
        }
        var out = "clipboard_get_ok\nlength=\(value.utf8.count)\n"
        if value.count <= 4_000 {
            out += "text=\(value)\n"
        } else if spills {
            out += "text_preview=\(String(value.prefix(500)))…\n"
            out += "path=\(spill)\n"
        } else {
            out += "text_preview=\(String(value.prefix(4_000)))…\n"
        }
        out += "source=UIPasteboard.general\n"
        return .textOnly(out)
    }
}

/// Alias tool that exposes `browser_use` while reusing any browser-like AgentTool.
final class BrowserUseAliasTool: AgentTool, @unchecked Sendable {
    private let underlying: any AgentTool

    init(underlying: any AgentTool = WebBrowseTool()) {
        self.underlying = underlying
    }

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "browser_use",
            summary: """
            Control the in-app browser (OpenMinis-compatible name for web_browse). Actions: open, read, extract, \
            click, type, screenshot-like snapshots via extract/status. Screenshots and downloads land under \
            /var/oases/browser/ when available. Requires approval for challenge pages.
            """,
            displayName: "浏览器", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
            localizedDisplayName: String(localized: "浏览器", comment: "Tool name on tool cards"),
            inputSchemaJSON: underlying.descriptor.inputSchemaJSON,
            surfaces: [.project],
            requiresPermission: false
        )
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        var result = try await underlying.invoke(argumentsJSON: argumentsJSON, onProgress: onProgress)
        if let text = result.text, !text.isEmpty {
            let landed = Self.landBrowserArtifact(text: text, sessionId: OasesPathResolver.ActiveSession.id)
            if let path = landed {
                result.text = (result.text ?? "") + "\nbrowser_path=\(path)"
            }
        }
        return result
    }

    static func landBrowserArtifact(text: String, sessionId: String?) -> String? {
        let name = "browser_snapshot_\(Int(Date().timeIntervalSince1970)).txt"
        let path = "\(OasesPathResolver.browser)/\(name)"
        do {
            try OasesPathResolver.writeGuestFile(path: path, content: text, sessionId: sessionId)
            return path
        } catch {
            return nil
        }
    }
}

