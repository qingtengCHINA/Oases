import AVFoundation
import Foundation

/// Transcribes recorded meeting audio with Xiaomi's MiMo ASR (`mimo-v2.5-asr`) through the
/// Oases gateway. MiMo takes WAV or MP3 as a base64 data URL of at most 10 MB in a
/// `chat/completions` request and returns plain punctuated text: no timestamps and no speaker
/// labels. So a chunk is cut at quiet moments into segments of about 40 s (16 kHz mono 16-bit
/// WAV, ~1.3 MB, ~1.7 MB as base64), each segment is sent on its own, and the text that comes
/// back is split into sentences timed across the segment's voiced stretches.
enum MeetingCloudASR {
    static let model = "mimo-v2.5-asr"
    static let sampleRate: Double = 16_000

    /// A segment ends at the quietest moment between `minimumSegment` and `maximumSegment`
    /// seconds, preferring moments near `targetSegment`.
    static let minimumSegment: Double = 25
    static let targetSegment: Double = 40
    static let maximumSegment: Double = 55
    /// Analysis frame for loudness, in samples (100 ms).
    static let frameSamples = 1_600

    enum Failure: LocalizedError {
        case unsupportedLanguage
        case unreadableAudio
        case unreadableReply

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage:
                return String(localized: "云端转写只支持中文和英文会议。", comment: "Meeting notes: cloud transcription supports Chinese and English only")
            case .unreadableAudio:
                return String(localized: "这段录音无法读取。", comment: "Meeting notes: a recorded audio chunk could not be read")
            case .unreadableReply:
                return String(localized: "云端转写的回复无法识别。", comment: "Meeting notes: the cloud transcription reply could not be parsed")
            }
        }
    }

    /// The `asr_options.language` for a meeting language (BCP 47), or nil when MiMo can't
    /// transcribe it. MiMo knows Chinese (with its dialects) and English; Cantonese is left to
    /// its own detection.
    static func asrLanguage(for bcp47: String) -> String? {
        let lower = bcp47.lowercased()
        if lower.hasPrefix("zh-hk") || lower.hasPrefix("yue") { return "auto" }
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("en") { return "en" }
        return nil
    }

    static func supports(language: String) -> Bool { asrLanguage(for: language) != nil }

    // MARK: - Transcribe a chunk

    /// Transcribes one recorded chunk; the lines carry meeting times.
    static func transcribe(chunkAt url: URL, chunkStart: Double, language: String) async throws -> [MeetingLine] {
        guard let asrLanguage = asrLanguage(for: language) else { throw Failure.unsupportedLanguage }
        let segments = try await Task.detached(priority: .utility) { try Self.segments(of: url) }.value
        guard !segments.isEmpty else { return [] }

        // A few segments at a time: the gateway sees a short burst instead of one request per
        // 40 s of a two-hour meeting at once.
        var texts = [String?](repeating: nil, count: segments.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func add() {
                guard next < segments.count else { return }
                let index = next
                let segment = segments[index]
                next += 1
                group.addTask { (index, try await request(segment, language: asrLanguage)) }
            }
            for _ in 0..<min(3, segments.count) { add() }
            while let (index, text) = try await group.next() {
                texts[index] = text
                add()
            }
        }

        var lines: [MeetingLine] = []
        for (segment, text) in zip(segments, texts) {
            guard let text else { continue }
            lines += Self.lines(from: text, segment: segment, chunkStart: chunkStart)
        }
        return lines
    }

    /// One segment to MiMo, with two retries for dropped connections, 429 and 5xx.
    private static func request(_ segment: Segment, language: String) async throws -> String {
        let audio = wav(segment.samples).base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "input_audio",
                    "input_audio": ["data": "data:audio/wav;base64,\(audio)"],
                ]],
            ]],
            "asr_options": ["language": language],
            "stream": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let client = APIClient(session: APIClient.longTimeout)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (reply, _) = try await client.data(path: "chat/completions", body: data)
                UsageLedger.record(json: reply, modelId: model)
                return try text(from: reply)
            } catch {
                attempt += 1
                guard attempt <= 2, isTransient(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 6))
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case APIError.badStatus(let code, _):
            return code == 408 || code == 429 || code >= 500
        case APIError.transport(let inner):
            guard let url = inner as? URLError else { return false }
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(url.code)
        default:
            return false
        }
    }

    /// The transcript in `choices[0].message.content` (a string, or text parts).
    static func text(from reply: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw Failure.unreadableReply
        }
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Audio

    /// A stretch of a chunk as 16 kHz mono samples.
    struct Segment: Sendable {
        /// Seconds into the chunk.
        let start: Double
        let samples: [Int16]
        /// Loudness per `frameSamples`, for timing lines.
        let frames: [Float]

        var duration: Double { Double(samples.count) / MeetingCloudASR.sampleRate }
    }

    /// Reads a chunk, converts it to 16 kHz mono and cuts it at quiet moments. Segments that are
    /// silent throughout are left out (nothing to transcribe, and silence invites made-up text).
    nonisolated static func segments(of url: URL) throws -> [Segment] {
        let samples = try monoSamples(of: url)
        guard !samples.isEmpty else { return [] }
        let frames = loudness(samples)
        let cuts = cutPoints(frames: frames, total: samples.count)
        var segments: [Segment] = []
        var from = 0
        for to in cuts + [samples.count] where to > from {
            let firstFrame = from / frameSamples
            let lastFrame = min(frames.count, (to + frameSamples - 1) / frameSamples)
            let segmentFrames = Array(frames[firstFrame..<max(firstFrame, lastFrame)])
            defer { from = to }
            guard (segmentFrames.max() ?? 0) >= 0.004 else { continue }
            let pcm = samples[from..<to].map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
            segments.append(Segment(start: Double(from) / sampleRate, samples: pcm, frames: segmentFrames))
        }
        return segments
    }

    /// Decodes the AAC chunk and resamples it to 16 kHz mono Float32.
    nonisolated static func monoSamples(of url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadableAudio }
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw Failure.unreadableAudio }
        converter.downmix = true

        let readCapacity: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readCapacity) else { throw Failure.unreadableAudio }
        let outCapacity = AVAudioFrameCount(Double(readCapacity) * sampleRate / max(1, inFormat.sampleRate)) + 1_024
        let source = ConverterSource(file: file, buffer: readBuffer, capacity: readCapacity)

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / max(1, inFormat.sampleRate)) + 1_024)
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { throw Failure.unreadableAudio }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                source.next(inputStatus)
            }
            if let channel = out.floatChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            }
            switch status {
            case .haveData, .inputRanDry:
                if source.finished && out.frameLength == 0 { return samples }
            case .endOfStream:
                return samples
            case .error:
                if samples.isEmpty { throw Failure.unreadableAudio }
                return samples
            @unknown default:
                return samples
            }
        }
    }

    /// Feeds the converter from the file, one read at a time.
    private final class ConverterSource: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let capacity: AVAudioFrameCount
        private(set) var finished = false

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer, capacity: AVAudioFrameCount) {
            self.file = file
            self.buffer = buffer
            self.capacity = capacity
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: capacity)
            } catch {
                finished = true
            }
            guard !finished, buffer.frameLength > 0 else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    /// RMS per `frameSamples`.
    nonisolated static func loudness(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frameSamples).map { start in
            let end = min(samples.count, start + frameSamples)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(max(1, end - start))).squareRoot()
        }
    }

    /// Sample offsets to cut at: the centre of the quietest 300 ms between the minimum and the
    /// maximum segment length, nudged towards the target length.
    nonisolated static func cutPoints(frames: [Float], total: Int) -> [Int] {
        let perSecond = sampleRate / Double(frameSamples)
        let minFrames = Int(minimumSegment * perSecond)
        let targetFrames = Int(targetSegment * perSecond)
        let maxFrames = Int(maximumSegment * perSecond)
        var cuts: [Int] = []
        var from = 0
        while frames.count - from > maxFrames {
            var best = from + targetFrames
            var bestScore = Float.greatestFiniteMagnitude
            for centre in (from + minFrames)...(from + maxFrames - 1) {
                let lo = max(0, centre - 1), hi = min(frames.count - 1, centre + 1)
                let quiet = frames[lo...hi].reduce(0, +) / Float(hi - lo + 1)
                // A small cost per second away from the target keeps cuts near it when the room
                // is equally quiet everywhere.
                let drift = Float(abs(centre - (from + targetFrames))) / Float(perSecond) * 0.0005
                if quiet + drift < bestScore {
                    bestScore = quiet + drift
                    best = centre
                }
            }
            cuts.append(min(total, best * frameSamples + frameSamples / 2))
            from = best
        }
        return cuts
    }

    /// 16-bit mono PCM WAV.
    nonisolated static func wav(_ samples: [Int16]) -> Data {
        let dataBytes = samples.count * 2
        var out = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        // iOS devices are little-endian, so the samples' bytes are already in WAV order.
        samples.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    // MARK: - Lines

    /// Splits a segment's text into lines and times each one by where its first character falls
    /// in the segment's voiced audio (MiMo returns no timestamps).
    nonisolated static func lines(from text: String, segment: Segment, chunkStart: Double) -> [MeetingLine] {
        let sentences = Self.sentences(HeardText.clean(text))
        guard !sentences.isEmpty else { return [] }
        let total = sentences.reduce(0) { $0 + $1.count }
        let voiceLevel = max(0.008, (segment.frames.max() ?? 0) * 0.12)
        let voiced = segment.frames.map { $0 >= voiceLevel }
        let voicedCount = voiced.filter { $0 }.count
        let frameSeconds = Double(frameSamples) / sampleRate

        func time(atFraction f: Double) -> Double {
            guard voicedCount > 0 else { return f * segment.duration }
            let wanted = Int((f * Double(voicedCount)).rounded(.down))
            var seen = 0
            for (i, isVoiced) in voiced.enumerated() where isVoiced {
                if seen == wanted { return Double(i) * frameSeconds }
                seen += 1
            }
            return segment.duration
        }

        var lines: [MeetingLine] = []
        var offset = 0
        for sentence in sentences {
            let t = chunkStart + segment.start + time(atFraction: Double(offset) / Double(max(1, total)))
            lines.append(MeetingLine(id: UUID().uuidString, t: t, text: sentence, cloud: true))
            offset += sentence.count
        }
        return lines
    }

    /// Sentences, short ones joined until a line has some substance, long ones split at commas.
    nonisolated static func sentences(_ text: String) -> [String] {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
        var raw: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let englishStop = c == "." && (i + 1 == chars.count || chars[i + 1] == " ")
            if enders.contains(c) || englishStop {
                raw.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { raw.append(rest) }

        var split: [String] = []
        for sentence in raw where !sentence.isEmpty {
            guard sentence.count > 90 else { split.append(sentence); continue }
            var piece = ""
            for c in sentence {
                piece.append(c)
                if (c == "，" || c == ",") && piece.count >= 40 {
                    split.append(piece.trimmingCharacters(in: .whitespaces))
                    piece = ""
                }
            }
            let tail = piece.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { split.append(tail) }
        }

        var joined: [String] = []
        for sentence in split {
            if let last = joined.last, last.count < 18, last.count + sentence.count <= 60 {
                let needsSpace = last.last.map { $0.isASCII && $0 != " " } ?? false
                joined[joined.count - 1] = last + (needsSpace ? " " : "") + sentence
            } else {
                joined.append(sentence)
            }
        }
        return joined
    }
}
