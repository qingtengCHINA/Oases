import XCTest
@testable import Oases_Chat

/// Oases Haiku (`claude-haiku-5-5`) is a limited-time free model: listed in
/// both the text and Ogent catalogs, and outside every membership limit.
@MainActor
final class PromoFreeModelTests: XCTestCase {
    private let haiku = "claude-haiku-5-5"

    func testHaikuIsListedForTextAndOgent() {
        let text = Models.options(for: .text).first { $0.id == haiku }
        XCTAssertEqual(text?.label, "Oases Haiku")
        XCTAssertEqual(text?.isPromoFree, true)
        XCTAssertEqual(text?.isBeta, false)

        let ogent = Models.options(for: .project).first { $0.id == haiku }
        XCTAssertEqual(ogent?.label, "Oases Haiku")
        XCTAssertEqual(ogent?.isPromoFree, true)
        XCTAssertNotNil(OasesBuiltinProvider.entry(forModelId: haiku), "Ogent sends through the built-in provider entry")

        XCTAssertTrue(Models.isPromoFree(haiku))
        XCTAssertFalse(Models.isPromoFree(Models.defaultChat))
    }

    func testFreePlanUsesHaikuWithoutMembershipOrQuota() {
        let center = MembershipCenter.shared
        let savedTier = center.tier
        defer { center.overrideTierForTesting(savedTier) }
        center.overrideTierForTesting(.free)

        XCTAssertNil(center.authorize(category: .text, modelId: haiku))
        XCTAssertNil(center.authorize(category: .project, modelId: haiku))
        XCTAssertNil(center.authorizeOgent(ownModel: false, modelId: haiku))
        // The free plan still limits other built-in models.
        XCTAssertNotNil(center.authorize(category: .text, modelId: "grok-4.6"))

        let text = center.usedTodayForTesting("text")
        let ogent = center.usedTodayForTesting("ogent")
        center.commit(category: .text, modelId: haiku)
        center.commit(category: .project, modelId: haiku)
        center.commitOgent(ownModel: false, modelId: haiku)
        XCTAssertEqual(center.usedTodayForTesting("text"), text, "limited-time free messages don't count")
        XCTAssertEqual(center.usedTodayForTesting("ogent"), ogent, "limited-time free Ogent runs don't count")
    }
}
