import Foundation
import Testing
@testable import Oases_Chat

/// Deleting the QingTeng account (guide §9), ported from K线艺术家's
/// `AccountDeletionTests` through Xplate and PlusProMax. Oases Chat keeps no account data on a server of its
/// own, so QTC is the only step: the request goes out with the session the
/// user confirmed, while it is still in the keychain; the session is
/// forgotten only after QTC answers; no answer is checked with the old
/// session, and a 401 then is "unconfirmed" (signed out, sign in again to
/// know), never "deleted".
@MainActor
@Suite("QingTeng account deletion")
struct AccountDeletionTests {
    private static let session = QTCSession(token: "t1", userId: "u1")

    /// QTC answering `/v1/me` with a profile and `/v1/me/delete` with `delete`.
    /// `atDelete` sees what the keychain held when the deletion arrived.
    private func qtc(delete: StubServer.Reply = .json(200, #"{"deleted":true}"#),
                     atDelete: @escaping @Sendable () -> Void = {}) -> StubServer {
        let profile = meJSON(["apple"])
        return StubServer { request in
            switch request.path {
            case "/v1/me/delete":
                atDelete()
                return delete
            case "/v1/me":
                return .json(200, profile)
            default:
                return .json(404, "{}")
            }
        }
    }

    private func signedIn(_ server: StubServer, keychain: QTCMemoryKeychain = QTCMemoryKeychain()) async -> AccountStore {
        let store = AccountStore(client: qtcClient(server), keychain: keychain.keychain)
        await store.signedIn(Self.session)
        return store
    }

    private func deletes(_ server: StubServer) -> [StubServer.Request] {
        server.requests.filter { $0.path == "/v1/me/delete" }
    }

    @Test func deletionGoesToQTCWithTheSessionAndThenSignsOut() async throws {
        let keychain = QTCMemoryKeychain()
        let heldAtDelete = Locked<QTCSession?>(nil)
        let server = qtc(atDelete: { heldAtDelete.withLock { $0 = keychain.stored } })
        let account = await signedIn(server, keychain: keychain)

        let result = try await account.deleteAccount(Self.session, appleAuthorizationCode: nil)

        #expect(result == .deleted)
        #expect(heldAtDelete.withLock { $0 } == Self.session, "the session is still kept while QTC deletes")
        #expect(keychain.stored == nil, "and forgotten once QTC answered")
        #expect(!account.isSignedIn)
        #expect(account.me == nil)
        #expect(!account.needsSignIn, "nothing to sign back in to: back to Settings")
        let delete = try #require(deletes(server).first)
        #expect(delete.header("Authorization") == "Bearer t1")
        #expect(delete.method == "POST")
        #expect(deletes(server).count == 1)
    }

    @Test func theAppleCodeAndClientIDAreSent() async throws {
        let server = qtc()
        let withApple = await signedIn(server)
        _ = try await withApple.deleteAccount(Self.session, appleAuthorizationCode: "apple-code-1")

        let request = try #require(deletes(server).first)
        #expect(request.stringFields == [
            "confirm": "DELETE",
            "appleAuthorizationCode": "apple-code-1",
            "appleClientId": "dev.oases.chat.ios",
        ])
        #expect(request.header("X-QTC-App") == "oases")

