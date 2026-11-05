import Foundation

// MARK: - Deliverable

/// A file Ogent produced for the user during a run: something it wrote under
/// the session's user-facing `/var/minis` folders (workspace, attachments,
/// shared, mounted folders). Surfaced as a file card on the console's
/// activity rail once the run finishes.
struct OgentDeliverable: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case video, image, audio, html, pdf, code, other
    }

    /// `minis://<namespace>/<percent-encoded path>` — the same form the shell
    /// tool reports and `AIChatView.handleMinisURLTap` opens.
    let minisURL: String
    let fileName: String
    let kind: Kind
    let producedAt: Date
    /// 1-based index of the run (user turn) that produced it. A run starts at
    /// a non-queued user message; files before the first user message are run 0.
    let runIndex: Int

    var id: String { minisURL }

    /// `/var/minis/<namespace>/<path>` — what the agent and the terminal see.
    var linuxPath: String? { OgentDeliverableLedger.linuxPath(forMinisURL: minisURL) }
}

// MARK: - Run

/// One run of the agent: the tool steps between a user message and the next.
struct OgentRun {
    enum Outcome: Equatable {
        /// The run is still going (the view model is processing it).
        case active
        case success
        case failed
        case cancelled
    }

    /// Same numbering as `OgentDeliverable.runIndex`.
    let runIndex: Int
    /// Tool blocks of the run, oldest first.
    let steps: [AssistantBlock]
    /// Assistant messages of the run, oldest first.
    let assistantMessages: [ChatMessage]
    /// True when this is the run after the most recent user message.
    let isLatest: Bool
}

// MARK: - Ledger

/// Pure bookkeeping behind the console rail: which files a run produced, and
/// which run the rail should describe. No view-model state — everything is
/// derived from the message list, so a session reload rebuilds the exact same
/// answer the live run produced.
enum OgentDeliverableLedger {
    /// Header the shell tool appends to its model-facing output after diffing
    /// `/var/minis` (`AIChatViewModel+ConcurrentTools`).
    static let sectionHeader = "[minis] New/modified files:"

    /// Namespaces whose files are things made for the user. `offloads`
    /// (truncated tool output) and `browser` (screenshots) are internal, as are
    /// the agent's own `memory`, `skills` and `mcp-servers`.
    static let deliverableNamespaces: Set<String> = ["workspace", "attachments", "shared", "mounts"]
    /// Relative-path prefixes inside allowed namespaces that are not outputs.
    /// `attachments/uploads/` holds the files the user attached.
    static let excludedPathPrefixes = ["attachments/uploads/"]
    /// Build/cache folders: a `pip install` or `npm install` in the workspace
    /// would otherwise flood the rail with thousands of "new files".
    static let noiseDirectories: Set<String> = [
        "node_modules", ".git", "__pycache__", ".venv", "venv", "site-packages",
        ".cache", ".npm", ".pytest_cache", ".mypy_cache",
    ]
    static let noiseExtensions: Set<String> = ["pyc", "pyo", "o", "tmp", "swp", "part", "crdownload"]
    /// Most recent deliverables kept per session.
    static let maxTracked = 200

    static let codeExtensions: Set<String> = [
        "py", "js", "mjs", "cjs", "ts", "jsx", "tsx", "swift", "c", "cc", "cpp", "h", "hpp",
        "rs", "go", "java", "kt", "rb", "php", "sh", "bash", "zsh", "css", "scss", "sql",
        "json", "yaml", "yml", "toml", "xml", "lua", "r", "ipynb",
    ]

    // MARK: Parsing

    /// The `minis://` URLs listed in a shell tool's `[minis] New/modified
    /// files:` section, in listed order. Reads only the last such section and
    /// stops at the first line that is not a `minis://` entry, so output that
    /// merely echoes the header text cannot inject entries.
    static func minisURLs(inToolOutput output: String) -> [String] {
        guard let header = output.range(of: sectionHeader, options: .backwards) else { return [] }
        var urls: [String] = []
        var isFirst = true
        for line in output[header.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if isFirst {
                // Remainder of the header line itself.
                isFirst = false
                continue
            }
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("minis://") else { break }
            urls.append(entry)
        }
        return urls
    }

