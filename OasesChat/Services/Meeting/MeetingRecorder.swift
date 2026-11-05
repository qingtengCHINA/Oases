import AVFoundation
import Observation
import Speech
import UIKit

/// Records a meeting: one microphone tap writes the audio chunks, feeds live recognition and
/// measures the level. Interruptions (a call, Siri, another app taking the microphone) become
/// gaps in the timeline; recording resumes by itself when iOS allows it. Recording continues
/// with the screen locked or in another app (background audio), and must be started in the app.
@MainActor
@Observable
final class MeetingRecorder {
    static let shared = MeetingRecorder()

    enum State: Equatable {
        case idle
        case recording
        case paused
        /// Stopped by the system; `resume()` when the user is ready.
        case interrupted
    }

    enum Failure: LocalizedError {
        case microphoneDenied
        case noInput
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return String(localized: "没有麦克风权限。请在“设置”中允许 Oases Chat 使用麦克风。", comment: "Meeting notes: microphone permission denied")
            case .noInput:
                return String(localized: "找不到可用的麦克风。", comment: "Meeting notes: no audio input available")
            case .alreadyRecording:
                return String(localized: "已经在录音了。", comment: "Meeting notes: a recording is already running")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var meetingID: String?
    /// 0…1, smoothed, for the level meter.
    private(set) var level: Float = 0
    /// What is being heard right now (not yet a line).
    private(set) var volatileText = ""
    /// Why there is no live transcript, when there isn't one.
    private(set) var transcriptionNote: String?

    private var engine: AVAudioEngine?
    private var writer: MeetingAudioWriter?
    private var transcriber: (any MeetingLiveTranscribing)?
    private var startedAt: CFTimeInterval = 0
    private var gapStart: Double?
    private var nextChunkIndex = 0
    /// The meeting late recognition results belong to (kept after `stop()`).
    private var linesMeetingID: String?
    private let observers = NotificationTokens()
    private let logger = AppLogger(category: "Meeting")

