import Foundation
import Observation

/// Meetings on disk: `Application Support/Meetings/<id>/meeting.json` plus `audio/chunk-NNN.m4a`.
/// Files keep the default protection (until first unlock), so recording keeps writing while the
/// phone is locked; audio is excluded from device backups.
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    private(set) var meetings: [Meeting] = []
    /// The meeting being recorded now, if any (never "repaired" on load).
    var recordingID: String?

    private var pendingSaves: [String: Task<Void, Never>] = [:]
    private let logger = AppLogger(category: "Meeting")

    private init() {
        reload()
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Meetings", isDirectory: true)
    }

    static func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func audioFolder(for id: String) -> URL { folder(for: id).appendingPathComponent("audio", isDirectory: true) }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    // MARK: Create, update, delete

    func create(language: String, engine: String) -> Meeting {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let id = "\(stamp)-\(UUID().uuidString.prefix(6))"
        let meeting = Meeting(id: id, startedAt: Date(), language: language, engine: engine)
        let audio = Self.audioFolder(for: id)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var audioURL = audio
        try? audioURL.setResourceValues(values)
        meetings.insert(meeting, at: 0)
        write(meeting)
        return meeting
    }

    /// Updates a meeting in memory and saves it (debounced while it is being recorded).
    func update(_ id: String, immediately: Bool = false, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        let snapshot = meetings[i]
        pendingSaves[id]?.cancel()
        if immediately {
            pendingSaves[id] = nil
            write(snapshot)
        } else {
            pendingSaves[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.write(snapshot)
                self?.pendingSaves[id] = nil
            }
        }
    }

    /// Moves the meeting's folder to Recently Deleted (restorable for 30 days).
    func delete(_ id: String) throws {
        guard recordingID != id else { return }
        let folder = Self.folder(for: id)
        let size = (try? FileManager.default.allocatedSizeOfDirectory(at: folder)) ?? 0
        try FileTrash.moveToTrash(folder, linuxPath: nil, isDirectory: true, size: size)
        meetings.removeAll { $0.id == id }
    }

    // MARK: Disk

    private func write(_ meeting: Meeting) {
        let url = Self.folder(for: meeting.id).appendingPathComponent("meeting.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meeting).write(to: url, options: .atomic)
        } catch {
            logger.error("meeting save failed: \(error.localizedDescription)")
        }
    }

    /// Reads every meeting; one left open by a crash or a kill is closed at its last audio.
    func reload() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil) else {
            meetings = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Meeting] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
                  var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            if meeting.endedAt == nil, meeting.id != recordingID {
                meeting.endedAt = meeting.startedAt.addingTimeInterval(meeting.duration)
                write(meeting)
            }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
    }
}

extension FileManager {
    /// Bytes used by everything under `url`.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: Set(keys))
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
