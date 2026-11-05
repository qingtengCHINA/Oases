import Foundation
import Testing
@testable import Oases_Chat

/// The QingTeng account client against a stub server (no network), ported
/// from K线艺术家's `QTCClientTests`, account endpoints only. Routes, bodies
/// and answers follow qtc-center/docs/app-integration-guide.md.
@Suite("QingTeng account client")
struct QTCClientTests {
    nonisolated private static let me = #"""
    {"userId":"u1","balance":120,
     "identities":[{"provider":"apple","subject":"s1"},{"provider":"passkey","subject":"s2"}],
     "payoutAddresses":{"arc":null,"solana":"So1ana"}}
    """#

    @Test func oasesTalksToQTCAsOases() {
        #expect(QTCConfig.baseURL.absoluteString == "https://api.qingtengstudio.com")
        #expect(QTCConfig.appID == "oases")
        #expect(QTCConfig.appleClientID == "dev.oases.chat.ios")
    }

    // MARK: - Sign-in

    @Test func appleSignInPostsTheIdTokenAndDecodes() async throws {
        let server = StubServer { _ in .json(200, #"{"token":"t1","userId":"u1","uid":482913,"created":true}"#) }

        let result = try await qtcClient(server).signInWithApple(idToken: "apple-identity-token")

        #expect(result.session == QTCSession(token: "t1", userId: "u1"))
        #expect(result.created)
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/auth/apple")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Authorization") == nil)
        #expect(request.stringFields == ["idToken": "apple-identity-token"], "only the identity token; never an email or a name")
    }

    @Test func oauthStartSendsTheRegisteredReturnAddress() async throws {
        let server = StubServer { _ in .json(200, #"{"url":"https://github.com/login/oauth/authorize?x=1"}"#) }
        let qtc = qtcClient(server)

        let url = try await qtc.oauthStart(provider: "github", codeChallenge: "challenge", linkingWith: nil)
        _ = try await qtc.oauthStart(provider: "microsoft", codeChallenge: "challenge2", linkingWith: "t1")

        #expect(url.absoluteString == "https://github.com/login/oauth/authorize?x=1")
        let (login, link) = (server.requests[0], server.requests[1])
        #expect(login.path == "/v1/auth/oauth/start")
        #expect(login.stringFields == ["provider": "github", "returnTo": "qtc-oases://oauth", "codeChallenge": "challenge", "mode": "login"])
        #expect(login.header("Authorization") == nil)
        #expect(link.stringFields?["mode"] == "link")
        #expect(link.header("Authorization") == "Bearer t1")
    }

    @Test func oauthStartReportsAProviderThatIsNotSwitchedOn() async {
        let server = StubServer { _ in .json(503, #"{"error":"provider_unavailable"}"#) }
        await #expect(throws: QTCError.providerUnavailable) {
            try await qtcClient(server).oauthStart(provider: "microsoft", codeChallenge: "c", linkingWith: nil)
        }
    }

    @Test func oauthAccountNotFoundCarriesTheProvider() async throws {
        let server = StubServer { _ in .json(409, #"{"error":"account_not_found","provider":"github"}"#) }

        await #expect(throws: QTCError.accountNotFound(provider: "github")) {
            try await qtcClient(server).oauthExchange(code: "code", codeVerifier: "verifier", createNew: false, linkingWith: nil)
        }
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/auth/oauth/exchange")
        #expect(request.keys == ["code", "codeVerifier"], "the first exchange doesn't ask for a new account")
    }

    @Test func createNewIsSentAsABoolean() async throws {
        let server = StubServer { _ in .json(200, #"{"token":"t2","userId":"u2","created":true}"#) }

        let result = try await qtcClient(server).oauthExchange(code: "code", codeVerifier: "verifier", createNew: true, linkingWith: nil)

        #expect(result == .signedIn(QTCSession(token: "t2", userId: "u2"), created: true))
        struct Body: Decodable { let code: String; let codeVerifier: String; let createNew: Bool }
        let request = try #require(server.requests.first)
        let body = try #require(request.decode(Body.self), "createNew must decode as a JSON boolean")
        #expect(body.createNew)
        #expect(request.bodyText?.contains(#""createNew":true"#) == true)
        #expect(request.header("Authorization") == nil)
    }

    @Test func oauthLinkingReportsWhetherItWasAlreadyBound() async throws {
        let server = StubServer { _ in .json(200, #"{"status":"already_bound","provider":"github"}"#) }

        let result = try await qtcClient(server).oauthExchange(code: "code", codeVerifier: "verifier", createNew: false, linkingWith: "t1")

        #expect(result == .linked(alreadyBound: true))
        #expect(server.requests.first?.header("Authorization") == "Bearer t1")
        server.setHandler { _ in .json(409, #"{"error":"identity_taken"}"#) }
        await #expect(throws: QTCError.identityTaken) {
            try await qtcClient(server).oauthExchange(code: "code", codeVerifier: "verifier", createNew: false, linkingWith: "t1")
        }
    }

    // MARK: - Session

    @Test func refreshSendsNoBody() async throws {
        let server = StubServer { _ in .json(200, #"{"token":"fresh","userId":"u1"}"#) }

        let session = try await qtcClient(server).refresh(token: "old")

        #expect(session == QTCSession(token: "fresh", userId: "u1"))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/auth/refresh")
        #expect(request.header("Authorization") == "Bearer old")
        #expect(request.body?.isEmpty ?? true)
        #expect(request.header("Content-Type") == nil)
    }

    @Test func unknownIdentityProvidersStillDecode() async throws {
        let server = StubServer { _ in .json(200, Self.me) }

        let me = try await qtcClient(server).me(token: "t1")

        #expect(me.userId == "u1")
        #expect(me.identities.map(\.provider) == ["apple", "passkey"])
        #expect(me.payoutAddresses == QTCMe.PayoutAddresses(arc: nil), "Solana is cancelled: its address is not read")
        #expect(me.uid == nil, "a profile without a UID still decodes")
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/me")
        #expect(request.header("Authorization") == "Bearer t1")
    }

    /// Oases Chat uses the account system only: the profile it keeps has no balance to show.
    @Test func theProfileKeepsNoBalance() async throws {
        let server = StubServer { _ in .json(200, meJSON(["apple"])) }
        let me = try await qtcClient(server).me(token: "t1")

        #expect(me.uid == 482913)
        #expect(!Mirror(reflecting: me).children.contains { ($0.label ?? "").localizedCaseInsensitiveContains("balance") })
        #expect(!Mirror(reflecting: me).children.contains { ($0.label ?? "").localizedCaseInsensitiveContains("gift") })
    }

    @Test func bindAppleReportsWhetherItWasAlreadyBound() async throws {
        let server = StubServer { _ in .json(200, #"{"status":"bound"}"#) }
        let qtc = qtcClient(server)

        #expect(try await qtc.bindApple(idToken: "apple-identity-token", token: "t1") == false)
        server.setHandler { _ in .json(200, #"{"status":"already_bound"}"#) }
        #expect(try await qtc.bindApple(idToken: "apple-identity-token", token: "t1") == true)

        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/me/identities/apple")
        #expect(request.header("Authorization") == "Bearer t1")
        #expect(request.stringFields == ["idToken": "apple-identity-token"])
    }

    @Test func payoutAddressesAreSetAndClearedWithNull() async throws {
        let server = StubServer { _ in .json(200, #"{"payoutAddresses":{"arc":"0xAbC","solana":null}}"#) }
        let qtc = qtcClient(server)

        let set = try await qtc.setPayoutAddress(arc: "0xAbC", token: "t1")
        _ = try await qtc.setPayoutAddress(arc: nil, token: "t1")

        #expect(set == QTCMe.PayoutAddresses(arc: "0xAbC"))
        let (put, clear) = (server.requests[0], server.requests[1])
        #expect(put.method == "PUT")
        #expect(put.path == "/v1/me/payout-address")
        #expect(put.stringFields == ["chain": "arc", "address": "0xAbC"])
        #expect(clear.stringFields == ["chain": "arc"], "clearing names Arc too")
        #expect(clear.bodyText?.contains(#""address":null"#) == true)
        server.setHandler { _ in .json(400, #"{"error":"invalid_address"}"#) }
        await #expect(throws: QTCError.invalidAddress) {
            try await qtc.setPayoutAddress(arc: "0x1", token: "t1")
        }
    }

    // MARK: - Deletion

    @Test func deleteSendsConfirmAndTheAppleFieldsOnlyWithACode() async throws {
        let server = StubServer { _ in .json(200, #"{"deleted":true}"#) }
        let qtc = qtcClient(server)

        try await qtc.deleteAccount(token: "t1", appleAuthorizationCode: nil)
        try await qtc.deleteAccount(token: "t1", appleAuthorizationCode: "apple-code")

        let (plain, withApple) = (server.requests[0], server.requests[1])
        #expect(plain.method == "POST")
        #expect(plain.path == "/v1/me/delete")
        #expect(plain.header("Authorization") == "Bearer t1")
        #expect(plain.header("X-QTC-App") == "oases")
        #expect(plain.header("Content-Type") == "application/json")
        #expect(plain.stringFields == ["confirm": "DELETE"])
        #expect(withApple.stringFields == [
            "confirm": "DELETE", "appleAuthorizationCode": "apple-code", "appleClientId": "dev.oases.chat.ios",
        ])
    }

    // MARK: - Errors

    @Test func statusesAndTransportFailuresMapToErrors() async {
        let server = StubServer()
        let qtc = qtcClient(server)
        let cases: [(StubServer.Reply, QTCError)] = [
            (.json(401, #"{"error":"unauthorized"}"#), .unauthorized),
            (.json(429, #"{"error":"rate_limited"}"#), .rateLimited),
            (.json(500, #"{"error":"internal_error"}"#), .unavailable),
            (.json(503, #"{"error":"db_unavailable"}"#), .unavailable),
            (.json(404, "not json"), .server(status: 404, code: nil)),
            (.json(200, #"{"unexpected":true}"#), .server(status: 200, code: nil)),
            (.failure(.notConnectedToInternet), .offline),
        ]
        for (reply, expected) in cases {
            server.setHandler { _ in reply }
            await #expect(throws: expected) { try await qtc.me(token: "t1") }
        }
    }

    @Test func sessionDescriptionsHideTheToken() {
        let session = QTCSession(token: "secret-token", userId: "u1")
        #expect(!String(describing: session).contains("secret-token"))
        #expect(!String(reflecting: session).contains("secret-token"))
        #expect(String(describing: session).contains("u1"))
    }
}
