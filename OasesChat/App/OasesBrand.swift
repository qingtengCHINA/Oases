import Foundation

/// User-facing product branding for OasesChat.
///
/// The product is **Oases Chat**. Engineering mode is **Ogent**.
/// OpenMinis is an upstream dependency, credited in About — not the product name.
enum OasesBrand {
    /// Primary app display name (CFBundleDisplayName-aligned).
    static let appName = "Oases Chat"

    /// Engineering / project mode product name.
    static let engineeringName = "Ogent"

    /// Short assistant / sidebar fallback when SOUL.md has no name.
    static let assistantFallbackName = engineeringName

    static let feedbackEmail = "support@oases.dev"
    /// The one privacy policy and terms of use of the app: the documents the first-launch consent
    /// page asks the user to accept (`ConsentLinks`), also linked from About and the membership
    /// page. There used to be a second, different pair here.
    static let privacyPolicyURL = URL(string: "https://www.qingtengstudio.com/privacy")!
    static let termsOfUseURL = URL(string: "https://www.qingtengstudio.com/terms")!
    /// App Store 兑换页 — 点开跳出 App，落在系统兑换码页面。
    static let appStoreRedeemURL = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/redeemLandingPage")!
    /// Studio site — feedback and issue reports land here, not a GitHub issues page.
    static let issuesURL = URL(string: "https://qingtengstudio.com/")!
    static let issuesNewURL = URL(string: "https://qingtengstudio.com/")!
    static let websiteURL = URL(string: "https://qingtengstudio.com/")!
    /// OpenMinis upstream (GPL-3.0). Parts of this app are ported from it; About credits it.
    static let githubURL = URL(string: "https://github.com/OpenMinis/OpenMinis")!
    static let openMinisURL = githubURL
    /// iSH (GPL-3.0), the Linux emulator Ogent's runtime is built on, and the ARM64 fork the
    /// app links.
    static let iSHURL = URL(string: "https://github.com/ish-app/ish")!
    static let iSHForkURL = URL(string: "https://github.com/OpenMinis/ish-arm64")!
    /// This app's own source (GPL-3.0), shown in About.
    static let sourceCodeURL: URL? = URL(string: "https://github.com/qingtengCHINA/Oases")

    static var tagline: String {
        String(localized: "文本、语音、图像，以及工程模式 Ogent。", comment: "About page tagline under the app name")
    }

    /// Support mail subject; kept in English so reports reach one inbox filter.
    static var feedbackSubject: String { "\(engineeringName) Feedback" }

    static var welcomeTitle: String { String(localized: "Welcome to \(engineeringName)", comment: "Welcome title; argument is the product name Ogent") }

    static var aboutTitle: String { String(localized: "About \(appName)", comment: "About page title; argument is the app name") }

    static var lockedTitle: String { String(localized: "\(engineeringName) is Locked", comment: "App lock overlay title; argument is the product name Ogent") }

    static var unlockReason: String { String(localized: "Unlock \(engineeringName)", comment: "Face ID / Touch ID prompt reason; argument is the product name Ogent") }

    static var shellTitle: String { String(localized: "\(engineeringName) Shell", comment: "Terminal screen title; argument is the product name Ogent") }

    static var computerTitle: String { String(localized: "\(engineeringName) Computer", comment: "Live tool sheet title; argument is the product name Ogent") }

    static var skillsCatalogTitle: String { String(localized: "\(engineeringName) Skills", comment: "Skills catalog title; argument is the product name Ogent") }

    static var browsingStatus: String { String(localized: "\(engineeringName) is browsing", comment: "Browser sheet status; argument is the product name Ogent") }

    static var defaultPrintJobName: String { engineeringName }

    /// English fallback for the `SettingsCopy.t("… 运行时", …)` row title.
    static var runtimeSettingsTitle: String { "\(engineeringName) Runtime" }

    /// HTTP Referer / client identity for provider calls that expect an app URL.
    static let httpReferer = "https://oaseschat.com"

    static var userAgentProduct: String { "OasesChat" }
}

/// Settings strings follow the language chosen in Appearance (`appLanguage`).
/// `t` resolves through the String Catalog; while a language has no
/// translation yet it falls back to the English argument and the legacy
/// tables in `SettingsCopy+LegacyFallback.swift`.
enum SettingsCopy {
    /// Active UI language. Empty `appLanguage` follows the device.
    static var code: String {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        if !raw.isEmpty { return raw }
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("zh-Hant") || pref.contains("Hant") || pref.contains("-TW") || pref.contains("-HK") {
            return "zh-Hant"
        }
        if pref.hasPrefix("zh") { return "zh-Hans" }
        if pref.hasPrefix("ja") { return "ja" }
        if pref.hasPrefix("ko") { return "ko" }
        if pref.hasPrefix("fr") { return "fr" }
        if pref.hasPrefix("de") { return "de" }
        if pref.hasPrefix("ru") { return "ru" }
        return "en"
    }

    static var isChinese: Bool { code == "zh-Hans" || code == "zh-Hant" }

    /// Copy in the active language. `zh` is the String Catalog key (source
    /// language zh-Hans): the compiler extracts it, interpolations becoming
    /// format keys. `en` is the English copy, kept at the call site for
    /// readers; every language's text lives in `Localizable.xcstrings`,
    /// which `scripts/i18n/check_coverage.py` keeps complete.
    static func t(_ zh: String.LocalizationValue, _ en: String) -> String {
        // The explicit bundle makes a language picked in-app apply right
        // away; plain `String(localized:)` only follows it after a relaunch.
        String(localized: zh, bundle: Bundle.main.languageBundle ?? .main)
    }

    /// For text that isn't a literal. The compiler can't extract it, so its
    /// catalog entry is maintained by hand.
    static func t(verbatim zh: String, _ en: String) -> String {
        Bundle.main.localizedString(forKey: zh, value: zh, table: nil)
    }
}
