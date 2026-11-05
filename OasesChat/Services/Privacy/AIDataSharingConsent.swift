import Foundation

/// The one-page consent (2026-10-30): 《隐私政策》, 《用户协议》 and the AI sentence, answered once
/// on the welcome flow's last page ("开始使用前"). The single consent record of the app.
///
/// Agreed: requests to AI services and the QingTeng account may go out. Declined: the app opens in
/// limited mode (everything local works), the account and network AI stay off, and an AI action or
/// QingTeng sign-in shows the same page as a sheet. Withdrawn in Settings: the same as declined.
enum AIDataSharingConsent {
    /// The page's version. Change it when the page or the documents change materially: everyone
    /// who agreed then sees the page again.
    static let currentVersion = "2026-10-30"

    /// Public for `@AppStorage` observation in the app entry point and for tests.
    static let versionKey = "aiDataSharingConsent.pageVersion"
    static let statusKey = "aiDataSharingConsent.status"
    static let acceptedAtKey = "aiDataSharingConsent.acceptedAt"
    /// When the answer (either way) was given.
    static let decidedAtKey = "aiDataSharingConsent.decidedAt"

    /// The consents before the one page: the AI data-sharing disclosure (an integer version) and
    /// the mainland China storefront's two consents (policy and terms; personal information) with
    /// the storefront it last read. Read once by `migrateLegacy`, then removed.
    static let legacyVersionKey = "aiDataSharingConsent.version"
    static let legacyPolicyKey = "consent.policy"
    static let legacyCrossBorderKey = "consent.crossBorder"
    static let legacyRegionKey = "consent.region"

    static let acceptedStatusRawValue = Status.accepted.rawValue

    enum Status: String, Equatable {
        case accepted
        case declined
    }

    /// Whether the current page has an affirmative decision.
    /// This synchronous API is safe to use from request and lifecycle guards.
    static var isAccepted: Bool {
        status(in: .standard) == .accepted
    }

    /// The user answered the current page either way: onboarding is done and the app opens.
    /// Declining is a valid answer — the app then runs in limited mode.
    static var hasDecision: Bool {
        status(in: .standard) != nil
    }

    /// Onboarding done but the page declined (or the consent withdrawn): everything works except
    /// the QingTeng account and sending data to AI services, until the user agrees on the page
    /// an AI action or sign-in shows.
    static var isLimitedMode: Bool {
        status(in: .standard) == .declined
    }

    /// Posted after `accept`, `decline` and `revoke`.
    static let didChangeNotification = Notification.Name("AIDataSharingConsent.didChange")

    static func acceptedAt(in defaults: UserDefaults = .standard) -> Date? {
        guard status(in: defaults) == .accepted,
              let seconds = defaults.object(forKey: acceptedAtKey) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Once, at launch, before anything reads the consent. Someone who accepted both the old
    /// policy-and-terms consent (mainland China storefront) and the old AI consent counts as having
    /// agreed; someone who declined or withdrew either stays declined; everyone else (no record,
    /// or the AI consent alone: it never covered the policy and terms) sees the page once.
    static func migrateLegacy(in defaults: UserDefaults = .standard) {
        let legacyKeys = [legacyVersionKey, legacyPolicyKey, legacyCrossBorderKey, legacyRegionKey]
        defer { legacyKeys.forEach { defaults.removeObject(forKey: $0) } }
        guard defaults.string(forKey: versionKey) == nil else { return }
        let hadAIRecord = defaults.integer(forKey: legacyVersionKey) >= 1
        guard hadAIRecord || defaults.object(forKey: legacyPolicyKey) != nil else { return }
        struct Mainland: Decodable { var granted: Bool }
        func mainland(_ key: String) -> Bool? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Mainland.self, from: $0) }?.granted
        }
        let ai = hadAIRecord ? defaults.string(forKey: statusKey).flatMap(Status.init(rawValue:)) : nil
        let policy = mainland(legacyPolicyKey)
        let crossBorder = mainland(legacyCrossBorderKey)
        if ai == .declined || policy == false || crossBorder == false {
            decline(in: defaults, notify: false)
        } else if ai == .accepted, policy == true {
            let acceptedAt = (defaults.object(forKey: acceptedAtKey) as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            accept(in: defaults, acceptedAt: acceptedAt, notify: false)
        } else {
            defaults.removeObject(forKey: statusKey)
            defaults.removeObject(forKey: acceptedAtKey)
        }
    }

    /// Requests to a model served on this device (loopback) never leave it,
    /// so they don't need the data-sharing consent.
    ///
    /// Only literal loopback hosts count. `127.` is matched as a whole IPv4
    /// address (four decimal octets), never as a name prefix: a host such as
    /// `127.0.0.1.example.com` resolves anywhere.
    static func isOnDevice(_ url: URL?) -> Bool {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            (1...3).contains(octet.count)
                && octet.allSatisfy { ("0"..."9").contains($0) }
                && (Int(octet) ?? 256) <= 255
        }
    }

    /// 同意并继续: records an affirmative choice for the current page, with its time.
    static func accept(
        in defaults: UserDefaults = .standard,
        acceptedAt: Date = Date(),
        notify: Bool = true
    ) {
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(Status.accepted.rawValue, forKey: statusKey)
        defaults.set(acceptedAt.timeIntervalSince1970, forKey: acceptedAtKey)
        defaults.set(acceptedAt.timeIntervalSince1970, forKey: decidedAtKey)
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// 不同意, or Settings › 撤回同意: records a negative choice. The app still opens, in limited
    /// mode (`isLimitedMode`); nothing goes to AI services or the QingTeng account until the user
    /// agrees on the page again.
    static func decline(in defaults: UserDefaults = .standard, notify: Bool = true) {
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(Status.declined.rawValue, forKey: statusKey)
        defaults.removeObject(forKey: acceptedAtKey)
        defaults.set(Date().timeIntervalSince1970, forKey: decidedAtKey)
        if notify { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }

    /// Clears the user's choice entirely, so the onboarding shows again.
    /// Withdrawing consent in Settings uses `decline` instead (limited mode).
    static func revoke(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: statusKey)
        defaults.removeObject(forKey: acceptedAtKey)
        defaults.removeObject(forKey: decidedAtKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Reads a valid decision only when it belongs to the current page. A refusal of an older
    /// page stays a refusal; agreement to an older page must be given again.
    static func status(in defaults: UserDefaults) -> Status? {
        guard let version = defaults.string(forKey: versionKey),
              let rawValue = defaults.string(forKey: statusKey),
              let status = Status(rawValue: rawValue)
        else {
            return nil
        }
        return status == .accepted && version != currentVersion ? nil : status
    }
}
