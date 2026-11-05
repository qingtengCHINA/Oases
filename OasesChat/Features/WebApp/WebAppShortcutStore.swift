import Foundation

private let storeLogger = AppLogger(category: "WebAppShortcuts")

/// Persistence for `WebAppShortcut` rows.
///
/// OpenMinis keeps these in its `ChatStore` SQLite database
/// (`ChatStore.shared.saveWebAppShortcut`). OasesChat has no such store, and
/// the data is a handful of small `Codable` rows keyed by id, so a JSON file
/// alongside the other app state is enough.
///
/// A shortcut is written when the user pins a tile, and read back when the
/// pinned tile deep-links into the app (`oases://open?session=…&path=…`), so
/// the file can re-resolve the HTML by id even if the path moved.
actor WebAppShortcutStore {
    static let shared = WebAppShortcutStore()

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OasesChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("webapp-shortcuts.json")
    }()

    private var cache: [String: WebAppShortcut]?

    private func loaded() -> [String: WebAppShortcut] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let rows = try? JSONDecoder().decode([String: WebAppShortcut].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = rows
        return rows
    }

    private func persist(_ rows: [String: WebAppShortcut]) {
        cache = rows
        do {
            let data = try JSONEncoder().encode(rows)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            storeLogger.error("save failed: \(error.localizedDescription)")
        }
    }

    func save(_ shortcut: WebAppShortcut) {
        var rows = loaded()
        rows[shortcut.id] = shortcut
        persist(rows)
        storeLogger.info("saved shortcut id=\(shortcut.id) scope=\(shortcut.pathScope.rawValue)")
    }

    func shortcut(id: String) -> WebAppShortcut? {
        loaded()[id]
    }

    func all() -> [WebAppShortcut] {
        Array(loaded().values)
    }

    func delete(id: String) {
        var rows = loaded()
        rows.removeValue(forKey: id)
        persist(rows)
    }
}
