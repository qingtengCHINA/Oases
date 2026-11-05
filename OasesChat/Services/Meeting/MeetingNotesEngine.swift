// Portions adapted from Cicada (https://github.com/wquguru/cicada), Apache License 2.0:
// the notes prompt, the lenient parser, the language check and the time carry-over.
import Foundation

/// Which model writes meeting notes and translates transcripts: the model group chosen in
/// Meeting Notes settings, else Oases Fast (`glm-5.3-flash`) through the built-in Oases provider.
enum MeetingModelResolver {
    static let groupKey = "meeting.notesGroupId"
    /// The built-in default.
    static let defaultModelID = "glm-5.3-flash"

    struct Resolved {
        let entry: ModelEntry
        /// "Provider · model", shown beside the Generate button and stored with the notes.
        let label: String
        /// The built-in Oases model: counts toward the membership's daily text quota.
        let isBuiltin: Bool
    }

    @MainActor
    static func resolve() -> Resolved? {
        let store = ProviderConfigStore.shared
        if let id = UserDefaults.standard.string(forKey: groupKey), !id.isEmpty,
           let group = store.group(for: id),
           let entryId = ModelGroupRouter.resolve(group: group, sessionId: "meeting-notes", store: store),
           let entry = store.entry(for: entryId) {
            let provider = store.instance(for: entry.providerInstanceId)?.label ?? ""
            let model = entry.model.displayName
            return Resolved(entry: entry, label: provider.isEmpty ? model : "\(provider) · \(model)",
                            isBuiltin: OasesBuiltinProvider.owns(entry.providerInstanceId))
        }
        guard OasesBuiltinProvider.hasCredential,
              let entry = OasesBuiltinProvider.entry(forModelId: defaultModelID) else { return nil }
        return Resolved(entry: entry, label: "Oases · \(defaultModelID)", isBuiltin: true)
    }

    /// Checks the membership quota for a built-in model before a run; nil when it may go ahead.
    @MainActor
    static func denial(for resolved: Resolved) -> MembershipDenial? {
        guard resolved.isBuiltin else { return nil }
        return MembershipCenter.shared.authorize(category: .text, modelId: resolved.entry.model.id)
    }

    /// Counts a finished run against the quota (built-in models only).
    @MainActor
    static func commit(_ resolved: Resolved) {
        guard resolved.isBuiltin else { return }
        MembershipCenter.shared.commit(category: .text, modelId: resolved.entry.model.id)
    }
}

/// Writes meeting notes from a transcript with one of the user's text models.
enum MeetingNotesEngine {
    enum Failure: LocalizedError {
        case noModel
        case consentRequired
        case emptyTranscript
        case unreadableReply
        case quota(MembershipDenial)

        var errorDescription: String? {
            switch self {
            case .noModel:
                return String(localized: "纪要模型不可用。请在会议纪要设置里选择一个模型组。",
                              comment: "Meeting notes: the notes model is unavailable")
            case .consentRequired:
                return String(localized: "生成纪要需要先同意把文字记录发送给模型。", comment: "Meeting notes: AI data sharing consent is needed")
            case .emptyTranscript:
                return String(localized: "这场会议还没有文字记录。", comment: "Meeting notes: nothing was transcribed yet")
            case .unreadableReply:
                return String(localized: "模型的回复无法整理成纪要，请重试或换一个模型。", comment: "Meeting notes: the model's reply could not be parsed")
            case .quota(let denial):
                return denial.reason
            }
        }
    }

    /// Transcript characters sent in one request; longer meetings are written in windows, each
    /// merged into the notes so far.
    static let windowCharacters = 24_000

    /// Writes notes for `meeting` in `language` (an English language name).
    @MainActor
    static func generate(for meeting: Meeting, language: String) async throws -> (notes: MeetingNotes, model: String) {
        guard !meeting.lines.isEmpty else { throw Failure.emptyTranscript }
        guard let resolved = MeetingModelResolver.resolve() else { throw Failure.noModel }
        let instance = ProviderConfigStore.shared.instance(for: resolved.entry.providerInstanceId)
        guard (try? LLMProviderFactory.requireDataSharingConsent(for: instance)) != nil else { throw Failure.consentRequired }
        if let denial = MeetingModelResolver.denial(for: resolved) { throw Failure.quota(denial) }

        let lines = meeting.lines
        let windows = Self.windows(lines)
        var notes = MeetingNotes()
        for (index, range) in windows.enumerated() {
            let final = windows.count == 1
            let from = range.lowerBound
            let upto = range.upperBound
            let system = prompt(notes: notes, lines: Array(lines[0..<upto]), from: final ? 0 : from,
                                language: language, final: final, isLastWindow: index == windows.count - 1)
            var next: MeetingNotes?
            for _ in 0..<2 {
                let raw = try await complete(entry: resolved.entry, system: system,
                                             instruction: "Update the notes. Write them in \(language).")
                guard let parsed = parse(raw, times: lines.prefix(upto).map(\.t), startedAt: lines.first?.t ?? 0) else { continue }
                if written(parsed, in: language) { next = parsed; break }
            }
            guard var next else { throw Failure.unreadableReply }
            carryTimes(from: notes, into: &next)
            if next.title == nil { next.title = notes.title }
            next.covered = upto
            next.updatedAt = Date()
            notes = next
        }
        MeetingModelResolver.commit(resolved)
        return (notes, resolved.label)
    }

