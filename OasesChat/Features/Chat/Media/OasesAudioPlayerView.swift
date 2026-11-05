//
//  OasesAudioPlayerView.swift
//  OasesChat
//
//  Inline audio bubble for minis:// media URLs. Ported from OpenMinis
//  Views/Chat/Media/AudioPlayback.swift.
//

import SwiftUI

struct OasesAudioPlayerView: View {
    let url: URL
    let fileURL: URL
    @ObservedObject private var player = GlobalAudioPlayer.shared
    @State private var fileReady = false
    @State private var showPreview = false

    /// Fixed height for both placeholder and controls to prevent layout jumps.
    private let controlsHeight: CGFloat = 70

    /// Whether this file is the one currently active in the global player.
    private var isActive: Bool { player.isActive(url: fileURL) }

    var body: some View {
        if fileReady {
            audioControls
        } else {
            placeholder
                .task { await waitForFile() }
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.caption2)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .font(.caption)
                Spacer()
                Button {
                    showPreview = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(ChatColors.secondaryText)

            HStack(spacing: 10) {
                Button {
                    if isActive {
                        player.togglePlayPause()
                    } else {
                        player.play(url: fileURL)
                    }
                } label: {
                    Image(systemName: isActive && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                if isActive && player.isLoaded {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.debouncedSeek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.01)
                    )
                    .tint(.accentColor)

                    Text(formatTime(player.duration))
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                        .monospacedDigit()
                } else {
                    Slider(value: .constant(0), in: 0...1)
                        .tint(.accentColor)
                        .disabled(true)

                    Text(formatTime(0))
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 320, minHeight: controlsHeight)
        .background(ChatColors.secondaryBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showPreview) {
            OasesAudioPreviewView(fileURL: fileURL)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(url.lastPathComponent).lineLimit(1)
        }
        .font(.caption)
        .foregroundColor(ChatColors.secondaryText)
        .padding(10)
        .frame(maxWidth: 320, minHeight: controlsHeight)
        .background(ChatColors.secondaryBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func waitForFile() async {
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                fileReady = true
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        fileReady = true
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
