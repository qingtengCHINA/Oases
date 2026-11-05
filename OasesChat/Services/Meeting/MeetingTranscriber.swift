import AVFoundation
import Speech

/// Live speech recognition for a meeting with `SFSpeechRecognizer`. A recognition request is
/// limited to about a minute, so a new one starts every 50 s: the next request is created before
/// the old one is ended, so no audio falls between them. Finished results become transcript
/// lines with meeting times; partial results are shown as the line being heard.
@MainActor
final class MeetingTranscriber {
    /// The request the tap feeds, swapped from the main thread.
    final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            let r = request
            lock.unlock()
            r?.append(buffer)
        }
    }

    static let requestSeconds: TimeInterval = 50

    let feed = Feed()
    private let recognizer: SFSpeechRecognizer
    private let onDevice: Bool
    private var current: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var rotation: Timer?
    private let meetingTime: @MainActor () -> Double
    private let onVolatile: @MainActor (String) -> Void
    private let onLines: @MainActor ([MeetingLine]) -> Void

    /// Nil when recognition isn't possible for `locale` (or only on a server the user hasn't
    /// agreed to send audio to).
    init?(locale: Locale, meetingTime: @escaping @MainActor () -> Double,
          onVolatile: @escaping @MainActor (String) -> Void,
          onLines: @escaping @MainActor ([MeetingLine]) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        let local = recognizer.supportsOnDeviceRecognition
        // Without the AI data sharing consent, audio must stay on the device.
        guard local || AIDataSharingConsent.isAccepted else { return nil }
        self.recognizer = recognizer
        onDevice = local
        self.meetingTime = meetingTime
        self.onVolatile = onVolatile
        self.onLines = onLines
    }

    /// "on-device" or "server", stored with the meeting.
    var engineName: String { onDevice ? "on-device" : "apple-server" }

    func start() {
        beginRequest()
        let timer = Timer(timeInterval: Self.requestSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotation = timer
    }

    /// Ends the open request (its final result still arrives) and stops starting new ones.
    func stop() {
        rotation?.invalidate()
        rotation = nil
        feed.set(nil)
        current?.endAudio()
        current = nil
        onVolatile("")
    }

    /// Drops everything (the meeting is over and its last results have been taken).
    func cancel() {
        stop()
        for t in tasks { t.cancel() }
        tasks.removeAll()
    }

    private func rotate() {
        let old = current
        beginRequest()
        old?.endAudio()
    }

    private func beginRequest() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        let offset = meetingTime()
        current = request
        feed.set(request)
        let requestID = ObjectIdentifier(request)
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let isFinal = result.isFinal
            let lines = isFinal ? Self.lines(from: result.bestTranscription, offset: offset) : []
            let partial = isFinal ? "" : result.bestTranscription.formattedString
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isCurrent = self.current.map(ObjectIdentifier.init) == requestID
                if isFinal {
                    if !lines.isEmpty { self.onLines(lines) }
                    if isCurrent { self.onVolatile("") }
                } else if isCurrent {
                    self.onVolatile(HeardText.clean(partial))
                }
            }
        }
        tasks.removeAll { $0.state == .completed || $0.state == .canceling }
        tasks.append(task)
    }

    /// Splits a finished transcription into lines at pauses (over a second) or every ~80
    /// characters, keeping the recogniser's punctuation.
    nonisolated static func lines(from transcription: SFTranscription, offset: Double) -> [MeetingLine] {
        let full = transcription.formattedString as NSString
        let segments = transcription.segments
        guard full.length > 0 else { return [] }
        guard !segments.isEmpty else {
            let text = HeardText.clean(full as String)
            return text.isEmpty ? [] : [MeetingLine(id: UUID().uuidString, t: offset, text: text)]
        }
        var groups: [[SFTranscriptionSegment]] = []
        var size = 0
        for seg in segments {
            if let last = groups.last?.last {
                let gap = seg.timestamp - (last.timestamp + last.duration)
                if gap > 1.0 || size > 80 {
                    groups.append([seg])
                    size = seg.substring.count
                    continue
                }
                groups[groups.count - 1].append(seg)
                size += seg.substring.count
            } else {
                groups.append([seg])
                size = seg.substring.count
            }
        }
        var lines: [MeetingLine] = []
        for (i, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            let start = first.substringRange.location
            let end = i + 1 < groups.count ? (groups[i + 1].first?.substringRange.location ?? full.length) : full.length
            guard start >= 0, end > start, end <= full.length else { continue }
            let text = HeardText.clean(full.substring(with: NSRange(location: start, length: end - start)))
            if !text.isEmpty {
                lines.append(MeetingLine(id: UUID().uuidString, t: offset + first.timestamp, text: text))
            }
        }
        return lines
    }
}
