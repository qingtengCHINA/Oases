import AVFoundation
import Foundation

final class SpeechFinishedDelegate: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task<Void, Never> { @MainActor in
            let mgr = BackgroundKeepAliveManager.shared
            if mgr.backgroundSpeakEnabled && mgr.isActive {
                mgr.evaluateSilentAudioFromDelegate()
            }
        }
    }
}
