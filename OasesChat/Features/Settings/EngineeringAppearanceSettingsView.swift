import SwiftUI

struct AppIconOption: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let iconName: String?  // nil = automatic (default asset catalog icon)
    let imageName: String  // bundle image file name for preview
}

struct LanguageOption: Identifiable {
    let id: String   // language code, "" = system
    let name: String  // native name
    let flag: String
}

/// Native names are shown as-is in every UI language; "System" is
/// localized at display time.
private let supportedLanguages: [LanguageOption] = [
    LanguageOption(id: "",       name: "System", flag: ""),
    LanguageOption(id: "en",     name: "English", flag: "🇺🇸"),
    LanguageOption(id: "zh-Hans", name: "简体中文", flag: "🇨🇳"), // i18n-ignore: native language name
    LanguageOption(id: "zh-Hant", name: "繁體中文", flag: "🇭🇰"), // i18n-ignore: native language name
    LanguageOption(id: "ja",     name: "日本語", flag: "🇯🇵"), // i18n-ignore: native language name
    LanguageOption(id: "ko",     name: "한국어", flag: "🇰🇷"), // i18n-ignore: native language name
    LanguageOption(id: "fr",     name: "Français", flag: "🇫🇷"),
    LanguageOption(id: "de",     name: "Deutsch", flag: "🇩🇪"),
    LanguageOption(id: "ru",     name: "Русский", flag: "🇷🇺"),
]

struct FontScaleRow: View {
    let label: String
    @Binding var level: FontScaleLevel

    private static let cases = FontScaleLevel.allCases
    private let stepCount = FontScaleRow.cases.count  // 5

    private var currentIndex: Int {
        Self.cases.firstIndex(of: level) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `label` arrives localized (`SettingsCopy.t`).
            Text(label)
            HStack(spacing: 12) {
                Button {
                    let idx = currentIndex - 1
                    if idx >= 0 {
                        level = Self.cases[idx]
                    }
                } label: {
                    Text("A")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                SteppedSlider(value: currentIndex, steps: stepCount) { newIndex in
                    if newIndex >= 0, newIndex < Self.cases.count {
                        let newLevel = Self.cases[newIndex]
                        if newLevel != level { level = newLevel }
                    }
                }

                Button {
                    let idx = currentIndex + 1
                    if idx < Self.cases.count {
                        level = Self.cases[idx]
                    }
                } label: {
                    Text("A")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A custom stepped slider that supports both drag and tap-to-snap.
/// Uses local gesture state to avoid layout feedback loops from SwiftUI's Slider.
private struct SteppedSlider: View {
    let value: Int
    let steps: Int
    let onChanged: (Int) -> Void

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 22
    private let tickSize: CGFloat = 6

    @State private var dragValue: Int?

    private var displayValue: Int { dragValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let midY = geo.size.height / 2
            let maxStep = CGFloat(steps - 1)

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(height: trackHeight)
                    .position(x: totalW / 2, y: midY)

                // Filled portion
                let fillW = maxStep > 0 ? totalW * CGFloat(displayValue) / maxStep : 0
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillW, height: trackHeight)
                    .position(x: fillW / 2, y: midY)

                // Tick marks
                ForEach(0..<steps, id: \.self) { i in
                    let x = maxStep > 0 ? totalW * CGFloat(i) / maxStep : 0
                    Circle()
                        .fill(i <= displayValue ? Color.accentColor : Color(.systemFill))
                        .frame(width: tickSize, height: tickSize)
                        .position(x: x, y: midY)
                }

                // Thumb
                let thumbX = maxStep > 0 ? totalW * CGFloat(displayValue) / maxStep : 0
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: thumbX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        if step != dragValue { dragValue = step }
                    }
                    .onEnded { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        dragValue = nil
                        onChanged(step)
                    }
            )
        }
        .frame(height: thumbSize + 8)
    }

    private func stepFromX(_ x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, steps > 1 else { return 0 }
        let fraction = x / width
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * CGFloat(steps - 1)).rounded())
    }
}

// EngineeringAppearanceSettingsView moved to Features/Settings/EngineeringAppearanceSettingsView.swift


