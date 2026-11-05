import Foundation

/// OpenMinis-aligned file tools: absolute Linux paths under the iSH rootfs
/// (`/var/oases/*`, `/root/.ogent/*`, …). Faster and safer than shell for
/// text file I/O; shell still sees the same files via fakefs `data/`.

// MARK: - Shared helpers

private enum LinuxFileToolSupport {
    static let defaultMaxLength = 15_000
    static let hardMaxLength = 80_000

    static func parseArgs(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func toolTitle(from args: [String: Any]) -> String? {
        let raw = (args["tool_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    static func resolveExisting(_ guestPath: String) throws -> (guest: String, host: URL) {
        guard let guest = OasesPathResolver.normalizeGuestPath(guestPath),
              let host = OasesPathResolver.hostURL(forGuest: guest, sessionId: OasesPathResolver.ActiveSession.id) else {
            throw OasesPathResolver.PathError.invalidPath(guestPath)
        }
        guard FileManager.default.fileExists(atPath: host.path) else {
            throw OasesPathResolver.PathError.notFound(guest)
        }
        return (guest, host)
    }

    static func resolveWritable(_ guestPath: String, createDirs: Bool) throws -> (guest: String, host: URL) {
        guard let guest = OasesPathResolver.normalizeGuestPath(guestPath),
              let host = OasesPathResolver.hostURL(forGuest: guest, sessionId: OasesPathResolver.ActiveSession.id) else {
            throw OasesPathResolver.PathError.invalidPath(guestPath)
        }
        if createDirs {
            try OasesPathResolver.ensureParentDirectories(forGuestFile: guest)
        } else {
            let parent = host.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try OasesPathResolver.ensureParentDirectories(forGuestFile: guest)
            }
        }
        return (guest, host)
    }

    static func isBinary(_ data: Data) -> Bool {
        let sample = data.prefix(512)
        return sample.contains(0)
    }

    static func findAllRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchFrom = haystack.startIndex
        while searchFrom < haystack.endIndex,
              let found = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            ranges.append(found)
            searchFrom = found.upperBound
        }
        return ranges
    }
}

// MARK: - Bounded reads

/// File reads for the file_read tools that never load more than a bounded
/// window: the guest can hold multi-GB files (GGUF models) and
/// `Data(contentsOf:)` would pull all of it into memory. Files up to
/// `wholeFileLimit` are read whole, so line numbers and totals stay exact.
/// Larger files go through a FileHandle: binary detection from the first 512
/// bytes, a head window streamed from the requested line, or a tail window
/// from the end — at most `windowBytes` of content either way.
enum BoundedFileReader {
    static let wholeFileLimit = 8 * 1024 * 1024
    /// Content bytes read from a large file (well above the 80k-char cap).
    static let windowBytes = 1024 * 1024
    /// How far into a large file an `offset` read may scan for its line.
    static let maxScanBytes = 256 * 1024 * 1024

    enum ReadError: LocalizedError {
        case offsetBeyondScanLimit(line: Int)

        var errorDescription: String? {
            switch self {
            case .offsetBeyondScanLimit(let line):
                return "line \(line) is more than \(BoundedFileReader.maxScanBytes / (1024 * 1024)) MB into this large file; use direction=tail or shell tools (sed -n, tail) instead."
            }
        }
    }

