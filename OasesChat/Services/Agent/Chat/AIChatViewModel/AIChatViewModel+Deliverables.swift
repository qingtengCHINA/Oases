import Foundation

// MARK: - Ogent deliverables

extension AIChatViewModel {
    /// Rebuild `deliverables` from the current message list. Cheap: shell
    /// outputs are parsed once per block and memoized on the block, so this is
    /// a walk over the tool blocks. Publishes only on change.
    func refreshDeliverables() {
        let next = OgentDeliverableLedger.collect(from: messages)
        if next != deliverables { deliverables = next }
    }

    /// Record what a finished shell command wrote under `/var/minis`
    /// (`path → modification date`, the `snapshotMinisFiles` diff) on its tool
    /// block, oldest first. The model-facing output carries the same list in
    /// its `[minis] New/modified files:` section, which is what a reloaded
    /// session parses — so live and reloaded sessions agree.
    func recordProducedFiles(_ newOrModified: [String: Date], msgIdx: Int, blockIdx: Int) {
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        messages[msgIdx].blocks[blockIdx].producedMinisURLs = newOrModified
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .compactMap { linuxPathToMinisURL($0.key) }
    }

    /// `/var/minis/<namespace>/…` path → modification date for the session's
    /// namespaces that live in their own host directories.
    ///
    /// `snapshotMinisFiles()` walks `/var/minis` inside the rootfs data dir,
    /// but in the current runtime that entry is only a fakefs stub: iSH routes
    /// attachments / workspace / offloads / browser to the session's
    /// persistent dirs and `shared` to the App Group, so that walk finds
    /// nothing and a shell command's outputs were never reported. This walks
    /// the real directories instead. Returns nothing while the legacy layout
    /// (a real `/var/minis` directory) is in place, which the old walk covers.
    func snapshotSessionFiles() -> [String: Date] {
        guard let sid = sessionId else { return [:] }
        if let legacy = resolveHostPath(Self.minisLinuxBaseDir) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return [:]
            }
        }
        return Self.snapshotFiles(in: [
            ("attachments", Self.minisAttachmentsPersistentDir(for: sid)),
            ("workspace", Self.minisWorkspacePersistentDir(for: sid)),
            ("offloads", Self.minisOffloadsPersistentDir(for: sid)),
            ("browser", Self.minisBrowserPersistentDir(for: sid)),
            ("shared", Self.minisSharedPersistentDir),
        ])
    }

    /// Regular files under each root (hidden files skipped), keyed by their
    /// guest path `/var/minis/<namespace>/<relative path>`. Stops after
    /// `limit` files so a huge tree cannot stall a tool call.
    nonisolated static func snapshotFiles(
        in roots: [(namespace: String, url: URL)],
        limit: Int = 20_000
    ) -> [String: Date] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var result: [String: Date] = [:]
        for (namespace, root) in roots {
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            while let item = enumerator.nextObject() {
                guard let url = item as? URL,
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix(basePath) else { continue }
                let relative = String(path.dropFirst(basePath.count))
                result["/var/minis/\(namespace)/\(relative)"] = values.contentModificationDate ?? .distantPast
                if result.count >= limit { return result }
            }
        }
        return result
    }
}