/// Disables the navigation controller's interactive pop gesture on the hosting page
/// to prevent conflict with horizontal Slider drag.
struct InteractivePopGestureDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = GestureDisablerView()
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private class GestureDisablerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setPopGesture(enabled: false)
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil { setPopGesture(enabled: true) }
        }
        private func setPopGesture(enabled: Bool) {
            // Walk the responder chain to find the UINavigationController
            var responder: UIResponder? = self
            while let r = responder {
                if let nav = r as? UINavigationController {
                    nav.interactivePopGestureRecognizer?.isEnabled = enabled
                    return
                }
                responder = r.next
            }
        }
    }
}

struct EngineeringAppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("appIconMode") private var appIconMode: Int = 0
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("launchScreen") private var launchScreen: Int = 0  // 0=Auto, 1=Last Session, 2=New Chat, 3=Home
    @AppStorage("toolPreviewEnabled") private var toolPreviewEnabled: Bool = true
    @AppStorage(OgentOceanPreference.key) private var oceanBackground: Bool = true
    /// 0 = Return inserts a newline (default), 1 = Return sends the message.
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    /// When true, holds `UIApplication.isIdleTimerDisabled` while any session
    /// is running a task. See `KeepScreenAwakeController`.
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false
    /// [T-keyboard-auto-pop default flip] When true, the input field becomes
    /// the first responder ~1.5 s after the model finishes a reply (the
    /// historical behavior). ON by default — most users want the composer
    /// ready for a follow-up immediately. Existing users who explicitly
    /// toggled OFF keep their stored false; users who never opened the
    /// toggle get the new ON default via @AppStorage's fallback.
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = false
    /// [T-thinking-auto-expand-toggle] When true (default, historical
    /// behavior) a NEW streaming thinking block auto-expands while reasoning
    /// streams. When false it stays collapsed until tapped. Read at
    /// block-mount time in ThinkingBlockView.
    @AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true
    @ObservedObject private var fontSettings = FontSettings.shared

    static let offersAlternateIcons = false

    private let iconOptions: [AppIconOption] = [
        AppIconOption(id: 0, title: "Automatic", subtitle: "Follows system", iconName: nil, imageName: "AlternateIcons/AppIcon-Light"),
        AppIconOption(id: 1, title: "Light", subtitle: "Always light", iconName: "AppIcon-Light", imageName: "AlternateIcons/AppIcon-Light"),
        AppIconOption(id: 2, title: "Dark", subtitle: "Always dark", iconName: "AppIcon-Dark", imageName: "AlternateIcons/AppIcon-Dark"),
        AppIconOption(id: 3, title: "Light (Legacy)", subtitle: "Classic light icon", iconName: "AppIcon-LegacyLight", imageName: "AlternateIcons/AppIcon-LegacyLight"),
        AppIconOption(id: 4, title: "Dark (Legacy)", subtitle: "Classic dark icon", iconName: "AppIcon-LegacyDark", imageName: "AlternateIcons/AppIcon-LegacyDark"),
    ]

    private func localizedIconTitle(_ option: AppIconOption) -> String {
        switch option.id {
        case 0: return SettingsCopy.t("自动", "Automatic")
        case 1: return SettingsCopy.t("浅色", "Light")
        case 2: return SettingsCopy.t("深色", "Dark")
        case 3: return SettingsCopy.t("浅色（旧版）", "Light (Legacy)")
        case 4: return SettingsCopy.t("深色（旧版）", "Dark (Legacy)")
        default: return option.title
        }
    }

    private func localizedIconSubtitle(_ option: AppIconOption) -> String {
        switch option.id {
        case 0: return SettingsCopy.t("跟随系统", "Follows system")
        case 1: return SettingsCopy.t("始终浅色", "Always light")
        case 2: return SettingsCopy.t("始终深色", "Always dark")
        case 3: return SettingsCopy.t("经典浅色图标", "Classic light icon")
        case 4: return SettingsCopy.t("经典深色图标", "Classic dark icon")
        default: return option.subtitle
        }
    }

    var body: some View {
        List {
            Section {
                Picker(SettingsCopy.t("主题", "Theme"), selection: $appearanceMode) {
                    Text(SettingsCopy.t("跟随系统", "System")).tag(0)
                    Text(SettingsCopy.t("浅色", "Light")).tag(1)
                    Text(SettingsCopy.t("深色", "Dark")).tag(2)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(SettingsCopy.t("主题", "Theme"))
            } footer: {
                Text(SettingsCopy.t("覆盖这款软件的系统外观。顶栏的日月按钮也会切换深浅色。", "Override the system appearance for this app. The sun icon in the top bar toggles light and dark as well."))
            }
            .onChange(of: appearanceMode) { _, _ in
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                windowScene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : .unspecified
                }
            }

            Section {
                Picker(SettingsCopy.t("进入 Ogent", "Enter Ogent"), selection: $launchScreen) {
                    Text(SettingsCopy.t("自动", "Auto")).tag(0)
                    Text(SettingsCopy.t("上次会话", "Last Session")).tag(1)
                    Text(SettingsCopy.t("新对话", "New Chat")).tag(2)
                    Text(SettingsCopy.t("空白对话", "Blank chat")).tag(3)
                }
            } header: {
                Text(SettingsCopy.t("进入 Ogent", "Enter Ogent"))
            } footer: {
                Text(SettingsCopy.t(
                    "决定点开 Ogent 时打开哪一段对话。自动：上次会话超过 15 分钟就开新对话。空白对话同样是聊天页，不会再进单独的主页。",
                    "Chooses which chat opens when you enter Ogent. Auto starts a new chat if the last session is older than 15 minutes. Blank chat is still the chat page, not a separate home."
                ))
            }

            Section {
                Picker(SettingsCopy.t("回车键", "Return Key"), selection: $returnKeyBehavior) {
                    Text(SettingsCopy.t("换行", "Newline")).tag(0)
                    Text(SettingsCopy.t("发送", "Send")).tag(1)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(SettingsCopy.t("回车键", "Return Key"))
            } footer: {
                Text(SettingsCopy.t(
                    "聊天输入框的回车是换行还是发送。外接键盘的 Shift+回车始终换行。",
                    "Choose whether the Return key in the chat input inserts a newline or sends the message. Hardware Shift+Return always inserts a newline."
                ))
            }

            Section {
                Toggle(SettingsCopy.t("任务时保持亮屏", "Keep Screen Awake"), isOn: $keepScreenAwakeDuringTasks)
            } header: {
                Text(SettingsCopy.t("保持亮屏", "Keep Screen Awake"))
            } footer: {
                Text(SettingsCopy.t(
                    "有会话正在执行任务时不让屏幕休眠。会更耗电。",
                    "Prevent the screen from sleeping while any session is running a task. May increase battery drain."
                ))
            }

            Section {
                Toggle(SettingsCopy.t("回复后自动聚焦输入", "Auto-Focus Input After Reply"), isOn: $autoFocusAfterReply)
            } header: {
                Text(SettingsCopy.t("回复后聚焦", "Auto-Focus Input After Reply"))
            } footer: {
                Text(SettingsCopy.t(
                    "打开后，模型回复结束会自动弹出键盘，方便接着说。默认开启。",
                    "When on, the keyboard pops up automatically after the model finishes replying so the input is ready for a follow-up. On by default; turn off if you prefer to read the response without an unexpected keyboard."
                ))
            }

            Section {
                Toggle(SettingsCopy.t("Ogent 动态背景", "Ogent Animated Background"), isOn: $oceanBackground)
            } footer: {
                Text(SettingsCopy.t(
                    "在 Ogent 页面背后显示由字符组成的水母海洋，随输入、发送和模型的状态变化。开启“减弱动态效果”时只显示静止画面。",
                    "Shows an ocean of jellyfish drawn in characters behind Ogent, reacting to typing, sending and what the model is doing. With Reduce Motion on it stays still."
                ))
            }

            Section {
                Toggle(SettingsCopy.t("工具预览", "Tool Preview Window"), isOn: $toolPreviewEnabled)
            } header: {
                Text(SettingsCopy.t("工具状态", "Tool Status Bar"))
            } footer: {
                Text(SettingsCopy.t(
                    "Ogent 执行工具时，在状态条旁显示实时预览。",
                    "Show a live preview thumbnail alongside the tool status bar during agent execution."
                ))
            }

            // [T-thinking-auto-expand-toggle] Whether a NEW streaming thinking
            // block opens expanded (historical behavior, default) or stays
            // collapsed. Only affects the streaming auto-expand; manual taps
            // always work either way.
            Section {
                Toggle(SettingsCopy.t("流式时展开思考", "Expand Thinking While Streaming"), isOn: $autoExpandThinking)
            } header: {
                Text(SettingsCopy.t("深度思考", "Deep Thinking"))
            } footer: {
                Text(SettingsCopy.t(
                    "打开后，模型推理时思考块会自动展开，结束后收起。关闭后默认收起，点一下可以看。",
                    "When on, a new thinking block expands automatically while the model is reasoning and collapses when it finishes. When off, thinking blocks stay collapsed — tap one to read it."
                ))
            }

            Section {
                FontScaleRow(
                    label: SettingsCopy.t("输入框", "Chat Input"),
                    level: $fontSettings.chatInputScale
                )
                FontScaleRow(
                    label: SettingsCopy.t("消息文字", "Message Text"),
                    level: $fontSettings.messageBaseScale
                )
                FontScaleRow(
                    label: SettingsCopy.t("应用基准", "App Base"),
                    level: $fontSettings.appBaseScale
                )
                if fontSettings.isModified {
                    Button(SettingsCopy.t("恢复默认", "Reset to Defaults")) {
                        fontSettings.resetToDefaults()
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text(SettingsCopy.t("字号", "Font Size"))
            } footer: {
                Text(SettingsCopy.t(
                    "分别调整输入框、消息和软件里的文字大小。改完立刻生效。",
                    "Scale fonts for chat input, message content, and general app text. Changes apply immediately."
                ))
            }

            // The alternate icons this picker offered were never added to the asset catalog,
            // so the section stays hidden until they exist.
            if Self.offersAlternateIcons, UIApplication.shared.supportsAlternateIcons {
                Section {
                    ForEach(iconOptions) { option in
                        Button {
                            guard appIconMode != option.id else { return }
                            appIconMode = option.id
                            UIApplication.shared.setAlternateIconName(option.iconName) { error in
                                if let error = error {
                                    print("[AppIcon] Failed to set icon: \(error.localizedDescription)")
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                if let img = UIImage(named: option.imageName) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                        )
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    // `option.title` / `option.subtitle` are fixed English
                                    // keys ("Automatic", "Light", "Always light", etc.).
                                    // Wrap in LocalizedStringKey so the catalog lookup kicks
                                    // in — Text(String) would render them verbatim.
                                    Text(localizedIconTitle(option))
                                        .foregroundStyle(.primary)
                                    Text(localizedIconSubtitle(option))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if appIconMode == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.title3)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text(SettingsCopy.t("应用图标", "App Icon"))
                } footer: {
                    Text(SettingsCopy.t(
                        "「自动」使用系统图标，在 iOS 18 及以后会随深色模式变化。",
                        "\"Automatic\" uses the system icon which adapts to Dark Mode on iOS 18+."
                    ))
                }
            }

            Section {
                ForEach(supportedLanguages) { lang in
                    Button {
                        // Persist a reopen-hint BEFORE flipping appLanguage —
                        // the @AppStorage write triggers the root
                        // `.id(appLanguage)` rebuild in OasesChatApp.swift, which
                        // drops the entire view tree including the Settings
                        // sheet. ContentView/SettingsSheet read this flag on
                        // re-mount and reopen the sheet + push back to the
                        // Appearance page so the user lands where they were
                        // with all strings rendered in the new language.
                        UserDefaults.standard.set("appearance", forKey: "pendingSettingsReopen")
                        // Apply bundle override BEFORE flipping @AppStorage so the
                        // RootView `.id(appLanguage)` rebuild localizes immediately.
                        Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)
                        appLanguage = lang.id
                        NotificationCenter.default.post(name: .soulMdChanged, object: nil)
                    } label: {
                        HStack(spacing: 12) {
                            if !lang.flag.isEmpty {
                                Text(lang.flag).font(.title2)
                            } else {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                            }
                            Text(lang.id.isEmpty ? SettingsCopy.t("系统", "System") : lang.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appLanguage == lang.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                Text(SettingsCopy.t("语言", "Language"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SettingsCopy.t(
                        "覆盖这款软件的显示语言。「系统」跟随设备语言。改完会重新打开设置，并停在这一页。",
                        "Override the display language for this app. \"System\" follows your device language. Changing it reopens Settings on this page."
                    ))
                    if Bundle.languageChangeNeedsRelaunch(appLanguage) {
                        Text(SettingsCopy.t(
                            "部分文字会在重新打开 App 后切换为所选语言。",
                            "Some text switches to the selected language after you reopen the app."
                        ))
                        .foregroundStyle(OasesColor.primary)
                    }
                }
            }
        }
        .navigationTitle(SettingsCopy.t("外观", "Appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .background(InteractivePopGestureDisabler())
    }
}
