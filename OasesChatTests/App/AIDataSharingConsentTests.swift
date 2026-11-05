import XCTest
@testable import Oases_Chat

final class AIDataSharingConsentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AIDataSharingConsentTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testLegacyFlagDoesNotGrantCurrentConsent() {
        defaults.set(true, forKey: "aiDataSharingConsentAccepted")

        XCTAssertNil(AIDataSharingConsent.status(in: defaults))
        XCTAssertNil(defaults.string(forKey: AIDataSharingConsent.versionKey))
    }

    func testAcceptRequiresCurrentVersionAndCanBeRevoked() {
        AIDataSharingConsent.accept(in: defaults)

        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .accepted)
        XCTAssertEqual(AIDataSharingConsent.currentVersion, "2026-10-30")
        XCTAssertEqual(defaults.string(forKey: AIDataSharingConsent.versionKey), AIDataSharingConsent.currentVersion)
        XCTAssertNotNil(defaults.object(forKey: AIDataSharingConsent.decidedAtKey))
        XCTAssertNotNil(defaults.object(forKey: AIDataSharingConsent.acceptedAtKey))

        AIDataSharingConsent.revoke(in: defaults)

        XCTAssertNil(AIDataSharingConsent.status(in: defaults))
        XCTAssertNil(defaults.object(forKey: AIDataSharingConsent.acceptedAtKey))
    }

    func testDeclineIsPersistedButDoesNotGrantAccess() {
        AIDataSharingConsent.decline(in: defaults)

        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .declined)
        XCTAssertFalse(AIDataSharingConsent.status(in: defaults) == .accepted)
        XCTAssertNil(defaults.object(forKey: AIDataSharingConsent.acceptedAtKey))
    }

    /// UI tests seed the decision with `-aiDataSharingConsent.pageVersion 2026-10-30
    /// -aiDataSharingConsent.status accepted`; the argument domain stores both as strings.
    func testLaunchArgumentStyleStringValuesAreRead() {
        defaults.set(AIDataSharingConsent.currentVersion, forKey: AIDataSharingConsent.versionKey)
        defaults.set("accepted", forKey: AIDataSharingConsent.statusKey)
        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .accepted)
    }

    // MARK: - acceptedAt

    func testAcceptedAtIsTheAcceptTimeOnlyWhileAccepted() {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        AIDataSharingConsent.accept(in: defaults, acceptedAt: when)
        XCTAssertEqual(AIDataSharingConsent.acceptedAt(in: defaults), when)

        AIDataSharingConsent.decline(in: defaults)
        XCTAssertNil(AIDataSharingConsent.acceptedAt(in: defaults))
    }

    func testAcceptedAtIgnoresAnOlderPageVersion() {
        AIDataSharingConsent.accept(in: defaults)
        defaults.set("2026-01-01", forKey: AIDataSharingConsent.versionKey)
        XCTAssertNil(AIDataSharingConsent.acceptedAt(in: defaults))
        XCTAssertNil(AIDataSharingConsent.status(in: defaults), "agreement to an older page is asked again")
    }

    /// A refusal of an older page stays a refusal (not asked again at launch).
    func testARefusalOfAnOlderPageStays() {
        AIDataSharingConsent.decline(in: defaults)
        defaults.set("2026-01-01", forKey: AIDataSharingConsent.versionKey)
        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .declined)
    }

    // MARK: - Migration from the older consents

    private func setMainland(_ key: String, granted: Bool) {
        defaults.set(Data(#"{"granted":\#(granted),"version":1,"date":0}"#.utf8), forKey: key)
    }

    /// The old AI consent alone never covered the policy and terms: the page once.
    func testTheOldAIConsentAloneMeansThePageOnce() {
        defaults.set(1, forKey: AIDataSharingConsent.legacyVersionKey)
        defaults.set("accepted", forKey: AIDataSharingConsent.statusKey)
        AIDataSharingConsent.migrateLegacy(in: defaults)
        XCTAssertNil(AIDataSharingConsent.status(in: defaults))
        XCTAssertNil(defaults.object(forKey: AIDataSharingConsent.legacyVersionKey))
    }

    /// Accepted both the old policy-and-terms consent and the old AI consent: agreed.
    func testBothOldConsentsCountAsAgreed() {
        defaults.set(1, forKey: AIDataSharingConsent.legacyVersionKey)
        defaults.set("accepted", forKey: AIDataSharingConsent.statusKey)
        setMainland(AIDataSharingConsent.legacyPolicyKey, granted: true)
        setMainland(AIDataSharingConsent.legacyCrossBorderKey, granted: true)
        defaults.set("mainland", forKey: AIDataSharingConsent.legacyRegionKey)
        AIDataSharingConsent.migrateLegacy(in: defaults)
        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .accepted)
        for key in [AIDataSharingConsent.legacyPolicyKey, AIDataSharingConsent.legacyCrossBorderKey, AIDataSharingConsent.legacyRegionKey] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    /// Declined or withdrew either old consent: stays declined.
    func testAnOldRefusalStaysDeclined() {
        defaults.set(1, forKey: AIDataSharingConsent.legacyVersionKey)
        defaults.set("declined", forKey: AIDataSharingConsent.statusKey)
        AIDataSharingConsent.migrateLegacy(in: defaults)
        XCTAssertEqual(AIDataSharingConsent.status(in: defaults), .declined)

        let other = "AIDataSharingConsentTests-\(UUID().uuidString)"
        let mainland = UserDefaults(suiteName: other)!
        defer { mainland.removePersistentDomain(forName: other) }
        mainland.set(1, forKey: AIDataSharingConsent.legacyVersionKey)
        mainland.set("accepted", forKey: AIDataSharingConsent.statusKey)
        mainland.set(Data(#"{"granted":true,"version":1,"date":0}"#.utf8), forKey: AIDataSharingConsent.legacyPolicyKey)
        mainland.set(Data(#"{"granted":false,"version":1,"date":0}"#.utf8), forKey: AIDataSharingConsent.legacyCrossBorderKey)
        AIDataSharingConsent.migrateLegacy(in: mainland)
        XCTAssertEqual(AIDataSharingConsent.status(in: mainland), .declined)
    }

    // MARK: - On-device (loopback) hosts

    func testLoopbackHostsAreOnDevice() {
        for raw in [
            "http://localhost:11434/v1",
            "http://LOCALHOST/v1",
            "http://localhost./v1",
            "http://127.0.0.1:8080",
            "https://127.1.2.3/v1",
            "http://[::1]:11434/v1",
        ] {
            XCTAssertTrue(AIDataSharingConsent.isOnDevice(URL(string: raw)), raw)
        }
    }

    func testLookalikeAndRemoteHostsAreNotOnDevice() {
        for raw in [
            "https://api.oases.dev/v1",
            "http://127.0.0.1.nip.io/v1",       // resolves anywhere
            "http://127.example.com/v1",
            "http://localhost.evil.com/v1",
            "http://127.0.0.1@evil.com/v1",     // userinfo, real host is evil.com
            "http://127.0.0.256/v1",
            "http://127.0.0/v1",
            "http://10.0.0.2:11434/v1",
            "http://192.168.1.5/v1",
            "file:///tmp/model",
        ] {
            XCTAssertFalse(AIDataSharingConsent.isOnDevice(URL(string: raw)), raw)
        }
        XCTAssertFalse(AIDataSharingConsent.isOnDevice(nil))
    }
}

/// The `.standard`-backed state used by the app (root switch, gates).
/// Snapshots and restores the simulator's real choice.
final class AIDataSharingConsentStateTests: XCTestCase {
    private let consent = AIDataSharingConsentFixture()

    override func tearDown() {
        consent.restore()
        super.tearDown()
    }

    func testNoDecisionMeansOnboardingNotLimitedMode() {
        consent.clearForTest()
        XCTAssertFalse(AIDataSharingConsent.hasDecision)
        XCTAssertFalse(AIDataSharingConsent.isLimitedMode)
        XCTAssertFalse(AIDataSharingConsent.isAccepted)
    }

    func testDeclineIsADecisionAndEntersLimitedMode() {
        consent.declineForTest()
        XCTAssertTrue(AIDataSharingConsent.hasDecision)
        XCTAssertTrue(AIDataSharingConsent.isLimitedMode)
        XCTAssertFalse(AIDataSharingConsent.isAccepted)
    }

    func testAcceptLeavesLimitedMode() {
        consent.declineForTest()
        consent.acceptForTest()
        XCTAssertTrue(AIDataSharingConsent.hasDecision)
        XCTAssertFalse(AIDataSharingConsent.isLimitedMode)
        XCTAssertTrue(AIDataSharingConsent.isAccepted)
        XCTAssertNotNil(AIDataSharingConsent.acceptedAt())
    }

    func testEveryChangePostsTheChangeNotification() {
        for change in [
            { AIDataSharingConsent.accept(in: .standard) },
            { AIDataSharingConsent.decline(in: .standard) },
            { AIDataSharingConsent.revoke(in: .standard) },
        ] {
            consent.clearForTest()
            let posted = expectation(forNotification: AIDataSharingConsent.didChangeNotification, object: nil)
            change()
            wait(for: [posted], timeout: 1)
        }
    }

    func testRequestsAreAllowedWithConsentOrToLoopbackOnly() {
        let cloud = URL(string: "https://api.oases.dev/v1")
        let local = URL(string: "http://127.0.0.1:11434/v1")

        consent.declineForTest()
        XCTAssertFalse(AIDataSharingConsent.allowsRequest(to: cloud))
        XCTAssertTrue(AIDataSharingConsent.allowsRequest(to: local))

        consent.acceptForTest()
        XCTAssertTrue(AIDataSharingConsent.allowsRequest(to: cloud))
    }

    func testConsentErrorsAreRecognised() {
        XCTAssertTrue(AIDataSharingConsent.isConsentError(APIError.dataSharingConsentRequired))
        XCTAssertTrue(AIDataSharingConsent.isConsentError(VoiceProviderError.dataSharingConsentRequired))
        XCTAssertTrue(AIDataSharingConsent.isConsentError(SessionIntentError.dataSharingConsentRequired))
        XCTAssertTrue(AIDataSharingConsent.isConsentError(CorrectionError.dataSharingConsentRequired))
        XCTAssertFalse(AIDataSharingConsent.isConsentError(APIError.invalidURL))
        XCTAssertFalse(AIDataSharingConsent.isConsentError(VoiceProviderError.authError))
        XCTAssertFalse(AIDataSharingConsent.isConsentError(URLError(.notConnectedToInternet)))
    }
}
