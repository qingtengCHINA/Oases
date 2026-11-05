import XCTest
@testable import Oases_Chat

/// Agent browser navigation must go through `BrowserPolicy` (no loopback /
/// LAN / debug server), including numeric IPv4 spellings WebKit accepts.
@MainActor
final class BrowserHardeningTests: XCTestCase {
    private let policy = BrowserPolicy()

    func testNumericAndMappedLoopbackFormsAreBlocked() {
        for raw in [
            "http://2130706433/",          // 127.0.0.1 as a 32-bit integer
            "http://127.1:8321/",          // shorthand
            "http://0x7f.0.0.1/",          // hex octet
            "http://017700000001/",        // octal
            "http://[::ffff:127.0.0.1]/",  // IPv4-mapped IPv6
            "http://[::ffff:c0a8:101]/",   // 192.168.1.1 mapped, hex form
            "http://0.0.0.0:8321/",
        ] {
            XCTAssertThrowsError(try policy.validate(url: URL(string: raw)!), raw)
        }
    }

    func testPublicHostsStillPass() throws {
        try policy.validate(url: URL(string: "https://example.com/")!)
        try policy.validate(url: URL(string: "http://198.51.100.10/")!)
        try policy.validate(url: URL(string: "https://8.8.8.8/")!)
    }

    func testEmbeddedIPv4Normalization() {
        XCTAssertEqual(BrowserPolicy.embeddedIPv4("2130706433"), "127.0.0.1")
        XCTAssertEqual(BrowserPolicy.embeddedIPv4("::ffff:10.0.0.1"), "10.0.0.1")
        XCTAssertNil(BrowserPolicy.embeddedIPv4("example.com"))
    }

    /// The agent `navigate` action refuses private destinations before
    /// anything is loaded.
    func testAgentNavigateRejectsLoopbackDebugServer() async throws {
        let manager = BrowserUseManager()
        let input = try XCTUnwrap(BrowserActionInput.parse(from: #"{"action":"navigate","url":"http://127.0.0.1:8321/rpc"}"#))
        let result = try await manager.execute(action: input)
        XCTAssertFalse(result.success)
        XCTAssertNil(manager.webView.url)
    }

    func testMinisSchemeOnlyServesMinisOrFileDocuments() {
        var fromWeb = URLRequest(url: URL(string: "minis://workspace/secret.js")!)
        fromWeb.mainDocumentURL = URL(string: "https://evil.example/")
        XCTAssertFalse(MinisURLSchemeHandler.isAllowedRequester(fromWeb))

        var fromMinis = URLRequest(url: URL(string: "minis://workspace/app.js")!)
        fromMinis.mainDocumentURL = URL(string: "minis://workspace/index.html")
        XCTAssertTrue(MinisURLSchemeHandler.isAllowedRequester(fromMinis))

        var topLevel = URLRequest(url: URL(string: "minis://workspace/index.html")!)
        topLevel.mainDocumentURL = topLevel.url
        XCTAssertTrue(MinisURLSchemeHandler.isAllowedRequester(topLevel))
    }
}

/// Diffable identifiers must be unique or `apply` raises.
final class MessageListIdentifierTests: XCTestCase {
    func testDuplicateItemsAreDroppedKeepingFirstOccurrence() {
        let a = UUID(), b = UUID(), block = UUID()
        let items: [MessageListItem] = [
            .wholeMessage(a),
            .assistantHeader(b),
            .assistantBlock(b, block),
            .assistantBlock(b, block),
            .wholeMessage(a),
            .assistantFooter(b),
        ]
        let result = items.removingDuplicateIdentifiers()
        XCTAssertEqual(result.items, [.wholeMessage(a), .assistantHeader(b), .assistantBlock(b, block), .assistantFooter(b)])
        XCTAssertEqual(result.dropped, [.assistantBlock(b, block), .wholeMessage(a)])
    }
}

/// `…/session1` must not grant file navigation into `…/session10`.
final class WebAppReadScopeTests: XCTestCase {
    func testContainmentRespectsDirectoryBoundary() {
        let root = "/var/mobile/minis/session1"
        XCTAssertTrue(WebAppWebViewController.isInside(root: root, target: root))
        XCTAssertTrue(WebAppWebViewController.isInside(root: root, target: root + "/index.html"))
        XCTAssertFalse(WebAppWebViewController.isInside(root: root, target: "/var/mobile/minis/session10/index.html"))
        XCTAssertFalse(WebAppWebViewController.isInside(root: root, target: "/var/mobile/minis/session1-evil"))
    }
}
