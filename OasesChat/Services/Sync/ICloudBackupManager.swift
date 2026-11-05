// OpenMinis wraps this in `#if DEBUG`. In OasesChat, Backup is a normal
// Settings page, so it ships in Release too — the code touches only the
// app's own iCloud Drive container and degrades to a no-op when the
// container is unavailable.
import Foundation
import SwiftUI
import UIKit
import SQLite3
import Compression
import os.log

private let logger = AppLogger(category: "ICloudBackup")

// MARK: - ICloudBackupManager

@MainActor
final class ICloudBackupManager: ObservableObject {

    static let shared = ICloudBackupManager()

    enum BackupCategory: String, CaseIterable, Identifiable {
        case sessions           // default.store + media/ + oases/
        case skillsAndMemories  // provider-config.db + skills/ + memory/
        case full               // all

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sessions: return "Sessions"
            case .skillsAndMemories: return "Skills & Memories"
            case .full: return "Full Backup"
            }
        }

        var filePrefix: String {
            switch self {
            case .sessions: return "sessions"
            case .skillsAndMemories: return "skills-memories"
            case .full: return "full"
            }
        }

        var systemImage: String {
            switch self {
            case .sessions: return "bubble.left.and.bubble.right"
            case .skillsAndMemories: return "brain.head.profile"
            case .full: return "archivebox"
            }
        }

        var iconColor: Color {
            switch self {
            case .sessions:          return .blue
            case .skillsAndMemories: return .purple
            case .full:              return .orange
            }
        }

        var description: String {
            switch self {
            case .sessions:
                return "Chat history, media attachments, and session workspace files"
            case .skillsAndMemories:
                return "Skills, memory logs, and skill configuration files"
            case .full:
                return "Complete backup including sessions, skills, and memories"
            }
        }
    }

    struct BackupEntry: Identifiable {
        let id: String          // file name
        let deviceName: String
        let category: BackupCategory
        let date: Date
        let fileSize: Int64
        let url: URL
    }

    @Published var isBackingUp = false
    @Published var isRestoring = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var availableBackups: [BackupEntry] = []

    private let fm = FileManager.default
    private let containerID = "iCloud.dev.oases.chat.ios"

    // MARK: - iCloud Container

    private var iCloudContainerURL: URL? {
        fm.url(forUbiquityContainerIdentifier: containerID)
    }

    var isICloudAvailable: Bool { iCloudContainerURL != nil }

    private var backupDirectoryURL: URL? {
        guard let container = iCloudContainerURL else { return nil }
        let deviceName = UIDevice.current.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return container
            .appendingPathComponent("Documents/backups/\(deviceName)", isDirectory: true)
    }

    private var backupsRootURL: URL? {
        guard let container = iCloudContainerURL else { return nil }
        return container.appendingPathComponent("Documents/backups", isDirectory: true)
    }

    // MARK: - Local Paths

    /// Engineering files may live under legacy `Library/MinisChat/` or
    /// `ChatStorePaths.libraryRootURL` (still MinisChat folder name today).
    /// OpenMinis keeps everything under `Library/MinisChat/` with its own
    /// `minis.db` / `skills.db`. OasesChat's conversations live in SwiftData's
    /// `default.store` (Application Support) and its provider config in
    /// `Library/OasesChat/provider-config.db`, so the paths differ even though
    /// the staging / compression logic below is unchanged. `BackupItem` is the
    /// single source of truth for these locations.
    ///
    /// SwiftData's backing store — conversations + messages.
    private var dataStoreURL: URL { BackupItem.swiftDataStore.liveURL }
    /// Engineering-mode chat store (`ChatStore`): sessions + messages in
    /// `minis.db`, per-session media/workspace files under `minis/`. The
    /// "Sessions" backup promises these, but they used to be left out.
    private var minisDBURL: URL { BackupItem.minisDB.liveURL }
    private var minisSessionsURL: URL { BackupItem.minisSessions.liveURL }
    /// Provider instances / model entries / groups.
    private var providerDBURL: URL { BackupItem.providerDB.liveURL }
    private var mediaURL: URL { BackupItem.media.liveURL }
    /// Agent session workspace (the iSH-visible `/var/oases` tree).
    private var workspaceURL: URL { BackupItem.workspace.liveURL }
    private var skillsURL: URL { BackupItem.skills.liveURL }
    private var memoryURL: URL { BackupItem.memory.liveURL }

    // MARK: - Backup

    func backup(category: BackupCategory) async throws {
        guard !isBackingUp else { return }
        guard let destDir = backupDirectoryURL else {
            throw BackupError.iCloudUnavailable
        }

        isBackingUp = true
        progress = 0
        statusMessage = "Preparing backup..."
        defer {
            isBackingUp = false
            statusMessage = ""
        }

        // Ensure destination directory exists
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create temp staging directory
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let stageDir = tempDir.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        // Stage files based on category
        statusMessage = "Copying files..."
        progress = 0.1

        switch category {
        case .sessions:
            try await stageSessionFiles(to: stageDir)
        case .skillsAndMemories:
            try await stageSkillsAndMemoryFiles(to: stageDir)
        case .full:
            try await stageSessionFiles(to: stageDir)
            try await stageSkillsAndMemoryFiles(to: stageDir)
        }

        progress = 0.6
        statusMessage = "Creating archive..."

        // Create ZIP
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let zipName = "\(category.filePrefix)_\(timestamp).zip"
        let zipURL = tempDir.appendingPathComponent(zipName)

        try await createZip(from: stageDir, to: zipURL)

        progress = 0.8
        statusMessage = "Uploading to iCloud..."

        // Move ZIP to iCloud
        let destURL = destDir.appendingPathComponent(zipName)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: zipURL, to: destURL)

        progress = 1.0
        statusMessage = "Backup complete"
        logger.info("Backup created: \(zipName)")

        // Refresh backup list
        await listBackups()
    }

    // MARK: - Stage Files

    private func stageSessionFiles(to dir: URL) async throws {
        // Consistent snapshot of the SwiftData store (see snapshotSQLite)
        if fm.fileExists(atPath: dataStoreURL.path) {
            try snapshotSQLite(from: dataStoreURL, to: dir.appendingPathComponent("default.store"))
        }

        // ChatStore: minis.db + the per-session folders (Library/MinisChat).
        // Sync bookkeeping next to them (cloud-sync-v2/, etag caches) is
        // deliberately left out — it describes one device's cloud state.
        let minisDir = dir.appendingPathComponent(BackupItem.minisDB.stagedPath)
            .deletingLastPathComponent()
        if fm.fileExists(atPath: minisDBURL.path) {
            try fm.createDirectory(at: minisDir, withIntermediateDirectories: true)
            try snapshotSQLite(from: minisDBURL, to: dir.appendingPathComponent(BackupItem.minisDB.stagedPath))
        }
        if fm.fileExists(atPath: minisSessionsURL.path) {
            try fm.createDirectory(at: minisDir, withIntermediateDirectories: true)
            try fm.copyItem(at: minisSessionsURL, to: dir.appendingPathComponent(BackupItem.minisSessions.stagedPath))
        }

        // Copy media/
        if fm.fileExists(atPath: mediaURL.path) {
            try fm.copyItem(at: mediaURL, to: dir.appendingPathComponent("media"))
        }

        // Copy oases/ (session workspace files)
        if fm.fileExists(atPath: workspaceURL.path) {
            try fm.copyItem(at: workspaceURL, to: dir.appendingPathComponent("oases"))
        }
    }

    private func stageSkillsAndMemoryFiles(to dir: URL) async throws {
        // Consistent snapshot of provider-config.db
        if fm.fileExists(atPath: providerDBURL.path) {
            try snapshotSQLite(from: providerDBURL, to: dir.appendingPathComponent("provider-config.db"))
        }

        // Copy skills/
        if fm.fileExists(atPath: skillsURL.path) {
            try fm.copyItem(at: skillsURL, to: dir.appendingPathComponent("skills"))
        }

        // Copy memory/
        if fm.fileExists(atPath: memoryURL.path) {
            try fm.copyItem(at: memoryURL, to: dir.appendingPathComponent("memory"))
        }
    }

    // MARK: - SQLite Snapshot

    /// Copy a live SQLite database consistently. The stores are open (and
    /// may be written) while a backup runs, so a checkpoint followed by a
    /// file copy could capture a half-applied transaction. `VACUUM INTO`
    /// writes a transactionally consistent copy through a separate
    /// read-only connection; if it fails, fall back to checkpoint + copy.
    private func snapshotSQLite(from src: URL, to dst: URL) throws {
        var db: OpaquePointer?
        if sqlite3_open_v2(src.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
            defer { sqlite3_close(db) }
            let escaped = dst.path.replacingOccurrences(of: "'", with: "''")
            if sqlite3_exec(db, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK {
                return
            }
            logger.warning("VACUUM INTO failed for \(src.lastPathComponent): \(String(cString: sqlite3_errmsg(db))) — falling back to copy")
        } else {
            sqlite3_close(db)
        }
        try? fm.removeItem(at: dst)
        try walCheckpoint(dbPath: src.path)
        try fm.copyItem(at: src, to: dst)
    }

    private func walCheckpoint(dbPath: String) throws {
        guard fm.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let db = db else {
            throw BackupError.databaseError("Failed to open DB for checkpoint: \(rc)")
        }
        defer { sqlite3_close(db) }

        let checkpointRC = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        if checkpointRC != SQLITE_OK {
            logger.warning("WAL checkpoint returned \(checkpointRC) for \(dbPath)")
        }
    }

    // MARK: - ZIP Creation (using NSFileCoordinator)

    private func createZip(from sourceDir: URL, to zipURL: URL) async throws {
        // Use Foundation's built-in ZIP capability via NSFileCoordinator
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            coordinator.coordinate(readingItemAt: sourceDir,
                                   options: .forUploading,
                                   error: &error) { zippedURL in
                do {
                    try self.fm.copyItem(at: zippedURL, to: zipURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - List Backups

    @discardableResult
    func listBackups() async -> [BackupEntry] {
        guard let root = backupsRootURL else {
            availableBackups = []
            return []
        }

        var entries: [BackupEntry] = []

        do {
            // Ensure directory exists
            if !fm.fileExists(atPath: root.path) {
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            }

            let deviceDirs = try fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey])
            for deviceDir in deviceDirs {
                let isDir = (try? deviceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let deviceName = deviceDir.lastPathComponent
                let files = (try? fm.contentsOfDirectory(at: deviceDir,
                                                          includingPropertiesForKeys: [.fileSizeKey])) ?? []

                for file in files {
                    guard file.pathExtension == "zip" else { continue }
                    let name = file.deletingPathExtension().lastPathComponent

                    guard let entry = parseBackupFileName(name, deviceName: deviceName, url: file) else {
                        continue
                    }
                    entries.append(entry)
                }
            }
        } catch {
            logger.error("Failed to list backups: \(error.localizedDescription)")
        }

        entries.sort { $0.date > $1.date }
        availableBackups = entries
        return entries
    }

    private func parseBackupFileName(_ name: String, deviceName: String, url: URL) -> BackupEntry? {
        // Format: <category>_<yyyy-MM-dd_HHmmss>
        let parts = name.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let categoryStr = String(parts[0])
        let dateStr = String(parts[1])

        let category: BackupCategory
        switch categoryStr {
        case "sessions": category = .sessions
        case "skills-memories": category = .skillsAndMemories
        case "full": category = .full
        default: return nil
        }

        // Re-parse: prefix may contain hyphen (skills-memories)
        let actualDateStr: String
        if categoryStr == "skills-memories" {
            // name = "skills-memories_2026-03-05_143022"
            let underscoreParts = name.components(separatedBy: "_")
            // ["skills-memories", "2026-03-05", "143022"]
            guard underscoreParts.count >= 3 else { return nil }
            actualDateStr = underscoreParts[1] + "_" + underscoreParts[2]
        } else {
            actualDateStr = dateStr
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        guard let date = formatter.date(from: actualDateStr) else { return nil }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return BackupEntry(id: name, deviceName: deviceName, category: category,
                          date: date, fileSize: fileSize, url: url)
    }

    // MARK: - Restore

    /// Phase 1 of a two-phase restore: download, extract (bounds- and
    /// path-checked, size-capped) into a staging area, verify every database
    /// with an integrity check, and record what to swap in. Nothing live is
    /// touched here — the stores are open (SwiftData's container, ChatStore,
    /// ProviderConfigDB) and replacing their files underneath them corrupts
    /// data. Phase 2, `PendingBackupRestore.applyIfNeeded`, swaps the staged
    /// files in on the next launch before those stores open.
    func restore(from entry: BackupEntry) async throws {
        guard !isRestoring else { return }

        isRestoring = true
        progress = 0
        statusMessage = "Downloading backup..."
        defer {
            isRestoring = false
            statusMessage = ""
        }

        // Ensure file is downloaded from iCloud
        try await ensureDownloaded(entry.url)

        progress = 0.3
        statusMessage = "Extracting backup..."

        // A newer restore replaces one that hasn't been applied yet.
        PendingBackupRestore.discard()
        let extractDir = PendingBackupRestore.rootURL.appendingPathComponent("extracted", isDirectory: true)
        let zipURL = entry.url
        let category = entry.category
        do {
            let items = try await Task.detached(priority: .userInitiated) { () throws -> [BackupItem] in
                try BackupArchive.extract(zipAt: zipURL, to: extractDir)
                // The ZIP may contain a "backup" subdirectory from our staging
                let backupSubdir = extractDir.appendingPathComponent("backup", isDirectory: true)
                let contentDir = FileManager.default.fileExists(atPath: backupSubdir.path) ? backupSubdir : extractDir
                let items = try PendingBackupRestore.validate(contentDir: contentDir, category: category)
                try FileManager.default.moveItem(at: contentDir, to: PendingBackupRestore.stagingURL)
                try? FileManager.default.removeItem(at: extractDir)
                return items
            }.value
            progress = 0.9
            PendingBackupRestore.save(.init(backupName: entry.id, stagedAt: Date(), remaining: items))
        } catch {
            PendingBackupRestore.discard()
            throw error
        }

        progress = 1.0
        statusMessage = "Restore ready — relaunch Oases Chat to apply it"
        logger.info("Staged backup for restore on next launch: \(entry.id)")
    }

    // MARK: - Download from iCloud

    private func ensureDownloaded(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus == .current {
            return
        }

        try fm.startDownloadingUbiquitousItem(at: url)

        // Poll until downloaded (with timeout)
        let deadline = Date().addingTimeInterval(120) // 2 min timeout
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            let updated = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if updated.ubiquitousItemDownloadingStatus == .current {
                return
            }
        }

        throw BackupError.downloadTimeout
    }

    // MARK: - Delete Backup

    func deleteBackup(_ entry: BackupEntry) throws {
        try fm.removeItem(at: entry.url)
        availableBackups.removeAll { $0.id == entry.id }
    }

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case iCloudUnavailable
        case databaseError(String)
        case zipError(String)
        case downloadTimeout

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable: return "iCloud is not available. Please sign in to iCloud in Settings."
            case .databaseError(let msg): return "Database error: \(msg)"
            case .zipError(let msg): return "Archive error: \(msg)"
            case .downloadTimeout: return "Timed out downloading backup from iCloud."
            }
        }
    }
}