    private init() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                MeetingRecorder.shared.handleInterruption(type: type, shouldResume: options?.contains(.shouldResume) ?? false)
            }
        })
        observers.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingRecorder.shared.handleMediaReset() }
        })
    }

    /// Seconds since the meeting started (wall clock, gaps included).
    var meetingTime: Double { state == .idle ? 0 : CACurrentMediaTime() - startedAt }

    /// Recorded time: meeting time minus the gaps.
    var recordedTime: Double {
        guard let id = meetingID, let m = MeetingStore.shared.meeting(id) else { return 0 }
        let gaps = m.gaps.reduce(0) { $0 + ($1.end - $1.start) } + (gapStart.map { meetingTime - $0 } ?? 0)
        return max(0, meetingTime - gaps)
    }

    // MARK: Control

    /// Asks for the microphone (and speech recognition) and starts a new meeting.
    func start(language: String) async throws -> String {
        guard state == .idle else { throw Failure.alreadyRecording }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }

        let locale = Locale(identifier: language)
        let cloud = MeetingSettings.cloudTranscription && MeetingCloudASR.supports(language: language)
        var transcriber: (any MeetingLiveTranscribing)?
        if speech == .authorized {
            transcriber = await MeetingLiveTranscription.make(
                locale: locale,
                meetingTime: { [weak self] in self?.meetingTime ?? 0 },
                onVolatile: { [weak self] text in self?.volatileText = text },
                onLines: { [weak self] lines in self?.append(lines) }
            )
            if transcriber != nil {
                transcriptionNote = nil
            } else if cloud {
                transcriptionNote = String(localized: "这台设备不能在本机实时识别所选语言。录音会分段用云端转写，结束后可查看文字记录。",
                                           comment: "Meeting notes: no live transcription, but the recording is transcribed in the cloud")
            } else {
                transcriptionNote = String(localized: "这台设备不能在本机识别所选语言，会议只录音。同意数据共享后可以使用 Apple 的服务器识别。",
                                           comment: "Meeting notes: live transcription unavailable without on-device support and consent")
            }
        } else {
            transcriptionNote = cloud
                ? String(localized: "没有语音识别权限，录音时不显示文字。录音会分段用云端转写。",
                         comment: "Meeting notes: speech recognition denied, cloud transcription still runs")
                : String(localized: "没有语音识别权限，会议只录音。可以在“设置”中允许语音识别。",
                         comment: "Meeting notes: speech recognition permission denied")
        }
        // Both permission prompts are answered; the meeting's clock starts now.
        guard state == .idle else { throw Failure.alreadyRecording }
        AudioSessionCoordinator.shared.begin(.meetingRecording)
        startedAt = CACurrentMediaTime()
        let meeting = MeetingStore.shared.create(language: language, engine: transcriber?.engineName ?? "none")
        if cloud {
            MeetingStore.shared.update(meeting.id, immediately: true) { $0.cloudTranscription = true }
        }
        MeetingStore.shared.recordingID = meeting.id
        meetingID = meeting.id
        linesMeetingID = meeting.id
        nextChunkIndex = 0
        gapStart = nil
        self.transcriber = transcriber
        do {
            try startEngine()
        } catch {
            MeetingStore.shared.recordingID = nil
            finishMeeting()
            throw error
        }
        state = .recording
        return meeting.id
    }

    func pause() {
        guard state == .recording else { return }
        stopEngine()
        gapStart = meetingTime
        state = .paused
    }

    func resume() {
        guard state == .paused || state == .interrupted else { return }
        AudioSessionCoordinator.shared.begin(.meetingRecording)
        do {
            try startEngine()
            closeGap()
            state = .recording
        } catch {
            logger.error("meeting resume failed: \(error.localizedDescription)")
            state = .interrupted
        }
    }

    /// Ends the meeting and saves it. Returns its id.
    @discardableResult
    func stop() -> String? {
        guard state != .idle, let id = meetingID else { return nil }
        stopEngine()
        closeGap()
        let finalTranscriber = transcriber
        // Late final results of the last request still land in the meeting for a few seconds.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            finalTranscriber?.cancel()
        }
        finishMeeting()
        // The last chunk's close lands on the main actor a moment after stopEngine; the join
        // waits for it and then writes recording.m4a next to the chunks.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            MeetingRecordingAssembler.shared.ensure(id)
        }
        return id
    }

    // MARK: Engine

    private func startEngine() throws {
        guard let id = meetingID else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let writer = MeetingAudioWriter(folder: MeetingStore.audioFolder(for: id), format: format,
                                        firstIndex: nextChunkIndex) { chunk in
            Task { @MainActor in MeetingRecorder.shared.chunkClosed(chunk, meetingID: id) }
        }
        let feed = transcriber?.audioSink
        let started = startedAt
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let rms = Self.rms(buffer)
            let t = CACurrentMediaTime() - started - Double(buffer.frameLength) / sampleRate
            writer.write(buffer, meetingTime: max(0, t), rms: rms)
            feed?.append(buffer)
            Task { @MainActor in MeetingRecorder.shared.updateLevel(rms) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.writer = writer
        transcriber?.start()
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        writer?.close()
        writer = nil
        transcriber?.stop()
        level = 0
        volatileText = ""
    }

    private func finishMeeting() {
        if let id = meetingID {
            MeetingStore.shared.update(id, immediately: true) { m in
                m.endedAt = Date()
            }
        }
        MeetingStore.shared.recordingID = nil
        AudioSessionCoordinator.shared.end(.meetingRecording)
        meetingID = nil
        transcriber = nil
        state = .idle
    }

    private func closeGap() {
        guard let start = gapStart, let id = meetingID else { return }
        let end = meetingTime
        gapStart = nil
        if end - start > 0.5 {
            MeetingStore.shared.update(id) { $0.gaps.append(MeetingGap(start: start, end: end)) }
        }
    }

    // MARK: Events

    private func append(_ lines: [MeetingLine]) {
        guard let id = linesMeetingID else { return }
        MeetingStore.shared.update(id) { m in
            // A late live result for a stretch the cloud already transcribed would duplicate it.
            let fresh = lines.filter { !m.isCloudTranscribed(at: $0.t) }
            guard !fresh.isEmpty else { return }
            m.lines.append(contentsOf: fresh)
            m.lines.sort { $0.t < $1.t }
        }
    }

    private func chunkClosed(_ chunk: MeetingChunk, meetingID id: String) {
        nextChunkIndex = max(nextChunkIndex, (Int(chunk.file.dropFirst(6).prefix(3)) ?? 0) + 1)
        // Saved at once: the cloud queue reads the chunk back from the store.
        MeetingStore.shared.update(id, immediately: true) { $0.chunks.append(chunk) }
        MeetingCloudQueue.shared.enqueue(meetingID: id, chunk: chunk)
    }

    private func updateLevel(_ rms: Float) {
        // Roughly -50…0 dBFS onto 0…1, with a quick attack and a slower release.
        let db = 20 * log10(max(rms, 0.000_01))
        let target = max(0, min(1, (db + 50) / 50))
        level = target > level ? target : level + (target - level) * 0.25
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            guard state == .recording else { return }
            stopEngine()
            gapStart = meetingTime
            state = .interrupted
        case .ended:
            if state == .interrupted, shouldResume { resume() }
        default:
            break
        }
    }

    private func handleMediaReset() {
        guard state == .recording else { return }
        stopEngine()
        gapStart = meetingTime
        state = .interrupted
        resume()
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = data[0]
        for i in 0..<n { sum += samples[i] * samples[i] }
        return (sum / Float(n)).squareRoot()
    }
}
