import AVFoundation
import UIKit

/// Soft interface sounds for a few moments that matter: sending, a long reply or an Ogent task
/// finishing, an error, a request for approval, the deep-thinking switch, moving a file to
/// Recently Deleted, and copying.
///
/// Sounds go through `AudioSessionCoordinator`'s lowest-priority `.uiSound` intent, which uses
/// the `.ambient` category: they follow the Ring/Silent switch, mix with the user's music without
/// ducking it, and never play while the app is capturing, speaking, playing media, in a call,
/// or in the background. Every sound has a visual counterpart; this only confirms it.
///
/// The cues were rendered offline from sensory-ui's "Soft" sound pack (MIT, Satyam Vyas).
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    enum Cue: String, CaseIterable, Identifiable {
        case send
        case replyDone = "reply_done"
        case taskDone = "task_done"
        case error
        case attention
        case toggle
        case trash
        case copy

        var id: String { rawValue }
        var fileName: String { "ui_" + rawValue }

        /// Player volume; the files share one loudness scale.
        var volume: Float {
            switch self {
            case .send: return 0.30
            case .replyDone: return 0.35
            case .taskDone: return 0.45
            case .error: return 0.40
            case .attention: return 0.40
            case .toggle: return 0.22
            case .trash: return 0.28
            case .copy: return 0.20
            }
        }

        /// Outcomes and requests are foreground cues; they win over interaction cues.
        var isForeground: Bool {
            switch self {
            case .replyDone, .taskDone, .error, .attention: return true
            case .send, .toggle, .trash, .copy: return false
            }
        }

        /// Name in the settings preview list.
        var title: String {
            switch self {
            case .send: return String(localized: "发送", comment: "Sound effects preview: the cue played when a message is sent")
            case .replyDone: return String(localized: "回复完成", comment: "Sound effects preview: the cue played when a long reply finishes")
            case .taskDone: return String(localized: "任务完成", comment: "Sound effects preview: the cue played when an Ogent task finishes")
            case .error: return String(localized: "出错", comment: "Sound effects preview: the cue played on an error")
            case .attention: return String(localized: "需要确认", comment: "Sound effects preview: the cue played when something needs the user's approval")
            case .toggle: return String(localized: "开关", comment: "Sound effects preview: the cue played when a composer switch flips")
            case .trash: return String(localized: "移入最近删除", comment: "Sound effects preview: the cue played when a file moves to Recently Deleted")
            case .copy: return String(localized: "复制", comment: "Sound effects preview: the cue played when text is copied")
            }
        }
    }

    static let enabledKey = "ui.soundEffectsEnabled"
    /// On unless the user turned it off.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var players: [Cue: AVAudioPlayer] = [:]
    private weak var current: AVAudioPlayer?
    private var currentCue: Cue?
    private var currentStartedAt: CFTimeInterval = 0
    private var lastAny: CFTimeInterval = 0
    private var lastForeground: CFTimeInterval = 0
    private var lastByCue: [Cue: CFTimeInterval] = [:]
    private var recent: [CFTimeInterval] = []
    private var releaseTask: Task<Void, Never>?

    private init() {}

    /// Plays `cue` if sounds are on and nothing else needs the audio session. `preview` (the
    /// settings list) plays even when sounds are off and skips the throttle.
    func play(_ cue: Cue, preview: Bool = false) {
        guard preview || Self.isEnabled else { return }
        guard UIApplication.shared.applicationState == .active,
              AudioSessionCoordinator.shared.isIdleForUISound,
              !VoiceOutputPlayer.shared.isPlaying, !VoiceOutputPlayer.shared.isSynthesizing
        else { return }
        let now = CACurrentMediaTime()
        guard preview || passesThrottle(cue, now: now) else { return }
        guard let player = player(for: cue) else { return }

        // A foreground cue cuts an interaction cue that only just started (send, then an
        // immediate error: only the error is heard).
        if let current, current.isPlaying {
            current.stop()
        }
        AudioSessionCoordinator.shared.begin(.uiSound)
        player.currentTime = 0
        player.volume = cue.volume
        player.play()
        current = player
        currentCue = cue
        currentStartedAt = now
        lastAny = now
        lastByCue[cue] = now
        if cue.isForeground { lastForeground = now }
        recent.append(now)

        releaseTask?.cancel()
        let hold = player.duration + 0.3
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            AudioSessionCoordinator.shared.end(.uiSound)
            self?.current = nil
            self?.currentCue = nil
        }
    }

    /// Loads every cue so the first one plays without a decode delay.
    func prepare() {
        for cue in Cue.allCases { _ = player(for: cue) }
    }

    // MARK: - Throttle

    /// At most one cue per 120 ms, the same cue once per 0.5 s, foreground cues 1.5 s apart,
    /// four cues in any 10 s. A foreground cue may interrupt an interaction cue under 0.3 s old.
    private func passesThrottle(_ cue: Cue, now: CFTimeInterval) -> Bool {
        recent.removeAll { now - $0 > 10 }
        if recent.count >= 4 { return false }
        if let last = lastByCue[cue], now - last < 0.5 { return false }
        if cue.isForeground {
            if now - lastForeground < 1.5 { return false }
            if now - lastAny < 0.12, let currentCue, currentCue.isForeground { return false }
            return true
        }
        // Interaction cues never cut into a foreground cue.
        if now - lastForeground < 1.5 { return false }
        return now - lastAny >= 0.12
    }

    private func player(for cue: Cue) -> AVAudioPlayer? {
        if let p = players[cue] { return p }
        guard let url = Bundle.main.url(forResource: cue.fileName, withExtension: "caf"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.prepareToPlay()
        players[cue] = p
        return p
    }
}

/// App-wide haptics switch (the system's own setting still applies on top).
enum HapticsPreference {
    static let key = "ui.hapticsEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
