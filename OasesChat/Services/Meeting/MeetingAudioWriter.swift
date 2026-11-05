import AVFoundation

/// Writes the meeting's audio into AAC chunks from the audio tap thread. A chunk closes at a
/// quiet moment once it is 6 minutes long (at the latest at 10 minutes), so a crash or a kill
/// loses at most the open chunk and chunks stay small enough to transcribe again later.
final class MeetingAudioWriter: @unchecked Sendable {
    static let preferredChunkSeconds: Double = 6 * 60
    static let maximumChunkSeconds: Double = 10 * 60
    /// RMS below this counts as quiet.
    static let quietLevel: Float = 0.012

    private let lock = NSLock()
    private let folder: URL
    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private var fileName = ""
    private var chunkStart: Double = 0
    private var frames: AVAudioFramePosition = 0
    private var quietFor: Double = 0
    private var nextIndex: Int
    /// Called (on the tap thread) when a chunk is complete.
    private let onChunk: @Sendable (MeetingChunk) -> Void

    init(folder: URL, format: AVAudioFormat, firstIndex: Int, onChunk: @escaping @Sendable (MeetingChunk) -> Void) {
        self.folder = folder
        self.format = format
        nextIndex = firstIndex
        self.onChunk = onChunk
    }

    /// `meetingTime`: seconds into the meeting at the start of `buffer`.
    func write(_ buffer: AVAudioPCMBuffer, meetingTime: Double, rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        let seconds = Double(buffer.frameLength) / format.sampleRate
        if file == nil { open(at: meetingTime) }
        do {
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A failed write (disk full) closes the chunk; the next buffer opens a new one.
            closeLocked()
            return
        }
        quietFor = rms < Self.quietLevel ? quietFor + seconds : 0
        let length = Double(frames) / format.sampleRate
        if length >= Self.maximumChunkSeconds || (length >= Self.preferredChunkSeconds && quietFor >= 0.4) {
            closeLocked()
        }
    }

    /// Closes the open chunk (pause, interruption, stop).
    func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func open(at meetingTime: Double) {
        fileName = String(format: "chunk-%03d.m4a", nextIndex)
        nextIndex += 1
        let url = folder.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.channelCount > 1 ? 96_000 : 64_000,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                interleaved: format.isInterleaved)
        chunkStart = meetingTime
        frames = 0
        quietFor = 0
    }

    private func closeLocked() {
        guard file != nil else { return }
        let chunk = MeetingChunk(file: fileName, start: chunkStart, duration: Double(frames) / format.sampleRate)
        file = nil  // releasing the AVAudioFile finalises it
        if chunk.duration > 0.2 { onChunk(chunk) }
    }
}
