import Foundation
import Testing
@testable import Oases_Chat

/// The payout address and its on-device checks (guide §6; the EIP-55
/// checksum is left to QTC's 400 invalid_address), the mainland-China rule
/// (`PayoutRegion`, ported from 词忆 through K线艺术家) and how sign-in
/// methods are listed (`IdentityDisplay`). Arc only: Solana is cancelled.
@Suite("Payout address and sign-in methods")
struct PayoutAddressTests {
    @Test func payoutVisibleOnlyOutsideMainlandChina() {
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "CN"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "US"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "HK"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "TW"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "MO"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: nil), "no region set is not mainland China")
    }

    /// The device region OR the first preferred language carrying CN hides the row; HK, MO and TW show it.
    @Test func payoutHiddenWhenRegionOrPreferredLanguageIsMainlandChina() {
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "CN", preferredLanguage: "zh-Hans-CN"), "region and language both mainland China")
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "GB", preferredLanguage: "zh-Hans"), "Simplified Chinese without a region, region UK")
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "CN", preferredLanguage: "en-GB"), "English, region mainland China")
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "HK", preferredLanguage: "zh-Hant-HK"), "Hong Kong")

        // The first language carries CN: hidden whatever the region says.
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "GB", preferredLanguage: "zh-Hans-CN"))
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "US", preferredLanguage: "en-CN"))
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: nil, preferredLanguage: "zh_Hans_CN"), "underscores")
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "JP", preferredLanguage: "zh-CN"))
        #expect(!PayoutRegion.showsPayoutAddresses(regionIdentifier: "cn", preferredLanguage: nil), "a lowercase region counts too")

        // Everywhere else shows it.
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "MO", preferredLanguage: "zh-Hant-MO"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "TW", preferredLanguage: "zh-Hant-TW"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "SG", preferredLanguage: "zh-Hans-SG"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "US", preferredLanguage: "en-US"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "US", preferredLanguage: "en"))
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: nil, preferredLanguage: nil), "nothing readable: shown")
        #expect(PayoutRegion.showsPayoutAddresses(regionIdentifier: "GB", preferredLanguage: "en-x-cn"), "cn in a private-use extension is not a region")

        #expect(PayoutRegion.regionSubtag(of: "zh-Hans-CN") == "CN")
        #expect(PayoutRegion.regionSubtag(of: "zh_Hans_CN") == "CN")
        #expect(PayoutRegion.regionSubtag(of: "en-GB") == "GB")
        #expect(PayoutRegion.regionSubtag(of: "zh-Hant-HK") == "HK")
        #expect(PayoutRegion.regionSubtag(of: "es-419") == "419")
        #expect(PayoutRegion.regionSubtag(of: "zh-Hans-CN@calendar=chinese") == "CN")
        #expect(PayoutRegion.regionSubtag(of: "zh-Hans-CN-u-ca-chinese") == "CN")
        #expect(PayoutRegion.regionSubtag(of: "zh-Hans") == nil)
        #expect(PayoutRegion.regionSubtag(of: "en") == nil)
        #expect(PayoutRegion.regionSubtag(of: "en-x-cn") == nil)
        #expect(PayoutRegion.regionSubtag(of: "") == nil)

        // The Arc wallet row follows the same rule.
        let identities = ["apple", "ethereum", "github"].map { QTCMe.Identity(provider: $0, subject: "s-\($0)") }
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "CN", preferredLanguage: "zh-Hans-CN") == ["apple", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "GB", preferredLanguage: "zh-Hans") == ["apple", "ethereum", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "CN", preferredLanguage: "en-GB") == ["apple", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "HK", preferredLanguage: "zh-Hant-HK") == ["apple", "ethereum", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "GB", preferredLanguage: "zh-Hans-CN") == ["apple", "github"], "language carries CN: no wallet either")
        #expect(IdentityDisplay.labels(for: identities, regionIdentifier: "US", preferredLanguage: "zh-Hans-CN") == ["Apple", "GitHub"])
    }

    @Test func identityLabelsAndUnknownHidden() {
        #expect(IdentityDisplay.label(for: "apple") == "Apple")
        #expect(IdentityDisplay.label(for: "github") == "GitHub")
        #expect(IdentityDisplay.label(for: "microsoft") == QT("account.microsoft"))
        #expect(AccountCopy.zhHans("account.microsoft") == "微软")
        #expect(IdentityDisplay.label(for: "ethereum") == QT("account.arcWallet"))
        #expect(AccountCopy.zhHans("account.arcWallet") == "Arc 钱包")
        #expect(IdentityDisplay.label(for: "solana") == nil)
        #expect(IdentityDisplay.label(for: "passkey") == nil)
        #expect(IdentityDisplay.label(for: "google") == nil)
        #expect(IdentityDisplay.label(for: "Apple") == nil)
        #expect(IdentityDisplay.label(for: "") == nil)

        let identities = ["apple", "passkey", "ethereum", "github", "solana", "ethereum"]
            .map { QTCMe.Identity(provider: $0, subject: "s-\($0)") }
        #expect(IdentityDisplay.labels(for: identities, regionIdentifier: "US") == ["Apple", QT("account.arcWallet"), "GitHub"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "US") == ["apple", "ethereum", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: nil) == ["apple", "ethereum", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "HK") == ["apple", "ethereum", "github"])
        #expect(IdentityDisplay.displayedProviders(for: identities, regionIdentifier: "CN") == ["apple", "github"], "mainland China: no wallet")
        #expect(IdentityDisplay.labels(for: identities, regionIdentifier: "CN") == ["Apple", "GitHub"])
        #expect(IdentityDisplay.labels(for: [], regionIdentifier: "US") == [])
        #expect(IdentityDisplay.walletProviders == ["ethereum"])

        #expect(IdentityDisplay.isBound("github", in: identities))
        #expect(!IdentityDisplay.isBound("microsoft", in: identities))
        #expect(IdentityDisplay.bindableProviders == ["apple", "github", "microsoft"], "wallets can't be linked in the app")
        #expect(IdentityDisplay.bindableProviders == LoginMethod.allCases.map(\.rawValue), "the page's bind buttons follow the same order")
    }

    @Test func arcShape() {
        let hex40 = "52908400098527886E0F7030069857D2E4169EE7"
        #expect(PayoutAddress.isPlausibleArc("0x" + hex40))
        #expect(PayoutAddress.isPlausibleArc("0x" + hex40.lowercased()))
        #expect(PayoutAddress.isPlausibleArc("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"), "mixed case: the checksum is QTC's to check")
        #expect(!PayoutAddress.isPlausibleArc("0x" + hex40.dropLast()), "39 digits")
        #expect(!PayoutAddress.isPlausibleArc("0x" + hex40 + "7"), "41 digits")
        #expect(!PayoutAddress.isPlausibleArc(hex40 + "00"), "no 0x")
        #expect(!PayoutAddress.isPlausibleArc("0X" + hex40), "the prefix is lowercase 0x")
        #expect(!PayoutAddress.isPlausibleArc("0x" + hex40.dropLast() + "g"), "g is not hex")
        #expect(!PayoutAddress.isPlausibleArc(" 0x" + hex40), "the page trims; the check doesn't")
        #expect(!PayoutAddress.isPlausibleArc("0x" + String(repeating: "０", count: 40)), "only ASCII hex digits, not full-width ones")
        #expect(!PayoutAddress.isPlausibleArc("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"), "a Solana address is not accepted")
        #expect(!PayoutAddress.isPlausibleArc(""))
    }
}

