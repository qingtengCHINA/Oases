import Foundation

/// Text shown to users must not carry the OpenAI / ChatGPT / GPT brand (App
/// Store, mainland China). Internal names keep it — `ProviderType.openAI`,
/// `LLMModel.provider == "OpenAI"`, model ids, hosts, wire fields — and only
/// what reaches the screen goes through here. `scripts/check_forbidden_brands.sh`
/// guards the literals.
enum BrandNeutralCopy {
    /// The OpenAI-protocol provider as users see it.
    static var aiProvider: String { SettingsCopy.t("AI 供应商", "AI provider") }

    /// Word used in place of a GPT family name in front of a version number.
    static let modelFamily = "Model"

    private static let brandPattern = #"(?i)\bopen\s?ai|chat\s?gpt|\bgpt"#

    static func containsBrand(_ text: String) -> Bool {
        text.range(of: brandPattern, options: .regularExpression) != nil
    }

    /// `LLMModel.provider` holds internal keys ("OpenAI") and catalogs such as
    /// models.dev report vendor names; branded ones show as `aiProvider`.
    static func providerName(_ provider: String) -> String {
        containsBrand(provider) ? aiProvider : provider
    }

    /// Model name with the brand removed: a GPT token before a version becomes
    /// `modelFamily` ("GPT-4o Mini" → "Model 4o Mini"), before a word it is
    /// dropped ("GPT Image 2" → "Image 2"), and vendor prefixes ("OpenAI: ",
    /// "openai/") go. Names without the brand come back unchanged.
    static func modelName(_ name: String) -> String {
        guard containsBrand(name) else { return name }
        var text = name
        let rules: [(pattern: String, template: String)] = [
            (#"(?i)\b(?:azure\s+)?open\s?ai\b\s*[:/|·-]?\s*"#, ""),
            (#"(?i)\b(?:chat\s?)?gpt[\s_-]*(?=\d)"#, modelFamily + " "),
            (#"(?i)\b(?:chat\s?)?gpt\b[\s_-]*"#, ""),
            (#"\s{2,}"#, " "),
        ]
        for rule in rules {
            text = text.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":/|·-")))
        return text.isEmpty ? modelFamily : text
    }
}
