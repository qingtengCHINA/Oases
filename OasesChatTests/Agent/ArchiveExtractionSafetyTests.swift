import Compression
import XCTest
@testable import Oases_Chat

/// Zip slip / malformed-archive regression tests for skill import
/// (`SkillStore.readZipEntries` / `bundledZipFiles`, including skill assets
/// arriving through iCloud sync) and `TarGzExtractor`.
@MainActor
final class ArchiveExtractionSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Path guard

    func testSanitizedRelativePath() {
        XCTAssertEqual(ArchivePathGuard.sanitizedRelativePath("scripts/run.sh"), "scripts/run.sh")
        XCTAssertEqual(ArchivePathGuard.sanitizedRelativePath("./a//b/./c/"), "a/b/c")
        for unsafe in ["", "/etc/passwd", "../x", "a/../../x", "a/..", "..", "a\\..\\b", "a\0b", "./", "//"] {
            XCTAssertNil(ArchivePathGuard.sanitizedRelativePath(unsafe), unsafe)
        }
    }

    func testDestinationRefusesSymlinkComponents() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dest.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertThrowsError(try ArchivePathGuard.destination(for: "link/pwned.txt", under: dest))
        XCTAssertThrowsError(try ArchivePathGuard.destination(for: "link", under: dest))
        XCTAssertThrowsError(try ArchivePathGuard.destination(for: "../outside/x", under: dest))
        XCTAssertEqual(
            try ArchivePathGuard.destination(for: "a/b.txt", under: dest).path,
            dest.appendingPathComponent("a/b.txt").path)
    }

    func testSkillIdValidation() {
        XCTAssertTrue(SkillStore.isSafeSkillId("tavily-search"))
        XCTAssertTrue(SkillStore.isSafeSkillId("技能-1"))
        for unsafe in ["", ".", "..", "../x", "a/b", ".hidden", "a\\b", "/abs"] {
            XCTAssertFalse(SkillStore.isSafeSkillId(unsafe), unsafe)
        }
    }

    // MARK: - Zip

    func testValidZipRoundTrips() throws {
        let zip = SkillStore.buildZipArchive(files: [
            (relativePath: "SKILL.md", data: Data("---\nname: x\n---\n".utf8)),
            (relativePath: "scripts/run.sh", data: Data("echo hi\n".utf8)),
        ])
        let files = try SkillStore.bundledZipFiles(SkillStore.readZipEntries(data: zip))
        XCTAssertEqual(files.map(\.path), ["SKILL.md", "scripts/run.sh"])
        XCTAssertEqual(files.last?.data, Data("echo hi\n".utf8))
        // Reading from a Data slice (non-zero startIndex) must work too.
        let padded = Data([0, 0, 0]) + zip
        XCTAssertEqual(try SkillStore.readZipEntries(data: padded[3...]).count, 2)
    }

    func testTraversalAndAbsoluteEntriesAreRejected() throws {
        for name in ["../../Library/Preferences/evil.plist", "/etc/evil", "scripts/../../evil", "..\\evil"] {
            let zip = SkillStore.buildZipArchive(files: [
                (relativePath: "SKILL.md", data: Data("x".utf8)),
                (relativePath: name, data: Data("pwned".utf8)),
            ])
            XCTAssertThrowsError(try SkillStore.bundledZipFiles(SkillStore.readZipEntries(data: zip)), name) { error in
                guard case SkillError.unsafeArchiveEntry(_) = error else {
                    return XCTFail("unexpected error \(error) for \(name)")
                }
            }
        }
    }

    func testSymlinkEntryIsRejected() {
        let zip = makeZip([ZipSpec(name: "scripts", payload: Data("/etc".utf8), externalAttributes: 0o120777 << 16)])
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: zip)) { error in
            guard case SkillError.unsafeArchiveEntry(_) = error else { return XCTFail("\(error)") }
        }
    }

    func testTruncatedAndCorruptZipsThrowInsteadOfCrashing() {
        let zip = SkillStore.buildZipArchive(files: [
            (relativePath: "SKILL.md", data: Data(repeating: 0x41, count: 300)),
            (relativePath: "scripts/a.py", data: Data(repeating: 0x42, count: 300)),
        ])
        // Every truncation either throws or reads cleanly — never traps.
        for length in stride(from: 0, to: zip.count, by: 7) {
            _ = try? SkillStore.readZipEntries(data: zip.prefix(length))
        }
        let eocd = zip.count - 22
        let cdOffset = Int(readU32(zip, eocd + 16))
        // Central directory offset past the end.
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: patched(zip, at: eocd + 16, u32: 0xFFFF_FFF0)))
        // Entry count larger than the directory holds.
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: patched(zip, at: eocd + 10, u16: 500)))
        // Name length running past the directory.
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: patched(zip, at: cdOffset + 28, u16: 0xFFFF)))
        // Local header offset past the end.
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: patched(zip, at: cdOffset + 42, u32: 0x7FFF_FFFF)))
        // Stored entry whose declared size doesn't match its data.
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: patched(zip, at: cdOffset + 24, u32: 301)))
    }

    func testSizeLimitsAreEnforced() {
        let zip = SkillStore.buildZipArchive(files: [(relativePath: "big.bin", data: Data(count: 4096))])
        var limits = SkillStore.ZipLimits()
        limits.maxEntryBytes = 1024
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: zip, limits: limits)) { error in
            guard case SkillError.archiveTooLarge = error else { return XCTFail("\(error)") }
        }
        limits = SkillStore.ZipLimits()
        limits.maxEntries = 1
        let two = SkillStore.buildZipArchive(files: [
            (relativePath: "a", data: Data("a".utf8)), (relativePath: "b", data: Data("b".utf8)),
        ])
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: two, limits: limits))
    }

    func testDeflateEntryCannotOutgrowItsDeclaredSize() throws {
        let original = Data(repeating: 0, count: 1 << 20)
        let deflated = try XCTUnwrap(rawDeflate(original))
        // Honest header: inflates exactly.
        let honest = makeZip([ZipSpec(name: "zeros", method: 8, payload: deflated, uncompressedSize: UInt32(original.count))])
        XCTAssertEqual(try SkillStore.readZipEntries(data: honest).first?.data, original)
        // Bomb-style header understating the size: output stays capped.
        let understated = makeZip([ZipSpec(name: "zeros", method: 8, payload: deflated, uncompressedSize: 100)])
        XCTAssertEqual(try SkillStore.readZipEntries(data: understated).first?.data.count, 100)
        // Overstated size (truncated/corrupt stream) is rejected.
        let overstated = makeZip([ZipSpec(name: "zeros", method: 8, payload: deflated, uncompressedSize: UInt32(original.count + 10))])
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: overstated))
        // Truncated DEFLATE data.
        let cut = makeZip([ZipSpec(name: "zeros", method: 8, payload: deflated.prefix(deflated.count / 2), uncompressedSize: UInt32(original.count))])
        XCTAssertThrowsError(try SkillStore.readZipEntries(data: cut))
    }

    func testImportFromArchiveRejectsZipSlipBeforeWritingAnything() throws {
        let marker = "zip-slip-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let escaped = AIChatViewModel.minisSkillsPersistentDir
            .appendingPathComponent("../\(marker).txt").standardizedFileURL
        let zip = SkillStore.buildZipArchive(files: [
            (relativePath: "SKILL.md", data: Data("---\nname: \(marker)\ndescription: probe\n---\nbody\n".utf8)),
            (relativePath: "../\(marker).txt", data: Data("pwned".utf8)),
        ])
        let url = root.appendingPathComponent("slip.zip")
        try zip.write(to: url)

        XCTAssertThrowsError(try SkillStore.shared.importFromArchive(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        XCTAssertFalse(SkillStore.shared.skills.contains { $0.id == marker })
    }

    // MARK: - tar.gz

    func testTarTraversalIsRejected() throws {
        let archive = try writeTarGz([
            TarSpec(name: "ok.txt", data: Data("ok".utf8)),
            TarSpec(name: "../escaped.txt", data: Data("pwned".utf8)),
        ])
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: archive, to: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    func testTarSymlinksStayInsideDestination() throws {
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let archive = try writeTarGz([
            TarSpec(name: "bin/busybox", data: Data("bb".utf8)),
            TarSpec(name: "bin/sh", type: UInt8(ascii: "2"), link: "/bin/busybox"),
            TarSpec(name: "lib/ld.so", type: UInt8(ascii: "2"), link: "../bin/busybox"),
        ])
        XCTAssertEqual(try TarGzExtractor.extract(archive: archive, to: dest), 3)
        let shTarget = try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("bin/sh").path)
        XCTAssertEqual(shTarget, "../bin/busybox") // absolute target re-rooted at dest
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("bin/sh"), encoding: .utf8), "bb")

        let escaping = try writeTarGz([TarSpec(name: "evil", type: UInt8(ascii: "2"), link: "../../etc")])
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: escaping, to: root.appendingPathComponent("d2")))
    }

    func testTarCannotWriteThroughItsOwnSymlink() throws {
        let archive = try writeTarGz([
            TarSpec(name: "sub/", type: UInt8(ascii: "5")),
            TarSpec(name: "lnk", type: UInt8(ascii: "2"), link: "sub"),
            TarSpec(name: "lnk/file.txt", data: Data("x".utf8)),
        ])
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: archive, to: root.appendingPathComponent("dest")))
    }

    func testTruncatedOrMalformedTarGzThrows() throws {
        let raw = tar([TarSpec(name: "a.txt", data: Data(repeating: 0x61, count: 2000))])
        // Payload shorter than the header claims.
        let short = root.appendingPathComponent("short.tar.gz")
        try gzip(raw.prefix(900)).write(to: short)
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: short, to: root.appendingPathComponent("d1")))
        // Truncated gzip stream.
        let full = gzip(raw)
        for length in [0, 5, 18, full.count / 2] {
            let url = root.appendingPathComponent("cut-\(length).tar.gz")
            try full.prefix(length).write(to: url)
            XCTAssertThrowsError(try TarGzExtractor.extract(archive: url, to: root.appendingPathComponent("d-\(length)")))
        }
        // Negative size field.
        var header = tarHeader(name: "neg", size: 0, type: UInt8(ascii: "0"))
        header.replaceSubrange(124..<136, with: Data("-0000000001\0".utf8))
        let negative = root.appendingPathComponent("neg.tar.gz")
        try gzip(header + Data(count: 1024)).write(to: negative)
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: negative, to: root.appendingPathComponent("d3")))
    }

    func testGzipOutputIsCapped() throws {
        let raw = tar([TarSpec(name: "zeros", data: Data(count: 4 << 20))])
        let url = root.appendingPathComponent("bomb.tar.gz")
        try gzip(raw).write(to: url)
        var limits = TarGzExtractor.Limits()
        limits.maxUncompressedBytes = 1 << 20
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: url, to: root.appendingPathComponent("d"), limits: limits))
    }

    // MARK: - Builders

    private struct ZipSpec {
        var name: String
        var method: UInt16 = 0
        var payload: Data
        var uncompressedSize: UInt32?
        var externalAttributes: UInt32 = 0
    }

    private func makeZip(_ entries: [ZipSpec]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = entry.uncompressedSize ?? UInt32(entry.payload.count)
            let offset = UInt32(archive.count)
            archive.u32(0x04034B50); archive.u16(20); archive.u16(0); archive.u16(entry.method)
            archive.u16(0); archive.u16(0); archive.u32(0)
            archive.u32(UInt32(entry.payload.count)); archive.u32(size)
            archive.u16(UInt16(name.count)); archive.u16(0)
            archive.append(name); archive.append(entry.payload)

            directory.u32(0x02014B50); directory.u16(0x031E); directory.u16(20); directory.u16(0)
            directory.u16(entry.method); directory.u16(0); directory.u16(0); directory.u32(0)
            directory.u32(UInt32(entry.payload.count)); directory.u32(size)
            directory.u16(UInt16(name.count)); directory.u16(0); directory.u16(0); directory.u16(0); directory.u16(0)
            directory.u32(entry.externalAttributes); directory.u32(offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.u32(0x06054B50); archive.u16(0); archive.u16(0)
        archive.u16(UInt16(entries.count)); archive.u16(UInt16(entries.count))
        archive.u32(UInt32(directory.count)); archive.u32(directoryOffset); archive.u16(0)
        return archive
    }

    private func patched(_ data: Data, at offset: Int, u16 value: UInt16) -> Data {
        var copy = data
        copy[offset] = UInt8(value & 0xFF)
        copy[offset + 1] = UInt8(value >> 8)
        return copy
    }

    private func patched(_ data: Data, at offset: Int, u32 value: UInt32) -> Data {
        var copy = data
        for i in 0..<4 { copy[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        return copy
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }

    private func rawDeflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private struct TarSpec {
        var name: String
        var type: UInt8 = UInt8(ascii: "0")
        var link: String = ""
        var data: Data = Data()
    }

    private func tarHeader(name: String, size: Int, type: UInt8, link: String = "") -> Data {
        var header = Data(count: 512)
        header.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
        header.replaceSubrange(100..<108, with: Data("0000644\0".utf8))
        let sizeField = String(size, radix: 8)
        let padded = String(repeating: "0", count: max(0, 11 - sizeField.count)) + sizeField + "\0"
        header.replaceSubrange(124..<136, with: Data(padded.utf8))
        header[156] = type
        if !link.isEmpty {
            header.replaceSubrange(157..<(157 + link.utf8.count), with: Data(link.utf8))
        }
        header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        return header
    }

    private func tar(_ entries: [TarSpec]) -> Data {
        var out = Data()
        for entry in entries {
            out.append(tarHeader(name: entry.name, size: entry.data.count, type: entry.type, link: entry.link))
            out.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 { out.append(Data(count: 512 - remainder)) }
        }
        out.append(Data(count: 1024))
        return out
    }

    private func gzip(_ raw: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0x03])
        out.append(rawDeflate(raw) ?? Data())
        out.u32(0) // CRC (not checked by the extractor)
        out.u32(UInt32(truncatingIfNeeded: raw.count))
        return out
    }

    private func writeTarGz(_ entries: [TarSpec]) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).tar.gz")
        try gzip(tar(entries)).write(to: url)
        return url
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (8 * UInt32(i))) & 0xFF)) }
    }
}