/// What the account page shows and saves, against a stub QTC.
@MainActor
@Suite("QingTeng account page")
struct AccountPageTests {
    /// Guide §5: `#` and at least 6 digits; 7-digit UIDs need no change.
    @Test func uidHasAtLeastSixDigits() {
        #expect(QTCMe.formatUid(1) == "#000001")
        #expect(QTCMe.formatUid(482913) == "#482913")
        #expect(QTCMe.formatUid(1234567) == "#1234567")
    }

    @Test func theProfileCarriesTheUIDAndNeverASolanaAddress() async throws {
        let server = StubServer { _ in
            .json(200, #"{"userId":"u1","uid":1,"balance":5,"identities":[{"provider":"solana","subject":"s"}],"payoutAddresses":{"arc":null,"solana":"So1ana"},"gifts":{"dailyLimit":10000,"dailyRemaining":10000,"resetsAt":"2026-10-24T00:00:00.000Z"}}"#)
        }
        let me = try await qtcClient(server).me(token: "t1")

        #expect(me.uid == 1)
        #expect(me.payoutAddresses == QTCMe.PayoutAddresses(arc: nil))
        #expect(LoginMethod.bound(in: me.identities).isEmpty, "a Solana identity is not listed")
    }

    private static let address = "0x52908400098527886E0F7030069857D2E4169EE7"

    private func signedIn(_ server: StubServer) async -> AccountStore {
        let store = AccountStore(client: qtcClient(server), keychain: QTCMemoryKeychain().keychain)
        await store.signedIn(QTCSession(token: "t1", userId: "u1"))
        return store
    }

    @Test func savingTheAddressShowsItAtOnce() async throws {
        let saved = #"{"payoutAddresses":{"arc":"\#(Self.address)","solana":null}}"#
        let profile = meJSON(["apple"])
        let server = StubServer { request in
            request.method == "PUT" ? .json(200, saved) : .json(200, profile)
        }
        let account = await signedIn(server)

        try await account.savePayoutAddress(Self.address)

        #expect(account.me?.payoutAddresses.arc == Self.address)
        #expect(account.me?.uid == 482913, "the rest of the profile is kept")
        #expect(account.me?.identities.map(\.provider) == ["apple"])
        let put = try #require(server.requests.last)
        #expect(put.path == "/v1/me/payout-address")
        #expect(put.stringFields == ["chain": "arc", "address": Self.address])
        #expect(put.header("Authorization") == "Bearer t1")
    }

    @Test func clearingSendsNull() async throws {
        let profile = meJSON(["apple"], arc: Self.address)
        let server = StubServer { request in
            request.method == "PUT" ? .json(200, #"{"payoutAddresses":{"arc":null}}"#) : .json(200, profile)
        }
        let account = await signedIn(server)
        #expect(account.me?.payoutAddresses.arc == Self.address)

        try await account.savePayoutAddress(nil)

        #expect(account.me?.payoutAddresses.arc == nil)
        #expect(server.requests.last?.bodyText?.contains(#""address":null"#) == true)
    }

    @Test func aRefusedAddressKeepsTheOldOneAndA401SignsOut() async throws {
        let profile = meJSON(["apple"], arc: Self.address)
        let server = StubServer { request in
            request.method == "PUT" ? .json(400, #"{"error":"invalid_address"}"#) : .json(200, profile)
        }
        let account = await signedIn(server)

        await #expect(throws: QTCError.invalidAddress) {
            try await account.savePayoutAddress("0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        }
        #expect(account.me?.payoutAddresses.arc == Self.address)
        #expect(account.isSignedIn)

        server.setHandler { _ in .json(401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: QTCError.unauthorized) {
            try await account.savePayoutAddress(Self.address)
        }
        #expect(!account.isSignedIn)
        #expect(account.needsSignIn)
    }

    // MARK: - What the page shows

    private func member(providers: [String], arc: String?) -> QTCMe {
        QTCMe(
            userId: "u1", uid: 1,
            identities: providers.map { QTCMe.Identity(provider: $0, subject: "s-\($0)") },
            payoutAddresses: QTCMe.PayoutAddresses(arc: arc)
        )
    }

    /// The card leads the page; Oases Chat shows no QingTeng balance anywhere.
    @Test func thePageCarriesNoBalance() {
        let page = AccountPageContent(me: member(providers: ["apple"], arc: Self.address), regionIdentifier: "US", preferredLanguage: "en-US")

        #expect(!Mirror(reflecting: page).children.contains { ($0.label ?? "").localizedCaseInsensitiveContains("balance") })
        #expect(page.uid == 1, "the card shows the UID")
    }

    @Test func thePageListsBoundMethodsAndOffersTheRest() {
        let me = member(providers: ["github", "ethereum", "solana", "passkey"], arc: Self.address)

        let abroad = AccountPageContent(me: me, regionIdentifier: "US", preferredLanguage: "en-US")
        #expect(abroad.boundProviders == ["github", "ethereum"], "server order; Solana and unknown ones hidden")
        #expect(abroad.unboundMethods == [.apple, .microsoft])
        #expect(abroad.showsPayoutAddress)
        #expect(abroad.payoutAddress == Self.address)

        for (region, language) in [("CN", "zh-Hans-CN"), ("GB", "zh-Hans-CN"), ("CN", "en-GB")] {
            let mainland = AccountPageContent(me: me, regionIdentifier: region, preferredLanguage: language)
            #expect(mainland.boundProviders == ["github"], "no Arc wallet row in mainland China")
            #expect(!mainland.showsPayoutAddress)
            #expect(mainland.payoutAddress == nil)
            #expect(mainland.unboundMethods == [.apple, .microsoft])
        }
        for (region, language) in [("HK", "zh-Hant-HK"), ("MO", "zh-Hant-MO"), ("TW", "zh-Hant-TW")] {
            #expect(AccountPageContent(me: me, regionIdentifier: region, preferredLanguage: language).showsPayoutAddress)
        }

        let loading = AccountPageContent(me: nil, regionIdentifier: "US", preferredLanguage: "en-US")
        #expect(loading.uid == nil, "dashes on the card until the profile is read")
        #expect(loading.boundProviders.isEmpty && loading.unboundMethods.isEmpty)
        #expect(!loading.showsPayoutAddress)
    }

    // MARK: - Profile reads that land late (K线艺术家's C3 review)

    private func profile(arc: String?, providers: [String] = []) -> QTCMe {
        QTCMe(userId: "u1", uid: 482913, identities: providers.map { QTCMe.Identity(provider: $0, subject: "s") },
              payoutAddresses: QTCMe.PayoutAddresses(arc: arc))
    }

    @Test func aReadThatStartedBeforeASaveNeverOverwritesIt() async throws {
        let saved = #"{"payoutAddresses":{"arc":"\#(Self.address)"}}"#
        let old = meJSON(["apple"])
        let server = StubServer { request in
            request.method == "PUT" ? .json(200, saved) : .json(200, old)
        }
        let account = await signedIn(server)
        // A foreground reload is under way and has read the old profile…
        let reload = try #require(account.beginProfileRead())

        try await account.savePayoutAddress(Self.address)

        // …and its answer lands after the save.
        #expect(!account.finishProfileRead(reload, with: profile(arc: nil)))
        #expect(account.me?.payoutAddresses.arc == Self.address)

        // Clearing is a change too.
        server.setHandler { request in
            request.method == "PUT" ? .json(200, #"{"payoutAddresses":{"arc":null}}"#) : .json(200, old)
        }
        let second = try #require(account.beginProfileRead())
        try await account.savePayoutAddress(nil)
        #expect(!account.finishProfileRead(second, with: profile(arc: Self.address)))
        #expect(account.me?.payoutAddresses.arc == nil)
    }

    @Test func onlyTheNewestReadIsShown() async throws {
        let account = await signedIn(StubServer { _ in .json(200, meJSON(["apple"])) })
        let older = try #require(account.beginProfileRead())
        let newer = try #require(account.beginProfileRead())

        #expect(account.finishProfileRead(newer, with: profile(arc: nil, providers: ["github"])))
        #expect(!account.finishProfileRead(older, with: profile(arc: nil, providers: ["microsoft"])), "out of order: dropped")
        #expect(LoginMethod.bound(in: account.me?.identities ?? []) == [.github])
    }

    @Test func aReadFromAnEarlierSessionIsDropped() async throws {
        let account = await signedIn(StubServer { _ in .json(200, meJSON(["apple"])) })
        let earlier = try #require(account.beginProfileRead())

        account.signOut()
        #expect(account.beginProfileRead() == nil, "nothing to read while signed out")
        await account.signedIn(QTCSession(token: "t2", userId: "u1"))

        #expect(!account.finishProfileRead(earlier, with: profile(arc: nil, providers: ["microsoft"])))
        #expect(LoginMethod.bound(in: account.me?.identities ?? []) == [.apple], "the new session's own read")
    }
}
