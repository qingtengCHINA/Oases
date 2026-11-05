import Foundation

/// Built-in field registrations. This file is the single place to add
/// or remove a setting from the agent-facing surface. Each section is
/// keyed by topic; topic names line up with the CLI subcommands.
///
/// Registration is idempotent and runs once at app launch from
/// `OasesChatApp.init` via `ConfigRegistry.shared.registerBuiltinsIfNeeded()`.
///
/// Stage-gate comments mark which registrations are held back because
/// their dependencies have not yet been ported:
///   • [Stage 2] requires ProviderConfigStore, AIChatViewModel, ThinkingLevel
///   • [Stage 3] requires ProviderConfigStore (SQLite version)
///   • [Stage 4] requires BackgroundKeepAliveManager, AgentLiveActivityManager
///   • [Stage 5] requires CloudSyncEngine
///   • [Soul]    requires SoulStore, SoulFile (TBD)
extension ConfigRegistry {
    @MainActor
    static func registerBuiltins(into r: ConfigRegistry) {
        registerSelfMeta(into: r)
        registerAppearance(into: r)
        registerChat(into: r)
        registerFiles(into: r)
        registerBrowser(into: r)
        registerSpeech(into: r)
        registerBackground(into: r)
        registerLogs(into: r)
        // [Stage 2] registerProviderCollections — depends on ProviderConfigStore
        // [Stage 2] registerDefaults           — depends on ProviderConfigStore + AIChatViewModel
        // [Stage 2] registerSession            — depends on ProviderConfigStore + AIChatViewModel
        // [Soul]    registerSoul               — depends on SoulStore, SoulFile
        registerRootfsMirror(into: r)
        registerMemory(into: r)
        // [Stage 5] registerSync               — depends on CloudSyncEngine
    }

    // MARK: Memory

    @MainActor
    private static func registerMemory(into r: ConfigRegistry) {
        r.register(AppStorageBoolField(
            path: "memory.enabled",
            displayName: String(localized: "Memory enabled (global default)", comment: "Setting name shown in the agent config-change confirmation sheet: memory default for new chats"),
            description: "Default for whether NEW chat sessions start with memory on. When on, a new session auto-injects GLOBAL.md + recent daily logs into the system prompt and exposes the memory_get / memory_write tools. When off, new sessions get neither. Already-open sessions keep their own per-session setting (toggle with /memory) and are not changed by this.",
            userDefaultsKey: "memory.global.enabled",
            defaultValue: true
        ))
    }

    // MARK: Collections — [Stage 2/3] registerProviderCollections (held back)
    //
    // ProvidersCollection, ModelsCollection, GroupsCollection, EnvVarsCollection
    // all depend on ProviderConfigStore (Stage 2) and EnvVarStore (Stage 3).
    // The read-only summaries for `providers`, `models`, `envvars`, `groups`
    // also depend on ProviderConfigStore.config.instances / .modelEntries / .modelGroups.
    // registerProviderCollections will be uncommented in Stage 2.

    // MARK: Defaults — [Stage 2] (held back)
    //
    // registerDefaults depends on:
    //   - ProviderConfigStore.shared.defaultPrimaryGroupId / .defaultSubGroupId
    //   - ProviderConfigStore.shared.agentLoopModelEntryIds / .agentLoopGroupIds
    //   - ProviderConfigStore.shared.normalizeEntryRef(_:)
    //   - AIChatViewModel.activeSessionId (static)
    //   - ThinkingLevel, SessionInferenceConfig, SessionModelBinding, SessionModelSource
    // Will be uncommented in Stage 2.

    // MARK: Session — [Stage 2] (held back)
    //
    // registerSession depends on:
    //   - AIChatViewModel.activeSessionId (static)
    //   - ProviderConfigStore.shared.inferenceConfig(for:) / .setInferenceConfig(_:for:)
    //   - ProviderConfigStore.shared.binding(for:) / .setBinding(_:for:) / .removeBinding(for:)
    //   - ThinkingLevel (Stage 2), SessionInferenceConfig, SessionModelBinding, SessionModelSource
    // Will be uncommented in Stage 2.

