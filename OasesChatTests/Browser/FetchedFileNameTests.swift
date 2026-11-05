import XCTest
@testable import Oases_Chat

/// A fetched file's name comes from the server (Content-Disposition or the URL) and is joined
/// onto the session's browser directory: it must never carry a path out of it.
final class FetchedFileNameTests: XCTestCase {
    func testContentDispositionTraversalIsReducedToOneComponent() {
        let header = #"attachment; filename="a/../../../../Documents/Skills/x/SKILL.md""#
        let parsed = BrowserUseManager.parseContentDispositionFilename(header)
        XCTAssertEqual(parsed.flatMap(BrowserUseManager.safeFileName), "SKILL.md")
    }

    func testPercentEncodedSlashesAndBackslashesAreStripped() {
        let header = "attachment; filename*=UTF-8''..%2F..%2Fsecret.plist"
        let parsed = BrowserUseManager.parseContentDispositionFilename(header)
        XCTAssertEqual(parsed.flatMap(BrowserUseManager.safeFileName), "secret.plist")
        XCTAssertEqual(BrowserUseManager.safeFileName(#"..\..\boot.ini"#), "boot.ini")
    }

    func testDotNamesEmptyNamesAndControlCharactersAreRefused() {
        XCTAssertNil(BrowserUseManager.safeFileName(""))
        XCTAssertNil(BrowserUseManager.safeFileName("."))
        XCTAssertNil(BrowserUseManager.safeFileName(".."))
        XCTAssertNil(BrowserUseManager.safeFileName("a/.."))
        XCTAssertNil(BrowserUseManager.safeFileName("///"))
        XCTAssertEqual(BrowserUseManager.safeFileName("re\u{0}port\n.pdf"), "report.pdf")
    }

    func testOrdinaryNamesAreKept() {
        XCTAssertEqual(BrowserUseManager.safeFileName("报告 2026.pdf"), "报告 2026.pdf")
        XCTAssertEqual(BrowserUseManager.safeFileName(".env"), ".env")
        XCTAssertEqual(BrowserUseManager.safeFileName(String(repeating: "a", count: 300))?.count, 200)
    }

    func testTheGuardedDestinationStaysInsideTheDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = try XCTUnwrap(BrowserUseManager.safeFileName("x/../../evil.sh"))
        let dest = try ArchivePathGuard.destination(for: name, under: root)
        XCTAssertEqual(dest.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
    }
}
