import AVFoundation
import Speech

/// Where the recorder's microphone tap sends audio for live recognition.
protocol MeetingAudioSink: AnyObject, Sendable {
    /// Called on the audio tap thread; the buffer is only valid during the call.
    func append(_ buffer: AVAudioPCMBuffer)
}

/// Live recognition during a meeting. `stop()` ends the current stretch (pause, interruption)
/// and keeps final results coming; `start()` begins a new stretch at the current meeting time.
@MainActor
protocol MeetingLiveTranscribing: AnyObject {
    var audioSink: any MeetingAudioSink { get }
    /// Stored with the meeting: "speech-analyzer", "on-device" or "apple-server".
    var engineName: String { get }
    func start()
    func stop()
    func cancel()
}

extension MeetingTranscriber.Feed: MeetingAudioSink {}

extension MeetingTranscriber: MeetingLiveTranscribing {
    var audioSink: any MeetingAudioSink { feed }
}

enum MeetingLiveTranscription {
    /// The best live recogniser for `locale`: on iOS 26 the SpeechAnalyzer transcriber when its
    /// model for the language is on the device (no one-minute request limit, better long-form
    /// accuracy, always on the device), else `SFSpeechRecognizer`. A missing model is downloaded
    /// in the background so the next meeting gets it.
    @MainActor
    static func make(locale: Locale,
                     meetingTime: @escaping @MainActor () -> Double,
                     onVolatile: @escaping @MainActor (String) -> Void,
                     onLines: @escaping @MainActor ([MeetingLine]) -> Void) async -> (any MeetingLiveTranscribing)? {
        if #available(iOS 26.0, *), let prepared = await MeetingAnalyzerTranscriber.prepare(locale: locale) {
            return MeetingAnalyzerTranscriber(locale: prepared.locale, format: prepared.format,
                                              meetingTime: meetingTime, onVolatile: onVolatile, onLines: onLines)
        }
        return MeetingTranscriber(locale: locale, meetingTime: meetingTime, onVolatile: onVolatile, onLines: onLines)
    }
}

/// Live meeting recognition with iOS 26's `SpeechAnalyzer` + `SpeechTranscriber`. The tap's
/// audio is converted to the analyzer's format and streamed in; volatile results show what is
/// being heard, final results become transcript lines timed by the result's audio range.
@available(iOS 26.0, *)
@MainActor
final class MeetingAnalyzerTranscriber: MeetingLiveTranscribing {
    /// Converts tap buffers and hands them to the analyzer's input stream (tap thread).
    final class Sink: MeetingAudioSink, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private var converter: AVAudioConverter?
        private let format: AVAudioFormat

        init(format: AVAudioFormat) { self.format = format }

        func open(_ continuation: AsyncStream<AnalyzerInput>.Continuation) {
            lock.lock(); self.continuation = continuation; lock.unlock()
        }

        func close() {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.finish()
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation, buffer.frameLength > 0 else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return }
            let ratio = format.sampleRate / max(1, buffer.format.sampleRate)
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            // The converter copies, so the analyzer never holds the tap's reused buffer.
            let input = OneShotInput(buffer)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in input.next(status) }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
    }

    /// Hands one buffer to the converter, then reports no more data for now.
    private final class OneShotInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else {
                status.pointee = .noDataNow
                return nil
            }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }

    let engineName = "speech-analyzer"
    var audioSink: any MeetingAudioSink { sink }

    private let locale: Locale
    private let sink: Sink
    private let meetingTime: @MainActor () -> Double
    private let onVolatile: @MainActor (String) -> Void
    private let onLines: @MainActor ([MeetingLine]) -> Void
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var finishing: [Task<Void, Never>] = []
    private let logger = AppLogger(category: "Meeting")

    init(locale: Locale, format: AVAudioFormat,
         meetingTime: @escaping @MainActor () -> Double,
         onVolatile: @escaping @MainActor (String) -> Void,
         onLines: @escaping @MainActor ([MeetingLine]) -> Void) {
        self.locale = locale
        sink = Sink(format: format)
        self.meetingTime = meetingTime
        self.onVolatile = onVolatile
        self.onLines = onLines
    }

    /// The supported locale and the analyzer's audio format, or nil when SpeechAnalyzer can't be
    /// used for `locale` right now (unsupported device or language, model not downloaded yet).
    static func prepare(locale: Locale) async -> (locale: Locale, format: AVAudioFormat)? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let wanted = supported.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            Task.detached(priority: .background) {
                let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try? await request.downloadAndInstall()
                }
            }
            return nil
        }
        let probe = Self.module(for: supported)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { return nil }
        return (supported, format)
    }

    private static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    func start() {
        let offset = meetingTime()
        let module = Self.module(for: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        sink.open(continuation)

        let onVolatile = self.onVolatile
        let onLines = self.onLines
        let logger = self.logger
        results = Task { @MainActor in
            do {
                for try await result in module.results {
                    let text = HeardText.clean(String(result.text.characters))
                    if result.isFinal {
                        onVolatile("")
                        let start = result.range.start.seconds
                        let duration = result.range.duration.seconds
                        let lines = Self.lines(text, start: offset + (start.isFinite ? start : 0),
                                               duration: duration.isFinite ? duration : 0)
                        if !lines.isEmpty { onLines(lines) }
                    } else {
                        onVolatile(text)
                    }
                }
            } catch {
                logger.error("speech analyzer results ended: \(error.localizedDescription)")
            }
        }
        Task {
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                logger.error("speech analyzer failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// Ends the stretch; its last final results still arrive.
    func stop() {
        sink.close()
        onVolatile("")
        guard let analyzer else { return }
        self.analyzer = nil
        let logger = self.logger
        finishing.append(Task {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                logger.error("speech analyzer finalize failed: \(error.localizedDescription)")
            }
        })
    }

    func cancel() {
        sink.close()
        let analyzer = self.analyzer
        self.analyzer = nil
        results?.cancel()
        results = nil
        finishing.forEach { $0.cancel() }
        finishing.removeAll()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// One line per final result, long results split at sentence ends with times spread across
    /// the result's audio range.
    nonisolated static func lines(_ text: String, start: Double, duration: Double) -> [MeetingLine] {
        guard !text.isEmpty else { return [] }
        let sentences = MeetingCloudASR.sentences(text)
        let total = max(1, sentences.reduce(0) { $0 + $1.count })
        var offset = 0
        return sentences.map { sentence in
            defer { offset += sentence.count }
            let t = start + duration * Double(offset) / Double(total)
            return MeetingLine(id: UUID().uuidString, t: t, text: sentence)
        }
    }
}