        let withoutApple = await signedIn(server)
        _ = try await withoutApple.deleteAccount(Self.session, appleAuthorizationCode: nil)
        #expect(deletes(server).last?.keys == ["confirm"], "no Apple fields without a code")
    }

    /// A refusal QTC words (a 5xx, a 429) deletes nothing here: still signed in, try again.
    @Test func aServerFailureKeepsTheAccountSignedIn() async {
        let keychain = QTCMemoryKeychain()
        let server = qtc(delete: .json(500, #"{"error":"internal_error"}"#))
        let account = await signedIn(server, keychain: keychain)

        await #expect(throws: QTCError.unavailable) {
            try await account.deleteAccount(Self.session, appleAuthorizationCode: nil)
        }
        #expect(account.isSignedIn)
        #expect(keychain.stored == Self.session)
    }

    /// Guide §9: no answer, then the old session refused, is not proof of
    /// deletion (the token may only have ended). Signed out to find out.
    @Test func noReplyThen401IsUnconfirmedAndSignsOut() async throws {
        let server = qtc()
        let keychain = QTCMemoryKeychain()
        let account = await signedIn(server, keychain: keychain)
        server.setHandler { request in
            request.path == "/v1/me/delete" ? .failure(.timedOut) : .json(401, #"{"error":"unauthorized"}"#)
        }

        let result = try await account.deleteAccount(Self.session, appleAuthorizationCode: nil)

        #expect(result == .unconfirmed)
        #expect(!account.isSignedIn)
        #expect(account.needsSignIn, "signing in again tells whether the account is still there")
        #expect(keychain.stored == nil)
        #expect(server.requests.last?.path == "/v1/me", "checked with the old session")
        #expect(server.requests.last?.header("Authorization") == "Bearer t1")
    }

    @Test func noReplyButTheAccountIsStillThereCanBeTriedAgain() async {
        let profile = meJSON(["apple"])
        let server = qtc()
        let account = await signedIn(server)
        server.setHandler { request in
            request.path == "/v1/me/delete" ? .failure(.timedOut) : .json(200, profile)
        }

        await #expect(throws: QTCError.unavailable) {
            try await account.deleteAccount(Self.session, appleAuthorizationCode: nil)
        }
        #expect(account.isSignedIn)
    }

    @Test func noReplyAndNoAnswerToTheCheckIsOffline() async {
        let server = qtc()
        let account = await signedIn(server)
        server.setHandler { _ in .failure(.notConnectedToInternet) }

        await #expect(throws: QTCError.offline) {
            try await account.deleteAccount(Self.session, appleAuthorizationCode: nil)
        }
        #expect(account.isSignedIn, "nothing known: nothing forgotten")
    }

    /// The account confirmed is the one deleted: after a switch, nothing is sent.
    @Test func aDeletionForAnotherSessionSendsNothing() async throws {
        let server = qtc()
        let account = await signedIn(server)

        let result = try await account.deleteAccount(QTCSession(token: "t0", userId: "u0"), appleAuthorizationCode: nil)

        #expect(result == .accountChanged)
        #expect(deletes(server).isEmpty)
        #expect(account.isSignedIn)
    }

    /// The confirmation page's deletion runs outside the page (a static helper
    /// its task calls, holding no view): cancelling Apple's sheet sends
    /// nothing; any other Apple failure deletes without the code.
    @Test func theAppleStepBeforeDeleting() async throws {
        let server = qtc()
        let account = await signedIn(server)

        let cancelled = await DeleteAccountView.delete(
            Self.session, apple: FakeApple(.failure(AppleSignIn.Cancelled())).authorizer, account: account
        )
        #expect(cancelled == .appleCancelled)
        #expect(deletes(server).isEmpty)
        #expect(account.isSignedIn)
        #expect(DeleteAccountView.message(for: cancelled) == "已取消注销")

        let failed = await DeleteAccountView.delete(
            Self.session, apple: FakeApple(.failure(URLError(.unknown))).authorizer, account: account
        )
        #expect(failed == .deleted)
        #expect(deletes(server).first?.keys == ["confirm"], "deleted without the code; only the revocation is skipped")
        #expect(!account.isSignedIn)
        #expect(DeleteAccountView.message(for: .deleted) == nil)
    }

    @Test func theAppleCodeGoesWithTheDeletion() async throws {
        let server = qtc()
        let account = await signedIn(server)

        let outcome = await DeleteAccountView.delete(Self.session, apple: FakeApple().authorizer, account: account)

        #expect(outcome == .deleted)
        #expect(deletes(server).first?.stringFields?["appleAuthorizationCode"] == "apple-code")
    }

    // MARK: - The profile decides about Apple (Codex, from 去做's review)

    /// Signed in, but `/v1/me` never answered: the profile is unknown.
    private func signedInWithoutProfile() async -> (StubServer, AccountStore) {
        let server = StubServer { request in
            request.path == "/v1/me/delete" ? .json(200, #"{"deleted":true}"#) : .failure(.notConnectedToInternet)
        }
        let account = await signedIn(server)
        #expect(account.isSignedIn && account.me == nil)
        return (server, account)
    }

    @Test func anUnknownProfileThatStillWontLoadSendsNothing() async {
        let (server, account) = await signedInWithoutProfile()
        let apple = FakeApple()
        let reads = server.paths.filter { $0 == "/v1/me" }.count

        let outcome = await DeleteAccountView.delete(Self.session, apple: apple.authorizer, account: account)

        #expect(outcome == .profileUnknown)
        #expect(server.paths.filter { $0 == "/v1/me" }.count == reads + 1, "the profile is read again first")
        #expect(deletes(server).isEmpty, "nothing is sent without knowing whether the account uses Apple")
        #expect(apple.calls == 0)
        #expect(account.isSignedIn)
        #expect(DeleteAccountView.message(for: outcome) == "暂时无法确认账号信息，请稍后再试")
    }

    @Test func anUnknownProfileThatLoadsWithAppleAsksAppleFirst() async throws {
        let (server, account) = await signedInWithoutProfile()
        let profile = meJSON(["apple"])
        server.setHandler { request in
            request.path == "/v1/me/delete" ? .json(200, #"{"deleted":true}"#) : .json(200, profile)
        }
        let apple = FakeApple()

        let outcome = await DeleteAccountView.delete(Self.session, apple: apple.authorizer, account: account)

        #expect(outcome == .deleted)
        #expect(apple.calls == 1, "Apple authorization is requested once the profile shows Apple")
        let delete = try #require(deletes(server).first)
        #expect(delete.stringFields?["appleAuthorizationCode"] == "apple-code")
        #expect(delete.stringFields?["appleClientId"] == "dev.oases.chat.ios")
    }

    @Test func anUnknownProfileThatLoadsWithoutAppleDeletesWithoutAsking() async throws {
        let (server, account) = await signedInWithoutProfile()
        let profile = meJSON(["github"])
        server.setHandler { request in
            request.path == "/v1/me/delete" ? .json(200, #"{"deleted":true}"#) : .json(200, profile)
        }
        let apple = FakeApple()

        let outcome = await DeleteAccountView.delete(Self.session, apple: apple.authorizer, account: account)

        #expect(outcome == .deleted)
        #expect(apple.calls == 0)
        #expect(deletes(server).first?.keys == ["confirm"])
    }

    @Test func anUnknownProfileWhoseReadIsRefusedSignsOutAndSendsNothing() async {
        let (server, account) = await signedInWithoutProfile()
        server.setHandler { _ in .json(401, #"{"error":"unauthorized"}"#) }
        let apple = FakeApple()

        let outcome = await DeleteAccountView.delete(Self.session, apple: apple.authorizer, account: account)

        #expect(outcome == .signedOut)
        #expect(deletes(server).isEmpty)
        #expect(apple.calls == 0)
        #expect(!account.isSignedIn)
    }

    // MARK: - A refresh during the deletion (Codex review)

    /// QTC holding the deletion back while `/v1/auth/refresh` answers at once
    /// with a fresh token for the same user.
    private func qtcHoldingDeletion(_ held: HeldReply, freshToken: String) -> StubServer {
        let profile = meJSON(["github"])
        return StubServer { request in
            switch request.path {
            case "/v1/me/delete": return held.wait()
            case "/v1/auth/refresh": return .json(200, #"{"token":"\#(freshToken)","userId":"u1"}"#)
            case "/v1/me": return .json(200, profile)
            default: return .json(404, "{}")
            }
        }
    }

    /// Another window's launch refreshes the near-expiry token while the
    /// deletion is held: the session becomes a fresh token for the same user.
    /// Once QTC deletes the account, that session, its profile and its keychain
    /// entry are gone all the same, and no later launch restores it.
    @Test func aRefreshDuringTheDeletionDoesNotKeepTheDeletedAccount() async throws {
        let nearExpiry = QTCSession(token: TestJWT.token(expiresAt: Date().addingTimeInterval(86_400)), userId: "u1")
        let freshToken = TestJWT.token(expiresAt: Date().addingTimeInterval(30 * 86_400))
        let held = HeldReply(.json(200, #"{"deleted":true}"#))
        let server = qtcHoldingDeletion(held, freshToken: freshToken)
        let keychain = QTCMemoryKeychain()
        let account = AccountStore(client: qtcClient(server), keychain: keychain.keychain)
        await account.signedIn(nearExpiry)
        #expect(account.me != nil)

        let deleting = Task { try await account.deleteAccount(nearExpiry, appleAuthorizationCode: nil) }
        try await eventuallyHolds { !self.deletes(server).isEmpty }
        await account.launch()  // another window: refreshes the token
        #expect(account.session == QTCSession(token: freshToken, userId: "u1"), "the session changed under the deletion")
        #expect(keychain.stored?.token == freshToken)

        held.letGo()
        let result = try await deleting.value

        #expect(result == .deleted)
        #expect(!account.isSignedIn, "the refreshed session of the deleted user is gone")
        #expect(account.me == nil)
        #expect(keychain.stored == nil)
        #expect(!account.needsSignIn)

        await account.launch()
        #expect(!account.isSignedIn, "nothing to restore")
    }

    /// A refresh still out when the deletion lands keeps nothing either.
    @Test func aRefreshLandingAfterTheDeletionKeepsNothing() async throws {
        let nearExpiry = QTCSession(token: TestJWT.token(expiresAt: Date().addingTimeInterval(86_400)), userId: "u1")
        let refresh = HeldReply(.json(200, #"{"token":"fresh","userId":"u1"}"#))
        let server = StubServer { request in
            switch request.path {
            case "/v1/me/delete": return .json(200, #"{"deleted":true}"#)
            case "/v1/auth/refresh": return refresh.wait()
            case "/v1/me": return .json(200, meJSON(["github"]))
            default: return .json(404, "{}")
            }
        }
        let keychain = QTCMemoryKeychain(nearExpiry)
        let account = AccountStore(client: qtcClient(server), keychain: keychain.keychain)

        let launching = Task { await account.launch() }
        try await eventuallyHolds { server.paths.contains("/v1/auth/refresh") }
        #expect(try await account.deleteAccount(nearExpiry, appleAuthorizationCode: nil) == .deleted)
        refresh.letGo()
        await launching.value

        #expect(!account.isSignedIn)
        #expect(keychain.stored == nil, "the late fresh token is never saved")
    }

    /// Someone else signed in while the deletion was out: that account stays.
    @Test func aDifferentAccountSignedInMeanwhileStays() async throws {
        let held = HeldReply(.json(200, #"{"deleted":true}"#))
        let server = qtcHoldingDeletion(held, freshToken: "unused")
        let keychain = QTCMemoryKeychain()
        let account = AccountStore(client: qtcClient(server), keychain: keychain.keychain)
        await account.signedIn(Self.session)

        let deleting = Task { try await account.deleteAccount(Self.session, appleAuthorizationCode: nil) }
        try await eventuallyHolds { !self.deletes(server).isEmpty }
        let other = QTCSession(token: "t2", userId: "u2")
        account.signOut()
        await account.signedIn(other)
        held.letGo()
        _ = try await deleting.value

        #expect(account.session == other)
        #expect(keychain.stored == other)
    }

    /// The confirmation's three paragraphs (guide §9), in Simplified Chinese.
    /// Oases Chat shows no QingTeng balance, so points are mentioned only as "账号和 QingTengStudio积分" (never "QTC 积分").
    @Test func theConfirmationSaysWhatIsLost() {
        // Read from the zh-Hans table, not through the device language.
        #expect(DeleteAccountView.warningLines == [QT("account.deleteLine1"), QT("account.deleteLine2"), QT("account.deleteLine3")])
        let lines = ["account.deleteLine1", "account.deleteLine2", "account.deleteLine3"].map { AccountCopy.zhHans($0) ?? "" }
        #expect(lines == [
            "这会删除你在所有 QingTeng App 里的账号和 QingTengStudio积分。",
            "注销后不能恢复；以后用同一个 Apple ID 登录，会得到一个全新的空账号。",
            "如果你订阅了 Oases Chat 或其他 QingTeng App，请到 iPhone 的「设置 › 你的名字 › 订阅」里自己取消，注销账号不会停止苹果的扣费。",
        ])
        #expect(!lines.joined().contains("余额"), "no balance wording")
        #expect(!lines.joined().contains("QTC"), "the server points are QingTengStudio积分, never QTC 积分")
    }

    /// Owner rule: the brand is "QingTeng" in every language, never in Chinese characters (Simplified or Traditional).
    @Test func noLanguageWritesQingTengInChinese() {
        for language in QingTengStrings.tables.keys {
            let table = AccountCopy.table(language)
            #expect(!table.isEmpty, "\(language): the table is in the app")
            for (key, text) in table where key.hasPrefix("account.") || key.hasPrefix("consent.") {
                #expect(!text.contains("\u{9752}\u{85E4}") && !text.contains("\u{9752}\u{7C50}"), "\(language): \(key)")
            }
        }
    }
}
