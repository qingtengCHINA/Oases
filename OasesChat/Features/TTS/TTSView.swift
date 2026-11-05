import SwiftUI
import AVFoundation
import UIKit

/// Renders an audio-mode assistant message: a play/pause control with a
/// progress bar and a download action. Mirrors Web's `<audio controls>` +
/// export button. Each message owns its own `AVAudioPlayer` via a
/// `@StateObject` player holder so multiple audio messages can coexist.
struct AudioMessageView: View {
    let audioUrl: String
    let mimeType: String

    @StateObject private var holder = AudioPlayerHolder()
    @State private var showActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.xs) {
            HStack(spacing: OasesSpacing.sm) {
                Button(action: toggle) {
                    Image(systemName: holder.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(OasesColor.primary))
                }
                .buttonStyle(.plain)
                .disabled(holder.isLoading)

                if holder.isLoading {
                    ProgressView().tint(OasesColor.primary).scaleEffect(0.8)
                }

                if let duration = holder.duration {
                    Text(format(duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground)
                }

                Spacer()

                Button {
                    Haptics.tap()
                    UIPasteboard.general.string = audioUrl
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                .buttonStyle(.plain)

                Button {
                    showActions = true
                } label: {
                    Label("下载", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .fill(OasesColor.card.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .padding(.top, OasesSpacing.xs)
        .onAppear { holder.configure(url: audioUrl, mime: mimeType) }
        .confirmationDialog("音频操作", isPresented: $showActions, titleVisibility: .visible) {
            Button("分享音频") { shareAudio() }
            Button("存储到文件") { saveToFiles() }
            Button("取消", role: .cancel) {}
        }
    }

    private func toggle() {
        holder.toggle()
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The audio bytes — reused from the player when already loaded,
    /// otherwise decoded / downloaded off the main actor.
    private func audioData() async -> Data? {
        if let loaded = holder.loadedData { return loaded }
        return await AudioPlayerHolder.loadData(from: audioUrl)
    }

    private var fileExtension: String {
        switch mimeType {
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        case "audio/webm": return "webm"
        default: return "mp3"
        }
    }

    /// Writes the audio to a temp file and shares it via the activity sheet
    /// — this is the only supported way to let the user save it to Files or
    /// share it to other apps on iOS.
    private func shareAudio() {
        Haptics.tap()
        Task {
            guard let data = await audioData(), let url = writeTempFile(data: data) else { return }
            presentActivity(items: [url])
        }
    }

    private func saveToFiles() {
        Haptics.tap()
        Task {
            guard let data = await audioData(), let url = writeTempFile(data: data) else { return }
            presentActivity(items: [url])
        }
    }

    private func writeTempFile(data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("oases-\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func presentActivity(items: [Any]) {
        guard let presenter = topMostController() else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private func topMostController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

@MainActor
final class AudioPlayerHolder: ObservableObject {
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var duration: TimeInterval?
    /// Bytes behind the player, kept so share / save don't fetch again.
    private(set) var loadedData: Data?

    private var player: AVAudioPlayer?
    private var delegate: AudioDelegate?
    private var isConfiguring = false
    /// A call / Siri / alarm pauses the player without telling its delegate,
    /// so the button used to stay on "pause" after the call. Removed in deinit.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // queue: .main, so this runs on the main thread.
            MainActor.assumeIsolated { self?.interruptionBegan() }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// The system already paused playback; show "play" again. No automatic
    /// resume: the user taps play to continue from where it stopped.
    private func interruptionBegan() {
        if isPlaying { isPlaying = false }
    }

    func configure(url: String, mime: String) {
        guard player == nil, !isConfiguring else { return }
        isConfiguring = true
        isLoading = true
        Task { [weak self] in
            // Network / base64 work runs off the main actor — the previous
            // synchronous `Data(contentsOf:)` here blocked the UI.
            let data = await AudioPlayerHolder.loadData(from: url)
            guard let self else { return }
            self.isConfiguring = false
            self.isLoading = false
            guard let data else { return }
            self.loadedData = data
            let delegate = AudioDelegate { [weak self] in
                Task { @MainActor in self?.isPlaying = false }
            }
            self.delegate = delegate
            let p = try? AVAudioPlayer(data: data)
            p?.delegate = delegate
            p?.prepareToPlay()
            self.player = p
            self.duration = p?.duration
        }
    }

    /// Decodes a `data:` URL or downloads a remote one, off the main actor.
    nonisolated static func loadData(from url: String) async -> Data? {
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            let b64 = String(url[url.index(after: comma)...])
            return await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: b64)
            }.value
        }
        guard let remote = URL(string: url) else { return nil }
        if remote.isFileURL {
            return await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: remote)
            }.value
        }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 60
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = result.1 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        return result.0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            Haptics.tap()
        }
    }
}

/// Bridges `AVAudioPlayerDelegate` finish back to a closure.
final class AudioDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    /// A decode error ends playback too; reset the button the same way.
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish() }
}