    /// `minis://` URL for a guest path, or nil when the path is outside
    /// `/var/minis/<namespace>/`. Mirrors `AIChatViewModel.linuxPathToMinisURL`
    /// so live and reloaded entries compare equal. Already-`minis://` input is
    /// returned unchanged.
    static func minisURL(forPath path: String) -> String? {
        if path.hasPrefix("minis://") { return path }
        let prefix = "/var/minis/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let namespace = String(rest[rest.startIndex..<slash])
        let filename = String(rest[rest.index(after: slash)...])
        guard !namespace.isEmpty, !filename.isEmpty else { return nil }
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return "minis://\(namespace)/\(encoded)"
    }

    /// `(namespace, decoded relative path)` of a `minis://` URL.
    static func components(ofMinisURL minisURL: String) -> (namespace: String, path: String)? {
        let scheme = "minis://"
        guard minisURL.hasPrefix(scheme) else { return nil }
        let rest = minisURL.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let namespace = String(rest[rest.startIndex..<slash])
        let encodedPath = String(rest[rest.index(after: slash)...])
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        guard !namespace.isEmpty, !path.isEmpty else { return nil }
        return (namespace, path)
    }

    static func linuxPath(forMinisURL minisURL: String) -> String? {
        guard let parts = components(ofMinisURL: minisURL) else { return nil }
        return "/var/minis/\(parts.namespace)/\(parts.path)"
    }

    /// Whether a `minis://` URL names a user-facing output.
    static func isDeliverable(minisURL: String) -> Bool {
        guard let (namespace, path) = components(ofMinisURL: minisURL),
              deliverableNamespaces.contains(namespace) else { return false }
        let relative = "\(namespace)/\(path)"
        if excludedPathPrefixes.contains(where: { relative.hasPrefix($0) }) { return false }
        let pieces = path.split(separator: "/")
        guard let last = pieces.last, !last.hasPrefix(".") else { return false }
        if pieces.dropLast().contains(where: { noiseDirectories.contains(String($0)) }) { return false }
        let ext = (String(last) as NSString).pathExtension.lowercased()
        return !noiseExtensions.contains(ext)
    }

