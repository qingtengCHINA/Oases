import Foundation
import ObjectiveC

/// In-app language (Settings → Appearance → Language).
///
/// Two mechanisms, because no single one reaches every lookup:
/// - The choice is written to the app-domain `AppleLanguages` key — the same
///   key iOS Settings → Oases Chat → Language writes. Foundation reads it at
///   launch, so from the next launch on *everything* follows it: SwiftUI,
///   `String(localized:)` / `LocalizedStringResource` (which resolve through
///   CFBundle, not `-localizedStringForKey:value:table:`), formatters and
///   system UI.
/// - Until then, `localizedString(forKey:value:table:)` on the main bundle is
///   redirected to the chosen `.lproj`, so `SettingsCopy.t`, `NSLocalizedString`
///   and the settings tree switch immediately, and `String(localized:)` in this
///   module goes through the chosen `.lproj` too (see the `String` extension
///   below) — without it, text such as the chat greeting stayed in the launch
///   language until a relaunch.
extension Bundle {
    private nonisolated(unsafe) static var overrideBundleKey: UInt8 = 0
    /// The `AppleLanguages` value this app last wrote, to tell it apart from
    /// one chosen in iOS Settings.
    private static let writtenAppleLanguagesKey = "oases.appleLanguagesWrittenByApp"
    static let appLanguageKey = "appLanguage"
    static let supportedLanguageCodes = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "ru"]

    var languageBundle: Bundle? {
        get { objc_getAssociatedObject(self, &Self.overrideBundleKey) as? Bundle }
        set { objc_setAssociatedObject(self, &Self.overrideBundleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Call once at launch, before `setLanguage`. Idempotent: a second
    /// exchange would swap the implementations back.
    static func enableLanguageOverride() {
        _ = swizzleOnce
        adoptLanguageChosenInSystemSettings()
    }

    private static let swizzleOnce: Void = {
        guard let original = class_getInstanceMethod(Bundle.self, #selector(localizedString(forKey:value:table:))),
              let swizzled = class_getInstanceMethod(Bundle.self, #selector(overrideLocalizedString(forKey:value:table:))) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }()

    /// If `AppleLanguages` differs from what this app wrote, the user picked a
    /// language in iOS Settings since; make it the in-app choice too so the
    /// two settings don't fight.
    private static func adoptLanguageChosenInSystemSettings() {
        let defaults = UserDefaults.standard
        guard let bundleID = Bundle.main.bundleIdentifier,
              let current = defaults.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String],
              current != defaults.stringArray(forKey: writtenAppleLanguagesKey),
              let code = supportedCode(for: current.first) else {
            return
        }
        defaults.set(code, forKey: appLanguageKey)
        defaults.set(current, forKey: writtenAppleLanguagesKey)
    }

    static func supportedCode(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        return supportedLanguageCodes.first { code in
            identifier == code || identifier.hasPrefix(code + "-") || localeCandidates(for: code).contains(identifier)
        }
    }

    @objc private func overrideLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if self == Bundle.main, let bundle = languageBundle {
            let translated = bundle.overrideLocalizedString(forKey: key, value: value, table: tableName)
            // If the language bundle returns the key unchanged, fall through to main.
            if translated != key || value != nil {
                return translated
            }
        }
        return overrideLocalizedString(forKey: key, value: value, table: tableName)
    }

    /// Pass `nil` or `""` to follow the system language.
    static func setLanguage(_ code: String?) {
        let defaults = UserDefaults.standard
        guard let code, !code.isEmpty else {
            Bundle.main.languageBundle = nil
            // Only undo our own value; a language picked in iOS Settings stays.
            if let bundleID = Bundle.main.bundleIdentifier,
               let written = defaults.stringArray(forKey: writtenAppleLanguagesKey),
               defaults.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String] == written {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            defaults.removeObject(forKey: writtenAppleLanguagesKey)
            return
        }

        let candidates = localeCandidates(for: code)
        var resolved: Bundle?
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                resolved = bundle
                break
            }
        }
        Bundle.main.languageBundle = resolved
        defaults.set(candidates, forKey: "AppleLanguages")
        defaults.set(candidates, forKey: writtenAppleLanguagesKey)
    }

    /// Whether some text still shows the launch language until the next
    /// launch (the language changed in this process).
    static func languageChangeNeedsRelaunch(_ code: String) -> Bool {
        let launchLanguage = Bundle.main.preferredLocalizations.first
        let wanted = code.isEmpty ? Locale.preferredLanguages.first : code
        return supportedCode(for: launchLanguage) != supportedCode(for: wanted)
    }

    /// Expand UI language ids into bundle / AppleLanguages candidates.
    static func localeCandidates(for code: String) -> [String] {
        switch code {
        case "zh-Hans":
            return ["zh-Hans", "zh-CN", "zh"]
        case "zh-Hant":
            return ["zh-Hant", "zh-TW", "zh-HK", "zh"]
        default:
            return [code]
        }
    }
}

extension String {
    /// This module's `String(localized:)`: the same lookup as Foundation's, but through the
    /// language picked in-app (Settings → Appearance → Language) right away. Foundation's
    /// resolves through CFBundle, whose language is fixed at launch, so every
    /// `String(localized:)` in the app used to stay in the launch language until a relaunch
    /// while SwiftUI `Text` literals had already switched. Swift prefers this module's
    /// declaration for calls without `bundle:`/`locale:`; calls that pass either keep
    /// Foundation's. With no in-app choice it is exactly Foundation's lookup.
    init(localized keyAndValue: String.LocalizationValue, table: String? = nil, comment: StaticString? = nil) {
        self.init(localized: keyAndValue, table: table, bundle: Bundle.main.languageBundle ?? .main, comment: comment)
    }
}