    // MARK: Soul — [Soul] (held back)
    //
    // registerSoul depends on SoulFile and SoulStore, which are not yet ported.
    // Will be uncommented when SoulStore is added.

    // MARK: Rootfs mirrors (alpine / pip / npm)

    @MainActor
    private static func registerRootfsMirror(into r: ConfigRegistry) {
        for category in ["alpine", "pip", "npm"] {
            let path = "rootfs-mirror.\(category)"
            r.register(AppStorageStringField(
                path: path,
                displayName: String(localized: "\(category.capitalized) mirror id", comment: "Setting name shown in the agent config-change confirmation sheet: selected download mirror; the value is a package source name such as Alpine, Pip or Npm"),
                description: "Selected mirror for \(category). Empty = default.",
                userDefaultsKey: "mirror.selected.\(category)",
                defaultValue: "",
                maxLength: 256
            ))
        }
    }

    // MARK: Self-meta

    @MainActor
    private static func registerSelfMeta(into r: ConfigRegistry) {
        r.register(ClosureField(
            path: "permissions.oasesConfig.enabled",
            displayName: String(localized: "Allow oases-config", comment: "Setting name shown in the agent config-change confirmation sheet: master switch that lets the agent change app settings"),
            description: "Master switch. Read-only here — toggle via Settings → Permissions.",
            valueSchema: .bool,
            access: .readonly,
            risk: .destructive,
            revertable: false,
            reader: { .bool(OasesConfigPermissionStore.shared.enabled) },
            writer: { _ in
                throw ConfigError.permissionDenied(
                    reason: "Master switch — toggle via Settings → Permissions only")
            }
        ))
    }

    // MARK: Appearance & Display

    @MainActor
    private static func registerAppearance(into r: ConfigRegistry) {
        r.register(AppStorageIntCodedEnumField(
            path: "appearance.theme",
            displayName: String(localized: "Theme", comment: "Setting name shown in the agent config-change confirmation sheet: light/dark color scheme"),
            description: "Light / Dark / System color scheme.",
            userDefaultsKey: "appearanceMode",
            cases: ["system", "light", "dark"],
            defaultIndex: 0
        ))
        r.register(AppStorageIntCodedEnumField(
            path: "appearance.appIcon",
            displayName: String(localized: "App icon", comment: "Setting name shown in the agent config-change confirmation sheet: home screen icon variant"),
            description: "Home screen icon variant.",
            userDefaultsKey: "appIconMode",
            cases: ["auto", "light", "dark", "legacy_light", "legacy_dark"],
            defaultIndex: 0
        ))
        r.register(AppStorageStringField(
            path: "appearance.language",
            displayName: String(localized: "App language", comment: "Setting name shown in the agent config-change confirmation sheet: app UI language"),
            description: "BCP-47 code (zh-Hans, en, ja, …) or empty for system.",
            userDefaultsKey: "appLanguage",
            defaultValue: "",
            maxLength: 16
        ))
        r.register(AppStorageIntCodedEnumField(
            path: "appearance.launchScreen",
            displayName: String(localized: "Launch screen", comment: "Setting name shown in the agent config-change confirmation sheet: which screen the app opens to"),
            description: "Which screen the app opens to.",
            userDefaultsKey: "launchScreen",
            cases: ["auto", "last", "new", "home"],
            defaultIndex: 0
        ))
        r.register(fontScaleField(
            path: "appearance.appFontSize",
            displayName: String(localized: "App font size", comment: "Setting name shown in the agent config-change confirmation sheet: global UI font scale"),
            description: "Global UI font scale (xSmall / small / default / medium / large / extraLarge).",
            keyPath: \.appBaseScale,
            risk: .normal
        ))
    }

    // MARK: Chat / Input

