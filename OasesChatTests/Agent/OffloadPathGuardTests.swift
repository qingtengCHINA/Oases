import XCTest
@testable import Oases_Chat

/// Code review 2026-09-29 (3.6 P0/P1): offload path arguments must stay inside
/// the guest-visible tree — no host sandbox paths, no `..` or symlink escapes.
final class OffloadPathGuardTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var dataRoot: URL!
    private var sessionRoot: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("offload-guard-\(UUID().uuidString)", isDirectory: true)
        dataRoot = root.appendingPathComponent("data", isDirectory: true)
        sessionRoot = root.appendingPathComponent("sessions/sid-1/workspace", isDirectory: true)
        outside = root.appendingPathComponent("Library", isDirectory: true)
        for dir in [dataRoot.appendingPathComponent("tmp"), sessionRoot!, outside!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("guest".utf8).write(to: dataRoot.appendingPathComponent("tmp/a.txt"))
        try Data("work".utf8).write(to: sessionRoot.appendingPathComponent("w.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("env-vars.json"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var roots: [String] { [dataRoot.path, sessionRoot.path] }

    /// Guest paths map into the fake data root, like `noff_resolve_host_path`.
    private func translate(_ guestPath: String) -> String? {
        dataRoot.path + guestPath
    }

    private func resolve(_ path: String, cwd: String? = nil, mount: ((String) -> Bool)? = nil) throws -> String {
        try OffloadPathGuard.resolve(
            path: path,
            cwd: cwd,
            allowedRoots: roots,
            translateGuestPath: translate,
            isGuestVisibleMount: mount
        )
    }

    private func assertRejected(_ path: String, cwd: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try resolve(path, cwd: cwd), "expected rejection: \(path)", file: file, line: line)
    }

    func testKernelTranslatedPathInsideRootIsAccepted() throws {
        let path = dataRoot.appendingPathComponent("tmp/a.txt").path
        XCTAssertEqual(try resolve(path), OffloadPathGuard.canonicalPath(path))
    }

    func testRawGuestPathIsTranslatedAndClampedAtGuestRoot() throws {
        let expected = OffloadPathGuard.canonicalPath(dataRoot.appendingPathComponent("tmp/a.txt").path)
        XCTAssertEqual(try resolve("/tmp/a.txt"), expected)
        XCTAssertEqual(try resolve("/../../tmp/a.txt"), expected)
    }

    func testHostSandboxPathsAreRejected() {
        assertRejected("/var/mobile/Containers/Data/Application/ABC/Library/MinisChat/env-vars.json")
        assertRejected("/private/var/mobile/Containers/Shared/AppGroup/ABC/MinisConfig/mcp-servers/servers.json")
        assertRejected(outside.appendingPathComponent("env-vars.json").path)
        assertRejected(NSHomeDirectory() + "/Library/Preferences/dev.oases.chat.ios.plist")
    }

    func testDotDotEscapesAreRejected() {
        // What `--output /../meta.db` looked like after kernel translation.
        assertRejected(dataRoot.path + "/../meta.db")
        assertRejected(dataRoot.path + "/tmp/../../Library/env-vars.json")
        assertRejected("../../../Library/env-vars.json", cwd: sessionRoot.path)
    }

    func testSymlinkEscapesAreRejected() throws {
        let tmp = dataRoot.appendingPathComponent("tmp")
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("leak").path,
                                  withDestinationPath: outside.appendingPathComponent("env-vars.json").path)
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("dirlink").path,
                                  withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("dangling").path,
                                  withDestinationPath: outside.appendingPathComponent("new.txt").path)
        assertRejected(tmp.appendingPathComponent("leak").path)
        assertRejected(tmp.appendingPathComponent("dirlink/env-vars.json").path)
        // A write through a dangling link would create a file outside the tree.
        assertRejected(tmp.appendingPathComponent("dangling").path)
        assertRejected("/tmp/leak")
    }

    func testSymlinkStayingInsideIsResolved() throws {
        let tmp = dataRoot.appendingPathComponent("tmp")
        try fm.createSymbolicLink(atPath: tmp.appendingPathComponent("alias").path,
                                  withDestinationPath: sessionRoot.appendingPathComponent("w.txt").path)
        XCTAssertEqual(try resolve(tmp.appendingPathComponent("alias").path),
                       OffloadPathGuard.canonicalPath(sessionRoot.appendingPathComponent("w.txt").path))
    }

    func testWriteTargetThatDoesNotExistYet() throws {
        let target = dataRoot.appendingPathComponent("tmp/out/new.png").path
        XCTAssertEqual(try resolve(target), OffloadPathGuard.canonicalPath(target))
    }

    func testRelativePathsResolveAgainstCwd() throws {
        XCTAssertEqual(try resolve("w.txt", cwd: sessionRoot.path),
                       OffloadPathGuard.canonicalPath(sessionRoot.appendingPathComponent("w.txt").path))
        assertRejected("w.txt", cwd: nil)
        assertRejected("")
    }

    func testTranslationLandingOutsideTheRootsIsRejected() {
        XCTAssertThrowsError(try OffloadPathGuard.resolve(
            path: "/etc/passwd",
            cwd: nil,
            allowedRoots: roots,
            translateGuestPath: { _ in self.outside.appendingPathComponent("env-vars.json").path },
            isGuestVisibleMount: nil
        ))
    }

    func testMountedFolderIsOnlyReachableThroughTheMountCheck() throws {
        let secret = outside.appendingPathComponent("env-vars.json").path
        let mountRoot = OffloadPathGuard.canonicalPath(outside.path)
        XCTAssertEqual(try resolve(secret, mount: { $0.hasPrefix(mountRoot) }), OffloadPathGuard.canonicalPath(secret))
        assertRejected(secret)
    }

    func testLexicalNormalisation() {
        XCTAssertEqual(OffloadPathGuard.lexicallyNormalized("/a/./b//c/../d"), "/a/b/d")
        XCTAssertEqual(OffloadPathGuard.lexicallyNormalized("/../../etc"), "/etc")
        XCTAssertEqual(OffloadPathGuard.lexicallyNormalized("/"), "/")
    }

    // MARK: - minis-sessions-cli --attach backstop

    func testAttachmentBackstopAllowsOnlyGuestVisibleBuckets() throws {
        let sessions = root.appendingPathComponent("sessions")
        let shared = root.appendingPathComponent("shared")
        try fm.createDirectory(at: sessions.appendingPathComponent("_global/memory"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: sessions.appendingPathComponent("sid-1/chat.db"))
        try Data("m".utf8).write(to: sessions.appendingPathComponent("_global/memory/m.md"))
        try fm.createSymbolicLink(atPath: dataRoot.appendingPathComponent("tmp/leak").path,
                                  withDestinationPath: outside.appendingPathComponent("env-vars.json").path)

        let allowed: (String) -> Bool = {
            OffloadPathGuard.isAllowedAttachmentHostPath(
                $0, dataRoot: self.dataRoot.path, sessionBases: [sessions.path], sharedRoots: [shared.path])
        }
        let guestFile = dataRoot.appendingPathComponent("tmp/a.txt").path
        let workspaceFile = sessionRoot.appendingPathComponent("w.txt").path
        let secret = outside.appendingPathComponent("env-vars.json").path
        let leak = dataRoot.appendingPathComponent("tmp/leak").path

        XCTAssertTrue(allowed(guestFile))
        XCTAssertTrue(allowed(workspaceFile))
        XCTAssertFalse(allowed(secret))
        XCTAssertFalse(allowed(leak))
        XCTAssertFalse(allowed(dataRoot.path + "/../Library/env-vars.json"))
        XCTAssertFalse(allowed(sessions.appendingPathComponent("sid-1/chat.db").path))
        XCTAssertFalse(allowed(sessions.appendingPathComponent("_global/memory/m.md").path))
        XCTAssertFalse(allowed("relative.txt"))

        let built = SessionsOffloadBridge.attachments(
            fromHostPaths: [guestFile, secret, leak, workspaceFile],
            isAllowed: allowed
        )
        XCTAssertEqual(built.map(\.name), ["a.txt", "w.txt"])
        XCTAssertEqual(built.first?.textContent, "guest")
    }

    func testProductionAttachmentBackstopRejectsAppSandbox() {
        XCTAssertFalse(OffloadPathGuard.isAllowedAttachmentHostPath(NSHomeDirectory() + "/Library/Preferences/x.plist"))
        XCTAssertFalse(OffloadPathGuard.isAllowedAttachmentHostPath(
            "/var/mobile/Containers/Data/Application/ABC/Library/MinisChat/env-vars.json"))
        XCTAssertFalse(OffloadPathGuard.isAllowedAttachmentHostPath(ISHRootfsManager.dataURL.path + "/../meta.db"))
        XCTAssertFalse(OffloadPathGuard.isAllowedAttachmentHostPath(
            AIChatViewModel.minisPersistentBase.appendingPathComponent("../env-vars.json").path))
    }
}
