import Foundation

/// Translates a meeting's transcript line by line with the notes model (Oases Fast by default).
/// Lines go in numbered batches; each batch is saved as it lands, so a long meeting shows
/// progress and an interrupted run resumes with the lines still missing.
enum MeetingTranslator {
    /// Transcript characters per request (keeps the reply well inside the output limit).
    static let batchCharacters = 3_000

    /// Translates the lines of `meetingID` that have no translation in `languageCode` yet.
    /// Returns the model label.
    @MainActor
    @discardableResult
    static func translate(meetingID: String, to languageCode: String,
                          progress: @MainActor (_ done: Int, _ total: Int) -> Void) async throws -> String {
        guard let meeting = MeetingStore.shared.meeting(meetingID), !meeting.lines.isEmpty else {
            throw MeetingNotesEngine.Failure.emptyTranscript
        }
        guard let resolved = MeetingModelResolver.resolve() else { throw MeetingNotesEngine.Failure.noModel }
        let instance = ProviderConfigStore.shared.instance(for: resolved.entry.providerInstanceId)
        guard (try? LLMProviderFactory.requireDataSharingConsent(for: instance)) != nil else {
            throw MeetingNotesEngine.Failure.consentRequired
        }
        if let denial = MeetingModelResolver.denial(for: resolved) { throw MeetingNotesEngine.Failure.quota(denial) }

        let language = MeetingSettings.notesLanguages.first { $0.code == languageCode }?.english ?? "English"
        let sameLanguage = meeting.translationLanguage == languageCode
        let todo = meeting.lines.filter { !sameLanguage || ($0.translation ?? "").isEmpty }
        if !sameLanguage {
            MeetingStore.shared.update(meetingID, immediately: true) { m in
                m.translationLanguage = languageCode
                for i in m.lines.indices { m.lines[i].translation = nil }
            }
        }
        let total = todo.count
        var done = 0
        progress(done, total)
        for batch in batches(todo) {
            try Task.checkCancellation()
            var translated: [Int: String] = [:]
            for _ in 0..<2 {
                let raw = try await MeetingNotesEngine.complete(entry: resolved.entry, system: prompt(language),
                                                                instruction: numbered(batch))
                translated = parse(raw, count: batch.count)
                if translated.count * 10 >= batch.count * 8 { break }
            }
            guard !translated.isEmpty else { throw MeetingNotesEngine.Failure.unreadableReply }
            MeetingStore.shared.update(meetingID, immediately: true) { m in
                guard m.translationLanguage == languageCode else { return }
                for (i, line) in batch.enumerated() {
                    guard let text = translated[i + 1],
                          let index = m.lines.firstIndex(where: { $0.id == line.id }) else { continue }
                    m.lines[index].translation = text
                }
            }
            done += batch.count
            progress(done, total)
        }
        MeetingModelResolver.commit(resolved)
        return resolved.label
    }

    static func batches(_ lines: [MeetingLine]) -> [[MeetingLine]] {
        var result: [[MeetingLine]] = []
        var current: [MeetingLine] = []
        var size = 0
        for line in lines {
            if size + line.text.count > batchCharacters, !current.isEmpty {
                result.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.text.count + 8
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func numbered(_ lines: [MeetingLine]) -> String {
        lines.enumerated().map { "[\($0.offset + 1)] \($0.element.text)" }.joined(separator: "\n")
    }

    /// Instructions for the model (not shown to the user).
    static func prompt(_ language: String) -> String {
        """
        You translate the transcript of a meeting into \(language). The user message holds numbered lines ([n] text), in order.
        Translate every line on its own, keeping its meaning, tone and any numbers. Use the surrounding lines for context.
        Speech recognition makes mistakes, often in names: when context makes the intended word clear, translate that word.
        Keep personal names, product names and code as the transcript spells them unless \(language) has a standard form.
        When a line is already in \(language), return it unchanged.
        Return JSON only, one entry per input line with the same numbers:
        {"lines": [{"n": 1, "text": "translation"}]}
        No markdown, no text outside the JSON.
        """
    }

    /// Number → translation; lenient about wrapping text and the array's key.
    static func parse(_ raw: String, count: Int) -> [Int: String] {
        var text = raw
        if let a = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let b = text.lastIndex(where: { $0 == "}" || $0 == "]" }), a < b {
            text = String(text[a...b])
        }
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let items: [[String: Any]]
        if let object = root as? [String: Any] {
            items = (object["lines"] as? [[String: Any]])
                ?? (object.values.first { $0 is [[String: Any]] } as? [[String: Any]]) ?? []
        } else {
            items = root as? [[String: Any]] ?? []
        }
        var out: [Int: String] = [:]
        for (i, item) in items.enumerated() {
            let n = (item["n"] as? NSNumber)?.intValue ?? (item["n"] as? String).flatMap(Int.init) ?? (i + 1)
            let value = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...count).contains(n), !value.isEmpty else { continue }
            out[n] = value
        }
        return out
    }
}