    @MainActor
    private static func registerChat(into r: ConfigRegistry) {
        r.register(AppStorageIntCodedEnumField(
            path: "chat.returnKey",
            displayName: String(localized: "Return key behavior", comment: "Setting name shown in the agent config-change confirmation sheet: what the Return key does in the chat box"),
            description: "What the on-screen Return key does in the chat box.",
            userDefaultsKey: "returnKeyBehavior",
            cases: ["newline", "send"],
            defaultIndex: 0
        ))
        r.register(AppStorageBoolField(
            path: "chat.keepScreenAwake",
            displayName: String(localized: "Keep screen awake during tasks", comment: "Setting name shown in the agent config-change confirmation sheet: prevent auto-lock while the agent works"),
            description: "Prevents auto-lock while the agent is busy.",
            userDefaultsKey: "keepScreenAwakeDuringTasks",
            defaultValue: false
        ))
        r.register(AppStorageBoolField(
            path: "chat.toolPreview",
            displayName: String(localized: "Tool preview", comment: "Setting name shown in the agent config-change confirmation sheet: live preview during tool execution"),
            description: "Show live preview during agent tool execution.",
            userDefaultsKey: "toolPreviewEnabled",
            defaultValue: true
        ))
        r.register(AppStorageBoolField(
            path: "chat.fabOnLeft",
            displayName: String(localized: "FAB on left", comment: "Setting name shown in the agent config-change confirmation sheet: floating action button placement"),
            description: "Move the floating action button to the left edge.",
            userDefaultsKey: "fabOnLeft",
            defaultValue: false
        ))
        r.register(AppStorageBoolField(
            path: "chat.autoFocusAfterReply",
            displayName: String(localized: "Auto-focus input after reply", comment: "Setting name shown in the agent config-change confirmation sheet: show keyboard after a reply"),
            description: "When ON, the keyboard pops up automatically ~1.5s after the model finishes a reply so the input is ready for a follow-up. Turn OFF if you prefer to read the response without an unexpected keyboard.",
            userDefaultsKey: "chat.autoFocusAfterReply",
            defaultValue: false
        ))
        r.register(fontScaleField(
            path: "chat.inputFontSize",
            displayName: String(localized: "Input font size", comment: "Setting name shown in the agent config-change confirmation sheet: chat composer font size"),
            description: "Font size for the chat composer text editor.",
            keyPath: \.chatInputScale,
            risk: .normal
        ))
        r.register(fontScaleField(
            path: "chat.messageFontSize",
            displayName: String(localized: "Message font size", comment: "Setting name shown in the agent config-change confirmation sheet: message body font size"),
            description: "Base font size for assistant / user message bodies (markdown). Setting this invalidates rendered markdown caches.",
            keyPath: \.messageBaseScale,
            risk: .normal
        ))
    }

    // MARK: Font-scale field factory

    @MainActor
    private static func fontScaleField(
        path: String,
        displayName: String,
        description: String,
        keyPath: ReferenceWritableKeyPath<FontSettings, FontScaleLevel>,
        risk: ConfigRisk
    ) -> ConfigField {
        let cases = FontScaleLevel.allCases.map(fontScaleToken)
        return ClosureField(
            path: path,
            displayName: displayName,
            description: description,
            valueSchema: .stringEnum(cases),
            risk: risk,
            revertable: true,
            reader: {
                .string(fontScaleToken(FontSettings.shared[keyPath: keyPath]))
            },
            writer: { value in
                guard case .string(let token) = value else {
                    throw ConfigError.typeMismatch(expected: "string")
                }
                guard let level = fontScaleFromToken(token) else {
                    throw ConfigError.invalidValue("Unknown font scale: \(token)")
                }
                FontSettings.shared[keyPath: keyPath] = level
            }
        )
    }

    private static func fontScaleToken(_ level: FontScaleLevel) -> String {
        switch level {
        case .xSmall:     return "xSmall"
        case .small:      return "small"
        case .default:    return "default"
        case .medium:     return "medium"
        case .large:      return "large"
        case .extraLarge: return "extraLarge"
        }
    }

    private static func fontScaleFromToken(_ token: String) -> FontScaleLevel? {
        switch token {
        case "xSmall":     return .xSmall
        case "small":      return .small
        case "default":    return .default
        case "medium":     return .medium
        case "large":      return .large
        case "extraLarge": return .extraLarge
        default:           return nil
        }
    }

    // MARK: File browser

