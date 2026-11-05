import Foundation
@testable import Oases_Chat

/// Tests that drive `ChatService`/`APIClient` need an accepted AI data-sharing
/// consent: the request guards read `UserDefaults.standard`, so the result
/// would otherwise depend on what the simulator's app last chose. Snapshots
/// the real choice, sets the one the test needs, and puts it back afterwards.
final class AIDataSharingConsentFixture {
    private let keys = [
        AIDataSharingConsent.versionKey,
        AIDataSharingConsent.statusKey,
        AIDataSharingConsent.acceptedAtKey,
        AIDataSharingConsent.decidedAtKey,
    ]
    private var saved: [String: Any]?

    func acceptForTest() {
        snapshotIfNeeded()
        AIDataSharingConsent.accept(in: .standard)
    }

    /// Limited mode: a decision was made, and it was "no".
    func declineForTest() {
        snapshotIfNeeded()
        AIDataSharingConsent.decline(in: .standard)
    }

    /// No decision for the current page (onboarding not finished).
    func clearForTest() {
        snapshotIfNeeded()
        AIDataSharingConsent.revoke(in: .standard)
    }

    func restore() {
        guard let saved else { return }
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        self.saved = nil
    }

    private func snapshotIfNeeded() {
        guard saved == nil else { return }
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            // `persistentDomain` skips the launch-argument domain, so a UI-test
            // style `-aiDataSharingConsent.status accepted` isn't written back.
            if let value = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] {
                snapshot[key] = value
            }
        }
        saved = snapshot
    }
}
