@preconcurrency import SwiftUI
@preconcurrency import Speech
import AVFoundation

/// Inline dictation indicator shown above the composer while the device is
/// transcribing speech into the input field. Voice input is just the device's
/// speech recognizer feeding the text field live — no dedicated voice screen.
struct DictationIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .opacity(pulse ? 0.5 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("正在聆听…")
                .font(.oasesCaptionBold())
                .foregroundStyle(OasesColor.mutedForeground)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .onAppear { pulse = true }
    }
}

// MARK: - Speech Recognizer

private let dictationLogger = AppLogger(category: "Dictation")

/// Wraps `SFSpeechRecognizer` + `AVAudioEngine` to feed live transcripts into
/// the composer. Requests microphone + speech authorization before touching the
/// audio engine, tears down cleanly before any new session (never installs a
/// duplicate tap), and guards against unavailable recognizers — all of which
/// previously caused the dictation button to crash.
///
/// Route changes and interruptions (code review 2026-11-04 R6): unplugging
/// headphones or a Bluetooth mic connecting changes the input format and stops
/// the engine; a tap left installed with the old format makes AVAudioEngine
/// raise an Objective-C exception Swift cannot catch. So on a route or engine
/// configuration change the tap and engine are torn down at once and capture
/// restarts with a new engine, the new route's format and a fresh recognition
/// request; what was heard so far is kept. A system interruption (call, Siri,
/// alarm) ends dictation instead: no end is guaranteed, and the mic should not
/// come back on by itself after a call.
@Observable
@MainActor
final class SpeechRecognizer {
    var transcript = ""
    /// True from a successful start until the session ends — by `stop()` or
    /// because recognition finished on its own (silence, final result,
    /// error). The host observes it to reset its "listening" state.
    private(set) var isListening = false

    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    /// The format the current tap was installed with.
    @ObservationIgnored private var tapFormat: AVAudioFormat?
    /// Created per session in the user's recognition language (the same
    /// setting the voice panel uses), not a hard-coded zh-CN.
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?

    /// Text of the earlier recognition segments of this dictation (each route
    /// change starts a new segment) and of the current one.
    @ObservationIgnored private var committedTranscript = ""
    @ObservationIgnored private var segmentTranscript = ""
    /// Bumped per segment and on teardown: results of an older segment's task
    /// are ignored.
    @ObservationIgnored private var segmentGeneration = 0
    /// Whether this recognizer holds the coordinator's `.capture` intent, so a
    /// stop never releases another recorder's intent.
    @ObservationIgnored private var holdsCaptureIntent = false
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var engineObserver: NSObjectProtocol?
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    enum StartResult: Sendable { case started, denied, failed }

    typealias StartResultHandler = @MainActor @Sendable (StartResult) -> Void