// MARK: - Backup items

/// Everything a backup archive can carry: where it sits inside the archive
/// (`stagedPath`, relative to the content root) and where it lives on disk.
enum BackupItem: String, CaseIterable, Codable {
    case swiftDataStore, media, workspace, minisDB, minisSessions, providerDB, skills, memory

    var stagedPath: String {
        switch self {
        case .swiftDataStore: return "default.store"
        case .media: return "media"
        case .workspace: return "oases"
        case .minisDB: return "MinisChat/minis.db"
        case .minisSessions: return "MinisChat/minis"
        case .providerDB: return "provider-config.db"
        case .skills: return "skills"
        case .memory: return "memory"
        }
    }

    var liveURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let libraryOases = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OasesChat", isDirectory: true)
        switch self {
        case .swiftDataStore: return appSupport.appendingPathComponent("default.store")
        case .media: return appSupport.appendingPathComponent("media", isDirectory: true)
        case .workspace: return libraryOases.appendingPathComponent("oases", isDirectory: true)
        case .minisDB: return ChatStorePaths.libraryRootURL.appendingPathComponent("minis.db")
        case .minisSessions: return ChatStorePaths.engineeringBaseURL
        case .providerDB: return libraryOases.appendingPathComponent("provider-config.db")
        case .skills: return appSupport.appendingPathComponent("skills", isDirectory: true)
        case .memory: return appSupport.appendingPathComponent("memory", isDirectory: true)
        }
    }

    var isSQLite: Bool { self == .swiftDataStore || self == .minisDB || self == .providerDB }

    /// Which launch hook swaps it in: ChatStore's own files are swapped by
    /// `ChatStore.init` right before it opens minis.db; everything else has
    /// to be swapped before SwiftData / ProviderConfigDB / SkillStore open.
    var scope: PendingRestoreScope {
        (self == .minisDB || self == .minisSessions) ? .chatStore : .appLaunch
    }

    static func items(for category: ICloudBackupManager.BackupCategory) -> [BackupItem] {
        switch category {
        case .sessions: return [.swiftDataStore, .media, .workspace, .minisDB, .minisSessions]
        case .skillsAndMemories: return [.providerDB, .skills, .memory]
        case .full: return allCases
        }
    }
}

