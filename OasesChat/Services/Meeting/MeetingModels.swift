// Portions adapted from Cicada (https://github.com/wquguru/cicada), Apache License 2.0:
// the meeting notes model, the transcript line and the export formats.
import Foundation

/// One spoken line of a meeting, in meeting time.
struct MeetingLine: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// Seconds from the start of the meeting.
    var t: Double
    var text: String
    /// True when the line came from cloud transcription of the recorded audio (it replaced the
    /// live on-device lines of that stretch). Nil for live lines and older meetings.
    var cloud: Bool?
    /// The line in `Meeting.translationLanguage`, when the transcript has been translated.
    var translation: String?
}

/// A stretch of the meeting that was not recorded (a call, another app taking the microphone).
struct MeetingGap: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

/// One recorded audio file of the meeting (recording is split into chunks of a few minutes so a
/// crash or a kill loses at most the last one).
struct MeetingChunk: Codable, Equatable, Sendable {
    var file: String
    /// Seconds from the start of the meeting.
    var start: Double
    var duration: Double
    /// Cloud transcription of this chunk; nil while it hasn't run (or the meeting doesn't use it).
    var cloud: CloudState?

    enum CloudState: String, Codable, Sendable {
        case done
        case failed
    }

    var end: Double { start + duration }
    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    static let schemaVersion = 1

    var id: String
    var schema = Meeting.schemaVersion
    /// The user's title; nil uses the notes' title or the date.
    var customTitle: String?
    var startedAt: Date
    var endedAt: Date?
    /// Speech recognition language (BCP 47), e.g. "zh-CN".
    var language: String
    /// Where the transcript came from, e.g. "on-device".
    var engine: String
    var lines: [MeetingLine] = []
    var gaps: [MeetingGap] = []
    var chunks: [MeetingChunk] = []
    var notes: MeetingNotes?
    /// The model that wrote the notes ("Provider · model").
    var notesModel: String?
    /// Whether recorded chunks are transcribed again in the cloud (set when the meeting starts,
    /// or when the user asks for it later). Nil for older meetings.
    var cloudTranscription: Bool?
    /// The cloud speech model whose text is in the transcript, once a chunk has been done.
    var cloudModel: String?
    /// Language code (as in `MeetingSettings.notesLanguages`) of the lines' `translation`.
    var translationLanguage: String?
    /// The whole recording as one file in the meeting folder (`recording.m4a`), joined from the
    /// chunks once the meeting ends; nil until then.
    var recordingFile: String?
    /// How many chunks the recording file was joined from (re-joined when more appear).
    var recordingChunkCount: Int?
    var recordingBytes: Int64?
    /// A notes run was asked for and hasn't finished (survives a kill: `MeetingNotesJobs`
    /// resumes it).
    var notesRequestedAt: Date?
    /// A translation into this language was asked for and hasn't finished.
    var translationRequestedTo: String?

    var duration: TimeInterval {
        if let last = chunks.last { return last.start + last.duration }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isRecording: Bool { endedAt == nil }

    /// The user's title, else the notes' name for it, else the date.
    var displayTitle: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let t = notes?.title, !t.isEmpty { return t }
        return String(localized: "会议 \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                      comment: "Meeting notes: default meeting title; argument is the date and time it started")
    }

    var transcriptText: String { lines.map(\.text).joined(separator: "\n") }

    /// Chunks still waiting for cloud transcription (none when the meeting doesn't use it).
    var pendingCloudChunks: [MeetingChunk] {
        cloudTranscription == true ? chunks.filter { $0.cloud == nil } : []
    }

    var failedCloudChunks: [MeetingChunk] { chunks.filter { $0.cloud == .failed } }

    /// Where meeting time `t` falls in the joined recording, which leaves the gaps out.
    func recordingTime(forMeetingTime t: Double) -> Double {
        let skipped = gaps.reduce(0.0) { total, gap in
            guard gap.start < t else { return total }
            return total + (min(gap.end, t) - gap.start)
        }
        return max(0, t - skipped)
    }

    /// Whether `t` falls in a chunk whose cloud transcript already replaced the live lines.
    func isCloudTranscribed(at t: Double) -> Bool {
        chunks.contains { $0.cloud == .done && $0.contains(t) }
    }
}

/// Meeting notes as the model writes them, every item tied to the transcript lines that say it.
struct MeetingNotes: Codable, Equatable, Sendable {
    var title: String?
    var summary = ""
    var topics: [NoteTopic] = []
    var conclusions: [NoteItem] = []
    var todos: [NoteItem] = []
    var terms: [NoteTerm] = []
    /// How many transcript lines these notes cover.
    var covered = 0
    var updatedAt: Date?

