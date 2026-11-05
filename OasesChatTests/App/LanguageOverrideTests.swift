import XCTest
@testable import Oases_Chat

/// The in-app language (Settings → Appearance → Language).
final class LanguageOverrideTests: XCTestCase {
    private var savedChoice: String?
    private var savedAppleLanguages: Any?
    private var savedWritten: [String]?
    private let bundleID = Bundle.main.bundleIdentifier!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedChoice = defaults.string(forKey: "appLanguage")
        savedAppleLanguages = defaults.persistentDomain(forName: bundleID)?["AppleLanguages"]
        savedWritten = defaults.stringArray(forKey: "oases.appleLanguagesWrittenByApp")
        Bundle.enableLanguageOverride()
    }

    override func tearDown() {
        Bundle.setLanguage(nil)
        let defaults = UserDefaults.standard
        defaults.set(savedChoice, forKey: "appLanguage")
        defaults.set(savedAppleLanguages, forKey: "AppleLanguages")
        defaults.set(savedWritten, forKey: "oases.appleLanguagesWrittenByApp")
        Bundle.main.languageBundle = savedChoice.flatMap { $0.isEmpty ? nil : $0 }.flatMap { code in
            Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        }
        super.tearDown()
    }

    private var persistedAppleLanguages: [String]? {
        UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String]
    }

    func testSettingsCopySwitchesImmediately() {
        Bundle.setLanguage("ja")
        XCTAssertEqual(Bundle.main.localizedString(forKey: "设置", value: nil, table: nil), "設定")
        XCTAssertEqual(SettingsCopy.t("设置", "Settings"), "設定")
        let count = 3
        XCTAssertEqual(SettingsCopy.t("\(count) 天", "\(count)d"), "3 日")

        Bundle.setLanguage("de")
        XCTAssertEqual(SettingsCopy.t("设置", "Settings"), "Einstellungen")

        // Japanese that happens to be written with the same characters as the
        // Chinese source is a real translation, not a missing one.
        Bundle.setLanguage("ja")
        XCTAssertEqual(SettingsCopy.t("保存", "Save"), Bundle.main.localizedString(forKey: "保存", value: nil, table: nil))
    }

    func testUnsupportedSystemLanguagesFallBackToEnglish() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
    }

    func testChoiceIsPersistedForTheNextLaunch() {
        Bundle.setLanguage("ru")
        XCTAssertEqual(persistedAppleLanguages, ["ru"])

        Bundle.setLanguage("zh-Hant")
        XCTAssertEqual(persistedAppleLanguages, ["zh-Hant", "zh-TW", "zh-HK", "zh"])

        // "System" undoes only what the app wrote.
        Bundle.setLanguage(nil)
        XCTAssertNil(persistedAppleLanguages)
    }

    func testSystemChoiceKeepsALanguagePickedInIOSSettings() {
        Bundle.setLanguage("fr")
        // The user then picks German in iOS Settings → Oases Chat → Language.
        UserDefaults.standard.set(["de-DE"], forKey: "AppleLanguages")
        Bundle.setLanguage(nil)
        XCTAssertEqual(persistedAppleLanguages, ["de-DE"])
    }

    func testSupportedCodeMapping() {
        XCTAssertEqual(Bundle.supportedCode(for: "de-DE"), "de")
        XCTAssertEqual(Bundle.supportedCode(for: "zh-Hant-HK"), "zh-Hant")
        XCTAssertEqual(Bundle.supportedCode(for: "zh-HK"), "zh-Hant")
        XCTAssertEqual(Bundle.supportedCode(for: "zh"), "zh-Hans")
        XCTAssertNil(Bundle.supportedCode(for: "es"))
    }
}
