import CryptoKit
import XCTest
@testable import Oases_Chat

final class ISHRootfsServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-rootfs-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        try super.tearDownWithError()
    }

    func testVerifyBundleAcceptsMatchingManifest() throws {
        let bundle = try makeBundle()
        let manifest = try ISHRootfsService.verifyBundle(at: bundle)
        XCTAssertEqual(manifest.alpineVersion, "3.21.0")
        XCTAssertEqual(manifest.architecture, "aarch64")
    }

    func testCorruptFileFailsBeforeActiveRootfsChanges() throws {
        let bundle = try makeBundle()
        let dataFile = bundle.appendingPathComponent("data/bin/sh")
        try Data("corrupt".utf8).write(to: dataFile)
        let active = temporaryRoot.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("keep-old-rootfs".utf8).write(to: active.appendingPathComponent("sentinel"))

        XCTAssertThrowsError(try ISHRootfsService.stage(bundleRoot: bundle, activeRoot: active))
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("sentinel")), "keep-old-rootfs")
    }

    func testSuccessfulStageReplacesActiveRootfsAtomically() throws {
        let bundle = try makeBundle()
        let active = temporaryRoot.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: active.appendingPathComponent("sentinel"))

        let manifest = try ISHRootfsService.stage(bundleRoot: bundle, activeRoot: active)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.appendingPathComponent("sentinel").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.appendingPathComponent("data/bin/sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.appendingPathComponent("meta.db").path))
    }

    func testManifestRejectsTraversalAndSymlinkEntries() throws {
        let bundle = try makeBundle()
        let manifestURL = bundle.appendingPathComponent("rootfs-manifest.json")
        let traversal = RootfsManifest(
            schemaVersion: 1,
            alpineVersion: "3.21.0",
            architecture: "aarch64",
            files: ["../outside": String(repeating: "0", count: 64)],
            runtimeOverlayVersion: 1
        )
        try JSONEncoder().encode(traversal).write(to: manifestURL)
        XCTAssertThrowsError(try ISHRootfsService.verifyBundle(at: bundle))

        let safeManifest = try makeManifest(for: bundle)
        let link = bundle.appendingPathComponent("data/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle.appendingPathComponent("data/bin/sh"))
        let symlinkManifest = RootfsManifest(
            schemaVersion: safeManifest.schemaVersion,
            alpineVersion: safeManifest.alpineVersion,
            architecture: safeManifest.architecture,
            files: safeManifest.files.merging(["data/link": safeManifest.files["data/bin/sh"]!]) { current, _ in current },
            runtimeOverlayVersion: safeManifest.runtimeOverlayVersion
        )
        try JSONEncoder().encode(symlinkManifest).write(to: manifestURL)
        XCTAssertThrowsError(try ISHRootfsService.verifyBundle(at: bundle))
    }

    func testUnsupportedArchitectureIsRejected() throws {
        let bundle = try makeBundle()
        let manifestURL = bundle.appendingPathComponent("rootfs-manifest.json")
        let original = try makeManifest(for: bundle)
        let wrong = RootfsManifest(
            schemaVersion: original.schemaVersion,
            alpineVersion: original.alpineVersion,
            architecture: "x86_64",
            files: original.files,
            runtimeOverlayVersion: original.runtimeOverlayVersion
        )
        try JSONEncoder().encode(wrong).write(to: manifestURL)
        XCTAssertThrowsError(try ISHRootfsService.verifyBundle(at: bundle))
    }

    private func makeBundle() throws -> URL {
        let bundle = temporaryRoot.appendingPathComponent("bundle", isDirectory: true)
        let data = bundle.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("etc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("sbin"), withIntermediateDirectories: true)
        try Data("shell".utf8).write(to: data.appendingPathComponent("bin/sh"))
        try Data("init".utf8).write(to: data.appendingPathComponent("sbin/init"))
        try Data("3.21.0\n".utf8).write(to: data.appendingPathComponent("etc/alpine-release"))
        try Data("sqlite".utf8).write(to: bundle.appendingPathComponent("meta.db"))
        _ = try makeManifest(for: bundle)
        return bundle
    }

    @discardableResult
    private func makeManifest(for bundle: URL) throws -> RootfsManifest {
        let paths = ["meta.db", "data/bin/sh", "data/sbin/init", "data/etc/alpine-release"]
        let files = Dictionary(uniqueKeysWithValues: try paths.map { path in
            let data = try Data(contentsOf: bundle.appendingPathComponent(path))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (path, hash)
        })
        let manifest = RootfsManifest(schemaVersion: 1, alpineVersion: "3.21.0", architecture: "aarch64", files: files, runtimeOverlayVersion: 1)
        try JSONEncoder().encode(manifest).write(to: bundle.appendingPathComponent("rootfs-manifest.json"))
        return manifest
    }
}