enum PendingRestoreScope: String, Codable {
    case chatStore
    case appLaunch
}

// MARK: - Pending restore (phase 2)

/// A restore staged by `ICloudBackupManager.restore(from:)` and swapped in
/// on the next launch, before the stores it replaces are opened:
///   • `applyIfNeeded(scope: .chatStore)` — called by `ChatStore.init`.
///   • `applyIfNeeded(scope: .appLaunch)` — must run at the very start of
///     app launch (before `ConversationContainer` / `ProviderConfigStore`).
/// Each swap moves the live copy aside first and puts it back if the swap
/// fails, so a failed restore leaves the previous data in place.
enum PendingBackupRestore {
    struct Manifest: Codable {
        var backupName: String
        var stagedAt: Date
        var remaining: [BackupItem]
    }

    static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackupRestore", isDirectory: true)
    }
    static var stagingURL: URL { rootURL.appendingPathComponent("staged", isDirectory: true) }
    private static var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    static func loadManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func save(_ manifest: Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Drop a staged restore (and any leftovers of an interrupted staging).
    static func discard() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Check an extracted archive before anything is swapped: the category's
    /// items that are present must have the right shape, and every database
    /// must pass `PRAGMA quick_check` (minis.db must also have its sessions
    /// table). Returns the items to restore.
    static func validate(contentDir: URL, category: ICloudBackupManager.BackupCategory) throws -> [BackupItem] {
        let fm = FileManager.default
        var present: [BackupItem] = []
        for item in BackupItem.items(for: category) {
            let url = contentDir.appendingPathComponent(item.stagedPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if item.isSQLite {
                guard !isDir.boolValue,
                      sqliteIsHealthy(url, requiredTable: item == .minisDB ? "sessions" : nil) else {
                    throw ICloudBackupManager.BackupError.databaseError("\(item.stagedPath) in this backup failed its integrity check")
                }
            } else if !isDir.boolValue {
                throw ICloudBackupManager.BackupError.zipError("\(item.stagedPath) in this backup is not a folder")
            }
            present.append(item)
        }
        guard !present.isEmpty else {
            throw ICloudBackupManager.BackupError.zipError("This backup contains no restorable data")
        }
        return present
    }

    static func sqliteIsHealthy(_ url: URL, requiredTable: String? = nil) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        func firstText(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }
        guard firstText("PRAGMA quick_check") == "ok" else { return false }
        if let table = requiredTable {
            let escaped = table.replacingOccurrences(of: "'", with: "''")
            return firstText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(escaped)'") != nil
        }
        return true
    }

    /// Swap in this scope's staged items. Safe to call on every launch: a
    /// no-op without a manifest. Synchronous on purpose — callers run it
    /// before opening the stores it replaces.
    static func applyIfNeeded(scope: PendingRestoreScope) {
        guard var manifest = loadManifest() else { return }
        let fm = FileManager.default
        let items = manifest.remaining.filter { $0.scope == scope }
        guard !items.isEmpty else { return }
        let aside = rootURL.appendingPathComponent("previous-\(scope.rawValue)", isDirectory: true)
        try? fm.removeItem(at: aside)
        for item in items {
            defer {
                manifest.remaining.removeAll { $0 == item }
                save(manifest)
            }
            let staged = stagingURL.appendingPathComponent(item.stagedPath)
            guard fm.fileExists(atPath: staged.path) else { continue }
            let live = item.liveURL
            let suffixes = item.isSQLite ? ["", "-wal", "-shm"] : [""]
            var movedAside: [(original: URL, aside: URL)] = []
            do {
                try fm.createDirectory(at: aside, withIntermediateDirectories: true)
                for suffix in suffixes {
                    let original = URL(fileURLWithPath: live.path + suffix)
                    guard fm.fileExists(atPath: original.path) else { continue }
                    let parked = aside.appendingPathComponent(item.rawValue + suffix)
                    try fm.moveItem(at: original, to: parked)
                    movedAside.append((original, parked))
                }
                try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staged, to: live)
                logger.info("Restore applied: \(item.rawValue) from \(manifest.backupName)")
            } catch {
                // Put the previous data back so a failed swap loses nothing.
                for entry in movedAside.reversed() {
                    try? fm.removeItem(at: entry.original)
                    try? fm.moveItem(at: entry.aside, to: entry.original)
                }
                logger.error("Restore of \(item.rawValue) failed, previous data kept: \(error.localizedDescription)")
            }
        }
        // The swapped-out copies were only kept for rollback.
        try? fm.removeItem(at: aside)
        if manifest.remaining.isEmpty { discard() }
    }
}

