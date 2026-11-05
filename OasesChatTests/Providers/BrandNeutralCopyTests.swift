import XCTest
@testable import Oases_Chat

/// App Store (mainland China): user-visible provider and model names must not
/// carry the OpenAI / ChatGPT / GPT brand, while internal keys keep it.
final class BrandNeutralCopyTests: XCTestCase {
    private let neutralProviderNames: Set<String> = ["AI 供应商", "AI 供應商", "AI provider"]

    func testModelNameDropsTheBrand() {
        XCTAssertEqual(BrandNeutralCopy.modelName("GPT-5.6 Sol"), "Model 5.6 Sol")
        XCTAssertEqual(BrandNeutralCopy.modelName("GPT-4o Mini"), "Model 4o Mini")
        XCTAssertEqual(BrandNeutralCopy.modelName("GPT Image 2"), "Image 2")
        XCTAssertEqual(BrandNeutralCopy.modelName("OpenAI: GPT-4o"), "Model 4o")
        XCTAssertEqual(BrandNeutralCopy.modelName("ChatGPT 4o Latest"), "Model 4o Latest")
        XCTAssertEqual(BrandNeutralCopy.modelName("OpenAI"), "Model")
    }

    func testModelNameLeavesOtherNamesAlone() {
        for name in ["Claude Sonnet 5", "Gemini 2.5 Pro", "OpenRouter Auto", "o3 Mini", "Oases Luna"] {
            XCTAssertEqual(BrandNeutralCopy.modelName(name), name)
        }
    }

    func testDerivedDisplayNameIsNeutralButIdIsUntouched() {
        XCTAssertEqual(modelDisplayName(from: "gpt-4o-mini"), "Model 4o Mini")
        XCTAssertEqual(modelDisplayName(from: "openai/gpt-oss-120b"), "OSS 120b")
        XCTAssertEqual(modelDisplayName(from: "deepseek-v4-flash"), "DeepSeek V4 Flash")
        XCTAssertEqual(LLMModel.gpt55.id, "gpt-5.5")
    }

    func testProviderNameMapsBrandedKeysOnly() {
        XCTAssertTrue(neutralProviderNames.contains(BrandNeutralCopy.providerName("OpenAI")))
        XCTAssertTrue(neutralProviderNames.contains(BrandNeutralCopy.providerName("Azure OpenAI")))
        XCTAssertEqual(BrandNeutralCopy.providerName("Anthropic"), "Anthropic")
        XCTAssertEqual(BrandNeutralCopy.providerName("OpenRouter"), "OpenRouter")
    }

    func testProviderTypeCopyIsNeutralAndStoredKeyIsStable() {
        XCTAssertTrue(neutralProviderNames.contains(ProviderType.openAI.displayName))
        // Capability / models.dev lookups and stored entries keep the internal key.
        XCTAssertEqual(ProviderType.openAI.modelProviderName, "OpenAI")
        XCTAssertEqual(ProviderType.anthropic.modelProviderName, ProviderType.anthropic.displayName)
        for type in ProviderType.allCases {
            XCTAssertFalse(BrandNeutralCopy.containsBrand(type.displayName), type.rawValue)
            XCTAssertFalse(BrandNeutralCopy.containsBrand(type.pickerSubtitle), type.rawValue)
        }
    }

    func testBuiltInModelNamesAreNeutral() {
        let builtIns = LLMModel.allModels + LLMModel.allOpenAICodexOAuth
            + ProviderType.allCases.flatMap(\.builtInModels)
        for model in builtIns {
            XCTAssertFalse(BrandNeutralCopy.containsBrand(model.displayName), "\(model.id): \(model.displayName)")
        }
    }
}
