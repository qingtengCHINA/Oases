import XCTest
@testable import Oases_Chat

final class AIProviderRoutingTests: XCTestCase {
    func testProjectRouteDefaultsToOasesWhenNoCustomProviderIsConfigured() {
        let summary = AIProviderRouting.projectRouteSummary

        XCTAssertTrue(summary.contains("project_ai_route=oases_default"), summary)
        XCTAssertTrue(AIProviderRouting.projectPromptNote.contains("Oases 默认端点"))
        XCTAssertEqual(AIProviderRouting.effectiveProjectRoute.kind, .oasesDefault)
        XCTAssertEqual(AIProviderRouting.effectiveProjectRoute.baseURL, Secrets.apiBaseURL)
    }

    func testProviderSelfTestCoversOptionalCustomOverrideWithoutNetworkProbe() {
        let result = AIProviderSettingsStore.runSelfTest()

        XCTAssertTrue(result.contains("ai_provider_settings_ok"), result)
        XCTAssertTrue(result.contains("project_ai_route=oases_default"), result)
        XCTAssertTrue(result.contains("provider_optional_override_ok"), result)
    }
}
