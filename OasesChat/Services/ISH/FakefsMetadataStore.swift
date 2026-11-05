import Foundation
import SQLite3

/// Offline reader/writer for an iSH fakefs `meta.db` — only for rootfs trees
/// the kernel has NOT mounted (a staging copy, or the active tree before boot).
///
/// Schema (vendor iSH `tools/fakefs.c`): `paths(path BLOB PRIMARY KEY, inode)`
/// and `stats(inode INTEGER PRIMARY KEY, stat BLOB)`, where `stat` is
/// `struct ish_stat { u32 mode, uid, gid, rdev }` in little endian. The guest
/// only sees host files that have a `paths` row, which is why rootfs surgery
/// has to move rows and host files together.
final class FakefsMetadataStore {
    struct Row: Equatable {
        let path: String
        let stat: Data

        var mode: UInt32 { FakefsMetadataStore.mode(of: stat) }
        var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        /// Regular files and symlinks are both plain host files in fakefs.
        var isHostFile: Bool {
            let type = mode & 0o170000
            return type == 0o100000 || type == 0o120000
        }
    }

    enum StoreError: LocalizedError {
        case open(String)
        case sql(String)

        var errorDescription: String? {
            switch self {
            case .open(let detail): return String(localized: "无法打开 fakefs meta.db：\(detail)", comment: "Linux rootfs error: the fakefs metadata database could not be opened; detail is a technical reason")
            case .sql(let detail): return String(localized: "fakefs meta.db 操作失败：\(detail)", comment: "Linux rootfs error: a query on the fakefs metadata database failed; detail is a technical reason")
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer?

    /// `readOnly` opens an immutable snapshot (no -wal/-shm sidecars), for
    /// databases that are never written, like the one inside the app bundle.
    /// A tree the kernel has mounted before must be opened read-write so a
    /// pending WAL from the last session is applied.
    init(url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let opened: Int32
        if readOnly {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "file"
            components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            let uri = components?.string ?? url.absoluteString
            opened = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        } else {
            opened = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        }
        guard opened == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        db = handle
        // Fail fast on files that are not a fakefs database.
        _ = try scalarInt("SELECT count(*) FROM paths")
    }

    deinit { close() }

    /// Creates an empty database with the schema of iSH `tools/fakefs.c`
    /// (including the root row), e.g. for tests and tooling.
    @discardableResult
    static func create(at url: URL) throws -> FakefsMetadataStore {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw StoreError.open(url.path)
        }
        let schema = """
            CREATE TABLE meta (id INTEGER UNIQUE DEFAULT 0, db_inode INTEGER);
            INSERT INTO meta (db_inode) VALUES (0);
            CREATE TABLE stats (inode INTEGER PRIMARY KEY, stat BLOB);
            CREATE TABLE paths (path BLOB PRIMARY KEY, inode INTEGER REFERENCES stats(inode));
            CREATE INDEX inode_to_path ON paths (inode, path);
            PRAGMA user_version = 3;
            """
        let ok = sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK
        sqlite3_close(handle)
        guard ok else { throw StoreError.sql("schema") }
        let store = try FakefsMetadataStore(url: url)
        try store.upsert(path: "", stat: stat(mode: 0o040755))
        return store
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: Stat blobs

    static func mode(of stat: Data) -> UInt32 {
        guard stat.count >= 4 else { return 0 }
        return stat.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    static func stat(mode: UInt32, uid: UInt32 = 0, gid: UInt32 = 0, rdev: UInt32 = 0) -> Data {
        var bytes = Data(capacity: 16)
        for value in [mode, uid, gid, rdev] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    // MARK: Queries

    func contains(_ path: String) throws -> Bool {
        try withStatement("SELECT 1 FROM paths WHERE path = ?") { stmt in
            bind(path, to: stmt, at: 1)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    /// `prefix` itself plus every descendant, parents before children.
    func rows(under prefix: String) throws -> [Row] {
        try withStatement("""
            SELECT p.path, s.stat FROM paths p JOIN stats s ON s.inode = p.inode
            WHERE p.path = ?1 OR substr(p.path, 1, ?2) = ?3
            ORDER BY p.path
            """) { stmt in
            bind(prefix, to: stmt, at: 1)
            sqlite3_bind_int(stmt, 2, Int32(prefix.utf8.count + 1))
            bind(prefix + "/", to: stmt, at: 3)
            return collectRows(stmt)
        }
    }

    func directoryPaths() throws -> [String] {
        try withStatement("SELECT p.path, s.stat FROM paths p JOIN stats s ON s.inode = p.inode ORDER BY p.path") { stmt in
            collectRows(stmt).filter(\.isDirectory).map(\.path)
        }
    }

    // MARK: Mutations

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteRows(under prefix: String) throws {
        try withStatement("DELETE FROM paths WHERE path = ?1 OR substr(path, 1, ?2) = ?3") { stmt in
            bind(prefix, to: stmt, at: 1)
            sqlite3_bind_int(stmt, 2, Int32(prefix.utf8.count + 1))
            bind(prefix + "/", to: stmt, at: 3)
            try step(stmt)
        }
        // Stats rows left without a path are dropped by the kernel on mount
        // ("delete orphaned stats"), so no cleanup is needed here.
    }

    /// Inserts or replaces `path` with a fresh inode carrying `stat`.
    func upsert(path: String, stat: Data) throws {
        let inode: Int64 = try withStatement("INSERT INTO stats (stat) VALUES (?)") { stmt in
            _ = stat.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(stat.count), Self.transient) }
            try step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
        try withStatement("INSERT OR REPLACE INTO paths (path, inode) VALUES (?, ?)") { stmt in
            bind(path, to: stmt, at: 1)
            sqlite3_bind_int64(stmt, 2, inode)
            try step(stmt)
        }
    }

    /// Adds a directory row for `path` and any missing ancestors.
    func ensureDirectory(_ path: String, mode: UInt32 = 0o040755) throws {
        var ancestors: [String] = []
        var current = path
        while !current.isEmpty, current != "/" {
            ancestors.append(current)
            current = (current as NSString).deletingLastPathComponent
            if current == "/" { break }
        }
        for dir in ancestors.reversed() {
            if try contains(dir) { continue }
            try upsert(path: dir, stat: Self.stat(mode: mode))
        }
    }

    // MARK: SQLite plumbing

    private func bind(_ path: String, to stmt: OpaquePointer, at index: Int32) {
        let bytes = Array(path.utf8)
        sqlite3_bind_blob(stmt, index, bytes, Int32(bytes.count), Self.transient)
    }

    private func collectRows(_ stmt: OpaquePointer) -> [Row] {
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pathLength = Int(sqlite3_column_bytes(stmt, 0))
            let path = sqlite3_column_blob(stmt, 0).map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: pathLength), as: UTF8.self)
            } ?? ""
            let statLength = Int(sqlite3_column_bytes(stmt, 1))
            let stat = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: statLength) } ?? Data()
            rows.append(Row(path: path, stat: stat))
        }
        return rows
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func step(_ stmt: OpaquePointer) throws {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw StoreError.sql(lastError) }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(lastError) }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sql(lastError) }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }
}