    @MainActor
    private static func registerFiles(into r: ConfigRegistry) {
        r.register(AppStorageStringField(
            path: "files.sortKey",
            displayName: String(localized: "Sort key", comment: "Setting name shown in the agent config-change confirmation sheet: file browser sort field"),
            description: "Sort field in the in-app file browser.",
            userDefaultsKey: "fileBrowser.sortKey",
            defaultValue: "name"
        ))
        r.register(AppStorageBoolField(
            path: "files.sortAscending",
            displayName: String(localized: "Sort ascending", comment: "Setting name shown in the agent config-change confirmation sheet: file browser sort direction"),
            description: "Sort direction in the file browser.",
            userDefaultsKey: "fileBrowser.sortAscending",
            defaultValue: true
        ))
        r.register(AppStorageBoolField(
            path: "files.foldersFirst",
            displayName: String(localized: "Folders first", comment: "Setting name shown in the agent config-change confirmation sheet: file browser lists folders before files"),
            description: "List folders before files when sorting.",
            userDefaultsKey: "fileBrowser.foldersFirst",
            defaultValue: true
        ))
    }

    // MARK: Browser

    @MainActor
    private static func registerBrowser(into r: ConfigRegistry) {
        r.register(AppStorageEnumField(
            path: "browser.uaProfile",
            displayName: String(localized: "User-agent profile", comment: "Setting name shown in the agent config-change confirmation sheet: in-app browser user agent preset"),
            description: "mobile_safari / desktop_safari / custom.",
            userDefaultsKey: "BrowserUserAgentProfile",
            cases: ["mobile_safari", "desktop_safari", "custom"],
            defaultValue: "mobile_safari"
        ))
        r.register(AppStorageStringField(
            path: "browser.customUA",
            displayName: String(localized: "Custom user-agent string", comment: "Setting name shown in the agent config-change confirmation sheet: in-app browser custom user agent"),
            description: "Used when uaProfile = custom. UTF-8 string up to 1 KB.",
            userDefaultsKey: "BrowserCustomUserAgentString",
            defaultValue: "",
            maxLength: 1024
        ))
        r.register(AppStorageIntField(
            path: "browser.viewportWidth",
            displayName: String(localized: "Custom viewport width", comment: "Setting name shown in the agent config-change confirmation sheet: in-app browser viewport width override"),
            description: "0 disables the override.",
            userDefaultsKey: "BrowserCustomViewportWidth",
            defaultValue: 0,
            min: 0, max: 4096
        ))
        r.register(AppStorageIntField(
            path: "browser.viewportHeight",
            displayName: String(localized: "Custom viewport height", comment: "Setting name shown in the agent config-change confirmation sheet: in-app browser viewport height override"),
            description: "0 disables the override.",
            userDefaultsKey: "BrowserCustomViewportHeight",
            defaultValue: 0,
            min: 0, max: 4096
        ))
    }

    // MARK: Speech (TTS + recognition)

    @MainActor
    private static func registerSpeech(into r: ConfigRegistry) {
        r.register(AppStorageBoolField(
            path: "speech.backgroundEnabled",
            displayName: String(localized: "Background TTS enabled", comment: "Setting name shown in the agent config-change confirmation sheet: read replies aloud in the background"),
            description: "Speak agent replies aloud, even when the app is backgrounded.",
            userDefaultsKey: "backgroundSpeakEnabled",
            defaultValue: false
        ))
        r.register(AppStorageDoubleField(
            path: "speech.rate",
            displayName: String(localized: "Speech rate", comment: "Setting name shown in the agent config-change confirmation sheet: text-to-speech rate"),
            description: "0.0 (slow) to 1.0 (fast).",
            userDefaultsKey: "speechRate",
            defaultValue: 0.5,
            min: 0.0, max: 1.0
        ))
        r.register(AppStorageDoubleField(
            path: "speech.pitch",
            displayName: String(localized: "Speech pitch", comment: "Setting name shown in the agent config-change confirmation sheet: text-to-speech pitch"),
            description: "0.5 (low) to 2.0 (high).",
            userDefaultsKey: "speechPitch",
            defaultValue: 1.0,
            min: 0.5, max: 2.0
        ))
        r.register(AppStorageDoubleField(
            path: "speech.volume",
            displayName: String(localized: "Speech volume", comment: "Setting name shown in the agent config-change confirmation sheet: text-to-speech volume"),
            description: "0.0 (mute) to 1.0 (full).",
            userDefaultsKey: "speechVolume",
            defaultValue: 1.0,
            min: 0.0, max: 1.0
        ))
        r.register(AppStorageStringField(
            path: "speech.voiceEn",
            displayName: String(localized: "English TTS voice", comment: "Setting name shown in the agent config-change confirmation sheet: voice used for English text-to-speech"),
            description: "AVSpeechSynthesisVoice identifier; empty = system default.",
            userDefaultsKey: "speechVoiceEn",
            defaultValue: "",
            maxLength: 256
        ))
        r.register(AppStorageStringField(
            path: "speech.voiceZh",
            displayName: String(localized: "Chinese TTS voice", comment: "Setting name shown in the agent config-change confirmation sheet: voice used for Chinese text-to-speech"),
            description: "AVSpeechSynthesisVoice identifier; empty = system default.",
            userDefaultsKey: "speechVoiceZh",
            defaultValue: "",
            maxLength: 256
        ))
        r.register(AppStorageStringField(
            path: "speech.recognitionLocale",
            displayName: String(localized: "Recognition locale", comment: "Setting name shown in the agent config-change confirmation sheet: speech-to-text language"),
            description: "BCP-47 locale used by speech-to-text.",
            // The key SpeechRecognitionManager reads (this was the name of its constant).
            userDefaultsKey: "SpeechRecognitionLocale",
            defaultValue: "",
            maxLength: 32
        ))
    }

