import Foundation

/// [T-log-redaction] What may reach a log line from a request: a body is reduced
/// to its size and a short head, a secret to its length. Ported from OpenMinis
/// `Shared/LogRedaction.swift`.
///
/// The Debug log used to carry pretty-printed request bodies (up to 3,000
/// characters of chat history, tool output and system prompt per request) and
/// the first 16-20 characters of OAuth access tokens / API keys. Those log files
/// are exported from Settings → Logs and shared, so neither may be in them.
enum LogRedaction {
    /// How much of a request body's head a log line keeps.
    static let bodyHeadChars = 160

    /// A secret reduced to its length.
    static func secret(_ value: String) -> String {
        "<redacted len=\(value.count)>"
    }

    /// Header names whose values are credentials.
    static func isSecretHeader(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == "authorization" || n == "proxy-authorization" || n == "cookie" || n == "set-cookie" {
            return true
        }
        return n.contains("api-key") || n.contains("apikey") || n.contains("token")
            || n.contains("secret") || n.contains("session-key")
    }

    /// `name: value`, with a credential's value replaced by its length.
    static func headerLine(_ name: String, _ value: String) -> String {
        "\(name): \(isSecretHeader(name) ? secret(value) : value)"
    }

    /// `N bytes, head: …` - the body's size and its first `bodyHeadChars`
    /// characters on one line, with token-looking strings scrubbed.
    static func bodySummary(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "0 bytes" }
        let headBytes = data.prefix(bodyHeadChars * 4)
        var head = String(decoding: headBytes, as: UTF8.self)
        if head.count > bodyHeadChars { head = String(head.prefix(bodyHeadChars)) }
        head = scrubTokens(head)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let more = data.count > headBytes.count || head.count >= bodyHeadChars ? "…" : ""
        return "\(data.count) bytes, head: \(head)\(more)"
    }

    /// The top-level keys of a JSON object body, never its values. For token
    /// endpoint responses, whose values ARE the credentials.
    static func jsonKeys(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<\(data.count) bytes, not a JSON object>"
        }
        return object.keys.sorted().joined(separator: ", ")
    }

    private static let tokenPatterns: [(NSRegularExpression, String)] = compile([
        // Bearer first: its token may itself be an sk- key, and scrubbing that
        // first would leave "Bearer sk-***" for the second rule to half-eat.
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer ***"),
        (#"sk-[A-Za-z0-9_\-]{4,}"#, "sk-***"),
    ])

    /// Replaces API-key / bearer-token looking strings.
    static func scrubTokens(_ text: String) -> String {
        apply(tokenPatterns, to: text)
    }

    // MARK: - Export sanitising [T-crash-diag-export]

    private static let exportPatterns: [(NSRegularExpression, String)] = compile([
        // A whole Authorization header value, in a log line or JSON.
        (#"(?i)("?(?:proxy-)?authorization"?\s*[:=]\s*"?)[^"\n]*"#, "$1<redacted>"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer ***"),
        (#"sk-[A-Za-z0-9_\-]{4,}"#, "sk-***"),
        // URL query strings: keep scheme/host/path, drop the parameters
        // (OAuth codes, signed URLs and `?key=` API keys live there).
        (#"(?i)(https?://[^\s?#"'<>]+)\?[^\s"'<>]*"#, "$1?<redacted>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        // Oases-specific: conversation text that older builds wrote into
        // diagnostic lines in Release. `tail="…"` / `head="…"` are the
        // [StreamHang] / [SnapshotDiag] / [HangFix] previews of message text.
        (#"\b(tail|head)="(?:[^"\\]|\\.)*""#, "$1=<omitted>"),
        // [ToolRepair] dumped the first 500 characters of raw tool arguments.
        (#"rawJoined=<<<.*?>>>"#, "rawJoined=<omitted>"),
    ])

    /// Text leaving the device (log export): sk- keys, Bearer tokens and
    /// Authorization values, URL query parameters, e-mail addresses and the
    /// message-text previews of the diagnostic lines above are replaced.
    static func sanitizeForExport(_ text: String) -> String {
        apply(exportPatterns, to: text)
    }

    /// A log file prepared for export: see `LogExportSanitizer`.
    static func sanitizeLogForExport(_ log: String) -> String {
        var sanitizer = LogExportSanitizer()
        var out: [String] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(contentsOf: sanitizer.sanitize(line: String(line)))
        }
        out.append(contentsOf: sanitizer.finish())
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func compile(_ specs: [(String, String)]) -> [(NSRegularExpression, String)] {
        specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }

    private static func apply(_ patterns: [(NSRegularExpression, String)], to text: String) -> String {
        var out = text
        for (regex, template) in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}

/// Line-by-line sanitiser for a daily log file on its way off the device, so a
/// 100 MB log never has to be held (or regex-scanned) as one string.
///
/// LoggingManager prefixes EVERY line it captures with `[HH:mm:ss] `. A line
/// that starts a log entry carries NSLog's date next (`[10:00:00] 2026-11-05
/// 10:00:00.123 OasesChat[…] …`) or, for `writeRawLine`/`print`, a bracketed
/// tag (`[10:00:00] [HangDetector] …`); the continuation lines of a multi-line
/// message carry neither. Every entry that printed a request body keeps its
/// first line and loses the body lines that follow — logs written before
/// [T-log-redaction] carried pretty-printed bodies (chat history, tool output,
/// system prompt) — and the content slices of a [StreamHang] assignedText dump
/// are dropped. Everything that remains goes through `sanitizeForExport`.
struct LogExportSanitizer {
    private static let entryStart = try? NSRegularExpression(
        pattern: #"^\[\d\d:\d\d:\d\d\] (?:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d|\[)"#)

    private var droppingBody = false
    private var droppedLines = 0
    /// Inside a multi-line `rawJoined=<<<…>>>` ([ToolRepair]) payload.
    private var droppingRawJoined = false

    /// Zero or more lines to write in place of `line`.
    mutating func sanitize(line: String) -> [String] {
        if droppingRawJoined {
            if line.contains(">>>") { droppingRawJoined = false }
            return []
        }
        let isEntry = Self.entryStart?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        var out: [String] = []
        if isEntry {
            out.append(contentsOf: flush())
            droppingBody = line.contains("Body (") || line.contains("Full Body")
                || line.contains("📤") || line.contains("Request Body")
            // The full-markdown slices of an assignedText dump are message
            // text by definition; their header line (lengths only) stays.
            if line.contains("[StreamHang]"), line.contains(" slice="), line.contains("│") {
                droppedLines += 1
                return out
            }
        } else if droppingBody {
            droppedLines += 1
            return out
        }
        var kept = line
        if let start = kept.range(of: "rawJoined=<<<"), kept[start.upperBound...].range(of: ">>>") == nil {
            // The payload runs onto the following lines: cut it here and skip
            // until its closing marker.
            kept = String(kept[..<start.lowerBound]) + "rawJoined=<omitted>"
            droppingRawJoined = true
        }
        out.append(LogRedaction.sanitizeForExport(kept))
        return out
    }

    /// Lines still owed at the end of the file.
    mutating func finish() -> [String] {
        flush()
    }

    private mutating func flush() -> [String] {
        defer { droppedLines = 0 }
        return droppedLines > 0 ? ["  <request body / message text omitted: \(droppedLines) lines>"] : []
    }

    /// Writes a sanitised copy of the log at `source` to `destination`,
    /// streaming it in 1 MB chunks.
    static func writeSanitizedCopy(of source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        var sanitizer = LogExportSanitizer()
        var carry = Data()
        func emit(_ lines: [String]) throws {
            guard !lines.isEmpty else { return }
            try writer.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex..<lastNewline]
            carry = Data(carry[carry.index(after: lastNewline)...])
            var lines: [String] = []
            for raw in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
                lines.append(contentsOf: sanitizer.sanitize(line: String(decoding: raw, as: UTF8.self)))
            }
            try emit(lines)
        }
        var tail: [String] = []
        if !carry.isEmpty {
            tail.append(contentsOf: sanitizer.sanitize(line: String(decoding: carry, as: UTF8.self)))
        }
        tail.append(contentsOf: sanitizer.finish())
        try emit(tail)
    }
}
