import Foundation
import Testing
@testable import Oases_Chat

/// The QingTeng account following the one-page consent (`AccountStore.followConsent`): nothing
/// goes to QTC without it, and declining or withdrawing signs out and voids sign-ins under way.
/// The consent record itself is covered in `AIDataSharingConsentTests`; the request gate in
/// `AIRequestGateTests`. These use the app's own defaults (put back afterwards). Compiled, not run.
@MainActor
@Suite("Consent and the QingTeng account", .serialized)
struct ConsentStoreTests {
    /// An account signed in against a stub QTC, its session in `keychain`, following the consent.
    private func signedInAccount(_ keychain: QTCMemoryKeychain) async -> AccountStore {
        let server = StubServer { _ in .json(200, meJSON(["apple"])) }
        let account = AccountStore(client: qtcClient(server), keychain: keychain.keychain)
        await account.signedIn(QTCSession(token: "t1", userId: "u1"))
        account.followConsent()
        return account
    }

    @Test func withdrawingSignsOutAndVoidsSignInsUnderWay() async {
        let consent = AIDataSharingConsentFixture()
        defer { consent.restore() }
        consent.acceptForTest()
        let keychain = QTCMemoryKeychain()
        let account = await signedInAccount(keychain)
        #expect(account.isSignedIn)
        let underWay = account.beginSignIn()

        consent.declineForTest()  // Settings › 撤回同意

        #expect(!account.isSignedIn)
        #expect(keychain.stored == nil, "the session is gone from the keychain")
        if let underWay {
            #expect(!account.accepts(underWay), "no sign-in under way lands afterwards")
        }
        #expect(account.beginSignIn() == nil, "nothing may start without the consent")
    }

    /// 不同意 the first time (nothing given before), with a session left from an earlier
    /// version: signed out the same way.
    @Test func aRefusalSignsOutASessionLeftFromBefore() async {
        let consent = AIDataSharingConsentFixture()
        defer { consent.restore() }
        consent.acceptForTest()
        let keychain = QTCMemoryKeychain()
        let account = await signedInAccount(keychain)
        consent.clearForTest()

        consent.declineForTest()

        #expect(!account.isSignedIn)
        #expect(keychain.stored == nil)
    }

    /// Agreeing again lets sign-in start again (the old session stays gone).
    @Test func agreeingAgainAllowsSignIn() async {
        let consent = AIDataSharingConsentFixture()
        defer { consent.restore() }
        consent.acceptForTest()
        let keychain = QTCMemoryKeychain()
        let account = await signedInAccount(keychain)
        consent.declineForTest()

        consent.acceptForTest()

        #expect(account.beginSignIn() != nil)
        #expect(!account.isSignedIn)
    }
}