    var isEmpty: Bool { summary.isEmpty && topics.isEmpty }
}

struct NoteTopic: Codable, Equatable, Identifiable, Sendable {
    var start: Double
    var title: String
    var summary: String
    var points: [String]
    var fishbone: Fishbone?
    /// When each point was first said, parallel to `points`.
    var pointTimes: [Double?]?
    var id: String { "\(Int(start))-\(title)" }

    func pointTime(_ i: Int) -> Double? { pointTimes.flatMap { i < $0.count ? $0[i] : nil } }
}

/// Causes behind a topic that discusses why something happened.
struct Fishbone: Codable, Equatable, Sendable {
    var question: String
    var branches: [FishboneBranch]
}

struct FishboneBranch: Codable, Equatable, Identifiable, Sendable {
    var label: String
    var detail: String
    var t: Double?
    /// How many transcript lines back this branch (0 reads as weak).
    var support: Int
    var id: String { label + detail }
}

struct NoteItem: Codable, Equatable, Identifiable, Sendable {
    var text: String
    var owner: String?
    var support: Int
    /// When it was first said.
    var t: Double?
    var id: String { text }
}

/// A name or term the notes settled on, and how recognition misheard it.
struct NoteTerm: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var note: String
    var heard: [String]
    var id: String { name }

    static func ordered(_ terms: [NoteTerm]) -> [NoteTerm] {
        terms.filter { !$0.heard.isEmpty } + terms.filter { $0.heard.isEmpty }
    }
}

// MARK: - Export

enum MeetingExport {
    static var notesHeading: String { String(localized: "纪要", comment: "Meeting notes: notes heading") }
    static var conclusionsHeading: String { String(localized: "结论", comment: "Meeting notes: conclusions heading") }
    static var todosHeading: String { String(localized: "待办", comment: "Meeting notes: to-dos heading") }
    static var termsHeading: String { String(localized: "人名和术语", comment: "Meeting notes: names and terms heading") }
    static var transcriptHeading: String { String(localized: "文字记录", comment: "Meeting notes: transcript heading") }

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func header(_ m: Meeting) -> String {
        let minutes = Int(m.duration / 60)
        let length = minutes < 1
            ? String(localized: "不到 1 分钟", comment: "Meeting notes: duration under a minute")
            : String(localized: "\(minutes) 分钟", comment: "Meeting notes: duration in minutes")
        return "\(m.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(length)"
    }