    static func kind(forFileName name: String) -> OgentDeliverable.Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if minisVideoExtensions.contains(ext) { return .video }
        if minisImageExtensions.contains(ext) { return .image }
        if minisAudioExtensions.contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if minisHTMLExtensions.contains(ext) { return .html }
        if codeExtensions.contains(ext) { return .code }
        return .other
    }

    static func makeDeliverable(minisURL: String, producedAt: Date, runIndex: Int) -> OgentDeliverable? {
        guard isDeliverable(minisURL: minisURL),
              let (_, path) = components(ofMinisURL: minisURL) else { return nil }
        let name = (path as NSString).lastPathComponent
        return OgentDeliverable(
            minisURL: minisURL,
            fileName: name,
            kind: kind(forFileName: name),
            producedAt: producedAt,
            runIndex: runIndex
        )
    }

    // MARK: Collection

    /// Files a finished tool block produced, as `minis://` URLs (unfiltered).
    ///
    /// Live shell blocks carry `producedMinisURLs` (set from the `/var/minis`
    /// diff when the command ends); reloaded shell blocks parse the persisted
    /// output, which carries the same list in its `[minis]` section. The parse
    /// result is memoized on the block. `file_write` / `file_edit` produce
    /// their target path when they succeed.
    static func producedURLs(of block: AssistantBlock) -> [String] {
        if let cached = block.producedMinisURLs { return cached }
        guard let status = block.toolStatus else { return [] }
        switch status {
        case .streaming, .running:
            return []
        case .success, .failed, .cancelled:
            break
        }
        let urls: [String]
        switch block.kind {
        case .shellTool:
            urls = minisURLs(inToolOutput: block.content)
        case .fileWriteTool(let path), .fileEditTool(let path):
            urls = status == .success ? [minisURL(forPath: path)].compactMap { $0 } : []
        default:
            urls = []
        }
        block.producedMinisURLs = urls
        return urls
    }

    /// Every deliverable in the session, oldest first, one entry per file:
    /// a file produced again later keeps only its latest production (so it
    /// belongs to the run that last touched it).
    static func collect(from messages: [ChatMessage]) -> [OgentDeliverable] {
        var items: [OgentDeliverable] = []
        var run = 0
        for message in messages {
            switch message.role {
            case .user:
                if !message.isQueued { run += 1 }
            case .assistant:
                for block in message.blocks where block.toolStatus != nil {
                    let urls = producedURLs(of: block)
                    guard !urls.isEmpty else { continue }
                    let producedAt = block.toolStartTime.map { $0.addingTimeInterval(block.toolDuration ?? 0) }
                        ?? message.timestamp
                    for url in urls {
                        if let item = makeDeliverable(minisURL: url, producedAt: producedAt, runIndex: run) {
                            items.append(item)
                        }
                    }
                }
            case .compactDivider, .systemInfo:
                continue
            }
        }
        return Array(dedupeKeepingLatest(items).suffix(maxTracked))
    }

    /// Drop earlier entries for a URL that appears again; order is preserved.
    static func dedupeKeepingLatest(_ items: [OgentDeliverable]) -> [OgentDeliverable] {
        var seen = Set<String>()
        var kept: [OgentDeliverable] = []
        for item in items.reversed() where seen.insert(item.minisURL).inserted {
            kept.append(item)
        }
        return kept.reversed()
    }

    /// Run number of the message at `index`: the count of non-queued user
    /// messages before it.
    static func runIndex(forMessageAt index: Int, in messages: [ChatMessage]) -> Int {
        messages.prefix(max(0, min(index, messages.count)))
            .reduce(0) { $0 + (($1.role == .user && !$1.isQueued) ? 1 : 0) }
    }

    /// Number of the run after the most recent user message.
    static func currentRunIndex(in messages: [ChatMessage]) -> Int {
        runIndex(forMessageAt: messages.count, in: messages)
    }

    /// Deliverables of one run, newest first.
    static func deliverables(_ all: [OgentDeliverable], inRun runIndex: Int) -> [OgentDeliverable] {
        all.filter { $0.runIndex == runIndex }.reversed()
    }

    /// Deliverables of the run after the most recent user message, newest first.
    static func thisRunDeliverables(_ all: [OgentDeliverable], messages: [ChatMessage]) -> [OgentDeliverable] {
        deliverables(all, inRun: currentRunIndex(in: messages))
    }

    // MARK: Runs

    /// The run the console rail should describe, or nil when the session has
    /// never called a tool (plain Q&A needs no rail).
    ///
    /// - While processing: the current run, even before its first tool call
    ///   (the rail then shows a thinking state instead of the previous run).
    /// - Idle: the most recent run that called tools, so a follow-up text-only
    ///   exchange keeps the last run's summary and files reachable.
    static func latestRun(in messages: [ChatMessage], isProcessing: Bool) -> OgentRun? {
        var runIndex = currentRunIndex(in: messages)
        var steps: [AssistantBlock] = []
        var assistants: [ChatMessage] = []
        var isLatest = true
        var pendingEmptyCurrentRun: OgentRun?
        var i = messages.count - 1
        while true {
            let atBoundary = i < 0 || (messages[i].role == .user && !messages[i].isQueued)
            if atBoundary {
                let run = OgentRun(
                    runIndex: runIndex,
                    steps: steps.reversed(),
                    assistantMessages: assistants.reversed(),
                    isLatest: isLatest
                )
                if !run.steps.isEmpty {
                    return pendingEmptyCurrentRun ?? run
                }
                if isLatest && isProcessing { pendingEmptyCurrentRun = run }
                // A session that never called a tool still gets the rail while it works (the
                // thinking mind lives there); it goes away again when the run ends.
                if i < 0 { return pendingEmptyCurrentRun }
                runIndex -= 1
                steps.removeAll()
                assistants.removeAll()
                isLatest = false
                i -= 1
                continue
            }
            let message = messages[i]
            if message.role == .assistant && !message.isCompactedHistory {
                assistants.append(message)
                for block in message.blocks.reversed() where block.toolStatus != nil {
                    steps.append(block)
                }
            }
            i -= 1
        }
    }

    static func outcome(of run: OgentRun, isProcessing: Bool) -> OgentRun.Outcome {
        if run.isLatest && isProcessing { return .active }
        if run.assistantMessages.contains(where: { $0.error != nil }) { return .failed }
        let interrupted = run.steps.contains { step in
            switch step.toolStatus {
            case .streaming, .running: return true
            default: return false
            }
        }
        if interrupted { return .cancelled }
        if case .cancelled = run.steps.last?.toolStatus { return .cancelled }
        return .success
    }

    /// Step shown by default: the one executing now, else the latest.
    static func defaultStepIndex(in steps: [AssistantBlock]) -> Int? {
        if let live = steps.lastIndex(where: { step in
            switch step.toolStatus {
            case .streaming, .running: return true
            default: return false
            }
        }) {
            return live
        }
        return steps.isEmpty ? nil : steps.count - 1
    }

    /// Time the run's tools took. Wall-clock union of the step intervals when
    /// every step has a start time (live session), so parallel tools are not
    /// double counted; the sum of recorded durations otherwise (reloaded
    /// sessions persist durations, not start times). The two agree for
    /// sequential runs.
    static func duration(of steps: [AssistantBlock], now: Date = Date()) -> TimeInterval {
        let intervals: [(start: Date, end: Date)] = steps.compactMap { step in
            guard let start = step.toolStartTime else { return nil }
            let end = step.toolDuration.map { start.addingTimeInterval($0) } ?? max(start, now)
            return (start, end)
        }
        guard !steps.isEmpty, intervals.count == steps.count else {
            return steps.reduce(0) { $0 + max(0, $1.toolDuration ?? 0) }
        }
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = (open.start, max(open.end, interval.end))
            } else {
                if let open = current { total += open.end.timeIntervalSince(open.start) }
                current = interval
            }
        }
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        return total
    }
}

