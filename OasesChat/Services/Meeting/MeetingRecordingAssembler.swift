import AVFoundation
import Foundation
import Observation

/// Joins a finished meeting's audio chunks into one `recording.m4a` in the meeting's folder,
/// the file the user plays back and exports. The chunks stay as they are: cloud transcription
/// reads them one by one, and a crash mid-join loses nothing. Runs once per meeting, after the
/// meeting ends (or, for a meeting the app was killed in, the next time it is opened).
@MainActor
@Observable
final class MeetingRecordingAssembler {
    static let shared = MeetingRecordingAssembler()
    static let fileName = "recording.m4a"

    private var running: Set<String> = []
    private let logger = AppLogger(category: "Meeting")

    private init() {}

    func isAssembling(_ meetingID: String) -> Bool { running.contains(meetingID) }

    static func recordingURL(for meeting: Meeting) -> URL? {
        guard let file = meeting.recordingFile else { return nil }
        let url = MeetingStore.folder(for: meeting.id).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Joins the chunks unless the recording already exists and covers every chunk.
    func ensure(_ meetingID: String) {
        guard !running.contains(meetingID),
              let meeting = MeetingStore.shared.meeting(meetingID),
              !meeting.isRecording, !meeting.chunks.isEmpty,
              meeting.recordingChunkCount != meeting.chunks.count || Self.recordingURL(for: meeting) == nil else { return }
        running.insert(meetingID)
        let folder = MeetingStore.folder(for: meetingID)
        let chunkURLs = meeting.chunks.sorted { $0.start < $1.start }
            .map { MeetingStore.audioFolder(for: meetingID).appendingPathComponent($0.file) }
        let count = meeting.chunks.count
        Task { [logger] in
            defer { running.remove(meetingID) }
            do {
                let bytes = try await Self.join(chunkURLs, into: folder.appendingPathComponent(Self.fileName))
                MeetingStore.shared.update(meetingID, immediately: true) { m in
                    m.recordingFile = Self.fileName
                    m.recordingChunkCount = count
                    m.recordingBytes = bytes
                }
            } catch {
                logger.error("meeting recording join failed: \(error.localizedDescription)")
            }
        }
    }

    enum Failure: LocalizedError {
        case noAudio
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return String(localized: "这场会议没有可用的录音。", comment: "Meeting notes: no recorded audio to join or export")
            case .exportFailed(let reason):
                return String(localized: "无法生成录音文件：\(reason)", comment: "Meeting notes: joining the recording failed; argument is the reason")
            }
        }
    }

    /// Chunks laid end to end (recorded time, gaps left out, as a voice memo would) and written
    /// without re-encoding. Returns the file's size.
    nonisolated static func join(_ chunkURLs: [URL], into output: URL) async throws -> Int64 {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed("track")
        }
        var cursor = CMTime.zero
        for url in chunkURLs {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        guard cursor.seconds > 0 else { throw Failure.noAudio }

        let temp = output.deletingLastPathComponent().appendingPathComponent("recording.tmp.m4a")
        try? FileManager.default.removeItem(at: temp)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed("session")
        }
        export.outputFileType = .m4a
        export.outputURL = temp
        export.shouldOptimizeForNetworkUse = false
        await export.export()
        if let error = export.error { throw Failure.exportFailed(error.localizedDescription) }
        guard export.status == .completed else { throw Failure.exportFailed("\(export.status.rawValue)") }
        // Replace atomically so a reader never sees a half-written file.
        _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size
    }
}
