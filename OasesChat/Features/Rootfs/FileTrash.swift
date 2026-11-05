import Foundation

/// One `meta.db` row of the rootfs (fakefs): the guest path and its raw stat (mode, owner, rdev).
struct FakefsMetadataRow: Codable, Equatable, Sendable {
    let path: String
    let stat: Data
}

/// What Recently Deleted needs from the rootfs metadata. `RootfsManager` in the app; a fake in
/// tests.
protocol FakefsMetadataStoring {
    func fakefsRows(under linuxPath: String) -> [FakefsMetadataRow]
    func removeFakefsPath(_ linuxPath: String)
    func restoreFakefsRows(_ rows: [FakefsMetadataRow])
    func ensureParentDirsInMetaDB(for linuxPath: String)
    func registerSubtreeInMetaDB(hostRoot: URL)
}

extension RootfsManager: FakefsMetadataStoring {}

/// A deleted item kept in Recently Deleted.
struct FileTrashEntry: Codable, Identifiable, Equatable, Sendable {
    /// The folder under the trash root that holds the item and this record.
    let id: String
    let name: String
    /// Where the item was, relative to the app's home directory when it was inside it (the
    /// container path changes across app updates), else absolute.
    let storedOriginalPath: String
    /// The guest path when the item lived in the rootfs.
    let linuxPath: String?
    let isDirectory: Bool
    let size: Int64
    let deletedAt: Date
    /// The rootfs metadata of the item and everything under it, put back on restore.
    let fakefsRows: [FakefsMetadataRow]

    /// Where to show the item came from: its guest path when it has one.
    var displayLocation: String {
        linuxPath ?? FileTrash.originalURL(of: self).path
    }
}

/// 最近删除 (Recently Deleted) for the file browser.
///
/// The repository's rule is that a delete never destroys data directly: deleting in the file
/// browser (and overwriting on import) moves the item here, with its rootfs metadata, and it can be
/// restored for 30 days. A symlink is moved as the link itself, never its target. Items are only
/// destroyed when the user empties them here, or 30 days after they were deleted.
enum FileTrash {
    static let retention: TimeInterval = 30 * 86_400

