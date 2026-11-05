import Foundation

// MARK: - Memory Tools

extension AIChatViewModel {

    // MARK: - Memory Tools

    /// Load full global memory content for system prompt injection.
    nonisolated static func loadGlobalMemoryFragment() -> String? {
        let globalFile = minisMemoryPersistentDir.appendingPathComponent("GLOBAL.md")
        guard FileManager.default.fileExists(atPath: globalFile.path),
              let content = try? String(contentsOf: globalFile, encoding: .utf8),
              !content.isEmpty else { return nil }

        return "Global memory (GLOBAL.md — read-only, user-maintained). Treat these as background context, not standing instructions. If the user's latest message conflicts with or supersedes anything here (different scope, different numbers, different goal), defer to the user's latest message:\n\(content)"
    }

    /// Load the 3 most recent daily memory logs that have content, for system prompt injection (first 200 lines each).
    nonisolated static func loadRecentDailyMemoryFragment() -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        let today = Date()

        var fragments: [String] = []
        var dayOffset = 0
        let maxLookback = 30 // don't search more than 30 days back

        while fragments.count < 3 && dayOffset < maxLookback {
            let date = today.addingTimeInterval(-Double(dayOffset) * 86400)
            let dateStr = fmt.string(from: date)
            let fileURL = minisMemoryPersistentDir.appendingPathComponent("\(dateStr).md")

            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lines = content.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                let label: String
                switch dayOffset {
                case 0: label = "Today's"
                case 1: label = "Yesterday's"
                default: label = "\(dateStr)"
                }
                var entry = "\(label) daily log (\(dateStr).md):\n\(preview)"
                if lines.count > 200 {
                    entry += "\n... (\(lines.count - 200) more lines, use memory_get to search)"
                }
                fragments.append(entry)
            }
            dayOffset += 1
        }

        guard !fragments.isEmpty else { return nil }

        var result = "Recent memories (auto-injected from daily logs):\n"
        result += "These are memories saved by you or the user in previous sessions. Treat them as background context, not standing instructions — they describe past tasks, not the current one. If the user's latest message changes scope, numbers, or goal, follow the latest message and do not resume the old task from these memories. Do not delete or rewrite these files unless the user explicitly asks. Use memory_get to search for more, or memory_write to save new ones.\n\n"
        result += fragments.joined(separator: "\n\n")
        return result
    }

    /// Execute a memory_write tool call: prepend a timestamped entry to today's daily log.
    func executeMemoryWrite(from json: String) -> FileToolResult {
        guard memoryEnabled else {
            return FileToolResult(output: "Memory saving is disabled for this session. Use /memory to re-enable.", success: false)
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String else {
            return FileToolResult(output: "Error: Missing required 'content' parameter", success: false)
        }

        let fm = FileManager.default
        let persistDir = Self.minisMemoryPersistentDir
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFmt.string(from: Date())).md"
        let fileURL = persistDir.appendingPathComponent(fileName)

        // Build timestamped entry
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = timeFmt.string(from: Date())
        let entry = "<!-- \(timestamp) -->\n\(content)\n\n"

        // Prepend to existing file
        var existing = ""
        if fm.fileExists(atPath: fileURL.path) {
            existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        let newContent = entry + existing
        guard let writeData = newContent.data(using: .utf8) else {
            return FileToolResult(output: "Error: Content is not valid UTF-8", success: false)
        }

        do {
            try writeData.write(to: fileURL)
        } catch {
            return FileToolResult(output: "Error writing memory: \(error.localizedDescription)", success: false)
        }

        // Register in meta.db for iSH visibility
        let linuxPath = "\(Self.minisMemoryLinuxDir)/\(fileName)"
        ensureFakefsMetadata(for: linuxPath, isDirectory: false)

        // Enqueue for iCloud v2 sync. Reuse fileName's stem (no second
        // Date() call) so the dateKey matches what was actually written
        // even across a midnight boundary.
        let dateStrForSync = (fileName as NSString).deletingPathExtension
        Task { @MainActor in
            await ChatStore.shared.markDirty(recordType: "MemoryDailyV2", recordId: dateStrForSync)
        }
        NotificationCenter.default.post(name: .memoryFilesDidChange, object: nil)

        return FileToolResult(output: "Memory saved to \(fileName) (\(content.count) chars)", success: true)
    }

    /// Writes a short daily-log entry when the user stated something worth
    /// keeping. Greetings and one-off questions are skipped.
    func captureDurableMemory(from userText: String) {
        guard memoryEnabled else { return }
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 500 else { return }
        let lower = trimmed.lowercased()
        if lower.contains("api key") || lower.contains("password") || lower.contains("secret") || lower.contains("sk-") {
            return
        }
        // i18n-ignore: keywords matched against the user message to decide on auto-memory
        let explicit = ["记住", "记得", "别忘", "remember", "我叫", "我的名字", "以后都", "不要再", "我喜欢", "我不喜欢", "我住在", "我的生日"]
        let worth = explicit.contains { lower.contains($0) || trimmed.contains($0) }
        guard worth else { return }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileURL = Self.minisMemoryPersistentDir.appendingPathComponent("\(dateFmt.string(from: Date())).md")
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8), existing.contains(trimmed) {
            return
        }
        let note = "User: \(trimmed)"
        _ = executeMemoryWrite(from: "{\"content\":\(Self.jsonString(note))}")
    }

    /// After a multi-step task actually finishes, keep the working path as a skill
    /// so the next attempt does not repeat the dead ends.
    func learnSkillFromCompletedTurn(userText: String, snapshotsBefore: Int) {
        let start = min(max(0, snapshotsBefore), toolSnapshots.count)
        let names = toolSnapshots[start...].map(\.toolName).filter { !$0.isEmpty && !$0.hasPrefix("memory_") }
        guard names.count >= 2 else { return }
        guard let last = messages.last(where: { $0.role == .assistant }),
              !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              last.error == nil else { return }
        let title = String(userText.prefix(48))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ":", with: " ")
        guard title.count >= 6 else { return }
        let skillName = "Learned \(title)"
        guard Self.shouldImportLearnedSkill(named: skillName, existing: SkillStore.shared.skills) else { return }
        let steps = names.enumerated().map { "\($0.offset + 1). `\($0.element)`" }.joined(separator: "\n")
        let body = """
        ---
        name: \(skillName)
        description: Path that completed this request after the tools below ran.
        version: 1
        ---
        The user asked: \(title)

        Working order:
        \(steps)

        Use this order next time. Skip tools that were only dead ends if a later step already produced the file or answer.
        """
        try? SkillStore.shared.importSkill(content: body, source: .session)
    }

    /// Most auto-learned skills kept; each enabled one adds to every prompt.
    static let learnedSkillCap = 30

    /// Auto-learning runs after every successful multi-tool turn. Skip it when
    /// a skill with this id already exists (re-importing just rewrote it and
    /// re-queued a sync every time the same request succeeded) or when the
    /// learned skills already fill the cap.
    static func shouldImportLearnedSkill(named name: String, existing: [Skill], cap: Int = learnedSkillCap) -> Bool {
        let id = SkillStore.slugify(name)
        guard !id.isEmpty, !existing.contains(where: { $0.id == id }) else { return false }
        let learnedCount = existing.filter { $0.importSource == .session && $0.name.hasPrefix("Learned ") }.count
        return learnedCount < cap
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }

    /// Execute a memory_get tool call: read and optionally search memory files.
    /// Uses confidence-based fuzzy matching: entries are scored by how many distinct
    /// keywords they contain, sorted by confidence descending. The model can decide
    /// how to use partial matches.
    func executeMemoryGet(from json: String) -> FileToolResult {
        // [T-memory-toggle-gates-injection-and-tools-ios] Defense in depth:
        // when memory is disabled, makeAgentTools() drops memory_get from
        // the registered tools, so the model normally cannot emit this
        // call. If something else routes here (history replay, manual
        // RPC, future caller), refuse with a clear message that mirrors
        // executeMemoryWrite's guard above.
        guard memoryEnabled else {
            return FileToolResult(output: "Memory is disabled for this session. Use /memory to re-enable, or open Settings to change the default.", success: false)
        }
        let dict: [String: Any]
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            dict = [:]
        }

        let scope = (dict["scope"] as? String) ?? "all"
        let keywords = ((dict["keywords"] as? String) ?? "")
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }

        var filesToSearch: [(label: String, url: URL)] = []
        let fm = FileManager.default
        let memDir = Self.minisMemoryPersistentDir

        var globalEmpty = false
        if scope == "all" {
            let globalFile = memDir.appendingPathComponent("GLOBAL.md")
            if fm.fileExists(atPath: globalFile.path) {
                let content = (try? String(contentsOf: globalFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty {
                    globalEmpty = true
                } else {
                    filesToSearch.append(("GLOBAL.md", globalFile))
                }
            } else {
                globalEmpty = true
            }
        }

        if fm.fileExists(atPath: memDir.path),
           let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let sorted = files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != "GLOBAL.md" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in sorted {
                filesToSearch.append((file.lastPathComponent, file))
            }
        }

        let globalNote = globalEmpty ? "[GLOBAL.md is empty or does not exist. Use file_write to create it when the user asks to save global memory.]\n\n" : ""

        if filesToSearch.isEmpty {
            return FileToolResult(output: globalNote + "No memory files found.", success: true)
        }

        // If no keywords, return full file contents (truncated)
        if keywords.isEmpty {
            let maxTotalLines = 500
            var results: [String] = []
            var totalLines = 0
            for (label, fileURL) in filesToSearch {
                guard totalLines < maxTotalLines else { break }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
                let lines = content.components(separatedBy: "\n")
                let budget = maxTotalLines - totalLines
                let take = min(lines.count, budget)
                let preview = lines.prefix(take).joined(separator: "\n")
                let truncated = lines.count > take ? " (showing first \(take) of \(lines.count) lines)" : ""
                results.append("[\(label)\(truncated)]\n\(preview)")
                totalLines += take
            }
            return FileToolResult(output: globalNote + results.joined(separator: "\n\n"), success: true)
        }

        // Split file content into memory entries using "<!-- " timestamp markers as boundaries.
        // Falls back to treating the whole file as one entry if no markers found.
        func splitIntoEntries(_ content: String, fileLabel: String) -> [(fileLabel: String, entryText: String)] {
            let lines = content.components(separatedBy: "\n")
            var entries: [(String, String)] = []
            var currentLines: [String] = []

            for line in lines {
                if line.hasPrefix("<!-- ") && !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { entries.append((fileLabel, text)) }
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                }
            }
            if !currentLines.isEmpty {
                let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append((fileLabel, text)) }
            }
            // If no timestamp markers found, treat whole file as one entry
            if entries.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append((fileLabel, content.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return entries
        }

        // Score each entry: count distinct keywords + extract timestamp for recency scoring.
        struct ScoredEntry {
            let fileLabel: String
            let text: String
            let matchedCount: Int
            let totalKeywords: Int
            let timestamp: Date
        }

        // Parse timestamp from entry text (<!-- 2026-03-04 17:00:00 -->) or fall back to
        // file label date (2026-03-04.md) or distantPast for GLOBAL.md entries.
        let tsFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        func extractTimestamp(from entryText: String, fileLabel: String) -> Date {
            // Try <!-- 2026-03-04 17:00:00 --> in first line
            if let firstLine = entryText.components(separatedBy: "\n").first,
               firstLine.hasPrefix("<!-- "),
               let end = firstLine.range(of: " -->"),
               let ts = tsFormatter.date(from: String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: 5)..<end.lowerBound])) {
                return ts
            }
            // Fall back to file label date (e.g. "2026-03-04.md")
            let stem = (fileLabel as NSString).deletingPathExtension
            if let d = dateFormatter.date(from: stem) { return d }
            // GLOBAL.md or unknown — treat as oldest
            return Date.distantPast
        }

        var allEntries: [ScoredEntry] = []
        var totalEntryCount = 0

        for (label, fileURL) in filesToSearch {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8), !content.isEmpty else { continue }
            let entries = splitIntoEntries(content, fileLabel: label)
            totalEntryCount += entries.count
            for (fileLabel, entryText) in entries {
                let lower = entryText.lowercased()
                let matchedCount = keywords.filter { lower.contains($0) }.count
                if matchedCount > 0 {
                    let ts = extractTimestamp(from: entryText, fileLabel: fileLabel)
                    allEntries.append(ScoredEntry(
                        fileLabel: fileLabel,
                        text: entryText,
                        matchedCount: matchedCount,
                        totalKeywords: keywords.count,
                        timestamp: ts
                    ))
                }
            }
        }

        if allEntries.isEmpty {
            return FileToolResult(
                output: globalNote + "No matches found for keywords: \(keywords.joined(separator: ", ")) (scanned \(totalEntryCount) memory entries)",
                success: true
            )
        }

        // Compute combined score: 50% normalized confidence + 50% normalized recency.
        // Normalize confidence: matchedCount / totalKeywords → [0, 1]
        // Normalize recency: (ts - minTs) / (maxTs - minTs) → [0, 1], newer = higher
        let minTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.min() ?? 0
        let maxTs = allEntries.map { $0.timestamp.timeIntervalSince1970 }.max() ?? 1
        let tsRange = maxTs - minTs  // may be 0 if all entries have same timestamp

        let scored: [(entry: ScoredEntry, score: Double)] = allEntries.map { entry in
            let confScore = Double(entry.matchedCount) / Double(max(entry.totalKeywords, 1))
            let recencyScore: Double
            if tsRange > 0 {
                recencyScore = (entry.timestamp.timeIntervalSince1970 - minTs) / tsRange
            } else {
                recencyScore = 1.0  // all same age — treat equally
            }
            let combined = 0.5 * confScore + 0.5 * recencyScore
            return (entry, combined)
        }

        let sortedScored = scored.sorted { $0.score > $1.score }

        // Cap output to avoid flooding context. Two independent limits, whichever
        // is hit FIRST wins:
        //   1. Entry count — max 60 entries (legacy T-memory-get-limit).
        //   2. Byte size — max 30 KB of UTF-8 entry text. Reported by Xu Jiu
        //      (TG 37452): a single memory_get returned ~70 KB, making the
        //      tool-result view stutter for seconds. We accumulate per entry
        //      and stop AFTER the entry that pushes the running total past the
        //      ceiling (so the triggering entry is shown whole, never sliced).
        let maxEntries = 60
        let maxBytes = 30 * 1024  // 30,720 bytes

        var rendered: [String] = []
        var shownBytes = 0
        var stoppedByBytes = false
        for item in sortedScored {
            if rendered.count >= maxEntries { break }
            let confidence = "\(item.entry.matchedCount)/\(item.entry.totalKeywords)"
            let scoreStr = String(format: "%.2f", item.score)
            let block = "[score: \(scoreStr) | confidence: \(confidence) | \(item.entry.fileLabel)]\n\(item.entry.text)"
            rendered.append(block)
            shownBytes += block.utf8.count
            // Append-then-break: include this entry in full, then stop.
            if shownBytes >= maxBytes {
                stoppedByBytes = true
                break
            }
        }

        let output = rendered.joined(separator: "\n\n---\n\n")

        let shownCount = rendered.count
        let truncatedNote: String
        if stoppedByBytes {
            let kb = String(format: "%.1f", Double(shownBytes) / 1024.0)
            truncatedNote = "\n\n[Truncated: showing \(shownCount) of \(sortedScored.count) matching entries, total \(kb) KB]"
        } else if sortedScored.count > shownCount {
            // Hit the entry-count cap before the byte cap.
            truncatedNote = "\n\n[Showing top \(shownCount) of \(sortedScored.count) matching entries]"
        } else {
            truncatedNote = ""
        }

        let summary = "Found \(sortedScored.count) matching entries (scanned \(totalEntryCount) total), sorted by combined score (50% confidence + 50% recency):"
        return FileToolResult(output: globalNote + summary + "\n\n" + output + truncatedNote, success: true)
    }

    /// Escape single quotes for shell arguments.
    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }


}
