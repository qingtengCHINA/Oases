import CryptoKit
import Foundation
import Testing
@testable import Oases_Chat

/// The sign-in page and the account page's bind buttons with a stub QTC, a
/// fake browser and a fake Sign in with Apple (ported from K线艺术家's
/// `SignInFlowTests` and `OAuthSignInTests`, including its C3 review fixes:
/// session-bound links, `PageLifetime`, nothing kept for a page that closed).
@MainActor
@Suite("QingTeng sign-in and linking", .serialized)
struct SignInFlowTests {
    private static let notFound = StubServer.Reply.json(409, #"{"error":"account_not_found","provider":"github"}"#)
    private static let loggedIn = StubServer.Reply.json(200, #"{"token":"t2","userId":"u2","created":false}"#)
    private static let callback = "qtc-oases://oauth?code=C1"

    private func makeAccount(_ server: OAuthServer, signedIn: Bool = false) async -> AccountStore {
        let store = AccountStore(client: server.client, keychain: QTCMemoryKeychain().keychain)
        if signedIn { await store.signedIn(QTCSession(token: "t1", userId: "u1")) }
        return store
    }

    // MARK: - Sign in with Apple

    @Test func appleSignInKeepsTheSession() async {
        let server = OAuthServer(me: .json(200, meJSON(["apple"]))) { request in
            request.path == "/v1/auth/apple" ? .json(200, #"{"token":"t9","userId":"u1","created":true}"#) : .json(404, "{}")
        }
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)
        let account = await makeAccount(server)

        let done = await flow.signInWithApple(into: account)

        #expect(done)
        #expect(account.session == QTCSession(token: "t9", userId: "u1"))
        #expect(account.me?.uid == 482913)
        #expect(flow.notice == nil)
        #expect(flow.inProgress == nil)
        let request = server.stub.requests.first { $0.path == "/v1/auth/apple" }
        #expect(request?.stringFields == ["idToken": "apple-id-token"], "only the identity token; never the email")
    }

    @Test func cancellingAppleIsSilent() async {
        let server = OAuthServer()
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: FakeApple(.failure(AppleSignIn.Cancelled())).authorizer)
        let account = await makeAccount(server)

        #expect(await !flow.signInWithApple(into: account))
        #expect(flow.notice == nil)
        #expect(server.stub.requests.isEmpty)
    }

    @Test func appleFailuresSayTryAgain() async {
        let server = OAuthServer { _ in .json(401, #"{"error":"unauthorized"}"#) }
        let apple = FakeApple(.failure(URLError(.unknown)))
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: apple.authorizer)
        let account = await makeAccount(server)

        #expect(await !flow.signInWithApple(into: account))
        #expect(flow.notice == .failed)

        // The identity token didn't verify at QTC.
        flow.notice = nil
        apple.result = .success(AppleCredential(idToken: "x", authorizationCode: "y"))
        #expect(await !flow.signInWithApple(into: account))
        #expect(flow.notice == .failed)
        #expect(!account.isSignedIn)
    }

    // MARK: - GitHub and Microsoft

    @Test func verifierAndChallengeAre43Base64URLCharacters() async throws {
        let server = OAuthServer(exchange: [Self.loggedIn, Self.loggedIn])
        let oauth = OAuthSignIn(client: server.client, opener: FakeBrowser(Self.callback).opener)

        _ = try await oauth.run(.github)
        _ = try await oauth.run(.github)

        let challenges = try server.starts.map { try #require($0.stringFields?["codeChallenge"]) }
        let verifiers = try server.exchanges.map { try #require($0.stringFields?["codeVerifier"]) }
        #expect(challenges.count == 2 && verifiers.count == 2)
        for (challenge, verifier) in zip(challenges, verifiers) {
            #expect(verifier.count == 43, "32 random bytes in base64url, no padding")
            #expect(challenge.count == 43)
            let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            #expect(challenge == digest, "S256: base64url(SHA-256(verifier))")
        }
        #expect(verifiers[0] != verifiers[1], "a new verifier for every sign-in")
        // RFC 7636, appendix B.
        #expect(OAuthSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func onlyThisRunsOwnCallbackIsUsed() async {
        let server = OAuthServer(exchange: [Self.loggedIn])
        let browser = FakeBrowser("otherapp://oauth?code=C1")
        let oauth = OAuthSignIn(client: server.client, opener: browser.opener)

        await #expect(throws: OAuthError.failed) { try await oauth.run(.github) }
        browser.callback = URL(string: "qtc-oases://elsewhere?code=C1")
        await #expect(throws: OAuthError.failed) { try await oauth.run(.github) }
        #expect(server.exchanges.isEmpty)

        // The address QTC sends back to must equal the whitelisted returnTo exactly.
        #expect(OAuthSignIn.callbackScheme == "qtc-oases", "the browser session listens on this scheme, without ://oauth")
        #expect(OAuthSignIn.isOwnCallback(URL(string: "qtc-oases://oauth?code=C1")!))
        #expect(!OAuthSignIn.isOwnCallback(URL(string: "qtc-oases://oauth/extra?code=C1")!))
        #expect(!OAuthSignIn.isOwnCallback(URL(string: "qtc-memquirk://oauth?code=C1")!))
    }

    @Test func unavailableHidesThatButtonOnly() async {
        let server = OAuthServer(start: .json(503, #"{"error":"provider_unavailable"}"#))
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)
        let account = await makeAccount(server)

        #expect(await !flow.signIn(with: .github, into: account))

        #expect(flow.hiddenProviders == [.github])
        #expect(flow.notice == .unavailable, "the tapped button goes away, so say why")
        #expect(!account.isSignedIn)
    }

    @Test func accountNotFoundAsksAndExistingAccountExplainsHowToBind() async throws {
        let server = OAuthServer(exchange: [Self.notFound])
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        let account = await makeAccount(server)

        let signingIn = Task { await flow.signIn(with: .github, into: account) }
        try await eventuallyHolds { flow.asksToCreateAccount }
        flow.answerNewAccount(false)

        #expect(await !signingIn.value)
        #expect(flow.notice == .useExistingAccount)
        #expect(server.exchanges.count == 1)
        #expect(!account.isSignedIn)
    }

    @Test func createNewReusesTheSameCodeAndVerifier() async throws {
        let server = OAuthServer(exchange: [Self.notFound, .json(200, #"{"token":"t2","userId":"u2","created":true}"#)])
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        let account = await makeAccount(server)

        let signingIn = Task { await flow.signIn(with: .github, into: account) }
        try await eventuallyHolds { flow.asksToCreateAccount }
        flow.answerNewAccount(true)

        #expect(await signingIn.value)
        #expect(account.session == QTCSession(token: "t2", userId: "u2"))
        #expect(flow.notice == nil)
        #expect(server.exchanges.count == 2)
        struct Body: Decodable { let code: String; let codeVerifier: String; let createNew: Bool? }
        let first = try #require(server.exchanges[0].decode(Body.self))
        let second = try #require(server.exchanges[1].decode(Body.self))
        #expect(first.createNew == nil)
        #expect(second.createNew == true)
        #expect(second.code == first.code && second.codeVerifier == first.codeVerifier)
    }

    @Test func outcomesBecomeTheRightNotices() async throws {
        let cases: [(exchange: [StubServer.Reply], callback: String?, notice: SignInFlow.Notice?)] = [
            ([Self.notFound, .json(401, #"{"error":"unauthorized"}"#)], Self.callback, .timedOut),
            ([.json(500, #"{"error":"internal_error"}"#)], Self.callback, .failed),
            ([], "qtc-oases://oauth?error=failed", .failed),
            ([], "qtc-oases://oauth?error=cancelled", nil),
            ([], nil, nil),
        ]
        for (exchange, callback, notice) in cases {
            let server = OAuthServer(exchange: exchange)
            let flow = SignInFlow(client: server.client, opener: FakeBrowser(callback).opener, apple: FakeApple().authorizer)
            let account = await makeAccount(server)
            let signingIn = Task { await flow.signIn(with: .github, into: account) }
            if exchange.count == 2 {
                try await eventuallyHolds { flow.asksToCreateAccount }
                flow.answerNewAccount(true)
            }
            #expect(await !signingIn.value)
            #expect(flow.notice == notice)
            #expect(flow.hiddenProviders.isEmpty)
        }
    }

    // MARK: - A page that closed

    @Test func leavingThePageAnswersExistingAccount() async throws {
        let server = OAuthServer(exchange: [Self.notFound, .json(200, #"{"token":"t2","userId":"u2","created":true}"#)])
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        let account = await makeAccount(server)

        let signingIn = Task { await flow.signIn(with: .microsoft, into: account) }
        try await eventuallyHolds { flow.asksToCreateAccount }
        flow.pageClosed()

        #expect(await !signingIn.value)
        #expect(server.exchanges.count == 1, "no account is created for a page that went away")
        #expect(flow.inProgress == nil)
        #expect(!flow.asksToCreateAccount)
        #expect(!account.isSignedIn)
    }

    @Test func aSignInThatLandsAfterThePageClosedIsNotKept() async throws {
        let held = HeldReply(.json(200, #"{"token":"t2","userId":"u2","created":false}"#))
        let stub = StubServer { request in
            switch request.path {
            case "/v1/auth/oauth/start": return .json(200, #"{"url":"\#(OAuthServer.authorizeURL)"}"#)
            case "/v1/auth/oauth/exchange": return held.wait()
            default: return .json(404, "{}")
            }
        }
        let client = qtcClient(stub)
        let keychain = QTCMemoryKeychain()
        let flow = SignInFlow(client: client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        let account = AccountStore(client: client, keychain: keychain.keychain)

        let signingIn = Task { await flow.signIn(with: .microsoft, into: account) }
        try await eventuallyHolds { stub.paths.contains("/v1/auth/oauth/exchange") }
        flow.pageClosed()
        held.letGo()

        #expect(await !signingIn.value)
        #expect(account.session == nil)
        #expect(keychain.stored == nil, "nothing written to the keychain")
    }

    @Test func aClosedPageSendsNoAppleTokenAndStartsNothing() async {
        let server = OAuthServer { request in
            request.path == "/v1/auth/apple" ? .json(200, #"{"token":"t9","userId":"u1","created":false}"#) : .json(404, "{}")
        }
        let apple = FakeApple()
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: apple.authorizer)
        apple.whileOpen = { flow.pageClosed() }
        let account = await makeAccount(server)

        #expect(await !flow.signInWithApple(into: account))
        #expect(!server.stub.paths.contains("/v1/auth/apple"))
        #expect(!account.isSignedIn)

        #expect(await !flow.signIn(with: .github, into: account))
        #expect(await !flow.signInWithApple(into: account))
        #expect(server.stub.requests.isEmpty)
        #expect(apple.calls == 1)
    }

    @Test func aPageGoneForGoodClosesItsFlow() async throws {
        let flow = SignInFlow(client: OAuthServer().client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)
        do {
            let lifetime = PageLifetime { flow.pageClosed() }
            withExtendedLifetime(lifetime) {}
        }
        try await eventuallyHolds { flow.isClosed }
    }

    // MARK: - Tasks don't keep the page alive (Codex P2)

    /// The page starts sign-ins through `SignInFlow.start`, whose task holds
    /// only the flow, the account and `onDone`. The page leaves while Apple's
    /// sheet is up: its lifetime ends at once and the flow closes, so Apple's
    /// late answer is never sent and never overwrites a later sign-in.
    @Test func aPageLeftDuringAppleSignInSavesNothingLater() async throws {
        let server = OAuthServer(exchange: [Self.loggedIn], me: .json(200, meJSON(["github"]))) { request in
            request.path == "/v1/auth/apple" ? .json(200, #"{"token":"t9","userId":"u9","created":false}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server)
        let gate = AppleGate()
        let leftFlow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: gate.authorizer)
        var lifetime: PageLifetime? = PageLifetime { leftFlow.pageClosed() }
        weak var watched = lifetime
        let done = Locked(0)

        let pending = leftFlow.start(.apple, into: account, onDone: { done.withLock { $0 += 1 } })
        await gate.waitUntilOpen()
        lifetime = nil
        #expect(watched == nil, "nothing the sign-in holds keeps the page's lifetime")
        try await eventuallyHolds { leftFlow.isClosed }

        // The user signs in on a new page meanwhile.
        let newFlow = SignInFlow(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        await newFlow.start(.github, into: account, onDone: { done.withLock { $0 += 1 } }).value
        #expect(account.session == QTCSession(token: "t2", userId: "u2"))

        // Apple answers the old page late.
        gate.finish()
        await pending.value

        #expect(account.session == QTCSession(token: "t2", userId: "u2"), "the later sign-in is kept")
        #expect(!server.stub.paths.contains("/v1/auth/apple"), "the old page's Apple token is never sent")
        #expect(done.withLock { $0 } == 1, "only the new page's sign-in finished")
        #expect(leftFlow.notice == nil)
    }

    /// The same for a link from the account page: the page leaves while
    /// Apple's sheet is up, and nothing is bound afterwards.
    @Test func aPageLeftDuringALinkBindsNothingLater() async throws {
        let server = OAuthServer(me: .json(200, meJSON(["github"]))) { request in
            request.path == "/v1/me/identities/apple" ? .json(200, #"{"status":"bound"}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server, signedIn: true)
        let sent = server.stub.requests.count
        let gate = AppleGate()
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(nil).opener, apple: gate.authorizer)
        var lifetime: PageLifetime? = PageLifetime { linker.pageClosed() }
        weak var watched = lifetime

        let pending = linker.start(.apple, account: account)
        await gate.waitUntilOpen()
        lifetime = nil
        #expect(watched == nil)
        // PageLifetime hands pageClosed() to the main actor: let it run before Apple answers.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        gate.finish()
        await pending.value

        #expect(server.stub.paths.dropFirst(sent).isEmpty, "no binding, no reload")
        #expect(linker.notice == nil)
        #expect(linker.linking == nil)
        #expect(account.isSignedIn)
    }

    // MARK: - Binding on the account page

    @Test func onlyAppleGitHubAndMicrosoftAreListed() {
        let identities = ["apple", "passkey", "ethereum", "github", "solana"].map { QTCMe.Identity(provider: $0, subject: "s") }
        #expect(LoginMethod.allCases == [.apple, .github, .microsoft])
        #expect(LoginMethod.bound(in: identities) == [.apple, .github])
        #expect(LoginMethod.bound(in: []) == [])
    }

    /// Start, then a bound exchange, then this profile.
    private static func linkServer(after me: String) -> StubServer.Handler {
        { request in
            switch request.path {
            case "/v1/auth/oauth/start": return .json(200, #"{"url":"\#(OAuthServer.authorizeURL)"}"#)
            case "/v1/auth/oauth/exchange": return .json(200, #"{"status":"bound","provider":"github"}"#)
            case "/v1/me": return .json(200, me)
            default: return .json(404, "{}")
            }
        }
    }

    @Test func bindingGitHubReloadsTheProfile() async {
        let server = OAuthServer(me: .json(200, meJSON(["apple"])))
        let account = await makeAccount(server, signedIn: true)
        server.stub.setHandler(Self.linkServer(after: meJSON(["apple", "github"])))
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)
        #expect(LoginMethod.bound(in: account.me?.identities ?? []) == [.apple])

        await linker.bind(.github, account: account)

        #expect(LoginMethod.bound(in: account.me?.identities ?? []) == [.apple, .github])
        #expect(linker.notice == nil)
        #expect(server.stub.paths.suffix(3) == ["/v1/auth/oauth/start", "/v1/auth/oauth/exchange", "/v1/me"])
        let start = server.stub.requests.first { $0.path == "/v1/auth/oauth/start" }
        #expect(start?.stringFields?["mode"] == "link")
        #expect(start?.header("Authorization") == "Bearer t1")
    }

    @Test func bindingAppleSendsTheIdentityTokenWithTheSession() async {
        let server = OAuthServer(me: .json(200, meJSON(["github"]))) { request in
            request.path == "/v1/me/identities/apple" ? .json(200, #"{"status":"bound"}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server, signedIn: true)
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)

        await linker.bind(.apple, account: account)

        let bind = server.stub.requests.first { $0.path == "/v1/me/identities/apple" }
        #expect(bind?.stringFields == ["idToken": "apple-id-token"])
        #expect(bind?.header("Authorization") == "Bearer t1")
        #expect(server.stub.paths.last == "/v1/me", "the profile is read again after binding")
        #expect(linker.notice == nil)
    }

    @Test func identityTakenIsExplained() async {
        let server = OAuthServer(exchange: [.json(409, #"{"error":"identity_taken"}"#)], me: .json(200, meJSON(["apple"]))) { request in
            request.path == "/v1/me/identities/apple" ? .json(409, #"{"error":"identity_taken"}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server, signedIn: true)
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(Self.callback).opener, apple: FakeApple().authorizer)

        await linker.bind(.microsoft, account: account)
        #expect(linker.notice == .identityTaken)

        linker.notice = nil
        await linker.bind(.apple, account: account)
        #expect(linker.notice == .identityTaken)
        #expect(account.isSignedIn)
    }

    @Test func aRefusedBindingChecksTheSessionFirst() async {
        // 401 on the bind: the Apple token or the session. /v1/me tells which.
        let server = OAuthServer(me: .json(200, meJSON(["github"]))) { request in
            request.path == "/v1/me/identities/apple" ? .json(401, #"{"error":"unauthorized"}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server, signedIn: true)
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)

        await linker.bind(.apple, account: account)
        #expect(linker.notice == .failed, "the session is fine: try binding again")
        #expect(account.isSignedIn)

        let expired = OAuthServer(me: .json(200, meJSON(["github"])))
        let signedOut = await makeAccount(expired, signedIn: true)
        expired.stub.setHandler { _ in .json(401, #"{"error":"unauthorized"}"#) }
        let other = AccountLinker(client: expired.client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)
        await other.bind(.apple, account: signedOut)
        #expect(!signedOut.isSignedIn)
        #expect(signedOut.needsSignIn)
        #expect(other.notice == nil, "back to sign-in rather than a message")
    }

    @Test func cancelledBindingsAreSilent() async {
        let server = OAuthServer(me: .json(200, meJSON(["apple"])))
        let account = await makeAccount(server, signedIn: true)
        let linker = AccountLinker(client: server.client, opener: FakeBrowser("qtc-oases://oauth?error=cancelled").opener, apple: FakeApple(.failure(AppleSignIn.Cancelled())).authorizer)
        let sent = server.stub.requests.count

        await linker.bind(.github, account: account)
        await linker.bind(.apple, account: account)

        #expect(linker.notice == nil)
        #expect(Array(server.stub.paths.dropFirst(sent)) == ["/v1/auth/oauth/start"])
    }

    // MARK: - A link the user walked away from

    @Test func signingOutWhileTheStartIsPendingBindsNothing() async throws {
        let held = HeldReply(.json(200, #"{"url":"\#(OAuthServer.authorizeURL)"}"#))
        let profile = meJSON(["apple"])
        let stub = StubServer { request in
            switch request.path {
            case "/v1/auth/oauth/start": return held.wait()
            case "/v1/auth/oauth/exchange": return .json(200, #"{"status":"bound","provider":"github"}"#)
            case "/v1/me": return .json(200, profile)
            default: return .json(404, "{}")
            }
        }
        let client = qtcClient(stub)
        let account = AccountStore(client: client, keychain: QTCMemoryKeychain().keychain)
        await account.signedIn(QTCSession(token: "t1", userId: "u1"))
        let browser = FakeBrowser(Self.callback)
        let linker = AccountLinker(client: client, opener: browser.opener, apple: FakeApple().authorizer)

        let binding = Task { await linker.bind(.github, account: account) }
        try await eventuallyHolds { stub.paths.contains("/v1/auth/oauth/start") }
        account.signOut()
        held.letGo()
        await binding.value

        #expect(browser.opened.isEmpty, "the browser never opens for an account the user left")
        #expect(!stub.paths.contains("/v1/auth/oauth/exchange"))
        #expect(linker.notice == nil)
        #expect(linker.linking == nil)
    }

    @Test func signingOutWhileTheBrowserIsOpenBindsNothing() async {
        let server = OAuthServer(exchange: [.json(200, #"{"status":"bound","provider":"github"}"#)], me: .json(200, meJSON(["apple"])))
        let account = await makeAccount(server, signedIn: true)
        let browser = FakeBrowser(Self.callback)
        browser.whileOpen = { account.signOut() }
        let linker = AccountLinker(client: server.client, opener: browser.opener, apple: FakeApple().authorizer)

        await linker.bind(.github, account: account)

        #expect(browser.opened.count == 1)
        #expect(server.exchanges.isEmpty, "the code is never exchanged with the old session")
        #expect(linker.notice == nil)
    }

    @Test func appleIsNotBoundOnceThePageClosedOrTheUserLeft() async {
        let server = OAuthServer(me: .json(200, meJSON(["github"]))) { request in
            request.path == "/v1/me/identities/apple" ? .json(200, #"{"status":"bound"}"#) : .json(404, "{}")
        }
        let account = await makeAccount(server, signedIn: true)
        let sent = server.stub.requests.count

        let apple = FakeApple()
        let linker = AccountLinker(client: server.client, opener: FakeBrowser(nil).opener, apple: apple.authorizer)
        apple.whileOpen = { linker.pageClosed() }
        await linker.bind(.apple, account: account)
        #expect(server.stub.paths.dropFirst(sent).isEmpty, "page closed: no binding, no reload")

        let leaving = FakeApple()
        leaving.whileOpen = { account.signOut() }
        let other = AccountLinker(client: server.client, opener: FakeBrowser(nil).opener, apple: leaving.authorizer)
        await other.bind(.apple, account: account)
        #expect(server.stub.paths.dropFirst(sent).isEmpty, "signed out: no binding")
        #expect(other.notice == nil)
    }

    @Test func aRunNoLongerWantedNeverExchanges() async throws {
        // Unwanted once the start is answered: the browser never opens.
        let server = OAuthServer(exchange: [Self.loggedIn])
        let browser = FakeBrowser(Self.callback)
        let oauth = OAuthSignIn(client: server.client, opener: browser.opener)
        #expect(try await oauth.run(.github, isStillWanted: { false }) == .cancelled)
        #expect(browser.opened.isEmpty)
        #expect(server.exchanges.isEmpty)

        // Unwanted while the browser was open: the code is never exchanged.
        let wanted = WantedFlag()
        browser.whileOpen = { wanted.value = false }
        #expect(try await oauth.run(.github, isStillWanted: { wanted.value }) == .cancelled)
        #expect(browser.opened.count == 1)
        #expect(server.exchanges.isEmpty)
    }

    @Test func linkModeSendsTheSessionAndNeverAsksToCreate() async throws {
        let server = OAuthServer(exchange: [
            .json(200, #"{"status":"bound","provider":"github"}"#),
            .json(200, #"{"status":"already_bound","provider":"microsoft"}"#),
            Self.notFound,
        ])
        let oauth = OAuthSignIn(client: server.client, opener: FakeBrowser(Self.callback).opener)
        let question = NewAccountQuestion(answer: true)

        #expect(try await oauth.run(.github, linkingTo: "t1", confirmNewAccount: { await question.ask() }) == .linked(alreadyBound: false))
        #expect(try await oauth.run(.microsoft, linkingTo: "t1", confirmNewAccount: { await question.ask() }) == .linked(alreadyBound: true))
        await #expect(throws: OAuthError.failed) {
            try await oauth.run(.github, linkingTo: "t1", confirmNewAccount: { await question.ask() })
        }

        #expect(question.asked == 0, "linking never offers a new account")
        #expect(server.starts.allSatisfy { $0.stringFields?["mode"] == "link" && $0.header("Authorization") == "Bearer t1" })
        #expect(server.exchanges.allSatisfy { $0.header("Authorization") == "Bearer t1" })
    }

    // MARK: - Withdrawing the consent (去做's Codex review)

    /// The one-page consent, given, on the app's own defaults (put back by `restore()`). The
    /// account follows it with `followConsent()`, as at launch.
    private func consenting() -> AIDataSharingConsentFixture {
        let consent = AIDataSharingConsentFixture()
        consent.acceptForTest()
        return consent
    }

    /// Withdrawn in another window, then given again, while Apple's sheet is
    /// up: the identity token is never sent and no session is kept.
    @Test func aWithdrawalWhileAppleIsOpenVoidsTheSignIn() async {
        let server = OAuthServer { request in
            request.path == "/v1/auth/apple" ? .json(200, #"{"token":"t9","userId":"u1","created":false}"#) : .json(404, "{}")
        }
        let consent = consenting()
        defer { consent.restore() }
        let keychain = QTCMemoryKeychain()
        let account = AccountStore(client: server.client, keychain: keychain.keychain)
        account.followConsent()
        let apple = FakeApple()
        apple.whileOpen = {
            consent.declineForTest()
            consent.acceptForTest()
        }
        let flow = SignInFlow(client: server.client, opener: FakeBrowser(nil).opener, apple: apple.authorizer)

        #expect(await !flow.signInWithApple(into: account))
        #expect(server.stub.requests.isEmpty, "no token exchange, no /v1/me")
        #expect(!account.isSignedIn)
        #expect(keychain.stored == nil)
    }

    /// The same while GitHub's page is open: the result code is never exchanged.
    @Test func aWithdrawalWhileTheBrowserIsOpenVoidsTheSignIn() async {
        let server = OAuthServer(exchange: [Self.loggedIn])
        let consent = consenting()
        defer { consent.restore() }
        let account = AccountStore(client: server.client, keychain: QTCMemoryKeychain().keychain)
        account.followConsent()
        let browser = FakeBrowser(Self.callback)
        browser.whileOpen = {
            consent.declineForTest()
            consent.acceptForTest()
        }
        let flow = SignInFlow(client: server.client, opener: browser.opener, apple: FakeApple().authorizer)

        #expect(await !flow.signIn(with: .github, into: account))
        #expect(server.exchanges.isEmpty)
        #expect(!account.isSignedIn)
        #expect(flow.notice == nil)
    }

    /// Withdrawn while QTC is answering the exchange: the session that comes
    /// back is not kept and /v1/me is never called.
    @Test func aSignInThatLandsAfterAWithdrawalIsNotKept() async throws {
        let held = HeldReply(.json(200, #"{"token":"t9","userId":"u1","created":false}"#))
        let stub = StubServer { request in
            switch request.path {
            case "/v1/auth/apple": return held.wait()
            case "/v1/me": return .json(200, meJSON(["apple"]))
            default: return .json(404, "{}")
            }
        }
        let client = qtcClient(stub)
        let consent = consenting()
        defer { consent.restore() }
        let keychain = QTCMemoryKeychain()
        let account = AccountStore(client: client, keychain: keychain.keychain)
        account.followConsent()
        let flow = SignInFlow(client: client, opener: FakeBrowser(nil).opener, apple: FakeApple().authorizer)

        let signingIn = Task { await flow.signInWithApple(into: account) }
        try await eventuallyHolds { stub.paths.contains("/v1/auth/apple") }
        consent.declineForTest()
        consent.acceptForTest()  // given again before the answer lands
        held.letGo()

        #expect(await !signingIn.value)
        #expect(!account.isSignedIn)
        #expect(keychain.stored == nil, "nothing written to the keychain")
        #expect(!stub.paths.contains("/v1/me"))
    }

    /// The account refuses a session on its own too: none is kept without
    /// the transfer consent, nor with a ticket from before a withdrawal.
    @Test func theAccountKeepsNoSessionWithoutTheConsent() async {
        let server = OAuthServer(me: .json(200, meJSON(["apple"])))
        let consent = consenting()
        defer { consent.restore() }
        let keychain = QTCMemoryKeychain()
        let account = AccountStore(client: server.client, keychain: keychain.keychain)
        account.followConsent()
        let session = QTCSession(token: "t9", userId: "u1")

        let before = account.beginSignIn()
        consent.declineForTest()
        #expect(account.beginSignIn() == nil, "nothing may start")
        #expect(await !account.signedIn(session))

        consent.acceptForTest()
        #expect(await !account.signedIn(session, ticket: before), "a ticket from before the withdrawal stays void")
        #expect(keychain.stored == nil)
        #expect(server.stub.requests.isEmpty)

        #expect(await account.signedIn(session, ticket: account.beginSignIn()))
        #expect(account.session == session)
    }
}
