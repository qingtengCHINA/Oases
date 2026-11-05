import XCTest
@testable import Oases_Chat

@MainActor
final class FinalDeliveryTests: XCTestCase {
    func testExistingFallbackFixturesCoverArtifactAndFailureStates() {
        let result = ProjectFinalDeliverySelfTest.run()

        XCTAssertTrue(result.hasPrefix("final_delivery_fallback_ok"), result)
    }

    func testFailedToolFixtureRetainsFailureEvidence() {
        let call = ToolFixtures.failedCall()

        XCTAssertEqual(call.status, .error)
        XCTAssertTrue(call.output?.contains("timeout") == true)
    }
}
