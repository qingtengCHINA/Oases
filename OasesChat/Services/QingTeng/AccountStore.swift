import Foundation
import Observation
import Security

/// The QingTeng session in the keychain: its own service, readable only by
/// the app (not the widget, share or Files extensions: they never need the account), after the first
/// unlock, on this device only.
enum QTCKeychain {
    private static let service = "dev.oases.chat.ios.qtc"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for account: String) {
        delete(account)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the QingTeng session lives between launches (the keychain; a fake in tests).
struct SessionKeychain: Sendable {
    var load: @Sendable () -> QTCSession?
    var save: @Sendable (QTCSession) -> Void
    var clear: @Sendable () -> Void

    /// The session as JSON in the keychain, account "qtc.session".
    static let live: SessionKeychain = {
        let account = "qtc.session"
        return SessionKeychain(
            load: {
                guard let json = QTCKeychain.read(account) else { return nil }
                return try? JSONDecoder().decode(QTCSession.self, from: Data(json.utf8))
            },
            save: { session in
                guard let data = try? JSONEncoder().encode(session), let json = String(data: data, encoding: .utf8) else { return }
                QTCKeychain.save(json, for: account)
            },
            clear: { QTCKeychain.delete(account) }
        )
    }()
}

/// The user's QingTeng account in Oases Chat (ported from 讲真话 (Maat), Stars and PlusProMax, themselves from Xplate and K线艺术家's
/// `AccountStore`): the session kept in the keychain, refreshed at launch
/// when it is about to expire, and the profile (`GET /v1/me`: UID, sign-in
/// methods, payout address).
///
/// Any 401 means "sign in again": the session is dropped and `needsSignIn`
/// is raised. Signing out only forgets the session and profile on this
/// device; the chats, Ogent sessions, providers and API keys, provider sign-ins and the membership stay, and the server is never
/// called (deleting the account is a separate step).
@Observable
@MainActor
final class AccountStore {
    /// A token with less than this left is refreshed at launch (tokens last 30 days).
    nonisolated static let refreshWindow: TimeInterval = 7 * 86_400

    private(set) var session: QTCSession?
    private(set) var me: QTCMe?
    /// The server ended the session (401): show sign-in again. Not set for a
    /// user who never signed in or signed out themselves.
    private(set) var needsSignIn = false

    var isSignedIn: Bool { session != nil }

    @ObservationIgnored private let client: QTCClient
    @ObservationIgnored private let keychain: SessionKeychain
    @ObservationIgnored private let now: () -> Date
    /// Bumped by every profile read that starts and by every change made
    /// here (saving an address, a new session): only the newest read may set
    /// `me`, and a read that began before a change never overwrites it.
    @ObservationIgnored private var profileRevision = 0
    /// Whether personal data may go to QTC now (the one-page consent, wired by `followConsent`;
    /// always true where no consent applies, as in tests).
    @ObservationIgnored var mayTransfer: @MainActor () -> Bool = { true }
    /// Watches the consent for a refusal or withdrawal (`followConsent`).
    @ObservationIgnored var consentObserver: NSObjectProtocol?
    /// Bumped, synchronously, when the transfer consent is taken back: every sign-in begun
    /// before is void, even if the consent is given again before it ends (去做's Codex review).
    @ObservationIgnored private(set) var authenticationEpoch = 0
    /// Accounts deleted from this device in this run. No restore or token refresh may bring one
    /// back: a refresh that lands during a deletion swaps in a fresh token for the same user, so
    /// deletion clean-up goes by user id, not by the exact session (Codex review).
    @ObservationIgnored private var deletedUserIDs: Set<String> = []

    /// A sign-in's claim to finish: taken before anything is sent, checked before the
    /// credential exchange and before the session is kept.
    struct SignInTicket: Equatable {
        fileprivate let epoch: Int
    }

    /// One `GET /v1/me` under way: the session it was sent with and the revision it saw.
    struct ProfileRead {
        let session: QTCSession
        let revision: Int
    }

    init(client: QTCClient = QTCClient(), keychain: SessionKeychain = .live, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.keychain = keychain
        self.now = now
    }

    /// At launch: restore the session; with less than 7 days left, refresh it
    /// (401 → signed out; no answer → keep the old token and try next launch);
    /// then load the profile.
    func launch() async {
        guard mayTransfer(), let stored = keychain.load() else { return }
        guard !deletedUserIDs.contains(stored.userId) else {
            keychain.clear()  // left behind by a deletion: never restored
            return
        }
        session = stored
        if let expiry = Self.expiry(of: stored.token), expiry.timeIntervalSince(now()) < Self.refreshWindow {
            do {
                let fresh = try await client.refresh(token: stored.token)
                guard session == stored else { return }  // signed out or in again meanwhile
                // The account was deleted while the refresh was out: keep nothing.
                guard !deletedUserIDs.contains(stored.userId), !deletedUserIDs.contains(fresh.userId) else { return }
                keychain.save(fresh)
                session = fresh
            } catch QTCError.unauthorized {
                guard session == stored else { return }
                handleUnauthorized()
                return
            } catch {
                // Offline or server trouble: the old token stays valid until it expires.
            }
        }
        await loadMe()
    }

    /// A ticket for a sign-in starting now; nil when nothing may go to QTC.
    func beginSignIn() -> SignInTicket? {
        guard mayTransfer() else { return nil }
        return SignInTicket(epoch: authenticationEpoch)
    }

    /// The sign-in may go on: the consent still holds and was not taken back since it began.
    func accepts(_ ticket: SignInTicket) -> Bool {
        ticket.epoch == authenticationEpoch && mayTransfer()
    }

    /// The transfer consent was taken back: sign-ins under way end without a session.
    func voidSignInsUnderWay() {
        authenticationEpoch += 1
    }

    /// After a sign-in begun now (no ticket of its own).
    @discardableResult
    func signedIn(_ session: QTCSession) async -> Bool {
        await signedIn(session, ticket: beginSignIn())
    }

    /// After any sign-in (Apple, GitHub, Microsoft): keep the session and load the profile.
    /// Refused (nothing kept, nothing sent) when the consent is missing or was taken back
    /// since `ticket` was issued. True when kept.
    @discardableResult
    func signedIn(_ session: QTCSession, ticket: SignInTicket?) async -> Bool {
        guard let ticket, accepts(ticket) else { return false }
        keychain.save(session)
        self.session = session
        profileRevision += 1
        me = nil
        needsSignIn = false
        await loadMe()
        return true
    }

    /// Reloads the profile; a 401 signs out. Other failures keep what is
    /// shown, and so does an answer overtaken by a newer read or a change.
    func loadMe() async {
        guard let read = beginProfileRead() else { return }
        do {
            let fresh = try await client.me(token: read.session.token)
            finishProfileRead(read, with: fresh)
        } catch QTCError.unauthorized {
            guard session == read.session else { return }
            handleUnauthorized()
        } catch {
            // Offline or server trouble: try again on the next load.
        }
    }

    /// Starts a profile read (nil when signed out, or when nothing may go to QTC).
    func beginProfileRead() -> ProfileRead? {
        guard let session, mayTransfer() else { return nil }
        profileRevision += 1
        return ProfileRead(session: session, revision: profileRevision)
    }

    /// Shows a profile read's answer unless it is out of date: another
    /// session, a newer read, or a change made since it started. True when shown.
    @discardableResult
    func finishProfileRead(_ read: ProfileRead, with profile: QTCMe) -> Bool {
        guard session == read.session, profileRevision == read.revision else { return false }
        me = profile
        return true
    }

    /// A change this app just made (and the server confirmed): shown at once,
    /// and every read that started before it is now out of date.
    func changeProfile(_ change: (QTCMe) -> QTCMe) {
        profileRevision += 1
        me = me.map(change)
    }

    /// Saves (or, with nil, clears) the Arc payout address and shows it at
    /// once. A 401 signs out; every failure is thrown for the page to word.
    func savePayoutAddress(_ address: String?) async throws(QTCError) {
        guard let session else { throw .unauthorized }
        let failure: QTCError
        do {
            let saved = try await client.setPayoutAddress(arc: address, token: session.token)
            guard self.session == session else { return }  // signed out or in again meanwhile
            if me != nil {
                // A foreground reload that read the old address can no longer land on top.
                changeProfile { QTCMe(userId: $0.userId, uid: $0.uid, identities: $0.identities, payoutAddresses: saved) }
            } else {
                await loadMe()
            }
            return
        } catch {
            failure = QTCError.from(error)
        }
        if failure == .unauthorized, self.session == session { handleUnauthorized() }
        throw failure
    }

    // MARK: - Deleting the account (guide §9)

    /// How a deletion ended when it didn't throw.
    enum DeletionResult: Equatable {
        /// Gone at QTC (in every QingTeng app); signed out here.
        case deleted
        /// The request got no answer and the old session is now refused: it
        /// may have gone through, or the session merely ended. Signed out;
        /// signing in again tells (guide §9: a 401 alone never means deleted).
        case unconfirmed
        /// Someone else is signed in now than when the user confirmed: nothing was sent.
        case accountChanged
    }

    /// Deletes the account `session` (the one signed in when the user
    /// confirmed) at QTC (`POST /v1/me/delete`, with a fresh Apple
    /// authorization code when the account uses Apple, so QTC can revoke it).
    /// The iOS app keeps no account data on a server of its own (its AI traffic goes straight to the
    /// Oases gateway, keyed by the device, not the account), so QTC is the only step; the Oases web
    /// server drops its own row within a day (the deleted-users sweep). The session and profile are
    /// forgotten here only once QTC has answered. Chats, sessions, providers, API keys and the
    /// membership stay.
    func deleteAccount(_ session: QTCSession, appleAuthorizationCode: String?) async throws(QTCError) -> DeletionResult {
        guard self.session == session else { return .accountChanged }

        let failure: QTCError
        do {
            try await client.deleteAccount(token: session.token, appleAuthorizationCode: appleAuthorizationCode)
            finishDeletion(of: session)
            return .deleted
        } catch {
            failure = QTCError.from(error)
        }
        guard failure == .offline || failure == .unauthorized else { throw failure }

        // No answer (or a refusal of the session): ask QTC whether the account is still there.
        do {
            _ = try await client.me(token: session.token)
        } catch {
            let check = QTCError.from(error)
            guard check == .unauthorized else { throw check == .offline ? QTCError.offline : QTCError.unavailable }
            // Deleted, or only the session ended: sign in again to know.
            if self.session == session { handleUnauthorized() }
            return .unconfirmed
        }
        // Still there: not deleted. The user can try again.
        throw .unavailable
    }

    /// The account is gone at QTC. Whatever session of that user this device holds now is
    /// forgotten, even one a concurrent refresh (another window's `launch()`) swapped in with a
    /// fresh token meanwhile, and no refresh still out may bring it back. A genuinely different
    /// account signed in meanwhile stays.
    private func finishDeletion(of session: QTCSession) {
        deletedUserIDs.insert(session.userId)
        if let current = self.session {
            guard current.userId == session.userId else { return }
            signOut()
        } else if keychain.load()?.userId == session.userId {
            keychain.clear()
        }
        needsSignIn = false
    }

    /// Forgets the session on this device only (keychain and profile).
    func signOut() {
        keychain.clear()
        session = nil
        profileRevision += 1
        me = nil
        needsSignIn = false
    }

    /// Any 401 from QTC: signed out, and sign-in is asked for again.
    func handleUnauthorized() {
        signOut()
        needsSignIn = true
    }

    /// Seconds until the token (a JWT) expires, from its `exp` claim; nil when
    /// unreadable. Only the time is read; the server checks the signature.
    nonisolated static func secondsLeft(of token: String) -> TimeInterval? {
        expiry(of: token)?.timeIntervalSinceNow
    }

    /// The token's `exp` as a date (the middle part is base64url JSON).
    nonisolated static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