    enum Failure: LocalizedError, Equatable {
        /// Part of the Linux system the rootfs needs to boot.
        case protectedPath(String)
        /// Something already sits where the item would be restored.
        case originalLocationTaken(String)
        /// The item is gone from the trash folder.
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .protectedPath(let path):
                return String(localized: "“\(path)” is part of the Linux system and can't be deleted.", comment: "File browser: refusing to move a system folder of the Linux environment to Recently Deleted; argument is the path")
            case .originalLocationTaken(let name):
                return String(localized: "Something named “\(name)” is already at the original location.", comment: "Recently Deleted: restore refused because the original location is occupied; argument is the file name")
            case .missing(let name):
                return String(localized: "“\(name)” is no longer in Recently Deleted.", comment: "Recently Deleted: the trashed item disappeared; argument is the file name")
            }
        }
    }

    /// `Library/OasesChat/Trash`. Tests point it elsewhere.
    nonisolated(unsafe) static var rootURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("OasesChat/Trash", isDirectory: true)
    }()

    nonisolated(unsafe) static var metadata: FakefsMetadataStoring = RootfsManager.shared

    /// Top-level guest folders a user may delete from (everything else at the top is the system).
    private static let userTopLevelFolders: Set<String> = ["root", "home", "tmp", "mnt", "media", "srv", "opt"]
    private static let protectedPaths: Set<String> = [
        "/var/minis", "/var/oases", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec",
        "/usr/local", "/usr/share", "/etc/apk",
    ]

    /// Guest paths the browser refuses to delete: `/`, the system folders at the top, and the
    /// folders the agent's environment is built on.
    static func isProtected(linuxPath: String) -> Bool {
        let trimmed = linuxPath.count > 1 && linuxPath.hasSuffix("/") ? String(linuxPath.dropLast()) : linuxPath
        if trimmed == "/" || trimmed.isEmpty { return true }
        if protectedPaths.contains(trimmed) { return true }
        let components = trimmed.split(separator: "/")
        if components.count == 1 { return !userTopLevelFolders.contains(String(components[0])) }
        return false
    }

    /// Whether anything (a dangling symlink included) is at `url`.
    static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    // MARK: - Delete

    /// Moves `url` (the entry itself, a symlink staying a symlink) into Recently Deleted.
    @discardableResult
    static func moveToTrash(_ url: URL, linuxPath: String?, isDirectory: Bool, size: Int64, now: Date = Date()) throws -> FileTrashEntry {
        if let linuxPath, isProtected(linuxPath: linuxPath) { throw Failure.protectedPath(linuxPath) }
        guard itemExists(at: url) else { throw Failure.missing(url.lastPathComponent) }
        let fm = FileManager.default
        try ensureRoot()
        let id = "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let folder = rootURL.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("item", isDirectory: true), withIntermediateDirectories: true)
        let rows = linuxPath.map { metadata.fakefsRows(under: $0) } ?? []
        let entry = FileTrashEntry(
            id: id,
            name: url.lastPathComponent,
            storedOriginalPath: storedPath(for: url),
            linuxPath: linuxPath,
            isDirectory: isDirectory,
            size: size,
            deletedAt: now,
            fakefsRows: rows
        )
        do {
            try write(entry, in: folder)
            try MountedFolderCoordinator.move(from: url, to: itemURL(of: entry))
        } catch {
            try? fm.removeItem(at: folder)  // our own empty record, nothing of the user's
            throw error
        }
        if let linuxPath { metadata.removeFakefsPath(linuxPath) }
        return entry
    }

    // MARK: - Browse, restore, empty

    /// The entries, newest first. Drops the ones past the 30 days first.
    static func entries(now: Date = Date()) -> [FileTrashEntry] {
        purgeExpired(now: now)
        return loadAll().sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts the item back where it was, with its rootfs metadata. Returns where it went.
    @discardableResult
    static func restore(_ entry: FileTrashEntry) throws -> URL {
        let source = itemURL(of: entry)
        guard itemExists(at: source) else { throw Failure.missing(entry.name) }
        let destination = originalURL(of: entry)
        guard !itemExists(at: destination) else { throw Failure.originalLocationTaken(entry.name) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let linuxPath = entry.linuxPath { metadata.ensureParentDirsInMetaDB(for: linuxPath) }
        try MountedFolderCoordinator.move(from: source, to: destination)
        if entry.linuxPath != nil {
            if entry.fakefsRows.isEmpty {
                metadata.registerSubtreeInMetaDB(hostRoot: destination)
            } else {
                metadata.restoreFakefsRows(entry.fakefsRows)
            }
        }
        try? FileManager.default.removeItem(at: folder(of: entry))
        return destination
    }

    /// Destroys one entry: the user's explicit "Delete Permanently".
    static func deletePermanently(_ entry: FileTrashEntry) throws {
        try FileManager.default.removeItem(at: folder(of: entry))
    }

    /// Destroys every entry: the user's explicit "Delete All".
    static func deleteAllPermanently() {
        for entry in loadAll() { try? deletePermanently(entry) }
    }

    /// Destroys the entries deleted more than 30 days ago.
    static func purgeExpired(now: Date = Date()) {
        for entry in loadAll() where now.timeIntervalSince(entry.deletedAt) > retention {
            try? deletePermanently(entry)
        }
    }

    // MARK: - Layout

    static func folder(of entry: FileTrashEntry) -> URL {
        rootURL.appendingPathComponent(entry.id, isDirectory: true)
    }

    static func itemURL(of entry: FileTrashEntry) -> URL {
        folder(of: entry).appendingPathComponent("item", isDirectory: true).appendingPathComponent(entry.name)
    }

    static func originalURL(of entry: FileTrashEntry) -> URL {
        let stored = entry.storedOriginalPath
        if stored.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(stored.dropFirst(2)))
        }
        return URL(fileURLWithPath: stored)
    }

    private static func storedPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homes = [NSHomeDirectory(), "/private" + NSHomeDirectory()]
        for home in homes where path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private static func ensureRoot() throws {
        var root = rootURL
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private static func write(_ entry: FileTrashEntry, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
    }

    private static func loadAll() -> [FileTrashEntry] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("entry.json")),
                  let entry = try? decoder.decode(FileTrashEntry.self, from: data),
                  entry.id == folder.lastPathComponent else { return nil }
            return entry
        }
    }
}
