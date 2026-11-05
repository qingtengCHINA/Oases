import XCTest
@testable import Oases_Chat

/// The file browser's delete moves items to Recently Deleted; nothing is removed outright, and a
/// symlink's target is never touched.
@MainActor
final class FileTrashTests: XCTestCase {
    private final class FakeMetadata: FakefsMetadataStoring {
        var rows: [String: Data] = [:]
        func fakefsRows(under linuxPath: String) -> [FakefsMetadataRow] {
            rows.filter { $0.key == linuxPath || $0.key.hasPrefix(linuxPath + "/") }
                .map { FakefsMetadataRow(path: $0.key, stat: $0.value) }
        }
        func removeFakefsPath(_ linuxPath: String) {
            rows = rows.filter { !($0.key == linuxPath || $0.key.hasPrefix(linuxPath + "/")) }
        }
        func restoreFakefsRows(_ restored: [FakefsMetadataRow]) {
            for row in restored { rows[row.path] = row.stat }
        }
        func ensureParentDirsInMetaDB(for linuxPath: String) {}
        func registerSubtreeInMetaDB(hostRoot: URL) {}
    }

    private var sandbox: URL!
    private var savedRoot: URL!
    private var savedMetadata: FakefsMetadataStoring!
    private var metadata: FakeMetadata!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        savedRoot = FileTrash.rootURL
        savedMetadata = FileTrash.metadata
        metadata = FakeMetadata()
        FileTrash.rootURL = sandbox.appendingPathComponent("Trash")
        FileTrash.metadata = metadata
    }

    override func tearDown() async throws {
        FileTrash.rootURL = savedRoot
        FileTrash.metadata = savedMetadata
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testDeleteThenRestorePutsTheFileAndItsMetadataBack() throws {
        let file = sandbox.appendingPathComponent("work/notes.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: file)
        metadata.rows["/root/notes.txt"] = Data([0xED, 0x81, 0, 0])

        let entry = try FileTrash.moveToTrash(file, linuxPath: "/root/notes.txt", isDirectory: false, size: 5)
        XCTAssertFalse(FileTrash.itemExists(at: file))
        XCTAssertTrue(metadata.rows.isEmpty, "the guest no longer sees the deleted file")
        XCTAssertEqual(FileTrash.entries().map(\.id), [entry.id])

        try FileTrash.restore(entry)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        XCTAssertEqual(metadata.rows["/root/notes.txt"], Data([0xED, 0x81, 0, 0]), "mode bits come back as they were")
        XCTAssertTrue(FileTrash.entries().isEmpty)
    }

    func testDeletingASymlinkNeverTouchesItsTarget() throws {
        let target = sandbox.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("photo.jpg"))
        let link = sandbox.appendingPathComponent("view/attachments")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let entry = try FileTrash.moveToTrash(link, linuxPath: nil, isDirectory: false, size: 0)
        XCTAssertFalse(FileTrash.itemExists(at: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("photo.jpg").path))
        let trashed = try FileManager.default.attributesOfItem(atPath: FileTrash.itemURL(of: entry).path)
        XCTAssertEqual(trashed[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testSystemFoldersOfTheRootfsAreRefused() {
        for path in ["/", "/bin", "/etc", "/usr", "/lib", "/var", "/var/oases", "/var/minis", "/usr/bin"] {
            XCTAssertTrue(FileTrash.isProtected(linuxPath: path), path)
        }
        for path in ["/root", "/root/project", "/home/u", "/tmp/x", "/etc/hosts", "/var/oases/workspace/a.txt"] {
            XCTAssertFalse(FileTrash.isProtected(linuxPath: path), path)
        }
        let file = sandbox.appendingPathComponent("bin")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try FileTrash.moveToTrash(file, linuxPath: "/bin", isDirectory: true, size: 0)) { error in
            XCTAssertEqual(error as? FileTrash.Failure, .protectedPath("/bin"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRestoreRefusesToOverwriteWhatIsThereNow() throws {
        let file = sandbox.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: file)
        let entry = try FileTrash.moveToTrash(file, linuxPath: nil, isDirectory: false, size: 3)
        try Data("new".utf8).write(to: file)

        XCTAssertThrowsError(try FileTrash.restore(entry)) { error in
            XCTAssertEqual(error as? FileTrash.Failure, .originalLocationTaken("a.txt"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(FileTrash.entries().count, 1, "the trashed copy stays restorable")
    }

    func testEntriesOlderThanThirtyDaysArePurged() throws {
        let file = sandbox.appendingPathComponent("old.txt")
        try Data("x".utf8).write(to: file)
        let deletedAt = Date().addingTimeInterval(-31 * 86_400)
        _ = try FileTrash.moveToTrash(file, linuxPath: nil, isDirectory: false, size: 1, now: deletedAt)
        XCTAssertTrue(FileTrash.entries().isEmpty)
    }
}
