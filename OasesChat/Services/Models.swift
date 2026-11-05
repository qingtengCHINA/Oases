import Foundation

enum Models {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let descriptionText: String
        let supportsEffort: Bool
        let supportsImageInput: Bool
        let category: Category
        var isBeta: Bool = false
        /// 限免：限时免费，不受会员机制限制（不需要会员等级，也不计入每日次数）。
        var isPromoFree: Bool = false

        var asLLMModel: LLMModel {
            let modality: ModelModality
            switch category {
            case .image:
                modality = [.textInput, .imageOutput]
            case .audio:
                modality = [.textInput, .audioOutput]
            default:
                modality = supportsImageInput ? .vision : .textOnly
            }
            return LLMModel(
                id: id,
                displayName: label,
                provider: "Oases",
                modalityOverride: modality,
                supportsReasoning: supportsEffort
            )
        }
    }

    enum Category: String, CaseIterable {
        case text, image, audio, project
        var label: String {
            switch self {
            case .text: return String(localized: "文本", comment: "Model category: text chat")
            case .image: return String(localized: "图像", comment: "Model category: image generation")
            case .audio: return String(localized: "音频", comment: "Model category: audio / speech")
            case .project: return String(localized: "工程", comment: "Model category: engineering (Ogent)")
            }
        }
    }

    enum Effort: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: return String(localized: "低", comment: "Reasoning effort level: low")
            case .medium: return String(localized: "中", comment: "Reasoning effort level: medium")
            case .high: return String(localized: "高", comment: "Reasoning effort level: high")
            }
        }
        var next: Effort {
            switch self {
            case .low: return .medium
            case .medium: return .high
            case .high: return .low
            }
        }
    }

    static var chat: [Option] {
        [
            Option(id: "glm-5.3-flash",
                   label: "Oases Fast",
                   descriptionText: String(localized: "默认模型，适合日常对话、写作和工程任务", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: true, category: .text),
            Option(id: "grok-4.6",
                   label: "Oases Pro",
                   descriptionText: String(localized: "高质量文本模型，适合分析和复杂对话", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: true, category: .text),
            Option(id: "gemini-3.8-flash-high",
                   label: "Oases Gemini",
                   descriptionText: String(localized: "适合看图、读文件和较快的回复", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: true, category: .text),
            Option(id: "claude-haiku-5-5",
                   label: "Oases Haiku",
                   descriptionText: String(localized: "限时免费，不消耗会员额度，回复快", comment: "Built-in model description in the model picker (limited-time free model)"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isPromoFree: true),
        ]
    }

    static var betaChat: [Option] {
        [
            Option(id: "ling-3.0-flash",
                   label: "Oases Ling",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
            Option(id: "lumo-fast",
                   label: "Oases Lumo",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
            Option(id: "grok-4.7",
                   label: "Oases Space",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
            Option(id: "claude-sonnet-4-6",
                   label: "Oases Sonnet",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
            Option(id: "kimi-k2.8",
                   label: "Oases Moon",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
            Option(id: "gpt-6-luna",
                   label: "Oases Luna",
                   descriptionText: String(localized: "尝鲜模型，能力与稳定性可能随时变化", comment: "Built-in model description in the model picker"),
                   supportsEffort: true, supportsImageInput: false, category: .text,
                   isBeta: true),
        ]
    }

    static var imageModels: [Option] {
        [
            Option(id: "grok-imagine-image-2.0",
                   label: "Oases Image",
                   descriptionText: String(localized: "适合快速图像生成和创意草图", comment: "Built-in model description in the model picker"),
                   supportsEffort: false, supportsImageInput: false, category: .image),
            Option(id: "gemini-3.1-flash-image",
                   label: "Oases Gemini",
                   descriptionText: String(localized: "尝鲜图像模型，生成效果可能不稳定", comment: "Built-in model description in the model picker"),
                   supportsEffort: false, supportsImageInput: false, category: .image,
                   isBeta: true),
        ]
    }

    /// Ogent 与文本模式共用同一套内置目录，默认都是 Oases Fast。
    static var projectModels: [Option] {
        (chat + betaChat).map { option in
            Option(
                id: option.id,
                label: option.label,
                descriptionText: option.descriptionText,
                supportsEffort: option.supportsEffort,
                supportsImageInput: option.supportsImageInput,
                category: .project,
                isBeta: option.isBeta,
                isPromoFree: option.isPromoFree
            )
        }
    }

    static let tts = "mimo-v2.5-tts"
    static let defaultChat = "glm-5.3-flash"
    static let defaultImage = "grok-imagine-image-2.0"
    static let defaultProject = "glm-5.3-flash"

    enum PreferenceKey {
        static let defaultChatModel = "defaultChatModel"
        static let defaultEffort = "defaultEffort"
    }

    /// Retired catalog ids still sitting in SwiftData / ChatStore rows.
    /// Map them onto the current Oases catalog so load/send never posts a
    /// dead model id to the proxy.
    static let retiredRedirects: [String: String] = [
        "kimi-k2.5": defaultChat,
        "kimi-k2.6": defaultChat,
        "mimo-v2.5": defaultChat,
        "gpt-5.4": "grok-4.6",
        "deepseek-v4-flash": "gemini-3.8-flash-high",
        "gemini-3.1-flash-lite": "gemini-3.8-flash-high",
        "grok-4.3": "grok-4.6",
        "grok-imagine-image": defaultImage,
        "gpt-image-2": defaultImage,
        "gpt-5.4-image-2": defaultImage,
        "reve-image-latest": defaultImage,
        "deepseek-v4-pro": defaultProject,
        "mimo-v2.5-pro": defaultProject,
    ]

    /// Returns a catalog id that still exists. `entry:` selections are left
    /// untouched — those are resolved by `ProviderChatRouting`.
    static func sanitizedId(_ id: String, category: Category = .text) -> String {
        if ProviderChatRouting.isEntryId(id) { return id }
        let remapped = retiredRedirects[id] ?? id
        if option(for: remapped, category: category) != nil { return remapped }
        if option(for: remapped) != nil { return remapped }
        return defaultModel(for: category)
    }

    static func preferredChatModel() -> String {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.defaultChatModel) ?? defaultChat
        return sanitizedId(stored, category: .text)
    }

    static func preferredEffort() -> Effort {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.defaultEffort) ?? Effort.high.rawValue
        return Effort(rawValue: raw) ?? .high
    }

    static func options(for category: Category) -> [Option] {
        switch category {
        case .text: return chat + betaChat
        case .image: return imageModels
        case .audio: return [Option(id: tts, label: "Oases Voice",
                                    descriptionText: String(localized: "语音合成模型", comment: "Built-in model description in the model picker"),
                                    supportsEffort: false, supportsImageInput: false,
                                    category: .audio)]
        case .project: return projectModels
        }
    }

    /// Whether a built-in catalog id is a limited-time free model.
    static func isPromoFree(_ id: String) -> Bool {
        option(for: id)?.isPromoFree == true
    }

    static func option(for id: String) -> Option? {
        chat.first(where: { $0.id == id })
        ?? betaChat.first(where: { $0.id == id })
        ?? imageModels.first(where: { $0.id == id })
        ?? projectModels.first(where: { $0.id == id })
        ?? (id == tts ? options(for: .audio).first : nil)
    }

    /// Mode-aware lookup. The same model id can appear in more than one
    /// category list with different capability flags.
    static func option(for id: String, category: Category) -> Option? {
        switch category {
        case .text: return (chat + betaChat).first(where: { $0.id == id }) ?? option(for: id)
        case .project: return projectModels.first(where: { $0.id == id }) ?? option(for: id)
        case .image: return imageModels.first(where: { $0.id == id }) ?? option(for: id)
        case .audio: return options(for: .audio).first(where: { $0.id == id }) ?? option(for: id)
        }
    }

    /// Classifies a catalog id. User-configured `entry:` ids are text unless
    /// the caller already knows the AppMode. Project is a surface, not a
    /// model family — never inferred from the id string.
    static func category(for modelId: String) -> Category {
        if ProviderChatRouting.isEntryId(modelId) { return .text }
        if let option = option(for: modelId) { return option.category }
        return .text
    }

    static func defaultModel(for category: Category) -> String {
        switch category {
        case .text: return defaultChat
        case .image: return defaultImage
        case .audio: return tts
        case .project: return defaultProject
        }
    }

    static func label(for id: String) -> String {
        option(for: id)?.label ?? id
    }

    static func label(for id: String, category: Category) -> String {
        option(for: id, category: category)?.label ?? id
    }
}
