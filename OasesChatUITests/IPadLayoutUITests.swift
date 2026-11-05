import UIKit
import XCTest

/// Regression coverage for the native iPad window layout.
///
/// This test deliberately uses the normal app launch path. `-ui-test` changes
/// the app's bootstrap decision, so the test only skips the iSH work through
/// the dedicated environment flag instead.
@MainActor
final class IPadLayoutUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The native window layout is only applicable on iPad."
        )

        app.launchEnvironment["OASES_SKIP_ISH_BOOTSTRAP"] = "1"
        // UserDefaults reads the standard `-key value` launch-argument form.
        // This keeps the accessibility label lookup deterministic without
        // changing any production defaults. The AI data-sharing decision is
        // seeded the same way so the app opens on the main UI, not the
        // first-run onboarding (the argument domain is never persisted).
        app.launchArguments = ["-appLanguage", "zh-Hans"] + Self.acceptedAIDataSharingConsent
    }

    /// `AIDataSharingConsent.versionKey` / `statusKey` for the current
    /// one-page consent, accepted.
    static let acceptedAIDataSharingConsent = [
        "-aiDataSharingConsent.pageVersion", "2026-10-30",
        "-aiDataSharingConsent.status", "accepted",
    ]

    override func tearDownWithError() throws {
        // Leave the simulator in the same orientation as the other UI tests.
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testIPadWindowKeepsDraftAcrossRotationAndTogglesSidebar() throws {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        let root = element(withIdentifier: "oases.root.surface")
        XCTAssertTrue(root.waitForExistence(timeout: 15))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitForWindowOrientation(landscape: false),
            "The app did not settle into portrait orientation."
        )
        XCTAssertGreaterThan(
            app.windows.firstMatch.frame.width,
            700,
            "Portrait iPad window is unexpectedly narrow."
        )
        assertRootUsesWindowWidth(root, named: "portrait")
        attachScreenshot(named: "iPad portrait layout")

        // Type without submitting. The same draft must survive the rotation.
        let input = chatInput(in: root)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isHittable)
        input.tap()
        input.typeText("iPad draft")
        XCTAssertTrue(accessibilityValue(of: input).contains("iPad draft"))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitForWindowOrientation(landscape: true),
            "The app did not settle into landscape orientation."
        )
        assertRootUsesWindowWidth(root, named: "landscape")
        attachScreenshot(named: "iPad landscape layout")

        let rotatedInput = chatInput(in: root)
        XCTAssertTrue(rotatedInput.waitForExistence(timeout: 10))
        XCTAssertTrue(
            accessibilityValue(of: rotatedInput).contains("iPad draft"),
            "The unsent draft was lost while rotating the iPad window."
        )

        // Landscape iPad is the wide-window case. The sidebar and chat column
        // must be visible as adjacent native columns without overlap.
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(windowFrame.width, 850)
        let sidebar = element(withIdentifier: "oases.sidebar")
        let chat = element(withIdentifier: "oases.chat.column")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(sidebar.frame.width, 0)
        XCTAssertGreaterThan(chat.frame.width, 0)
        XCTAssertLessThanOrEqual(
            sidebar.frame.maxX,
            chat.frame.minX + 2,
            "The iPad sidebar overlaps the chat column."
        )
        XCTAssertLessThanOrEqual(
            chat.frame.maxX,
            windowFrame.maxX + 2,
            "The chat column extends beyond the native window."
        )

        // On a regular-width iPad the existing menu button collapses and
        // restores the pinned sidebar. Keep both checks on this same root.
        let menu = app.buttons["打开侧栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(
            waitForDisappearance(of: sidebar),
            "The iPad sidebar did not hide after tapping 打开侧栏."
        )
        XCTAssertTrue(root.exists)

        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 5),
            "The iPad sidebar did not return after tapping 打开侧栏 again."
        )

        // Finally verify that the composer remains an interactive text input
        // and that tapping it brings up the software keyboard on iPad.
        let finalInput = chatInput(in: root)
        XCTAssertTrue(finalInput.waitForExistence(timeout: 10))
        XCTAssertTrue(finalInput.isHittable)
        finalInput.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "The iPad composer did not present a keyboard after tapping."
        )
    }

    private func element(withIdentifier identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func chatInput(in root: XCUIElement) -> XCUIElement {
        // The current composer is a SwiftUI TextField(axis: .vertical),
        // while older builds exposed the UIKit-backed composer as a TextView.
        // Prefer the current AX type and retain the legacy fallback.
        let textField = root.textFields.firstMatch
        if textField.exists {
            return textField
        }
        return root.textViews.firstMatch
    }

    private func accessibilityValue(of element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        return ""
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRootUsesWindowWidth(
        _ root: XCUIElement,
        named orientation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowWidth = app.windows.firstMatch.frame.width
        let rootWidth = root.frame.width
        XCTAssertGreaterThan(rootWidth, 0, "\(orientation) root has no width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            rootWidth,
            windowWidth * 0.90,
            "\(orientation) root does not use the native window width",
            file: file,
            line: line
        )
    }

    private func waitForWindowOrientation(
        landscape: Bool,
        timeout: TimeInterval = 10
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                let frame = self.app.windows.firstMatch.frame
                return landscape ? frame.width > frame.height : frame.height > frame.width
            },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDisappearance(
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
