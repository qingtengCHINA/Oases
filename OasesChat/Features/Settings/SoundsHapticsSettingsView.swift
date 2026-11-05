import SwiftUI

/// 声音与触感: interface sounds and haptics, each with its own switch, plus a list to hear
/// every sound.
struct SoundsHapticsSettingsView: View {
    @AppStorage(SoundEffects.enabledKey) private var soundOn = true
    @AppStorage(HapticsPreference.key) private var hapticsOn = true

    var body: some View {
        List {
            Section {
                Toggle(SettingsCopy.t("音效", "Sound Effects"), isOn: $soundOn)
                    .onChange(of: soundOn) { _, on in
                        if on { SoundEffects.shared.play(.toggle, preview: true) }
                    }
                Toggle(SettingsCopy.t("触感反馈", "Haptics"), isOn: $hapticsOn)
                    .onChange(of: hapticsOn) { _, on in
                        if on { Haptics.select() }
                    }
            } footer: {
                Text(SettingsCopy.t(
                    "发送、长回复或任务完成、出错和需要你确认时，播放轻柔的提示音。提示音跟随静音开关和媒体音量，不会打断正在播放的音乐；听写、朗读、播放音频或通话时不会响。",
                    "Plays soft cues when you send, when a long reply or a task finishes, on errors, and when something needs your approval. Cues follow the Ring/Silent switch and media volume and never interrupt your music; they stay quiet during dictation, read-aloud, audio playback and calls."
                ))
            }

            Section {
                ForEach(SoundEffects.Cue.allCases) { cue in
                    Button {
                        SoundEffects.shared.play(cue, preview: true)
                    } label: {
                        HStack {
                            Text(cue.title)
                                .foregroundStyle(OasesColor.foreground)
                            Spacer()
                            Image(systemName: "speaker.wave.2")
                                .foregroundStyle(OasesColor.mutedForeground)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityHint(Text(SettingsCopy.t("播放这个提示音", "Plays this sound")))
                }
            } header: {
                Text(SettingsCopy.t("试听", "Preview"))
            } footer: {
                Text(SettingsCopy.t(
                    "提示音由 sensory-ui 的 Soft 音色渲染（MIT 许可）。",
                    "Sounds rendered from sensory-ui's Soft pack (MIT License)."
                ))
            }
            .disabled(!soundOn)
            .opacity(soundOn ? 1 : 0.5)
        }
        .navigationTitle(SettingsCopy.t("声音与触感", "Sounds & Haptics"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { SoundEffects.shared.prepare() }
    }
}