    // MARK: Background
    //
    // Note: background.liveActivity depends on BackgroundKeepAliveManager and
    // AgentLiveActivityManager.isLiveActivitySupported — both will be ported
    // in Stage 4. Until then only the AppStorage-backed fields are registered;
    // the liveActivity closure field is commented out.

    @MainActor
    private static func registerBackground(into r: ConfigRegistry) {
        r.register(AppStorageBoolField(
            path: "background.enhanced",
            displayName: String(localized: "Enhanced background execution", comment: "Setting name shown in the agent config-change confirmation sheet: keep agent tasks running in the background"),
            description: "Keep agent tasks running when the app is backgrounded.",
            userDefaultsKey: "enhancedBackgroundExecution",
            defaultValue: false,
            risk: .sensitive
        ))
        r.register(AppStorageBoolField(
            path: "background.notifications",
            displayName: String(localized: "Background notifications", comment: "Setting name shown in the agent config-change confirmation sheet: notify when long tasks finish"),
            description: "Post a system notification when long-running tasks complete.",
            userDefaultsKey: "backgroundNotificationsEnabled",
            defaultValue: true
        ))
        r.register(AppStorageBoolField(
            path: "background.locationTracking",
            displayName: String(localized: "Location tracking", comment: "Setting name shown in the agent config-change confirmation sheet: use location updates to stay alive in the background"),
            description: "Use location updates to keep the agent alive in the background.",
            userDefaultsKey: "locationTrackingEnabled",
            defaultValue: false,
            risk: .sensitive
        ))
        // [Stage 4] background.liveActivity — depends on BackgroundKeepAliveManager
        // and AgentLiveActivityManager.isLiveActivitySupported.
        // Will be uncommented when BackgroundKeepAliveManager is ported.
    }

    // MARK: Logs
    //
    // [Stage 5] registerLogs — depends on LoggingManager (part of Debug/Diagnostics stack).
    // A stub AppStorage field is provided instead so `logs.enabled` is agent-visible
    // from day one without the full LoggingManager.

    @MainActor
    private static func registerLogs(into r: ConfigRegistry) {
        // [Stage 5] Full version: ClosureField reading/writing LoggingManager.shared.isEnabled
        // For now: plain AppStorage bool. When LoggingManager is ported, replace this with
        // the ClosureField that routes through LoggingManager.shared.isEnabled = b.
        r.register(AppStorageBoolField(
            path: "logs.enabled",
            displayName: String(localized: "Logging enabled", comment: "Setting name shown in the agent config-change confirmation sheet: write diagnostic log files"),
            description: "Capture stdout/stderr to daily log files for diagnostics. Takes effect the next time the app starts.",
            // The key LoggingManager reads (this said "logsEnabled", which nothing read).
            userDefaultsKey: "loggingEnabled",
            defaultValue: false
        ))
    }
}