// MARK: - Console text

enum OgentConsoleText {
    /// Last meaningful line of streamed shell output, for the rail's live tail:
    /// ANSI escapes and control characters removed, carriage-return progress
    /// lines (ffmpeg, curl) reduced to their latest segment, placeholder lines
    /// skipped. Scans only the final `scanLimit` characters.
    static func lastMeaningfulLine(of text: String, scanLimit: Int = 4096, maxLength: Int = 240) -> String? {
        guard !text.isEmpty else { return nil }
        let executingPlaceholder = ToolCardPlaceholder.executing
        let tail = text.utf8.count > scanLimit ? text.suffix(scanLimit) : Substring(text)
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let segments = stripANSI(String(rawLine)).split(separator: "\r", omittingEmptySubsequences: true)
            for segment in segments.reversed() {
                let line = segment.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty,
                      line != "Executing...",
                      line != executingPlaceholder,
                      !line.hasPrefix("…[output truncated]…") else { continue }
                return line.count > maxLength ? String(line.suffix(maxLength)) : line
            }
        }
        return nil
    }

    /// Removes CSI / OSC / two-byte escape sequences and C0/C1 controls
    /// (tab becomes a space; `\r` is kept for progress-line handling).
    static func stripANSI(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {
                let next = i + 1
                guard next < scalars.count else { break }
                let n = scalars[next].value
                if n == 0x5B { // CSI: ESC [ ... final byte 0x40–0x7E
                    var j = next + 1
                    while j < scalars.count {
                        let c = scalars[j].value
                        j += 1
                        if c >= 0x40 && c <= 0x7E { break }
                    }
                    i = j
                } else if n == 0x5D { // OSC: ESC ] ... BEL | ESC \
                    var j = next + 1
                    while j < scalars.count {
                        let c = scalars[j].value
                        if c == 0x07 { j += 1; break }
                        if c == 0x1B, j + 1 < scalars.count, scalars[j + 1].value == 0x5C { j += 2; break }
                        j += 1
                    }
                    i = j
                } else {
                    i = next + 1
                }
                continue
            }
            if v == 0x09 {
                out.append(" ")
            } else if v == 0x0D {
                out.append(scalars[i])
            } else if v >= 0x20 && v != 0x7F && !(v >= 0x80 && v <= 0x9F) {
                out.append(scalars[i])
            }
            i += 1
        }
        return String(out)
    }
}