// MARK: - ZIP extraction

/// Minimal, defensive reader for the store-or-deflate ZIPs this feature
/// writes (NSFileCoordinator `.forUploading`). Every offset is bounds-checked
/// and read unaligned, entry names are confined to the destination (no
/// absolute paths, `..`, backslashes or symlink entries), sizes are capped
/// and each entry is inflated as a stream straight to disk, never producing
/// more bytes than its header declares.
enum BackupArchive {
    struct Limits {
        var maxEntries = 500_000
        var maxTotalUncompressedBytes: Int64 = 32 << 30
        /// Keep this much disk free beyond the declared archive contents.
        var diskHeadroomBytes: Int64 = 200 << 20
    }

    enum ArchiveError: LocalizedError {
        case malformed(String)
        case unsafePath(String)
        case unsupported(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let m): return "Archive error: \(m)"
            case .unsafePath(let p): return "Archive error: unsafe entry path \(p)"
            case .unsupported(let m): return "Archive error: unsupported \(m)"
            case .tooLarge(let m): return "Archive error: \(m)"
            }
        }
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    /// Extract `zipURL` into `destination` (created if needed). Throws
    /// before writing anything if the central directory is malformed,
    /// unsafe or over the limits.
    static func extract(zipAt zipURL: URL, to destination: URL, limits: Limits = Limits()) throws {
        let data = try Data(contentsOf: zipURL, options: .alwaysMapped)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.resolvingSymlinksInPath()

        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let entries = try readCentralDirectory(buf, limits: limits)
            let declared = entries.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
            guard declared <= limits.maxTotalUncompressedBytes else {
                throw ArchiveError.tooLarge("backup expands to \(declared) bytes")
            }
            if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
               declared + limits.diskHeadroomBytes > free {
                throw ArchiveError.tooLarge("not enough free space to restore this backup")
            }
            // Resolve every destination first so a bad entry late in the
            // archive can't leave a half-extracted tree behind.
            let targets = try entries.map { entry -> URL in
                let target = root.appendingPathComponent(entry.name).standardizedFileURL
                guard target.path.hasPrefix(root.path + "/") else { throw ArchiveError.unsafePath(entry.name) }
                return target
            }
            for (entry, target) in zip(entries, targets) {
                if entry.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeEntry(entry, from: buf, to: target)
            }
        }
    }

    private static func u16(_ buf: UnsafeRawBufferPointer, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= buf.count else { throw ArchiveError.malformed("truncated header") }
        return Int(UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
    }

    private static func u32(_ buf: UnsafeRawBufferPointer, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= buf.count else { throw ArchiveError.malformed("truncated header") }
        return Int(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    private static func readCentralDirectory(_ buf: UnsafeRawBufferPointer, limits: Limits) throws -> [Entry] {
        let size = buf.count
        guard size >= 22 else { throw ArchiveError.malformed("file too small") }
        // End of central directory: last 22 bytes plus an optional comment.
        var eocd = -1
        var i = size - 22
        let floor = max(0, size - 22 - 0xFFFF)
        while i >= floor {
            if try u32(buf, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.malformed("no end-of-central-directory record") }
        let entryCount = try u16(buf, eocd + 10)
        let cdSize = try u32(buf, eocd + 12)
        let cdOffset = try u32(buf, eocd + 16)
        guard entryCount != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw ArchiveError.unsupported("ZIP64 archive")
        }
        guard entryCount <= limits.maxEntries else { throw ArchiveError.tooLarge("too many entries (\(entryCount))") }
        guard cdOffset + cdSize <= eocd else { throw ArchiveError.malformed("central directory out of bounds") }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var offset = cdOffset
        for _ in 0..<entryCount {
            guard try u32(buf, offset) == 0x02014b50 else { throw ArchiveError.malformed("bad central directory entry") }
            let flags = try u16(buf, offset + 8)
            let method = UInt16(try u16(buf, offset + 10))
            let compressedSize = try u32(buf, offset + 20)
            let uncompressedSize = try u32(buf, offset + 24)
            let nameLen = try u16(buf, offset + 28)
            let extraLen = try u16(buf, offset + 30)
            let commentLen = try u16(buf, offset + 32)
            let externalAttrs = try u32(buf, offset + 38)
            let localHeaderOffset = try u32(buf, offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= size else { throw ArchiveError.malformed("entry name out of bounds") }
            let nameBytes = UnsafeRawBufferPointer(rebasing: buf[nameStart..<(nameStart + nameLen)])
            guard let rawName = String(bytes: nameBytes, encoding: .utf8) else {
                throw ArchiveError.malformed("entry name is not UTF-8")
            }
            offset = nameStart + nameLen + extraLen + commentLen
            guard offset <= size else { throw ArchiveError.malformed("central directory out of bounds") }

            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, localHeaderOffset != 0xFFFF_FFFF else {
                throw ArchiveError.unsupported("ZIP64 entry \(rawName)")
            }
            guard flags & 0x1 == 0 else { throw ArchiveError.unsupported("encrypted entry \(rawName)") }
            // Unix mode lives in the high 16 bits; refuse symlink entries.
            guard (externalAttrs >> 16) & 0o170000 != 0o120000 else { throw ArchiveError.unsafePath(rawName) }
            if rawName.hasPrefix("__MACOSX/") { continue }
            guard let name = safeRelativePath(rawName) else { throw ArchiveError.unsafePath(rawName) }
            let isDirectory = rawName.hasSuffix("/")
            guard isDirectory || method == 0 || method == 8 else {
                throw ArchiveError.unsupported("compression method \(method) for \(rawName)")
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize,
                                 localHeaderOffset: localHeaderOffset, isDirectory: isDirectory))
        }
        return entries
    }

    /// Normalised relative path, or nil for anything that could escape the
    /// destination: absolute paths, `.`/`..` components, backslashes, NUL.
    static func safeRelativePath(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return nil }
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func writeEntry(_ entry: Entry, from buf: UnsafeRawBufferPointer, to target: URL) throws {
        let header = entry.localHeaderOffset
        guard try u32(buf, header) == 0x04034b50 else { throw ArchiveError.malformed("bad local header for \(entry.name)") }
        let dataStart = header + 30 + (try u16(buf, header + 26)) + (try u16(buf, header + 28))
        guard dataStart + entry.compressedSize <= buf.count else {
            throw ArchiveError.malformed("data for \(entry.name) out of bounds")
        }
        let payload = UnsafeRawBufferPointer(rebasing: buf[dataStart..<(dataStart + entry.compressedSize)])

        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw ArchiveError.malformed("cannot create \(entry.name)")
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        if entry.method == 0 {
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ArchiveError.malformed("size mismatch for stored \(entry.name)")
            }
            try handle.write(contentsOf: payload)
            return
        }
        // Raw deflate, streamed in chunks and capped at the declared size.
        let chunk = 256 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { output.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.malformed("inflate init failed")
        }
        defer { compression_stream_destroy(stream) }
        stream.pointee.src_ptr = payload.baseAddress?.assumingMemoryBound(to: UInt8.self)
            ?? UnsafePointer(output)
        stream.pointee.src_size = payload.count
        var written = 0
        while true {
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = chunk
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 {
                written += produced
                guard written <= entry.uncompressedSize else {
                    throw ArchiveError.malformed("\(entry.name) inflates past its declared size")
                }
                try handle.write(contentsOf: UnsafeRawBufferPointer(start: output, count: produced))
            }
            if status == COMPRESSION_STATUS_END { break }
            guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.pointee.src_size > 0 else {
                throw ArchiveError.malformed("corrupt compressed data for \(entry.name)")
            }
        }
        guard written == entry.uncompressedSize else {
            throw ArchiveError.malformed("\(entry.name) is truncated")
        }
    }
}

// MARK: - Helpers

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
