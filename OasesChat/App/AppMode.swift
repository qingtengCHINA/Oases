import Foundation
import UIKit

enum AppMode: String, CaseIterable, Identifiable, Codable {
    case chat, tts, image, project
    var id: String { rawValue }

    var brandTag: String {
        switch self {
        case .chat: return "Chat"
        case .tts: return "Voice"
        case .image: return "Image"
        case .project: return "Ogent"
        }
    }

    var featureLabel: String {
        switch self {
        case .chat: return SettingsCopy.t("文本", "Text")
        case .tts: return SettingsCopy.t("音频", "Voice")
        case .image: return SettingsCopy.t("图像", "Image")
        case .project: return "Ogent"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .tts: return "speaker.wave.2"
        case .image: return "photo"
        case .project: return "terminal"
        }
    }

    /// Mirrors Web `FeatureCategory` — the user-facing mode tab. `audio` mode
    /// is internally routed as `tts`, matching `getRoutingModeForCategory`.
    var category: Models.Category {
        switch self {
        case .chat: return .text
        case .tts: return .audio
        case .image: return .image
        case .project: return .project
        }
    }

    /// Default model id for this mode, mirrors Web `DEFAULT_MODEL_BY_CATEGORY`.
    var defaultModel: String {
        switch self {
        case .chat: return Models.defaultChat
        case .tts: return Models.tts
        case .image: return Models.defaultImage
        case .project: return Models.defaultProject
        }
    }

    /// User-preference-aware default used when starting a new conversation.
    var preferredModel: String {
        switch self {
        case .chat: return Models.preferredChatModel()
        default: return defaultModel
        }
    }

    /// Placeholder copy for the composer, mirrors Web's per-mode placeholder.
    var composerPlaceholder: String {
        switch self {
        case .chat: return String(localized: "今天想聊点什么？", comment: "Composer placeholder in Chat (text) mode")
        case .tts: return String(localized: "输入要朗读的文本", comment: "Composer placeholder in Voice (read-aloud) mode")
        case .image: return String(localized: "描述你想生成的图像", comment: "Composer placeholder in Image generation mode")
        case .project: return String(localized: "传讯息给 Ogent（工程模式，可 @ 提及档案）", comment: "Composer placeholder in Ogent (engineering) mode; @ mentions files")
        }
    }

    /// Per-mode welcome glyph tint — the ONLY visual that differs between
    /// empty states, per the design spec:
    ///   text  → current pink metallic
    ///   audio → red metallic
    ///   image → blue metallic
    ///   project → light iridescent purple metallic
    var metallicTint: MetallicTint {
        switch self {
        case .chat: return .pink
        case .tts: return .red
        case .image: return .blue
        case .project: return .iridescentPurple
        }
    }
}

/// Tint + light/dark trio handed to the MetallicPaint shader. Each preset
/// keeps light/dark near-neutral so the metallic sheen reads clearly, with
/// the `tint` carrying the per-mode hue.
struct MetallicTint {
    let lightColor: UIColor
    let darkColor: UIColor
    let tintColor: UIColor
    /// Chromatic-aberration amount — bumped for the "炫彩" iridescent preset.
    let chromaticSpread: Float

    static let pink = MetallicTint(
        lightColor: .white,
        darkColor: .black,
        tintColor: UIColor(red: 0xfe / 255, green: 0xb3 / 255, blue: 0xff / 255, alpha: 1),
        chromaticSpread: 2
    )

    static let red = MetallicTint(
        lightColor: UIColor(red: 1.0, green: 0.92, blue: 0.92, alpha: 1),
        darkColor: UIColor(red: 0.08, green: 0.0, blue: 0.02, alpha: 1),
        tintColor: UIColor(red: 0xff / 255, green: 0x3b / 255, blue: 0x5c / 255, alpha: 1),
        chromaticSpread: 2.2
    )

    static let blue = MetallicTint(
        lightColor: UIColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 1),
        darkColor: UIColor(red: 0.0, green: 0.02, blue: 0.08, alpha: 1),
        tintColor: UIColor(red: 0x4d / 255, green: 0x9f / 255, blue: 0xff / 255, alpha: 1),
        chromaticSpread: 2.2
    )

    /// "淡渐变紫炫彩金属色" — light purple base with extra chroma for the
    /// iridescent sheen.
    static let iridescentPurple = MetallicTint(
        lightColor: UIColor(red: 0.92, green: 0.84, blue: 1.0, alpha: 1),
        darkColor: UIColor(red: 0.05, green: 0.0, blue: 0.12, alpha: 1),
        tintColor: UIColor(red: 0x9d / 255, green: 0x4e / 255, blue: 0xdd / 255, alpha: 1),
        chromaticSpread: 3.6
    )
}
