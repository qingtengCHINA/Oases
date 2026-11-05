import Foundation
import Testing
@testable import Oases_Chat

/// The one-page consent at the send-time gate (`AIConsentGate`) and the request gate's tickets
/// and content check (`AIRequestGate`). Compiled, not run.
@MainActor
@Suite("AI request gate", .serialized)
struct AIRequestGateTests {

    // MARK: - The send-time gate

    /// Without the consent a send shows the page as a sheet instead of going, keeps the input, and
    /// goes on once the user agrees.
    @Test func aSendWaitsForTheConsent() {
        var accepted = false
        let gate = AIConsentGate(isAccepted: { accepted }, recordAcceptance: { accepted = true })
        var sent = 0

        #expect(!gate.requireConsent(then: { sent += 1 }))
        #expect(gate.isPresented)
        #expect(sent == 0)

        gate.accept()

        #expect(sent == 1)
        #expect(accepted)
        #expect(!gate.isPresented)
        #expect(gate.pendingAction == nil)
    }

    /// 不同意 drops the send; nothing goes and the input stays.
    @Test func decliningSendsNothing() {
        let gate = AIConsentGate(
            isAccepted: { false },
            recordAcceptance: { Issue.record("must not record the consent") }
        )
        var sent = 0

        gate.requireConsent(then: { sent += 1 })
        gate.dismiss()

        #expect(sent == 0)
        #expect(gate.pendingAction == nil)
        #expect(!gate.isPresented)
    }

    /// With the consent a send goes at once.
    @Test func withTheConsentASendGoesAtOnce() {
        let gate = AIConsentGate(isAccepted: { true }, recordAcceptance: {})
        #expect(gate.requireConsent(then: {}))
        #expect(!gate.isPresented)
    }

    // MARK: - The request gate

    /// A request carrying user content needs the consent (its own error, so the UI offers the
    /// sheet); loopback is exempt. Without a test override the transfer check reads the consent too.
    @Test func contentNeedsTheConsent() {
        let consent = AIDataSharingConsentFixture()
        defer { consent.restore() }
        AIRequestGate.setAllowsTransferForTesting(nil)
        defer { AIRequestGate.setAllowsTransferForTesting(true) }
        let cloud = URL(string: "https://api.oases.dev/v1/chat/completions")

        consent.declineForTest()
        #expect(!AIRequestGate.allowsTransfer)
        #expect(throws: APIError.self) { try AIRequestGate.checkBeforeSending(to: cloud) }
        #expect(throws: CancellationError.self) { try AIRequestGate.checkTransfer(to: cloud) }
        #expect(throws: Never.self) { try AIRequestGate.checkBeforeSending(to: URL(string: "http://localhost:8080/v1")) }

        consent.acceptForTest()
        #expect(AIRequestGate.allowsTransfer)
        #expect(throws: Never.self) { try AIRequestGate.checkBeforeSending(to: cloud) }
    }

    /// A withdrawal voids the tickets issued before it, even after the consent is given again.
    @Test func aWithdrawalVoidsEarlierTickets() {
        let consent = AIDataSharingConsentFixture()
        defer { consent.restore() }
        AIRequestGate.setAllowsTransferForTesting(nil)
        defer { AIRequestGate.setAllowsTransferForTesting(true) }
        consent.acceptForTest()
        let before = AIRequestGate.issueTicket()
        #expect(AIRequestGate.accepts(before))

        consent.declineForTest()
        AIRequestGate.voidRequests()
        #expect(!AIRequestGate.accepts(before))

        consent.acceptForTest()
        #expect(!AIRequestGate.accepts(before), "a ticket from before the withdrawal stays void")
        #expect(AIRequestGate.accepts(AIRequestGate.issueTicket()))
    }

    /// A run's task carries its ticket into every request it makes; outside a run there is none.
    @Test func aRunCarriesItsTicket() async {
        #expect(AIRequestGate.ticket == nil)
        let seen = Locked<AIRequestGate.Ticket?>(nil)
        await AIRequestGate.startRun {
            seen.withLock { $0 = AIRequestGate.ticket }
        }.value
        #expect(seen.withLock { $0 } != nil)
    }
}
