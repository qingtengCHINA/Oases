import Foundation

/// Host-side path helpers that must be reachable without hopping into the
/// `ChatStore` actor (install-time fakefs hooks, SwiftUI body, etc.).
///
/// ## Layout
/// On-disk layout is still the OpenMinis-compatible tree for data safety:
/// `Library/MinisChat/minis/…`, provider-config, env-vars, sync caches.
///
/// Product code should prefer the Oases-named aliases below
/// (`engineeringBaseURL`, `libraryRootURL`). Do **not** bulk-rename the
/// directory on disk without a migration — existing installs store sessions
/// and sync state under `MinisChat/`.
enum ChatStorePaths {
    /// Library root used by engineering mode host files.
    /// Currently `…/Library/MinisChat` (legacy-compatible).
    static var libraryRootURL: URL {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = libraryURL.appendingPathComponent(legacyLibraryFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Per-session engineering data root: `…/Library/MinisChat/minis`.
    static var engineeringBaseURL: URL {
        let minis = libraryRootURL.appendingPathComponent(legacySessionsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: minis, withIntermediateDirectories: true)
        return minis
    }

    /// Legacy name kept for call sites / OpenMinis-parity code.
    static var minisBaseURL: URL { engineeringBaseURL }

    /// On-disk folder name under Library. Stable for migration reasons.
    static let legacyLibraryFolderName = "MinisChat"
    static let legacySessionsFolderName = "minis"

    static func fileURL(underLibrary relativePath: String) -> URL {
        libraryRootURL.appendingPathComponent(relativePath)
    }

    static func sessionDirectory(sessionId: String) -> URL {
        engineeringBaseURL.appendingPathComponent(sessionId, isDirectory: true)
    }
}

extension ChatStore {
    /// Non-actor path for callers that only need the on-disk root.
    nonisolated static var minisBaseURLPath: URL { ChatStorePaths.engineeringBaseURL }

    /// Oases-facing alias.
    nonisolated static var engineeringBaseURLPath: URL { ChatStorePaths.engineeringBaseURL }
}