    static func notesMarkdown(_ n: MeetingNotes?) -> String {
        guard let n, !n.isEmpty else { return "" }
        var out = "## \(notesHeading)\n\n\(n.summary)\n\n"
        for t in n.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p)\n" }
            if let f = t.fishbone {
                out += "\n**\(f.question)**\n\n"
                for b in f.branches { out += "- \(b.label)：\(b.detail)\n" }
            }
            out += "\n"
        }
        if !n.conclusions.isEmpty {
            out += "### \(conclusionsHeading)\n\n"
                + n.conclusions.map { "- \($0.text)\n" }.joined() + "\n"
        }
        if !n.todos.isEmpty {
            out += "### \(todosHeading)\n\n"
                + n.todos.map { "- [ ] \($0.text)" + ($0.owner.map { "（\($0)）" } ?? "") + "\n" }.joined() + "\n"
        }
        if !n.terms.isEmpty {
            out += "### \(termsHeading)\n\n"
                + n.terms.map { "- **\($0.name)** \($0.note)\n" }.joined() + "\n"
        }
        return out
    }

    static func markdown(_ m: Meeting) -> String {
        var out = "# \(m.displayTitle)\n\n\(header(m))\n\n"
        let notes = notesMarkdown(m.notes)
        if !notes.isEmpty { out += notes }
        out += "## \(transcriptHeading)\n\n"
        for l in m.lines {
            out += "**[\(clock(l.t))]** \(l.text)\n"
            if let tr = translation(of: l, in: m) { out += "> \(tr)\n" }
            out += "\n"
        }
        return out
    }

    static func plainText(_ m: Meeting) -> String {
        "\(m.displayTitle)\n\(header(m))\n\n" + m.lines.map { line in
            let text = "[\(clock(line.t))] \(line.text)"
            return translation(of: line, in: m).map { text + "\n        " + $0 } ?? text
        }.joined(separator: "\n") + "\n"
    }

    /// A line's translation, when the meeting has been translated.
    static func translation(of line: MeetingLine, in m: Meeting) -> String? {
        guard m.translationLanguage != nil, let t = line.translation, !t.isEmpty else { return nil }
        return t
    }

    static func srt(_ m: Meeting) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, l) in m.lines.enumerated() {
            let next = i + 1 < m.lines.count ? m.lines[i + 1].t : l.t + 4
            let end = max(l.t + 1, min(next, l.t + 8))
            out += "\(i + 1)\n\(ts(l.t)) --> \(ts(end))\n\(l.text)\n\n"
        }
        return out
    }

    /// The notes and transcript as a simple HTML page (for PDF and printing).
    static func html(_ m: Meeting) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = "<h1>\(esc(m.displayTitle))</h1><p class=meta>\(esc(header(m)))</p>"
        if let n = m.notes, !n.isEmpty {
            body += "<h2>\(esc(notesHeading))</h2><p>\(esc(n.summary))</p>"
            for t in n.topics {
                body += "<h3>\(clock(t.start)) \(esc(t.title))</h3>"
                if !t.summary.isEmpty { body += "<p>\(esc(t.summary))</p>" }
                if !t.points.isEmpty { body += "<ul>" + t.points.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }
            }
            if !n.conclusions.isEmpty {
                body += "<h3>\(esc(conclusionsHeading))</h3><ul>"
                    + n.conclusions.map { "<li>\(esc($0.text))</li>" }.joined() + "</ul>"
            }
            if !n.todos.isEmpty {
                body += "<h3>\(esc(todosHeading))</h3><ul>"
                    + n.todos.map { "<li>☐ \(esc($0.text))\($0.owner.map { "（\(esc($0))）" } ?? "")</li>" }.joined() + "</ul>"
            }
        }
        body += "<h2>\(esc(transcriptHeading))</h2>"
        body += m.lines.map { line in
            var p = "<p><span class=t>\(clock(line.t))</span> \(esc(line.text))"
            if let tr = translation(of: line, in: m) { p += "<br><span class=tr>\(esc(tr))</span>" }
            return p + "</p>"
        }.joined()
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; font-size: 11pt; line-height: 1.55; color: #1f1d19; }
        h1 { font-size: 20pt; margin-bottom: 2pt; } h2 { font-size: 15pt; margin-top: 18pt; } h3 { font-size: 12pt; margin-top: 12pt; }
        .meta { color: #66635e; } .t { color: #66635e; font-variant-numeric: tabular-nums; margin-right: 6pt; }
        .tr { color: #66635e; }
        </style></head><body>\(body)</body></html>
        """
    }
}
