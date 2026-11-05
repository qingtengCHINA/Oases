import Foundation

/// OpenMinis-aligned memory tools backed by Oases `MemoryRepository`.
/// Writes land under the global `/var/oases/memory` host tree (and the
/// structured repository) so both shell and agent recall see them.

final class MemoryWriteTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "memory_write",
        summary: """
        Write a durable memory entry for later recall across sessions. Content is stored in the \
        host MemoryRepository and mirrored under /var/oases/memory/ as Markdown. Avoid secrets.
        """,
        displayName: "写入记忆", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "写入记忆", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["content"],"properties":{"tool_title":{"type":"string"},"content":{"type":"string","description":"Memory content (Markdown ok)."},"title":{"type":"string","description":"Optional short title/topic."}}}
        """,
        surfaces: [.project, .chat],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            return .textOnly("Error: Missing required 'content' parameter.")
        }
        let title = ((args["title"] as? String) ?? "Note")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "<!-- \(stamp) -->\n\(content)\n"

        // Mirror to the global guest-visible path for Ogent. Text chat keeps
        // its memories in the repository only and leaves the Linux rootfs alone.
        let mirrorsToGuest = !AgentToolContext.isTextChat
        let day = Self.dayFormatter.string(from: Date())
        let guestPath = "\(OasesPathResolver.memory)/\(day).md"
        if mirrorsToGuest, let host = OasesPathResolver.hostURL(forGuest: guestPath, sessionId: nil) {
            try? FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing = try? String(contentsOf: host, encoding: .utf8) {
                try? (body + "\n" + existing).write(to: host, atomically: true, encoding: .utf8)
            } else {
                try? body.write(to: host, atomically: true, encoding: .utf8)
            }
        }

        let doc = MemoryDocument(
            title: title.isEmpty ? "Note" : title,
            body: content,
            tags: ["memory_write"],
            provenance: MemoryProvenance(source: "oases.memory_write")
        )
        do {
            let saved = try await MemoryRepository.shared.save(doc)
            var out = "✓ memory_write id=\(saved.id.uuidString) title=\(saved.title)"
            if mirrorsToGuest {
                out += "\npath=\(guestPath)"
                if let oases = OasesPathResolver.oasesURL(forGuest: guestPath) {
                    out += "\noases_url: \(oases)"
                }
            }
            return .textOnly(out)
        } catch {
            return .textOnly("Error writing memory: \(error.localizedDescription)")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

final class MemoryGetTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "memory_get",
        summary: """
        Retrieve memories from durable storage. Supports keyword fuzzy search across recent daily \
        logs under /var/oases/memory and the host MemoryRepository.
        """,
        displayName: "读取记忆", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "读取记忆", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{"tool_title":{"type":"string"},"scope":{"type":"string","enum":["daily","all"],"default":"all"},"keywords":{"type":"string","description":"Space-separated keywords; all must match a line/document."}}}
        """,
        surfaces: [.project, .chat],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let keywords = ((args["keywords"] as? String) ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        let scope = ((args["scope"] as? String) ?? "all").lowercased()

        var chunks: [String] = []

        // Daily files under /var/oases/memory (Ogent's copies; text chat
        // reads the repository only).
        if !AgentToolContext.isTextChat,
           let memDir = OasesPathResolver.hostURL(forGuest: OasesPathResolver.memory, sessionId: nil) {
            let files = (try? FileManager.default.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil)) ?? []
            let mdFiles = files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in mdFiles.prefix(14) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if keywords.isEmpty || keywords.allSatisfy({ text.lowercased().contains($0) }) {
                    chunks.append("## \(file.lastPathComponent)\n\(String(text.prefix(4_000)))")
                }
            }
        }

        if scope == "all" || AgentToolContext.isTextChat {
            let docs = (try? await MemoryRepository.shared.all()) ?? []
            for doc in docs.prefix(40) {
                let blob = "\(doc.title)\n\(doc.body)".lowercased()
                if keywords.isEmpty || keywords.allSatisfy({ blob.contains($0) }) {
                    chunks.append("## \(doc.title)\n\(doc.body)")
                }
            }
        }

        if chunks.isEmpty {
            return .textOnly(keywords.isEmpty ? "(no memories yet)" : "(no memories matched keywords)")
        }
        let body = chunks.joined(separator: "\n\n---\n\n")
        let truncated = body.count > 20_000
        return ToolResult(text: truncated ? String(body.prefix(20_000)) : body, truncated: truncated)
    }
}
