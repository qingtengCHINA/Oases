import XCTest
@testable import Oases_Chat

/// The shell (fakefs hook), the file tools and `minis://` rendering must agree
/// on where a guest file lives; when they didn't, a video Ogent downloaded into
/// `/var/minis/attachments` could never be shown in chat.
final class OasesFsRouterRoutingTests: XCTestCase {
    private let router = OasesFsRouter.shared

    func testSessionBucketsLandInTheTreeMinisURLsResolveFrom() throws {
        let sid = "route-\(UUID().uuidString.prefix(8))"
        let expected = AIChatViewModel.minisPersistentBase
            .appendingPathComponent(sid)
            .appendingPathComponent("attachments")
            .appendingPathComponent("clip.mp4")

        for guest in ["/var/oases/attachments/clip.mp4", "/var/minis/attachments/clip.mp4"] {
            let host = try XCTUnwrap(router.routedHostURL(normalized: guest, sessionId: sid), guest)
            XCTAssertEqual(host.standardizedFileURL.path, expected.standardizedFileURL.path, guest)
        }

        // A file written through the shell's path is what `minis://` renders.
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: expected)
        defer { try? FileManager.default.removeItem(at: expected.deletingLastPathComponent().deletingLastPathComponent()) }
        let previous = AIChatViewModel.activeSessionId
        AIChatViewModel.activeSessionId = sid
        defer { AIChatViewModel.activeSessionId = previous }
        let resolved = AIChatViewModel.resolveMinisURL(URL(string: "minis://attachments/clip.mp4")!)
        XCTAssertEqual(resolved?.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testGlobalTreesAreTheAppGroupDirsInEveryContext() throws {
        let cases: [(String, URL)] = [
            ("memory", AIChatViewModel.minisMemoryPersistentDir),
            ("skills", AIChatViewModel.minisSkillsPersistentDir),
            ("shared", AIChatViewModel.minisSharedPersistentDir),
            ("mcp-servers", AIChatViewModel.minisMcpServersPersistentDir),
        ]
        for (subdir, dir) in cases {
            for sid in [nil, "global-\(UUID().uuidString.prefix(6))"] as [String?] {
                for base in ["/var/oases", "/var/minis"] {
                    let host = try XCTUnwrap(router.routedHostURL(normalized: "\(base)/\(subdir)/a/b.md", sessionId: sid))
                    XCTAssertEqual(host.path, dir.appendingPathComponent("a/b.md").path)
                    XCTAssertEqual(router.routedHostURL(normalized: "\(base)/\(subdir)", sessionId: sid)?.path, dir.path)
                }
            }
        }
    }

    func testRootfsAndSessionlessBucketPathsAreNotRouted() {
        XCTAssertNil(router.routedHostURL(normalized: "/usr/bin/python3", sessionId: "s"))
        XCTAssertNil(router.routedHostURL(normalized: "/var/oases", sessionId: "s"))
        XCTAssertNil(router.routedHostURL(normalized: "/var/oases/memoryx/a", sessionId: "s"))
        XCTAssertNil(router.routedHostURL(normalized: "/var/oases/workspace/a", sessionId: nil))
        // File tools still fall back to the rootfs file.
        XCTAssertNotNil(router.hostURL(forGuest: "/usr/bin/python3", sessionId: "s"))
    }

    func testMergeNeverOverwritesAndKeepsBothOnClash() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("legacy")
        let destination = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appendingPathComponent("video.mp4"))
        try Data("new".utf8).write(to: destination.appendingPathComponent("video.mp4"))
        try Data("b".utf8).write(to: source.appendingPathComponent("sub/b.txt"))
        try Data("c".utf8).write(to: destination.appendingPathComponent("sub/c.txt"))
        try Data("d".utf8).write(to: source.appendingPathComponent("only-legacy.txt"))

        let moved = OasesFsRouter.mergeContents(of: source, into: destination, fileManager: fm)

        XCTAssertEqual(moved, 3)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("video.mp4"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("video-oases.mp4"), encoding: .utf8), "old")
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("sub/b.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("sub/c.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("only-legacy.txt").path))
        // Running it again is a no-op.
        XCTAssertEqual(OasesFsRouter.mergeContents(of: source, into: destination, fileManager: fm), 0)
    }

    func testFileBrowserRootLinksTheTreesTheShellUses() throws {
        let fm = FileManager.default
        let sid = "browse-\(UUID().uuidString.prefix(8))"
        let root = AIChatViewModel.prepareFileBrowserRoot(for: sid)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: AIChatViewModel.minisPersistentBase.appendingPathComponent(sid))
        }
        func target(_ name: String) throws -> String {
            URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(name).path)).standardized.path
        }
        for bucket in ["workspace", "attachments", "offloads", "browser"] {
            let routed = try XCTUnwrap(router.routedHostURL(normalized: "/var/minis/\(bucket)", sessionId: sid))
            XCTAssertEqual(try target(bucket), routed.standardized.path, bucket)
        }
        for global in ["shared", "skills", "memory"] {
            let routed = try XCTUnwrap(router.routedHostURL(normalized: "/var/minis/\(global)", sessionId: nil))
            XCTAssertEqual(try target(global), routed.standardized.path, global)
        }
        // Idempotent, and a file put in the view lands in the session tree.
        XCTAssertEqual(AIChatViewModel.prepareFileBrowserRoot(for: sid), root)
        try Data("v".utf8).write(to: root.appendingPathComponent("attachments/view.txt"))
        XCTAssertTrue(fm.fileExists(atPath: AIChatViewModel.minisAttachmentsPersistentDir(for: sid).appendingPathComponent("view.txt").path))
    }

    func testMediaHandoffIsNotANavigationFailure() {
        let handoff = NSError(domain: "WebKitErrorDomain", code: 204)
        XCTAssertTrue(BrowserUseManager.isMediaHandoff(handoff))
        XCTAssertFalse(BrowserUseManager.isMediaHandoff(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(BrowserUseManager.isMediaHandoff(NSError(domain: NSURLErrorDomain, code: 204)))
    }
}
