import Foundation
import Security
import Testing
@testable import Oases_Chat

/// Whether this test build can use the keychain. An unsigned build
/// (`CODE_SIGNING_ALLOWED=NO`) may not be allowed to.
private enum KeychainProbe {
    static let isAvailable: Bool = {
        let account = "qtc.test.probe"
        QTCKeychain.save("probe", for: account)
        defer { QTCKeychain.delete(account) }
        return QTCKeychain.read(account) == "probe"
    }()

    /// A generic password straight from the keychain, by service and account.
    static func string(service: String, account: String) -> String? {
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
}

/// The signed-in QingTeng session, kept in the keychain and refreshed at
/// launch (ported from K线艺术家's `AccountStoreTests`; guide §3).
@MainActor
@Suite("QingTeng account session")
struct AccountStoreTests {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func store(_ server: StubServer, _ keychain: QTCMemoryKeychain) -> AccountStore {
        let now = now
        return AccountStore(client: qtcClient(server), keychain: keychain.keychain, now: { now })
    }

    /// The server's answers by path; anything else is a 404.
    private func server(refresh: StubServer.Reply = .json(200, #"{"token":"fresh","userId":"u1"}"#),
                        me: StubServer.Reply = .json(200, meJSON(["apple"]))) -> StubServer {
        StubServer { request in
            switch request.path {
            case "/v1/auth/refresh": return refresh
            case "/v1/me": return me
            default: return .json(404, #"{"error":"not_found"}"#)
            }
        }
    }

    private func session(expiringIn interval: TimeInterval) -> QTCSession {
        QTCSession(token: TestJWT.token(expiresAt: now + interval), userId: "u1")
    }

    // MARK: - Launch

    @Test func launchRefreshesATokenWithLessThan7DaysLeft() async throws {
        let old = session(expiringIn: 6 * day)
        let keychain = QTCMemoryKeychain(old)
        let server = server()
        let account = store(server, keychain)

        await account.launch()

        let fresh = QTCSession(token: "fresh", userId: "u1")
        #expect(account.session == fresh)
        #expect(keychain.stored == fresh)
        #expect(server.paths == ["/v1/auth/refresh", "/v1/me"])
        #expect(server.requests[0].header("Authorization") == "Bearer \(old.token)")
        #expect(server.requests[1].header("Authorization") == "Bearer fresh", "the profile is read with the new token")
        #expect(account.me?.uid == 482913)
        #expect(account.isSignedIn)
        #expect(!account.needsSignIn)
    }

    @Test func launchLeavesATokenWithMoreThan7DaysAlone() async {
        let current = session(expiringIn: 8 * day)
        let keychain = QTCMemoryKeychain(current)
        let server = server()
        let account = store(server, keychain)

        await account.launch()

        #expect(server.paths == ["/v1/me"], "no refresh request")
        #expect(account.session == current)
        #expect(keychain.saves == 0)
        #expect(account.me?.userId == "u1")
    }

    @Test func refresh401SignsOut() async {
        let keychain = QTCMemoryKeychain(session(expiringIn: 2 * day))
        let server = server(refresh: .json(401, #"{"error":"unauthorized"}"#))
        let account = store(server, keychain)

        await account.launch()

        #expect(account.session == nil)
        #expect(!account.isSignedIn)
        #expect(account.needsSignIn)
        #expect(keychain.stored == nil)
        #expect(keychain.clears == 1)
        #expect(server.paths == ["/v1/auth/refresh"], "a signed-out launch doesn't ask for the profile")
    }

    @Test func refreshOfflineKeepsTheOldToken() async {
        let old = session(expiringIn: 2 * day)
        let keychain = QTCMemoryKeychain(old)
        let server = server(refresh: .failure(.notConnectedToInternet), me: .failure(.notConnectedToInternet))
        let account = store(server, keychain)

        await account.launch()

        #expect(account.session == old)
        #expect(keychain.stored == old)
        #expect(keychain.saves == 0)
        #expect(keychain.clears == 0)
        #expect(!account.needsSignIn)
        #expect(server.paths == ["/v1/auth/refresh", "/v1/me"])
    }

    @Test func launchWithoutAStoredSessionSendsNothing() async {
        let server = server()
        let account = store(server, QTCMemoryKeychain())

        await account.launch()

        #expect(server.requests.isEmpty)
        #expect(!account.isSignedIn)
        #expect(!account.needsSignIn, "never signed in is not the same as signed out by the server")
    }

    // MARK: - Signing in and out

    @Test func signingInKeepsTheSessionAndLoadsTheProfile() async {
        let keychain = QTCMemoryKeychain()
        let server = server()
        let account = store(server, keychain)
        let session = QTCSession(token: "t1", userId: "u1")

        await account.signedIn(session)

        #expect(account.session == session)
        #expect(keychain.stored == session)
        #expect(account.me?.uid == 482913)
        #expect(server.requests.first?.header("Authorization") == "Bearer t1")
    }

    @Test func profile401AsksForSignInAgain() async {
        let keychain = QTCMemoryKeychain()
        let server = server(me: .json(401, #"{"error":"unauthorized"}"#))
        let account = store(server, keychain)

        await account.signedIn(QTCSession(token: "t1", userId: "u1"))

        #expect(account.session == nil)
        #expect(account.me == nil)
        #expect(account.needsSignIn)
        #expect(keychain.stored == nil)
    }

    /// A 401 at any later point (a reload of the page) also goes back to sign-in, once.
    @Test func a401OnAReloadSignsOutWithoutLooping() async {
        let keychain = QTCMemoryKeychain()
        let server = server()
        let account = store(server, keychain)
        await account.signedIn(QTCSession(token: "t1", userId: "u1"))
        server.setHandler { _ in .json(401, #"{"error":"unauthorized"}"#) }
        let sent = server.requests.count

        await account.loadMe()
        await account.loadMe()

        #expect(!account.isSignedIn)
        #expect(account.needsSignIn)
        #expect(server.requests.count == sent + 1, "signed out after the first 401: nothing more is sent")
    }

    @Test func signOutClearsTheKeychainWithoutCallingTheServer() async {
        let keychain = QTCMemoryKeychain()
        let server = server()
        let account = store(server, keychain)
        await account.signedIn(QTCSession(token: "t1", userId: "u1"))
        let sent = server.requests.count

        account.signOut()

        #expect(account.session == nil)
        #expect(account.me == nil)
        #expect(!account.isSignedIn)
        #expect(!account.needsSignIn, "signing out yourself isn't an expired session")
        #expect(keychain.stored == nil)
        #expect(keychain.clears == 1)
        #expect(server.requests.count == sent)
    }

    /// Signing in again after a 401 clears the sign-in request.
    @Test func signingInAgainClearsNeedsSignIn() async {
        let server = server(me: .json(401, #"{"error":"unauthorized"}"#))
        let account = store(server, QTCMemoryKeychain())
        await account.signedIn(QTCSession(token: "t1", userId: "u1"))
        #expect(account.needsSignIn)

        server.setHandler { _ in .json(200, meJSON(["github"])) }
        await account.signedIn(QTCSession(token: "t2", userId: "u1"))

        #expect(!account.needsSignIn)
        #expect(account.isSignedIn)
        #expect(LoginMethod.bound(in: account.me?.identities ?? []) == [.github])
    }

    // MARK: - Token expiry

    @Test func secondsLeftReadsExp() throws {
        let token = TestJWT.token(expiresAt: .now + 3_600)
        let left = try #require(AccountStore.secondsLeft(of: token))
        #expect(abs(left - 3_600) < 60)
        #expect(AccountStore.secondsLeft(of: "not-a-jwt") == nil)
        #expect(AccountStore.secondsLeft(of: "a.\(TestJWT.base64URL(#"{"sub":"u1"}"#)).c") == nil, "no exp claim")
        #expect(AccountStore.secondsLeft(of: "a.%%%.c") == nil)
        #expect(AccountStore.refreshWindow == 7 * 86_400)
    }

    // MARK: - Keychain

    /// Skipped when the test build can't reach the keychain (unsigned).
    @Test(.enabled(if: KeychainProbe.isAvailable, "the keychain needs a signed test build"))
    func liveKeychainKeepsTheSessionAsJSON() throws {
        let live = SessionKeychain.live
        let previous = live.load()
        defer { if let previous { live.save(previous) } else { live.clear() } }
        let session = QTCSession(token: "t1", userId: "u1")

        live.save(session)

        #expect(live.load() == session)
        let raw = try #require(QTCKeychain.read("qtc.session"))
        #expect(try JSONDecoder().decode(QTCSession.self, from: Data(raw.utf8)) == session)
        #expect(KeychainProbe.string(service: "dev.oases.chat.ios.qtc", account: "qtc.session") == raw, "its own keychain service")
        // Not with the provider API keys (`ProviderConfigStore`: `dev.oases.chat.ios.provider.<id>`).
        #expect(KeychainProbe.string(service: "dev.oases.chat.ios.provider.qtc", account: "qtc.session") == nil)
        live.clear()
        #expect(live.load() == nil)
    }
}
