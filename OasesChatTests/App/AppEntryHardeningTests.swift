import SwiftData
import UIKit
import XCTest
@testable import Oases_Chat

/// Build config, entry-point routing and store recovery (code review
/// 2026-09-29, items 0.6 / 0.8 / 0.11 / 0.13).
final class InfoPlistConfigTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testKeysFromInfoPropertiesAreMerged() {
        XCTAssertEqual(info["NSSupportsLiveActivities"] as? Bool, true)
        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
        XCTAssertNotNil(info["OASESVerboseLogging"])
        XCTAssertNotNil(info["NSFaceIDUsageDescription"])
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
    }

    func testBackgroundModesMatchRealUse() {
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        XCTAssertTrue(modes.contains("audio"))
        XCTAssertFalse(modes.contains("location"))
        XCTAssertFalse(modes.contains("processing"))
        XCTAssertNil(info["NSLocationAlwaysAndWhenInUseUsageDescription"])
    }

    /// App Review 5.6 (2026-10-08): no capability may be declared without a
    /// feature the user can see. HealthKit and HomeKit were removed.
    func testNoHealthOrHomeUsageDescriptions() {
        XCTAssertNil(info["NSHealthShareUsageDescription"])
        XCTAssertNil(info["NSHealthUpdateUsageDescription"])
        XCTAssertNil(info["NSHomeKitUsageDescription"])
    }

    func testATSExceptionsAreNestedUnderAppTransportSecurity() {
        XCTAssertNil(info["NSExceptionDomains"])
        let ats = info["NSAppTransportSecurity"] as? [String: Any]
        let domains = ats?["NSExceptionDomains"] as? [String: Any]
        XCTAssertNotNil(domains?["oases.dev"])
        XCTAssertNotNil(domains?["oaseschat.com"])
    }

    /// Declared languages = the in-app picker's languages, each of which ships
    /// a compiled string table (coverage itself is enforced by
    /// scripts/i18n/check_coverage.py).
    func testDeclaredLocalizationsAreTheCoveredOnes() {
        let declared = Set(info["CFBundleLocalizations"] as? [String] ?? [])
        XCTAssertEqual(declared, Set(Bundle.supportedLanguageCodes))
        for code in declared {
            XCTAssertNotNil(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code), code)
        }
        XCTAssertEqual(info["CFBundleDevelopmentRegion"] as? String, "en")
    }

    func testURLSchemeMatchesShareExtensionAndRouter() {
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(DeepLinkRouter.scheme))
    }

    func testQuickActionTitlesAreLocalized() {
        for key in ["shortcut.newChat.title", "shortcut.voiceChat.title", "shortcut.cameraChat.title"] {
            XCTAssertNotEqual(String(localized: String.LocalizationValue(key)), key, key)
        }
    }

    func testOpenSourceLicensesAreBundled() {
        let components = OpenSourceLicensesView.loadManifest()
        XCTAssertTrue(components.contains { $0.name.hasPrefix("iSH") })
        for component in components {
            for file in component.files {
                XCTAssertNotNil(OpenSourceLicensesView.licenseText(file), "\(component.name): \(file)")
            }
        }
    }
}

final class ConversationContainerRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationContainerRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testHealthyStoreOpensNormally() {
        let (_, recovery) = ConversationContainer.load(storeURL: dir.appendingPathComponent("ok.store"))
        XCTAssertEqual(recovery, .none)
    }

    func testCorruptStoreIsBackedUpAndReplaced() throws {
        let storeURL = dir.appendingPathComponent("broken.store")
        try Data("this is not a sqlite database".utf8).write(to: storeURL)

        let (container, recovery) = ConversationContainer.load(storeURL: storeURL)

        guard case .resetStore(let backup) = recovery else {
            return XCTFail("expected resetStore, got \(recovery)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("broken.store").path))
        let context = ModelContext(container)
        context.insert(ConversationModel())
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ConversationModel>()).count, 1)
    }
}