    struct Selection {
        let fileSize: Int
        /// Hex of the first 64 bytes when the file looks binary.
        let binaryHexPreview: String?
        /// False when the selected bytes are not UTF-8 text.
        let isText: Bool
        let content: String
        /// Content was cut at `maxLength` characters.
        let truncated: Bool
        /// 1-based line range shown; nil for a tail window of a large file.
        let displayStart: Int?
        let displayEnd: Int?
        /// Total line count; nil when the file was too large to count.
        let totalLines: Int?
        /// Lines shown (used for large-file tail headers).
        let lineCount: Int
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// Selects lines like the tools always did: `offset` (1-based) plus up
    /// to `maxLines` from the head, or the last `maxLines` when `tail`, then
    /// cuts the joined text at `maxLength` characters.
    static func read(_ url: URL, offset: Int, maxLines: Int?, maxLength: Int, tail: Bool) throws -> Selection {
        let size = fileSize(url) ?? 0
        if size <= wholeFileLimit {
            return try readWhole(url, offset: offset, maxLines: maxLines, maxLength: maxLength, tail: tail)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = try handle.read(upToCount: 512) ?? Data()
        if sample.contains(0) {
            return binary(size: size, sample: sample)
        }

        var lines: [String]
        let displayStart: Int?
        if tail {
            let start = max(0, size - windowBytes)
            try handle.seek(toOffset: UInt64(start))
            var window = try handle.read(upToCount: windowBytes) ?? Data()
            // Drop the partial first line of a window that starts mid-file.
            if start > 0, let newline = window.firstIndex(of: 0x0A) {
                window = window.subdata(in: (newline + 1)..<window.endIndex)
            }
            guard let text = decodeUTF8(window) else { return notText(size: size) }
            lines = text.components(separatedBy: "\n")
            lines = Array(lines.suffix(maxLines ?? lines.count))
            displayStart = nil
        } else {
            let startByte = try byteOffset(ofLine: offset, in: handle)
            try handle.seek(toOffset: UInt64(startByte.offset))
            let window = try handle.read(upToCount: windowBytes) ?? Data()
            guard let text = decodeUTF8(window) else { return notText(size: size) }
            lines = window.isEmpty ? [] : text.components(separatedBy: "\n")
            // The window's last line is partial unless it reaches EOF.
            if startByte.offset + window.count < size, lines.count > 1 {
                lines.removeLast()
            }
            lines = Array(lines.prefix(maxLines ?? lines.count))
            displayStart = startByte.line
        }

        let (content, truncated) = cut(lines.joined(separator: "\n"), maxLength: maxLength)
        return Selection(
            fileSize: size,
            binaryHexPreview: nil,
            isText: true,
            content: content,
            truncated: truncated,
            displayStart: displayStart,
            displayEnd: displayStart.map { $0 + lines.count - 1 },
            totalLines: nil,
            lineCount: lines.count
        )
    }

    private static func readWhole(_ url: URL, offset: Int, maxLines: Int?, maxLength: Int, tail: Bool) throws -> Selection {
        let fileData = try Data(contentsOf: url)
        if fileData.prefix(512).contains(0) {
            return binary(size: fileData.count, sample: fileData)
        }
        guard let fullText = String(data: fileData, encoding: .utf8) else {
            return notText(size: fileData.count)
        }
        let allLines = fullText.components(separatedBy: "\n")
        let selected: ArraySlice<String>
        let displayStart: Int
        let displayEnd: Int
        if tail {
            let slice = allLines.suffix(maxLines ?? allLines.count)
            selected = slice
            displayStart = allLines.count - slice.count + 1
            displayEnd = allLines.count
        } else {
            let startIdx = min(offset - 1, allLines.count)
            let limit = maxLines ?? (allLines.count - startIdx)
            let endIdx = min(startIdx + limit, allLines.count)
            selected = allLines[startIdx..<endIdx]
            displayStart = startIdx + 1
            displayEnd = endIdx
        }
        let (content, truncated) = cut(selected.joined(separator: "\n"), maxLength: maxLength)
        return Selection(
            fileSize: fileData.count,
            binaryHexPreview: nil,
            isText: true,
            content: content,
            truncated: truncated,
            displayStart: displayStart,
            displayEnd: displayEnd,
            totalLines: allLines.count,
            lineCount: selected.count
        )
    }

    /// Byte offset where 1-based `line` starts, streaming newlines from the
    /// start of the file. Past EOF it returns the end and the line reached.
    private static func byteOffset(ofLine line: Int, in handle: FileHandle) throws -> (offset: Int, line: Int) {
        guard line > 1 else { return (0, 1) }
        try handle.seek(toOffset: 0)
        var current = 1
        var position = 0
        while position < maxScanBytes {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                return (position, current)
            }
            var index = chunk.startIndex
            while let newline = chunk[index...].firstIndex(of: 0x0A) {
                current += 1
                if current == line {
                    return (position + (newline - chunk.startIndex) + 1, current)
                }
                index = newline + 1
            }
            position += chunk.count
        }
        throw ReadError.offsetBeyondScanLimit(line: line)
    }

