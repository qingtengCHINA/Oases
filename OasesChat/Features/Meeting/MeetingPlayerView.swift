import AVFoundation
import SwiftUI

/// The meeting's recording: play, pause, scrub, with the elapsed and total time. Taps on
/// transcript lines can seek here through `seekRequest`.
struct MeetingPlayerView: View {
    let url: URL
    let duration: TimeInterval
    /// Set to a meeting time to jump there (the view resets it to nil).
    @Binding var seekRequest: Double?

    @State private var player = MeetingPlayer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: OasesSpacing.sm) {
            Button {
                player.toggle()
                Haptics.select()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(OasesColor.primary, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(OasesPressStyle(scale: 0.94))
            .accessibilityLabel(Text(player.isPlaying
                                     ? String(localized: "暂停", comment: "Meeting notes: pause recording")
                                     : String(localized: "播放录音", comment: "Meeting notes: play the recording")))

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { player.isScrubbing ? player.scrubTime : player.currentTime },
                    set: { player.scrub(to: $0) }
                ), in: 0...max(1, player.duration > 0 ? player.duration : duration)) { editing in
                    player.endScrub(editing: editing)
                }
                .tint(OasesColor.primary)
                HStack {
                    Text(verbatim: MeetingExport.clock(player.isScrubbing ? player.scrubTime : player.currentTime))
                    Spacer()
                    Text(verbatim: MeetingExport.clock(player.duration > 0 ? player.duration : duration))
                }
                .font(.oasesCaption().monospacedDigit())
                .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .padding(OasesSpacing.md)
        .background(OasesColor.card, in: RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5)
        )
        .onAppear { player.load(url) }
        .onDisappear { player.unload() }
        .onChange(of: url) { _, new in player.load(new) }
        .onChange(of: seekRequest) { _, t in
            guard let t else { return }
            player.seek(to: t, play: true)
            seekRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.pause() }
        }
    }
}

/// AVPlayer behind the card. Playback takes the media-attachment audio intent so it coexists
/// with the coordinator's other users and never competes with a recording in progress.
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isScrubbing = false
    private(set) var scrubTime: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var holdsIntent = false

    func load(_ url: URL) {
        unload()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = max(0, time.seconds)
                if self.duration == 0, let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.releaseIntent()
                self.player?.seek(to: .zero)
                self.currentTime = 0
            }
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self?.duration = d.seconds
            }
        }
    }

    func unload() {
        pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        currentTime = 0
        duration = 0
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        if !holdsIntent {
            AudioSessionCoordinator.shared.begin(.mediaAttachment)
            holdsIntent = true
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        releaseIntent()
    }

    func seek(to time: TimeInterval, play: Bool) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, time)
        if play, !isPlaying { self.play() }
    }

    func scrub(to time: TimeInterval) {
        isScrubbing = true
        scrubTime = time
    }

    func endScrub(editing: Bool) {
        guard !editing else { return }
        isScrubbing = false
        seek(to: scrubTime, play: false)
    }

    private func releaseIntent() {
        guard holdsIntent else { return }
        AudioSessionCoordinator.shared.end(.mediaAttachment)
        holdsIntent = false
    }
}
