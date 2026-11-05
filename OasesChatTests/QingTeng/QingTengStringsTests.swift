// i18n-ignore-file: test data (the owner's wording rules are checked against literal Chinese text).
import Foundation
import Testing
@testable import Oases_Chat

/// The QingTeng account and consent copy (`QingTengStrings`): every key in all eight of the in-app
/// language picker's languages, `QT()` following the picked language, and the owner's wording
/// rules. Compiled, not run.
@MainActor
@Suite("QingTeng copy", .serialized)
struct QingTengStringsTests {
    /// The in-app language picker's languages (`CFBundleLocalizations`, `SettingsCopy.code`).
    static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "ru"]

    @Test func everyKeyIsInEveryLanguage() throws {
        let keys = Set(QingTengStrings.zhHans.keys)
        #expect(keys.count > 60)
        #expect(Set(QingTengStrings.tables.keys) == Set(Self.languages))
        for language in Self.languages {
            let table = try #require(QingTengStrings.tables[language], "\(language) has a table")
            #expect(Set(table.keys) == keys, "\(language): the same keys as Simplified Chinese")
            for (key, text) in table {
                #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): \(key) is written")
            }
        }
    }

    /// Every key a view asks for is in the table (a missing one would show the key itself).
    @Test func everyKeyTheViewsUseExists() {
        let used = [
            "account.rowTitle", "account.signedOut", "account.navTitle", "account.methods", "account.bound",
            "account.copyUid", "account.saveImage", "account.cardName", "account.delete", "account.signout",
            "consent.title", "consent.aiSentence", "consent.privacyLink", "consent.termsLink",
            "consent.agree", "consent.disagree", "consent.withdraw", "consent.withdrawTitle",
            "consent.withdrawBtn", "consent.withdrawMsg",
            "common.cancel", "common.confirm", "common.close",
            "privacy.account", "privacy.qtPolicy", "privacy.qtTerms",
        ]
        for key in used {
            #expect(QingTengStrings.zhHans[key] != nil, "\(key)")
            #expect(QingTengStrings.string(key, language: "en") != key, "\(key)")
        }
    }

    /// `QT()` follows the language picked in Settings › Appearance (`appLanguage`); a language
    /// without a table falls back to English.
    @Test func qtFollowsThePickedLanguage() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "appLanguage")
        defer {
            if let saved { defaults.set(saved, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") }
        }
        defaults.set("ru", forKey: "appLanguage")
        #expect(QT("account.rowTitle") == "Аккаунт QingTeng")
        defaults.set("zh-Hans", forKey: "appLanguage")
        #expect(QT("account.rowTitle") == "QingTeng 账号")
        #expect(QingTengStrings.string("account.rowTitle", language: "es") == "QingTeng Account")
        #expect(QingTengStrings.string("no.such.key", language: "en") == "no.such.key")
    }

    /// Owner rules: the brand is "QingTeng" in every language (never the Chinese characters for it),
    /// no "transfer abroad" wording, the account pages never call the server points "QTC 积分", and
    /// no copy of another app is left. The one page's copy is the owner's (2026-10-30).
    @Test func theWordingFollowsTheOwnersRules() {
        for (language, table) in QingTengStrings.tables {
            for (key, text) in table {
                #expect(!text.contains("\u{9752}\u{85E4}") && !text.contains("\u{9752}\u{7C50}"), "\(language): \(key)")
                #expect(!text.contains("境外") && !text.contains("出境"), "\(language): \(key)")
                #expect(!text.contains("QTC"), "\(language): \(key)")
                #expect(!text.contains("讲真话") && !text.contains("講真話") && !text.contains("Aletheon"), "\(language): \(key)")
                #expect(!text.contains("核查"), "\(language): \(key): Maat's online checks")
            }
        }
        #expect(QingTengStrings.zhHans["consent.title"] == "开始使用前")
        #expect(QingTengStrings.zhHans["consent.aiSentence"] == "使用 AI 功能时，你提供的内容会发送给 AI 服务处理。")
        #expect(QingTengStrings.zhHans["consent.agree"] == "同意并继续")
        #expect(QingTengStrings.en["consent.title"] == "Before You Start")
        #expect(QingTengStrings.en["consent.aiSentence"] == "When you use AI features, what you provide is sent to an AI service to process.")
        #expect(QingTengStrings.en["consent.agree"] == "Agree and Continue")
        #expect(QingTengStrings.en["consent.disagree"] == "Don't Agree")
        #expect(QingTengStrings.zhHant["consent.privacyLink"] == "《隱私權政策》")
        #expect(QingTengStrings.zhHant["consent.termsLink"] == "《使用條款》")
        for table in QingTengStrings.tables.values {
            #expect(!table.values.contains { $0.contains("单独同意") || $0.contains("單獨同意") })
        }
    }

    /// Microsoft's small print sits next to its buttons in every language (guide §4).
    @Test func microsoftsSmallPrintIsEverywhere() {
        for (language, table) in QingTengStrings.tables {
            #expect(table["account.msNote"]?.isEmpty == false, "\(language)")
        }
    }
}