    /// UTF-8 text of `data`, tolerating a multi-byte character cut off at
    /// the end of a window.
    private static func decodeUTF8(_ data: Data) -> String? {
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.prefix(data.count - trim), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func cut(_ text: String, maxLength: Int) -> (String, Bool) {
        let limit = max(0, maxLength)
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    private static func binary(size: Int, sample: Data) -> Selection {
        let hex = sample.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        return Selection(fileSize: size, binaryHexPreview: hex, isText: false, content: "", truncated: false,
                         displayStart: nil, displayEnd: nil, totalLines: nil, lineCount: 0)
    }

    private static func notText(size: Int) -> Selection {
        Selection(fileSize: size, binaryHexPreview: nil, isText: false, content: "", truncated: false,
                  displayStart: nil, displayEnd: nil, totalLines: nil, lineCount: 0)
    }
}

// MARK: - file_read

final class LinuxFileReadTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "file_read",
        summary: """
        Read a file from the Linux filesystem (iSH Alpine). Faster than shell_execute \
        for reading files. Absolute Linux paths preferred (e.g. /var/oases/workspace/data.csv). \
        Relative paths resolve under /var/oases/workspace/. Rejects binary files.
        """,
        displayName: "读取文件", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "读取文件", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["path"],"properties":{"tool_title":{"type":"string","description":"Concise 5-10 word summary for the user UI."},"path":{"type":"string","description":"Absolute Linux path or workspace-relative path."},"offset":{"type":"integer","description":"1-based start line (default 1). Ignored when direction=tail."},"lines":{"type":"integer","description":"Max lines to return."},"max_length":{"type":"integer","description":"Max characters (default 15000, hard cap 80000)."},"direction":{"type":"string","enum":["head","tail"],"description":"Read from start (head) or end (tail)."}}}
        """,
        surfaces: [.project],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = LinuxFileToolSupport.parseArgs(argumentsJSON)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .textOnly("Error: Missing required 'path' parameter.")
        }

        do {
            let (guest, host) = try LinuxFileToolSupport.resolveExisting(path)

            let offset = max(1, (args["offset"] as? Int) ?? 1)
            let maxLines = args["lines"] as? Int
            let requested = (args["max_length"] as? Int) ?? LinuxFileToolSupport.defaultMaxLength
            let maxLength = min(max(1, requested), LinuxFileToolSupport.hardMaxLength)
            let direction = ((args["direction"] as? String) ?? "head").lowercased()

            // Bounded: large files (e.g. GGUF models) are never loaded whole.
            let selection = try BoundedFileReader.read(
                host, offset: offset, maxLines: maxLines, maxLength: maxLength, tail: direction == "tail"
            )
            if let hex = selection.binaryHexPreview {
                return .textOnly("[\(guest) | \(selection.fileSize) bytes | binary]\nHex preview: \(hex)")
            }
            guard selection.isText else {
                return .textOnly("Error: \(guest) is not valid UTF-8 text.")
            }
            let content = selection.content
            let truncated = selection.truncated

            var header = "[\(guest) | \(selection.fileSize) bytes | "
            if let total = selection.totalLines, let start = selection.displayStart, let end = selection.displayEnd {
                header += "\(total) lines | showing \(start)-\(end)"
            } else if let start = selection.displayStart, let end = selection.displayEnd {
                header += "large file, lines not counted | showing \(start)-\(end)"
            } else {
                header += "large file, lines not counted | showing last \(selection.lineCount) lines"
            }
            if truncated { header += " (truncated at \(maxLength) chars)" }
            header += "]"
            var body = "\(header)\n\(content)"
            if let oases = OasesPathResolver.oasesURL(forGuest: guest) {
                body += "\noases_url: \(oases)"
            }
            if let title = LinuxFileToolSupport.toolTitle(from: args) {
                body = "\(title)\n\(body)"
            }
            return ToolResult(text: body, truncated: truncated)
        } catch {
            return .textOnly("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - file_write

final class LinuxFileWriteTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "file_write",
        summary: """
        Write content to a file on the Linux filesystem. Absolute Linux paths preferred \
        (e.g. /var/oases/workspace/script.py). Relative paths resolve under /var/oases/workspace/. \
        Creates parent directories when create_dirs is true. Visible to shell_execute.
        """,
        displayName: "写入文件", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "写入文件", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["path","content"],"properties":{"tool_title":{"type":"string","description":"Concise 5-10 word summary for the user UI."},"path":{"type":"string","description":"Absolute Linux path or workspace-relative path."},"content":{"type":"string","description":"UTF-8 text to write."},"append":{"type":"boolean","description":"Append instead of overwrite (default false)."},"create_dirs":{"type":"boolean","description":"Create parent directories (default true)."}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = LinuxFileToolSupport.parseArgs(argumentsJSON)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .textOnly("Error: Missing required 'path' parameter.")
        }
        guard let content = args["content"] as? String else {
            return .textOnly("Error: Missing required 'content' parameter.")
        }
        let append = (args["append"] as? Bool) ?? false
        let createDirs = (args["create_dirs"] as? Bool) ?? true

        do {
            let (guest, host) = try LinuxFileToolSupport.resolveWritable(path, createDirs: createDirs)
            guard let data = content.data(using: .utf8) else {
                return .textOnly("Error: Content is not valid UTF-8.")
            }

            if append, FileManager.default.fileExists(atPath: host.path) {
                let handle = try FileHandle(forWritingTo: host)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                // Sync guest metadata for append path
                if ish_runtime_is_ready() != 0 {
                    // Re-write full file through runtime so meta.db stays consistent.
                    let full = try String(contentsOf: host, encoding: .utf8)
                    try OasesPathResolver.writeGuestFile(path: guest, content: full)
                }
            } else {
                try OasesPathResolver.writeGuestFile(
                    path: guest,
                    content: content,
                    sessionId: OasesPathResolver.ActiveSession.id
                )
                if !FileManager.default.fileExists(atPath: host.path) {
                    try data.write(to: host, options: .atomic)
                }
            }

            let action = append ? "Appended" : "Wrote"
            var summary = "✓ \(action) \(guest) (\(data.count) bytes)"
            if let oases = OasesPathResolver.oasesURL(forGuest: guest) {
                summary += "\noases_url: \(oases)"
            }
            summary += "\n[oases:open]\(host.path)"
            if let title = LinuxFileToolSupport.toolTitle(from: args) {
                summary = "\(title)\n\(summary)"
            }
            return .textOnly(summary)
        } catch {
            return .textOnly("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - file_edit

final class LinuxFileEditTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "file_edit",
        summary: """
        Make targeted edits to an existing Linux file using exact string replacement. \
        ALWAYS file_read first. Prefer file_edit over file_write when modifying existing files. \
        old_string must match exactly one location unless replace_all is true.
        """,
        displayName: "编辑文件", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "编辑文件", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["path","old_string","new_string"],"properties":{"tool_title":{"type":"string","description":"Concise 5-10 word summary for the user UI."},"path":{"type":"string","description":"Absolute Linux path or workspace-relative path."},"old_string":{"type":"string","description":"Exact text to find (must be unique unless replace_all)."},"new_string":{"type":"string","description":"Replacement text (empty deletes)."},"replace_all":{"type":"boolean","description":"Replace all occurrences (default false)."}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = LinuxFileToolSupport.parseArgs(argumentsJSON)
        guard let path = args["path"] as? String, !path.isEmpty else {
            return .textOnly("Error: Missing required 'path' parameter.")
        }
        guard let oldString = args["old_string"] as? String else {
            return .textOnly("Error: Missing required 'old_string' parameter.")
        }
        guard let newString = args["new_string"] as? String else {
            return .textOnly("Error: Missing required 'new_string' parameter.")
        }
        guard !oldString.isEmpty else {
            return .textOnly("Error: old_string must not be empty. Use file_write to create or overwrite files.")
        }
        let replaceAll = (args["replace_all"] as? Bool) ?? false

        do {
            let (guest, host) = try LinuxFileToolSupport.resolveExisting(path)
            // Editing loads the whole file; refuse huge ones instead of
            // pulling e.g. a multi-GB model into memory.
            if let size = BoundedFileReader.fileSize(host), size > BoundedFileReader.wholeFileLimit {
                return .textOnly("Error: \(guest) is \(size) bytes, too large for file_edit (limit \(BoundedFileReader.wholeFileLimit) bytes). Use shell tools (sed) instead.")
            }
            let fileContent = try String(contentsOf: host, encoding: .utf8)
            let ranges = LinuxFileToolSupport.findAllRanges(of: oldString, in: fileContent)

            if ranges.isEmpty {
                let preview = fileContent
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(40)
                    .enumerated()
                    .map { "\($0.offset + 1): \($0.element)" }
                    .joined(separator: "\n")
                return .textOnly(
                    "Error: old_string not found in \(guest). Use file_read before editing.\n\nFile preview (first 40 lines):\n\(preview)"
                )
            }
            if !replaceAll, ranges.count > 1 {
                return .textOnly(
                    "Error: old_string matched \(ranges.count) locations in \(guest). Provide a more unique old_string or set replace_all=true."
                )
            }

            var updated = fileContent
            if replaceAll {
                updated = fileContent.replacingOccurrences(of: oldString, with: newString)
            } else if let only = ranges.first {
                updated.replaceSubrange(only, with: newString)
            }

            try OasesPathResolver.writeGuestFile(path: guest, content: updated)
            if !FileManager.default.fileExists(atPath: host.path) ||
                (try? String(contentsOf: host, encoding: .utf8)) != updated {
                try updated.write(to: host, atomically: true, encoding: .utf8)
            }

            let count = replaceAll ? ranges.count : 1
            var summary = "✓ Edited \(guest) (\(count) replacement\(count == 1 ? "" : "s"))"
            if let oases = OasesPathResolver.oasesURL(forGuest: guest) {
                summary += "\noases_url: \(oases)"
            }
            summary += "\n[oases:open]\(host.path)"
            if let title = LinuxFileToolSupport.toolTitle(from: args) {
                summary = "\(title)\n\(summary)"
            }
            return .textOnly(summary)
        } catch {
            return .textOnly("Error: \(error.localizedDescription)")
        }
    }
}
