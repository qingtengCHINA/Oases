import SwiftUI
import UIKit

/// Meeting Notes preferences: the language spoken (for recognition), whether recordings are
/// transcribed again in the cloud, the language the notes are written in, and which model writes
/// the notes and translations.
enum MeetingSettings {
    static let languageKey = "meeting.language"
    static let notesLanguageKey = "meeting.notesLanguage"
    static let reminderShownKey = "meeting.recordingReminderShown"
    static let cloudTranscriptionKey = "meeting.cloudTranscription"

    /// Cloud transcription with MiMo ASR (on unless the user turned it off).
    static var cloudTranscription: Bool {
        UserDefaults.standard.object(forKey: cloudTranscriptionKey) as? Bool ?? true
    }

    /// Recognition languages offered (BCP 47).
    static let spokenLanguages = ["zh-CN", "zh-TW", "zh-HK", "en-US", "en-GB", "ja-JP", "ko-KR", "fr-FR", "de-DE", "ru-RU"]

    /// Notes languages: code → the English name the model is told.
    static let notesLanguages: [(code: String, english: String)] = [
        ("zh-Hans", "Simplified Chinese"), ("zh-Hant", "Traditional Chinese"), ("en", "English"),
        ("ja", "Japanese"), ("ko", "Korean"), ("fr", "French"), ("de", "German"), ("ru", "Russian"),
    ]

    static var spokenLanguage: String {
        if let saved = UserDefaults.standard.string(forKey: languageKey), spokenLanguages.contains(saved) { return saved }
        switch SettingsCopy.code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "ru": return "ru-RU"
        default: return "en-US"
        }
    }

    static var notesLanguageCode: String {
        if let saved = UserDefaults.standard.string(forKey: notesLanguageKey),
           notesLanguages.contains(where: { $0.code == saved }) { return saved }
        return notesLanguages.contains(where: { $0.code == SettingsCopy.code }) ? SettingsCopy.code : "en"
    }

    static var notesLanguageEnglish: String {
        notesLanguages.first { $0.code == notesLanguageCode }?.english ?? "English"
    }

    static func displayName(spoken code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static func displayName(notes code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Turns the meeting's HTML into a paginated A4 PDF with the system's text layout.
enum MeetingPDF {
    @MainActor
    static func render(_ meeting: Meeting) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: MeetingExport.html(meeting))
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let printable = page.insetBy(dx: 48, dy: 56)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: bounds)
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}

/// Settings > Meeting Notes: languages, cloud transcription and the notes model.
struct MeetingSettingsView: View {
    @AppStorage(MeetingSettings.languageKey) private var spoken = MeetingSettings.spokenLanguage
    @AppStorage(MeetingSettings.notesLanguageKey) private var notesLanguage = MeetingSettings.notesLanguageCode
    @AppStorage(MeetingSettings.cloudTranscriptionKey) private var cloud = true
    @AppStorage(MeetingModelResolver.groupKey) private var groupId = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "会议语言", comment: "Meeting settings: language spoken in the meeting"), selection: $spoken) {
                        ForEach(MeetingSettings.spokenLanguages, id: \.self) { code in
                            Text(verbatim: MeetingSettings.displayName(spoken: code)).tag(code)
                        }
                    }
                    Picker(String(localized: "纪要语言", comment: "Meeting settings: language the notes are written in"), selection: $notesLanguage) {
                        ForEach(MeetingSettings.notesLanguages, id: \.code) { item in
                            Text(verbatim: MeetingSettings.displayName(notes: item.code)).tag(item.code)
                        }
                    }
                } footer: {
                    Text(String(localized: "会议语言用于录音时的实时转写，在本机完成。纪要和译文用纪要语言写。",
                                comment: "Meeting settings: footer explaining the spoken language and the notes language"))
                }
                Section {
                    Toggle(String(localized: "云端转写", comment: "Meeting settings: transcribe recordings again in the cloud"), isOn: $cloud)
                } footer: {
                    Text(cloudFooter)
                }
                Section {
                    Picker(String(localized: "纪要和翻译模型", comment: "Meeting settings: model that writes notes and translations"), selection: $groupId) {
                        Text(verbatim: "Oases Fast").tag("")
                        ForEach(ProviderConfigStore.shared.modelGroups) { group in
                            Text(verbatim: group.name).tag(group.id)
                        }
                    }
                } footer: {
                    Text(String(localized: "生成纪要和翻译时，文字记录会发送给这个模型。默认用 Oases Fast，也可以换成你自己的模型组（需要能稳定输出 JSON，建议上下文 128K 以上）。",
                                comment: "Meeting settings: footer explaining where the transcript goes and the default model"))
                }
            }
            .navigationTitle(String(localized: "会议纪要设置", comment: "Meeting settings: page title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成", comment: "Profile editor: save changes")) { dismiss() }
                }
            }
        }
    }

    private var cloudFooter: String {
        let base = String(localized: "录音每满几分钟就把这一段上传到 Oases 重新转写，替换实时转写的文字：更准，能听懂方言和中英夹杂。只支持中文和英文会议，需要先同意 AI 数据共享。不区分说话人。",
                          comment: "Meeting settings: what cloud transcription does")
        guard !MeetingCloudASR.supports(language: spoken) else { return base }
        return base + " " + String(localized: "当前的会议语言不支持云端转写，只用本机转写。",
                                    comment: "Meeting settings: the chosen spoken language can't use cloud transcription")
    }
}
