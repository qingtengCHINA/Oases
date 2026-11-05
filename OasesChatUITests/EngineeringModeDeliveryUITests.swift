import XCTest

@MainActor
final class EngineeringModeDeliveryUITests: XCTestCase {
    func testAppLaunchesWithoutShowingAStartupSelfTestSurface() {
        let app = XCUIApplication()
        // Seed the AI data-sharing decision so launch goes past onboarding
        // (see `IPadLayoutUITests.acceptedAIDataSharingConsent`).
        app.launchArguments = ["-ui-test"] + IPadLayoutUITests.acceptedAIDataSharingConsent
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
