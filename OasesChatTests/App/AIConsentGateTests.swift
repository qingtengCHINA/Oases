import XCTest
@testable import Oases_Chat

/// The send-time consent gate: with consent the caller proceeds; in limited
/// mode the send waits for the sheet and runs right after 「同意」, and
/// 「暂不」 drops it without touching anything.
@MainActor
final class AIConsentGateTests: XCTestCase {
    func testAcceptedConsentLetsTheCallerProceed() {
        let gate = AIConsentGate(isAccepted: { true }, recordAcceptance: { XCTFail("already accepted") })
        var ran = 0

        XCTAssertTrue(gate.requireConsent(then: { ran += 1 }))

        XCTAssertFalse(gate.isPresented)
        XCTAssertNil(gate.pendingAction)
        XCTAssertEqual(ran, 0, "the caller runs its own send; the gate must not run it twice")
    }

    func testLimitedModeHoldsTheSendUntilTheUserAgrees() {
        var accepted = false
        let gate = AIConsentGate(isAccepted: { accepted }, recordAcceptance: { accepted = true })
        var ran = 0

        XCTAssertFalse(gate.requireConsent(then: { ran += 1 }))
        XCTAssertTrue(gate.isPresented)
        XCTAssertNotNil(gate.pendingAction)
        XCTAssertEqual(ran, 0)

        gate.accept()

        XCTAssertTrue(accepted)
        XCTAssertEqual(ran, 1)
        XCTAssertFalse(gate.isPresented)
        XCTAssertNil(gate.pendingAction)
    }

    func testNotNowDropsTheSendAndRecordsNothing() {
        let gate = AIConsentGate(isAccepted: { false }, recordAcceptance: { XCTFail("must not record consent") })
        var ran = 0

        gate.requireConsent(then: { ran += 1 })
        gate.dismiss()

        XCTAssertEqual(ran, 0)
        XCTAssertFalse(gate.isPresented)
        XCTAssertNil(gate.pendingAction)
    }

    func testOnlyTheLatestSendIsKept() {
        var accepted = false
        let gate = AIConsentGate(isAccepted: { accepted }, recordAcceptance: { accepted = true })
        var sent: [String] = []

        gate.requireConsent(then: { sent.append("first") })
        gate.requireConsent(then: { sent.append("second") })
        gate.accept()

        XCTAssertEqual(sent, ["second"])
    }

    /// Call sites re-enter the gate from the pending action (`performSend`
    /// calls itself); after acceptance that pass must go straight through.
    func testReenteringSendRunsOnceAfterAcceptance() {
        var accepted = false
        let gate = AIConsentGate(isAccepted: { accepted }, recordAcceptance: { accepted = true })
        var delivered = 0

        func send() {
            guard gate.requireConsent(then: { send() }) else { return }
            delivered += 1
        }

        send()
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(gate.isPresented)

        gate.accept()

        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(gate.isPresented)
    }

    func testOpeningTheSheetFromTheNoticeQueuesNothing() {
        var accepted = false
        let gate = AIConsentGate(isAccepted: { accepted }, recordAcceptance: { accepted = true })

        gate.present(pending: nil)
        XCTAssertTrue(gate.isPresented)
        gate.accept()

        XCTAssertTrue(accepted)
        XCTAssertFalse(gate.isPresented)
    }

    func testPrivacySettingsDeepLink() {
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["privacy"]), .privacy)
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["data-privacy"]), .privacy)
        XCTAssertEqual(SettingsRoute(deepLink: .privacy), .dataPrivacy)
    }
}