    var isAvailable: Bool {
        (speechRecognizer ?? Self.makeRecognizer())?.isAvailable ?? false
    }

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: VoiceLanguages.lastUsed)) ?? SFSpeechRecognizer()
    }

    func requestAndStart(onResult: @escaping StartResultHandler) {
        // Both authorizations must be granted before touching the audio
        // engine — starting it without mic permission crashes. The auth
        // callbacks arrive on background queues, so hop back to the main
        // actor before touching `self`.
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVAudioApplication.requestRecordPermission { micGranted in
                Task { @MainActor in
                    guard speechStatus == .authorized, micGranted else {
                        onResult(.denied)
                        return
                    }
                    do {
                        try self.start()
                        onResult(.started)
                    } catch {
                        onResult(.failed)
                    }
                }
            }
        }
    }

    private func start() throws {
        // Tear down any prior session first — never install a tap on an
        // engine that already has one (that throws a fatal exception).
        stop()

        let recognizer = Self.makeRecognizer()
        speechRecognizer = recognizer
        guard let speechRecognizer = recognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "SpeechRecognizer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])
        }

        // Apple documents `.duckOthers` as settable only with playAndRecord,
        // playback or multiRoute; with `.record` `setCategory` can reject the
        // options (-50) and dictation never starts. `.record` already
        // silences other audio, so the option added nothing.
        // The coordinator owns the session (.record / .measurement for capture); setting the
        // category here directly left it stuck on .record and hid capture from the coordinator.
        // A meeting recording owns the microphone.
        guard !AudioSessionCoordinator.shared.isMeetingRecording else {
            throw NSError(domain: "SpeechRecognizer", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "正在录制会议，暂时不能听写。", comment: "Dictation refused while a meeting is being recorded")])
        }
        AudioSessionCoordinator.shared.begin(.capture)
        holdsCaptureIntent = true
        // Give the session back on every early exit below.
        var started = false
        defer { if !started { releaseCaptureIntent() } }
        guard AVAudioSession.sharedInstance().category == .record else {
            throw NSError(domain: "SpeechRecognizer", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])
        }

        committedTranscript = ""
        segmentTranscript = ""
        transcript = ""
        try startCaptureSegment(with: speechRecognizer)
        isListening = true
        started = true
        observeAudioSession()
    }

    /// A new engine, a tap in the current route's hardware format and a fresh
    /// recognition request. Used at start and after every route change.
    private func startCaptureSegment(with speechRecognizer: SFSpeechRecognizer) throws {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device when available falls back to server automatically.
        // Limited mode (no consent): keep audio on the device whenever this
        // recognizer can.
        request.requiresOnDeviceRecognition = !AIDataSharingConsent.isAccepted
            && speechRecognizer.supportsOnDeviceRecognition

        let inputNode = engine.inputNode
        // The hardware format of the route as it is now. A tap whose sample
        // rate differs from the hardware's raises an Objective-C exception
        // ("format.sampleRate == hwFormat.sampleRate"), so never reuse a format
        // read before a route change.
        let format = inputNode.inputFormat(forBus: 0)
        // A format with a zero sample rate (common on the Simulator, which
        // has no real microphone, and for a moment mid route change) makes
        // installTap fatal-crash — bail out gracefully instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SpeechRecognizer", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "音频输入格式无效")])
        }
        // installTap and start can raise Objective-C exceptions when the route
        // is mid-change; noff_try_objc turns them into a failed start.
        var installed = noff_try_objc {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
        }
        if !installed {
            // Let Core Audio pick the node's native format if the explicit one
            // and the bus still disagree.
            installed = noff_try_objc {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    request.append(buffer)
                }
            }
        }
        guard installed else {
            throw NSError(domain: "SpeechRecognizer", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])
        }

        engine.prepare()
        var startError: Error?
        let didStart = noff_try_objc {
            do { try engine.start() } catch { startError = error }
        }
        guard didStart, startError == nil else {
            _ = noff_try_objc { inputNode.removeTap(onBus: 0) }
            throw startError ?? NSError(domain: "SpeechRecognizer", code: -6,
                                        userInfo: [NSLocalizedDescriptionKey: String(localized: "语音识别不可用")])
        }

        audioEngine = engine
        tapFormat = format
        recognitionRequest = request
        segmentTranscript = ""
        segmentGeneration += 1
        let generation = segmentGeneration
        observeEngineConfiguration(engine)

        recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
            let isFinal = error != nil || (result?.isFinal ?? false)
            let text = result?.bestTranscription.formattedString
            Task { @MainActor in
                // A segment replaced after a route change, or a stopped
                // session, must not touch the current one.
                guard generation == self.segmentGeneration else { return }
                if let text {
                    self.segmentTranscript = text
                    self.transcript = Self.joined(self.committedTranscript, text)
                }
                if isFinal { self.stop() }
            }
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        removeObservers()
        tearDownCapture()
        transcript = committedTranscript
        isListening = false
        releaseCaptureIntent()
    }

    /// Stops the engine and tap and ends the current recognition segment,
    /// keeping what it heard. The audio session intent is left alone.
    private func tearDownCapture() {
        segmentGeneration += 1
        committedTranscript = Self.joined(committedTranscript, segmentTranscript)
        segmentTranscript = ""
        recognitionTask?.cancel()
        recognitionTask = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            _ = noff_try_objc { engine.inputNode.removeTap(onBus: 0) }
        }
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        audioEngine = nil
        tapFormat = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    private func releaseCaptureIntent() {
        guard holdsCaptureIntent else { return }
        holdsCaptureIntent = false
        AudioSessionCoordinator.shared.end(.capture)
    }

    // MARK: - Route changes and interruptions

    private func observeAudioSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // AVAudioSession posts these on its own thread; `.main` delivers them
        // on the main thread, where the engine and this object live.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self?.interruptionBegan()
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                self?.routeChanged(reason: reason)
            }
        })
    }

    private func observeEngineConfiguration(_ engine: AVAudioEngine) {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        // Posted when the hardware I/O format changes; the engine has already
        // stopped and its tap format is stale.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartCapture(reason: "engine configuration change")
            }
        }
    }

    private func removeObservers() {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func interruptionBegan() {
        guard isListening else { return }
        dictationLogger.info("interruption began → dictation stopped")
        stop()
    }

    private func routeChanged(reason: UInt) {
        guard isListening, restartTask == nil else { return }
        // Most route changes leave capture alone; act only when the engine
        // stopped or the hardware format no longer matches the tap.
        if let engine = audioEngine, engine.isRunning, let tapFormat {
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            if hardware.sampleRate == tapFormat.sampleRate, hardware.channelCount == tapFormat.channelCount {
                return
            }
        }
        restartCapture(reason: "route change (reason \(reason))")
    }

    /// Tears the tap down now — it must never outlive the format it was
    /// installed with — and starts a new segment once the route settles.
    /// Gives up, keeping the transcript, after a few failed attempts.
    private func restartCapture(reason: String) {
        guard isListening else { return }
        dictationLogger.info("\(reason) → restarting capture")
        tearDownCapture()
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            // A route change and an engine configuration change usually come
            // together, and the new input can read 0 Hz for a moment.
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, self.isListening else { return }
                guard let recognizer = self.speechRecognizer else { break }
                do {
                    try self.startCaptureSegment(with: recognizer)
                    self.restartTask = nil
                    dictationLogger.info("capture resumed on the new route (attempt \(attempt))")
                    return
                } catch {
                    dictationLogger.warning("capture restart attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            self.stop()
        }
    }

    /// Joins segment transcripts: no space between Chinese/Japanese text,
    /// one space otherwise.
    nonisolated static func joined(_ head: String, _ tail: String) -> String {
        let head = head.trimmingCharacters(in: .whitespaces)
        let tail = tail.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        if let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first,
           isSpacelessScript(last) || isSpacelessScript(first) {
            return head + tail
        }
        return head + " " + tail
    }

    private nonisolated static func isSpacelessScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF,   // CJK punctuation, Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF:   // Full-width forms
            return true
        default:
            return false
        }
    }
}
