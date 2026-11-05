import XCTest
@testable import Oases_Chat

/// Rootfs v2 (preinstalled toolchain): directory materialization, user-data
/// migration across rootfs upgrades, and the prompt inventory.
final class RootfsUpgradeTests: XCTestCase {
    private var temporaryRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("oases-rootfs-upgrade-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: temporaryRoot)
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private let dirMode: UInt32 = 0o040755
    private let fileMode: UInt32 = 0o100644

    /// A minimal fakefs tree: `entries` maps guest path → file content
    /// (nil for a directory). Rows are created for every entry.
    private func makeRootfs(_ name: String, entries: [String: String?], hostOnly: [String: String] = [:]) throws -> URL {
        let root = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try FakefsMetadataStore.create(at: root.appendingPathComponent("meta.db"))
        defer { store.close() }
        for (path, content) in entries.sorted(by: { $0.key < $1.key }) {
            let host = data.appendingPathComponent(String(path.dropFirst()))
            if let content {
                try fm.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: host)
                try store.upsert(path: path, stat: FakefsMetadataStore.stat(mode: fileMode))
            } else {
                try fm.createDirectory(at: host, withIntermediateDirectories: true)
                try store.upsert(path: path, stat: FakefsMetadataStore.stat(mode: dirMode))
            }
        }
        for (path, content) in hostOnly {
            let host = data.appendingPathComponent(String(path.dropFirst()))
            try fm.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: host)
        }
        return root
    }

    private func rowPaths(_ root: URL, under prefix: String) throws -> [String] {
        let store = try FakefsMetadataStore(url: root.appendingPathComponent("meta.db"))
        defer { store.close() }
        return try store.rows(under: prefix).map(\.path)
    }

    private func content(_ root: URL, _ guestPath: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent("data").appendingPathComponent(String(guestPath.dropFirst())), encoding: .utf8)
    }

    // MARK: Store

    func testStatBlobRoundTripsLittleEndianMode() {
        let blob = FakefsMetadataStore.stat(mode: 0o041777, uid: 0, gid: 42)
        XCTAssertEqual(blob.count, 16)
        XCTAssertEqual(FakefsMetadataStore.mode(of: blob), 0o041777)
        XCTAssertEqual(Array(blob[8..<12]), [42, 0, 0, 0])
    }

    func testRowsUnderPrefixDoesNotMatchSiblingsWithSamePrefix() throws {
        let root = try makeRootfs("prefix", entries: [
            "/root": nil, "/root/a.txt": "a", "/rootless": nil, "/rootless/b.txt": "b",
        ])
        XCTAssertEqual(try rowPaths(root, under: "/root"), ["/root", "/root/a.txt"])
    }

    // MARK: Materialization

    func testMaterializeRecreatesEmptyDirectoriesDroppedByGit() throws {
        let root = try makeRootfs("materialize", entries: ["/tmp": nil, "/var": nil, "/var/cache": nil, "/var/cache/apk": nil])
        let tmp = root.appendingPathComponent("data/tmp")
        let apkCache = root.appendingPathComponent("data/var/cache/apk")
        try fm.removeItem(at: tmp)
        try fm.removeItem(at: root.appendingPathComponent("data/var"))

        XCTAssertEqual(ISHRootfsService.materializeDirectories(in: root), 4)
        XCTAssertTrue(fm.fileExists(atPath: tmp.path))
        XCTAssertTrue(fm.fileExists(atPath: apkCache.path))
    }

    func testMaterializeIgnoresTreesWithoutFakefsDatabase() throws {
        let root = temporaryRoot.appendingPathComponent("not-fakefs", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: root.appendingPathComponent("meta.db"))
        XCTAssertEqual(ISHRootfsService.materializeDirectories(in: root), 0)
    }

    // MARK: Migration

    func testMigrationCarriesUserSubtreesWithRowsAndKeepsNewSystemFiles() throws {
        let old = try makeRootfs("old", entries: [
            "/root": nil,
            "/root/.ogent": nil,
            "/root/.ogent/memory": nil,
            "/root/.ogent/memory/notes.md": "remember me",
            "/usr": nil,
            "/usr/bin": nil,
            "/usr/bin/tool": "old-system-binary",
            "/usr/local": nil,
            "/usr/local/bin": nil,
            "/usr/local/bin/mine.sh": "echo mine",
            "/etc": nil,
            "/etc/apk": nil,
            "/etc/apk/world": "busybox\npython3~3.12\nnodejs\n",
        ], hostOnly: ["/root/.ogent/models/model.gguf": "GGUF-host-only"])
        let new = try makeRootfs("new", entries: [
            "/root": nil,
            "/usr": nil,
            "/usr/bin": nil,
            "/usr/bin/tool": "new-system-binary",
            "/usr/bin/ffmpeg": "ffmpeg",
            "/usr/local": nil,
            "/usr/local/bin": nil,
            "/etc": nil,
            "/etc/apk": nil,
            "/etc/apk/world": "busybox\npython3\nffmpeg\n",
        ])

        let report = try ISHRootfsService.migrateUserData(from: old, into: new, bundledPackages: ["busybox", "python3", "ffmpeg"])

        // User data carried, with rows, so the guest can see it.
        XCTAssertEqual(content(new, "/root/.ogent/memory/notes.md"), "remember me")
        XCTAssertTrue(try rowPaths(new, under: "/root").contains("/root/.ogent/memory/notes.md"))
        XCTAssertEqual(content(new, "/usr/local/bin/mine.sh"), "echo mine")
        XCTAssertTrue(try rowPaths(new, under: "/usr/local").contains("/usr/local/bin/mine.sh"))
        // Host-only files (written by the app, never registered) still come along.
        XCTAssertEqual(content(new, "/root/.ogent/models/model.gguf"), "GGUF-host-only")
        // System files come from the new bundle.
        XCTAssertEqual(content(new, "/usr/bin/tool"), "new-system-binary")
        XCTAssertEqual(try rowPaths(new, under: "/usr/bin"), ["/usr/bin", "/usr/bin/ffmpeg", "/usr/bin/tool"])
        // Packages the old rootfs had but the bundle lacks are recorded for ogent-need --restore.
        XCTAssertEqual(report.droppedPackages, ["nodejs"])
        XCTAssertTrue(content(new, ISHRootfsService.previousWorldGuestPath)?.contains("nodejs") == true)
        XCTAssertTrue(try rowPaths(new, under: "/root/.ogent/rootfs-profiles").contains(ISHRootfsService.previousWorldGuestPath))
        XCTAssertGreaterThan(report.carriedRows, 5)
    }

    func testMigrationSkipsRowsWhoseHostFileVanished() throws {
        let old = try makeRootfs("old-split", entries: ["/root": nil, "/root/gone.txt": "x", "/root/kept.txt": "y"])
        try fm.removeItem(at: old.appendingPathComponent("data/root/gone.txt"))
        let new = try makeRootfs("new-split", entries: ["/root": nil])

        let report = try ISHRootfsService.migrateUserData(from: old, into: new, bundledPackages: [])
        XCTAssertEqual(report.skippedRows, 1)
        XCTAssertEqual(try rowPaths(new, under: "/root"), ["/root", "/root/kept.txt"])
        XCTAssertTrue(report.droppedPackages.isEmpty)
        XCTAssertNil(content(new, ISHRootfsService.previousWorldGuestPath))
    }

    // MARK: Interrupted staging

    func testRecoveryRestoresPreviousTreeWhenActiveIsMissing() throws {
        let parent = temporaryRoot.appendingPathComponent("support", isDirectory: true)
        let active = parent.appendingPathComponent("iSH-rootfs", isDirectory: true)
        let previous = try makeRootfs("support/.iSH-rootfs-previous-A", entries: ["/root": nil, "/root/keep.txt": "mine"])
        _ = try makeRootfs("support/.iSH-rootfs-staging-B", entries: ["/root": nil])

        XCTAssertTrue(ISHRootfsService.recoverInterruptedStage(activeRoot: active))
        XCTAssertEqual(content(active, "/root/keep.txt"), "mine")
        XCTAssertFalse(fm.fileExists(atPath: previous.path))
        let leftovers = try fm.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".iSH-rootfs-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRecoveryKeepsIntactActiveTreeAndDropsLeftovers() throws {
        let parent = temporaryRoot.appendingPathComponent("support2", isDirectory: true)
        let active = try makeRootfs("support2/iSH-rootfs", entries: ["/root": nil, "/root/current.txt": "new"])
        _ = try makeRootfs("support2/.iSH-rootfs-previous-A", entries: ["/root": nil, "/root/current.txt": "old"])

        XCTAssertFalse(ISHRootfsService.recoverInterruptedStage(activeRoot: active))
        XCTAssertEqual(content(active, "/root/current.txt"), "new")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: parent.path), ["iSH-rootfs"])
    }

    // MARK: Bundled rootfs v2

    func testBundledRootfsShipsPreinstalledToolchain() throws {
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "AlpineFakefs", withExtension: nil))
        let manifest = try ISHRootfsService.verifyBundle(at: bundle)
        XCTAssertGreaterThanOrEqual(manifest.effectiveRootfsVersion, 2)
        let packages = Set(manifest.packages ?? [])
        for required in ["python3", "curl", "ffmpeg", "yt-dlp-core", "uv", "git", "py3-requests", "py3-pillow"] {
            XCTAssertTrue(packages.contains(required), "missing \(required)")
        }
        let store = try FakefsMetadataStore(url: bundle.appendingPathComponent("meta.db"), readOnly: true)
        defer { store.close() }
        for path in ["/usr/bin/ffmpeg", "/usr/bin/yt-dlp", "/usr/bin/python3", "/usr/bin/curl", "/tmp", "/var/cache/apk"] {
            XCTAssertTrue(try store.contains(path), "meta.db lacks \(path)")
        }
    }

    // MARK: Inventory

    func testInventoryListsInstalledCommandsAndModules() throws {
        let data = temporaryRoot.appendingPathComponent("inventory/data", isDirectory: true)
        for relative in ["usr/bin/python3", "usr/bin/ffmpeg", "bin/bash", "usr/lib/python3.12/site-packages/requests/__init__.py",
                         "usr/lib/python3.12/site-packages/yaml/__init__.py", "usr/lib/python3.12/site-packages/brotli.cpython-312-aarch64-linux-musl.so"] {
            let url = data.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let snapshot = OgentToolInventory.snapshot(dataURL: data)
        XCTAssertEqual(snapshot.commands, ["python3", "bash", "ffmpeg"])
        XCTAssertEqual(snapshot.pythonModules, ["requests", "pyyaml", "brotli"])

        let text = OgentToolInventory.promptSection(for: snapshot)
        XCTAssertTrue(text.contains("Already installed: python3, bash, ffmpeg."))
        XCTAssertTrue(text.contains("ogent-need"))
        XCTAssertFalse(text.contains("ogent-need --restore"))
    }
}