    /// Splits the transcript into windows of about `windowCharacters`.
    static func windows(_ lines: [MeetingLine]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0, size = 0
        for (i, l) in lines.enumerated() {
            size += l.text.count + 16
            if size >= windowCharacters {
                result.append(start..<(i + 1))
                start = i + 1
                size = 0
            }
        }
        if start < lines.count { result.append(start..<lines.count) }
        return result
    }

    @MainActor
    static func complete(entry: ModelEntry, system: String, instruction: String) async throws -> String {
        let provider = try await LLMProviderFactory.makeAgentProvider(for: entry)
        let cap = entry.model.maxOutputTokens ?? 6000
        let stream = try await provider.streamAgentMessage(
            messages: [AgentMessage(role: .user, parts: [.text(instruction)])],
            systemPrompt: system,
            tools: [],
            maxTokens: min(6000, max(1024, cap)),
            thinkingLevel: .off
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    // MARK: - Prompt

    static func clock(_ t: Double) -> String { MeetingExport.clock(t) }

    static func prompt(notes: MeetingNotes, lines: [MeetingLine], from: Int, language: String, final: Bool,
                       isLastWindow: Bool = true) -> String {
        func line(_ i: Int) -> String { "[L\(i + 1) \(clock(lines[i].t))] \(lines[i].text)" }
        var current = "{}"
        if !notes.isEmpty, let data = try? JSONEncoder().encode(Compact(notes)), let s = String(data: data, encoding: .utf8) {
            current = s
        }
        let context = max(0, from - 2)
        let ended = isLastWindow ? "that has just ended" : "that went on longer than this part"
        var p = """
        You keep notes for a meeting \(final ? "\(ended). Write them from the whole transcript" : "\(ended). Update them with the new lines").
        Write the notes in \(language). Return JSON only.

        """
        if !final {
            p += "Current notes (JSON):\n\(current)\n\n"
            if context < from {
                p += "Already covered (context only):\n" + (context..<from).map(line).joined(separator: "\n") + "\n\n"
            }
        }
        p += "\(final ? "Transcript" : "New lines") (id, mm:ss, text). The meeting was recorded on one phone, so speakers are not told apart. Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
        p += (from..<lines.count).map(line).joined(separator: "\n")
        if let first = lines.first?.t, let last = lines.last?.t {
            let most = max(1, min(8, Int((last - first) / 180) + 1))
            p += "\n\nThis meeting ran \(clock(last - first)) so far: use at most \(most) topic\(most == 1 ? "" : "s")."
        }
        // i18n-ignore: instructions for the model, not shown to the user.
        p += """


        Return the full notes as one JSON object with exactly these keys:
        {"title": "the meeting's name: what it is about, a few words",
         "summary": "2-3 sentences on the whole meeting",
         "topics": [{"start": seconds, "title": "short title", "summary": "one sentence", "points": [{"text": "key point", "evidence": ["L4"]}], "evidence": ["L3"],
                     "fishbone": null or {"question": "the problem or question", "branches": [{"label": "2-6 words", "detail": "one short line", "t": seconds, "evidence": ["L5"]}]}}],
         "conclusions": [{"text": "...", "evidence": ["L7", "L8"]}],
         "todos": [{"text": "...", "owner": "a person named in the transcript, or null when unclear", "evidence": ["L9"]}],
         "terms": [{"name": "correct spelling", "note": "who or what, a few words", "heard": ["how it was misrecognised"]}]}
        Rules:
        - title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not "会议" alone).
        - summary: at most 3 short sentences.
        - Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes. Merge small neighbouring topics. Keep earlier topics unless new lines correct them.
        - At most 4 points per topic, each one short phrase. Merge rather than repeat.
        - At most 5 conclusions and only real to-dos (often none).
        - Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.
        - Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.
        - terms: at most 10: first names the transcript misspells (heard), then people, places and jargon a reader would not know. name is the correct spelling; heard lists only the wrong forms the transcript used.
        - Write the title and every summary, title, point, branch, conclusion and to-do in \(language), even when the transcript is in another language. Only term names keep the transcript's spelling.
        - Write about what was said, never about the transcript or recognition quality.
        - Use empty arrays when there is nothing. No markdown, no text outside the JSON.
        """
        return p
    }

    /// The notes as sent back to the model (no bookkeeping fields).
    private struct Compact: Encodable {
        let title: String?
        let summary: String
        let topics: [Topic]
        let conclusions: [String]
        let todos: [String]
        let terms: [NoteTerm]
        struct Topic: Encodable {
            let start: Double
            let title: String
            let summary: String
            let points: [String]
            let fishbone: Fishbone?
        }
        init(_ n: MeetingNotes) {
            title = n.title
            summary = n.summary
            topics = n.topics.map { Topic(start: $0.start, title: $0.title, summary: $0.summary, points: $0.points, fishbone: $0.fishbone) }
            conclusions = n.conclusions.map(\.text)
            todos = n.todos.map(\.text)
            terms = n.terms
        }
    }

    // MARK: - Checks

    /// Whether the notes' own words are in `language`: Chinese, Japanese and Korean need a fair
    /// share of CJK letters; other languages must not be mostly CJK.
    static func written(_ notes: MeetingNotes, in language: String) -> Bool {
        let text = ([notes.summary] + notes.topics.map(\.title)).joined()
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["Chinese", "Japanese", "Korean"].contains { language.contains($0) }
        return wantsCJK ? cjk * 5 >= letters.count : cjk * 2 < letters.count
    }

    /// A point the model repeats keeps the time it was first heard.
    static func carryTimes(from old: MeetingNotes, into new: inout MeetingNotes) {
        var known: [String: Double] = [:]
        for t in old.topics { for (i, p) in t.points.enumerated() { if let x = t.pointTime(i) { known[p] = x } } }
        for (ti, t) in new.topics.enumerated() {
            let times = t.points.enumerated().map { i, p in [t.pointTime(i), known[p]].compactMap { $0 }.min() }
            new.topics[ti].pointTimes = times.contains { $0 != nil } ? times : nil
        }
        let items = Dictionary((old.conclusions + old.todos).compactMap { i in i.t.map { (i.text, $0) } }, uniquingKeysWith: { a, _ in a })
        func earliest(_ a: Double?, _ b: Double?) -> Double? { [a, b].compactMap { $0 }.min() }
        for i in new.conclusions.indices { new.conclusions[i].t = earliest(new.conclusions[i].t, items[new.conclusions[i].text]) }
        for i in new.todos.indices { new.todos[i].t = earliest(new.todos[i].t, items[new.todos[i].text]) }
    }

    // MARK: - Parse

    /// Lenient: missing keys become empty; evidence ids are checked against the transcript.
    static func parse(_ raw: String, times: [Double], startedAt: Double) -> MeetingNotes? {
        let lineCount = times.count
        var text = raw
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b { text = String(text[a...b]) }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func str(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        func lineNumbers(_ v: Any?) -> Set<Int> {
            let ids = (v as? [Any])?.compactMap { $0 as? String } ?? []
            return Set(ids.compactMap { id -> Int? in
                guard let n = Int(id.drop(while: { !$0.isNumber })), n >= 1, n <= lineCount else { return nil }
                return n
            })
        }
        func support(_ v: Any?) -> Int { lineNumbers(v).count }
        func time(_ v: Any?) -> Double? { lineNumbers(v).min().map { times[$0 - 1] } }
        var n = MeetingNotes()
        n.summary = str(root["summary"])
        let title = str(root["title"]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」《》"))
        n.title = title.isEmpty ? nil : title
        n.topics = (root["topics"] as? [[String: Any]] ?? []).compactMap { t in
            let title = str(t["title"])
            guard !title.isEmpty else { return nil }
            var fish: Fishbone?
            if let f = t["fishbone"] as? [String: Any] {
                let branches = (f["branches"] as? [[String: Any]] ?? []).compactMap { b -> FishboneBranch? in
                    let label = str(b["label"])
                    return label.isEmpty ? nil : FishboneBranch(label: label, detail: str(b["detail"]), t: num(b["t"]),
                                                                support: support(b["evidence"]))
                }
                if branches.count >= 2 { fish = Fishbone(question: str(f["question"]), branches: branches) }
            }
            var points: [String] = [], pointTimes: [Double?] = []
            for p in t["points"] as? [Any] ?? [] {
                let text = (p as? [String: Any]).map { str($0["text"]) } ?? str(p)
                guard !text.isEmpty else { continue }
                points.append(text)
                pointTimes.append((p as? [String: Any]).flatMap { time($0["evidence"]) })
            }
            return NoteTopic(start: num(t["start"]) ?? startedAt, title: title, summary: str(t["summary"]),
                             points: points, fishbone: fish,
                             pointTimes: pointTimes.contains { $0 != nil } ? pointTimes : nil)
        }
        func items(_ key: String) -> [NoteItem] {
            (root[key] as? [[String: Any]] ?? []).compactMap { i in
                let text = str(i["text"])
                let owner = str(i["owner"])
                return text.isEmpty ? nil : NoteItem(text: text, owner: owner.isEmpty ? nil : owner,
                                                     support: support(i["evidence"]), t: time(i["evidence"]))
            }
        }
        n.conclusions = items("conclusions")
        n.todos = items("todos")
        n.terms = (root["terms"] as? [[String: Any]] ?? []).compactMap { t in
            let name = str(t["name"])
            let heard = (t["heard"] as? [Any] ?? []).map(str).filter { !$0.isEmpty && $0 != name }
            return name.isEmpty ? nil : NoteTerm(name: name, note: str(t["note"]), heard: heard)
        }
        if n.terms.count > 20 { n.terms = Array(NoteTerm.ordered(n.terms).prefix(20)) }
        return n.isEmpty ? nil : n
    }
}