final class DeepLinkRoutingTests: XCTestCase {
    func testSessionIdFromPathOrQuery() {
        XCTAssertEqual(DeepLinkRouter.sessionId(from: URL(string: "oases://session/abc-123")!), "abc-123")
        XCTAssertEqual(DeepLinkRouter.sessionId(from: URL(string: "oases://session?id=xyz")!), "xyz")
        XCTAssertNil(DeepLinkRouter.sessionId(from: URL(string: "oases://session")!))
    }

    func testSettingsTargets() {
        XCTAssertNil(DeepLinkRouter.settingsTarget([]))
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["background"]), .background)
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["providers", "p1"]), .providerDetail(instanceId: "p1"))
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["model-groups"]), .modelGroups)
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["mcp", "s1"]), .mcpServerDetail(serverId: "s1"))
        XCTAssertNil(DeepLinkRouter.settingsTarget(["no-such-page"]))
    }
}

@MainActor
final class QuickActionRouterTests: XCTestCase {
    func testNewChatRequestIsHandedOutOnceWithItsAction() {
        let router = QuickActionRouter.shared
        _ = router.consumeNewChatRequest() // drain anything earlier tests left

        let voice = UIApplicationShortcutItem(
            type: QuickActionRouter.ShortcutType.voiceChat, localizedTitle: "Voice"
        )
        XCTAssertTrue(router.handle(voice))
        XCTAssertEqual(router.consumeNewChatRequest(), .init(action: .startVoice))
        XCTAssertNil(router.consumeNewChatRequest())

        let plain = UIApplicationShortcutItem(
            type: QuickActionRouter.ShortcutType.newChat, localizedTitle: "New"
        )
        XCTAssertTrue(router.handle(plain))
        XCTAssertEqual(router.consumeNewChatRequest(), .init(action: nil))
        XCTAssertFalse(router.handle(UIApplicationShortcutItem(type: "unknown", localizedTitle: "?")))
    }
}

#if DEBUG
final class DebugServerHardeningTests: XCTestCase {
    func testRedactsCredentialHeadersURLsAndBodies() {
        let headers = DebugSecretRedactor.headers([
            "Authorization": "Bearer sk-live-123",
            "x-api-key": "k",
            "x-goog-api-key": "g",
            "Content-Type": "application/json",
        ])
        XCTAssertEqual(headers["Authorization"], DebugSecretRedactor.mask)
        XCTAssertEqual(headers["x-api-key"], DebugSecretRedactor.mask)
        XCTAssertEqual(headers["x-goog-api-key"], DebugSecretRedactor.mask)
        XCTAssertEqual(headers["Content-Type"], "application/json")

        let url = DebugSecretRedactor.url("https://g.example/v1/models?alt=sse&key=AIzaSECRET")
        XCTAssertFalse(url.contains("AIzaSECRET"))
        XCTAssertTrue(url.contains("alt=sse"))

        let body = DebugSecretRedactor.text(
            #"{"api_key":"abc","model":"m","refresh_token": "rt"} Authorization: Bearer tok.en sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"#
        )
        for secret in ["\"abc\"", "\"rt\"", "tok.en", "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"] {
            XCTAssertFalse(body.contains(secret), secret)
        }
        XCTAssertTrue(body.contains("\"model\":\"m\""))
    }

    func testRequestParsingCapsBodyAndRejectsBadLengths() throws {
        func parse(_ raw: String) throws -> DebugServer.HTTPReadResult {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw XCTSkip("socketpair failed") }
            defer { close(fds[0]); close(fds[1]) }
            let bytes = Array(raw.utf8)
            _ = bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, bytes.count) }
            shutdown(fds[1], SHUT_WR)
            return DebugServer.readHTTPRequest(fds[0])
        }

        XCTAssertEqual(
            try parse("POST /rpc HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"),
            .request(method: "POST", path: "/rpc", accept: "", body: "{}")
        )
        XCTAssertEqual(
            try parse("POST /rpc HTTP/1.1\r\nContent-Length: \(DebugServer.maxBodyBytes + 1)\r\n\r\n"),
            .tooLarge
        )
        XCTAssertEqual(try parse("POST /rpc HTTP/1.1\r\nContent-Length: -5\r\n\r\n"), .malformed)
    }
}
#endif
