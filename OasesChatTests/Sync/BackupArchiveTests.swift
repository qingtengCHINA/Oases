import Compression
import SQLite3
import XCTest
@testable import Oases_Chat

/// Restore-side ZIP reader and staged-restore validation: traversal,
/// symlink and truncation inputs must be rejected without writing outside
/// the destination (or crashing).
final class BackupArchiveTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - ZIP builder (stored + raw-deflate entries)

    private struct Entry {
        var name: String
        var payload: Data = Data()
        var deflate = false
        var unixMode: UInt32 = 0o100644
        /// Override the declared uncompressed size (to lie about it).
        var declaredSize: Int? = nil
    }

    private func le16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    private func le32(_ v: Int, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> s) & 0xff)) } }

    private func deflate(_ data: Data) -> Data {
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(n)
    }

    private func makeZip(_ entries: [Entry]) -> Data {
        var body = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let stored = e.deflate ? deflate(e.payload) : e.payload
            let method = e.deflate ? 8 : 0
            let offset = body.count
            le32(0x04034b50, &body); le16(20, &body); le16(0, &body); le16(method, &body)
            le32(0, &body); le32(0, &body)                       // time/date, crc
            le32(stored.count, &body); le32(e.declaredSize ?? e.payload.count, &body)
            le16(name.count, &body); le16(0, &body)
            body.append(name); body.append(stored)

            le32(0x02014b50, &central); le16(0x0314, &central); le16(20, &central)
            le16(0, &central); le16(method, &central); le32(0, &central); le32(0, &central)
            le32(stored.count, &central); le32(e.declaredSize ?? e.payload.count, &central)
            le16(name.count, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le16(0, &central)
            le32(Int(e.unixMode) << 16, &central); le32(offset, &central)
            central.append(name)
        }
        var zip = body
        let cdOffset = zip.count
        zip.append(central)
        le32(0x06054b50, &zip); le16(0, &zip); le16(0, &zip)
        le16(entries.count, &zip); le16(entries.count, &zip)
        le32(central.count, &zip); le32(cdOffset, &zip); le16(0, &zip)
        return zip
    }

    private func write(_ data: Data) throws -> URL {
        let url = workDir.appendingPathComponent("\(UUID().uuidString).zip")
        try data.write(to: url)
        return url
    }

    // MARK: - Extraction

    func testExtractsStoredAndDeflatedEntries() throws {
        let text = String(repeating: "restore me ", count: 5_000)
        let zip = try write(makeZip([
            Entry(name: "backup/", unixMode: 0o040755),
            Entry(name: "backup/a.txt", payload: Data("hello".utf8)),
            Entry(name: "backup/dir/b.txt", payload: Data(text.utf8), deflate: true),
        ]))
        let dest = workDir.appendingPathComponent("out", isDirectory: true)
        try BackupArchive.extract(zipAt: zip, to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("backup/a.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("backup/dir/b.txt"), encoding: .utf8), text)
    }

    func testRejectsPathTraversalWithoutWritingAnything() throws {
        for evil in ["../evil.txt", "backup/../../evil.txt", "/tmp/evil.txt", "backup\\..\\evil.txt"] {
            let zip = try write(makeZip([
                Entry(name: "backup/ok.txt", payload: Data("ok".utf8)),
                Entry(name: evil, payload: Data("pwned".utf8)),
            ]))
            let dest = workDir.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
            XCTAssertThrowsError(try BackupArchive.extract(zipAt: zip, to: dest), evil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("evil.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("backup/ok.txt").path),
                           "a bad entry anywhere aborts before extraction starts")
        }
    }

    func testRejectsSymlinkEntries() throws {
        let zip = try write(makeZip([Entry(name: "backup/link", payload: Data("/etc".utf8), unixMode: 0o120777)]))
        XCTAssertThrowsError(try BackupArchive.extract(zipAt: zip, to: workDir.appendingPathComponent("out")))
    }

    func testTruncatedOrLyingArchivesThrowInsteadOfCrashing() throws {
        let good = makeZip([Entry(name: "backup/a.txt", payload: Data(String(repeating: "z", count: 4096).utf8), deflate: true)])
        for cut in [10, 30, good.count / 2, good.count - 5] {
            let zip = try write(good.prefix(cut))
            XCTAssertThrowsError(try BackupArchive.extract(zipAt: zip, to: workDir.appendingPathComponent("t-\(cut)")))
        }
        // Declares 10 bytes, inflates to 4096: must stop, not overrun.
        let bomb = try write(makeZip([Entry(name: "backup/a.txt", payload: Data(String(repeating: "z", count: 4096).utf8),
                                            deflate: true, declaredSize: 10)]))
        XCTAssertThrowsError(try BackupArchive.extract(zipAt: bomb, to: workDir.appendingPathComponent("bomb")))
    }

    func testSafeRelativePath() {
        XCTAssertEqual(BackupArchive.safeRelativePath("backup/dir/"), "backup/dir")
        XCTAssertEqual(BackupArchive.safeRelativePath("backup//a.txt"), "backup/a.txt")
        XCTAssertNil(BackupArchive.safeRelativePath("backup/./a"))
        XCTAssertNil(BackupArchive.safeRelativePath(".."))
        XCTAssertNil(BackupArchive.safeRelativePath(""))
    }

    // MARK: - Staged restore validation

    func testValidationRequiresHealthyDatabases() throws {
        let content = workDir.appendingPathComponent("content", isDirectory: true)
        let minisDir = content.appendingPathComponent("MinisChat", isDirectory: true)
        try FileManager.default.createDirectory(at: minisDir, withIntermediateDirectories: true)
        let dbURL = minisDir.appendingPathComponent("minis.db")

        try Data("definitely not sqlite".utf8).write(to: dbURL)
        XCTAssertThrowsError(try PendingBackupRestore.validate(contentDir: content, category: .sessions))

        try FileManager.default.removeItem(at: dbURL)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE sessions (id TEXT PRIMARY KEY)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(try PendingBackupRestore.validate(contentDir: content, category: .sessions), [.minisDB])
    }

    func testValidationRejectsArchiveWithNothingToRestore() throws {
        let content = workDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PendingBackupRestore.validate(contentDir: content, category: .full))
    }
}
