import Foundation

/// Energy-based stand-in for the RealTimeCutVADLibrary binary (Silero + WebRTC).
/// Drop-in API surface so OpenMinis `VoiceActivityDetector` compiles offline
/// when the remote xcframework cannot be fetched. Swap `vendor/spm` path back
/// to the real package once the binary is available locally.

public enum SL: Int {
    case SAMPLERATE_8 = 0
    case SAMPLERATE_16 = 1
    case SAMPLERATE_24 = 2
    case SAMPLERATE_48 = 3
}

public enum SMVER: Int {
    case v4 = 0
    case v5 = 1
}

@objc public protocol VADDelegate: AnyObject {
    func voiceStarted()
    func voiceEnded(withWavData wavData: Data!)
    @objc optional func voiceDidContinue(withPCMFloatData pcmFloatData: Data!)
}

/// Mirrors the ObjC `VADWrapper` used by OpenMinis VoiceActivityDetector.
public final class VADWrapper: NSObject {
    public weak var delegate: VADDelegate?

    private var sampleRate: Double = 16000
    private var startProb: Float = 0.7
    private var endProb: Float = 0.7
    private var startTrueRatio: Float = 0.8
    private var endFalseRatio: Float = 0.95
    private var startFrameCount: Int = 10
    private var endFrameCount: Int = 57

    private var speaking = false
    private var startHits = 0
    private var endHits = 0
    private var segmentPCM: [Float] = []
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    public func setSamplerate(_ sl: SL) {
        switch sl {
        case .SAMPLERATE_8:  sampleRate = 8000
        case .SAMPLERATE_16: sampleRate = 16000
        case .SAMPLERATE_24: sampleRate = 24000
        case .SAMPLERATE_48: sampleRate = 48000
        }
    }

    public func setSileroModel(_ modelVersion: SMVER) {
        // no-op — stub has no Silero weights
        _ = modelVersion
    }

    public func setThresholdWithVadStartDetectionProbability(
        _ a: Float,
        vadEndDetectionProbability b: Float,
        voiceStartVadTrueRatio c: Float,
        voiceEndVadFalseRatio d: Float,
        voiceStartFrameCount e: Int32,
        voiceEndFrameCount f: Int32
    ) {
        startProb = a
        endProb = b
        startTrueRatio = c
        endFalseRatio = d
        startFrameCount = max(1, Int(e))
        endFrameCount = max(1, Int(f))
    }

    @available(*, deprecated, message: "Use processAudioData(withBuffer:count:)")
    public func processAudioData(_ audioData: [NSNumber]) {
        let floats = audioData.map { $0.floatValue }
        floats.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                processAudioData(withBuffer: base, count: UInt(buf.count))
            }
        }
    }

    public func processAudioData(withBuffer audioData: UnsafePointer<Float>, count: UInt) {
        let n = Int(count)
        guard n > 0 else { return }

        var sumSq: Float = 0
        for i in 0..<n { sumSq += audioData[i] * audioData[i] }
        let rms = sqrt(sumSq / Float(n))
        // Map RMS to a pseudo-probability. Speech-ish frames typically > 0.01.
        let prob = min(1.0, max(0.0, (rms - 0.005) / 0.08))

        lock.lock()
        defer { lock.unlock() }

        if !speaking {
            if prob >= startProb * 0.6 { // slightly looser than real Silero
                startHits += 1
            } else {
                startHits = max(0, startHits - 1)
            }
            if startHits >= startFrameCount {
                speaking = true
                startHits = 0
                endHits = 0
                segmentPCM.removeAll(keepingCapacity: true)
                for i in 0..<n { segmentPCM.append(audioData[i]) }
                let del = delegate
                DispatchQueue.main.async { del?.voiceStarted() }
            }
        } else {
            for i in 0..<n { segmentPCM.append(audioData[i]) }
            // Live continuum callback (optional on delegate).
            let chunk = UnsafeBufferPointer(start: audioData, count: n)
            let data = Data(buffer: chunk)
            let del = delegate
            DispatchQueue.main.async {
                del?.voiceDidContinue?(withPCMFloatData: data)
            }

            if prob < endProb * 0.5 {
                endHits += 1
            } else {
                endHits = max(0, endHits - 1)
            }
            if endHits >= endFrameCount {
                speaking = false
                endHits = 0
                let wav = Self.makeWav(samples: segmentPCM, sampleRate: 16000)
                segmentPCM.removeAll(keepingCapacity: true)
                let del = delegate
                DispatchQueue.main.async { del?.voiceEnded(withWavData: wav) }
            }
        }
    }

    /// Minimal 16-bit mono WAV encoder for the stub end-of-segment payload.
    private static func makeWav(samples: [Float], sampleRate: Double) -> Data {
        // Resample naively by picking every Nth sample toward 16 kHz if needed.
        // Caller already mixes at various rates; for stub we just clamp.
        let sr = Int(sampleRate)
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for s in samples {
            let clipped = max(-1.0, min(1.0, s))
            pcm.append(Int16(clipped * Float(Int16.max)))
        }
        let dataSize = pcm.count * 2
        var data = Data()
        func appendASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendU32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(1) // mono
        appendU32(UInt32(sr))
        appendU32(UInt32(sr * 2))
        appendU16(2)
        appendU16(16)
        appendASCII("data")
        appendU32(UInt32(dataSize))
        pcm.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self), count: dataSize))
        }
        // Safer append:
        // rewrite last part cleanly
        return encodeWav(pcm: pcm, sampleRate: sr)
    }

    private static func encodeWav(pcm: [Int16], sampleRate: Int) -> Data {
        let dataSize = pcm.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + dataSize)
        func put(_ s: String) { data.append(contentsOf: s.utf8) }
        func put16(_ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func put32(_ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        put("RIFF"); put32(UInt32(36 + dataSize)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(dataSize))
        pcm.withUnsafeBufferPointer { buf in
            let raw = UnsafeRawBufferPointer(buf)
            data.append(contentsOf: raw)
        }
        return data
    }
}
