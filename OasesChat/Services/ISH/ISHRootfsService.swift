import Foundation

enum ISHRootfsService {
    enum StageError: LocalizedError, Equatable {
        case missingBundle
        case missingData
        case missingDatabase
        case insufficientDiskSpace
        case verificationFailed(String)
        case replacementFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle: return String(localized: "内置 Alpine rootfs bundle 不存在", comment: "Linux rootfs error: the bundled Alpine rootfs is missing from the app")
            case .missingData: return String(localized: "内置 Alpine rootfs data 不存在", comment: "Linux rootfs error: the data folder of the bundled Alpine rootfs is missing")
            case .missingDatabase: return String(localized: "内置 Alpine meta.db 不存在", comment: "Linux rootfs error: the metadata database of the bundled Alpine rootfs is missing")
            case .insufficientDiskSpace: return String(localized: "设备可用空间不足，未替换当前 rootfs", comment: "Linux rootfs error: not enough free storage, so the current rootfs was kept")
            case .verificationFailed(let detail): return String(localized: "rootfs 校验失败：\(detail)", comment: "Linux rootfs error: integrity check of the rootfs failed; detail is the reason")
            case .replacementFailed(let detail): return String(localized: "rootfs 原子替换失败：\(detail)", comment: "Linux rootfs error: swapping in the new rootfs failed; detail is the reason")
            }
        }
    }

    static func verifyBundle(at bundleRoot: URL, fileManager: FileManager = .default) throws -> RootfsManifest {
        guard fileManager.fileExists(atPath: bundleRoot.path) else { throw StageError.missingBundle }
        let manifestURL = bundleRoot.appendingPathComponent("rootfs-manifest.json")
        let dataURL = bundleRoot.appendingPathComponent("data", isDirectory: true)
        let metaURL = bundleRoot.appendingPathComponent("meta.db")
        guard fileManager.fileExists(atPath: dataURL.path) else { throw StageError.missingData }
        guard fileManager.fileExists(atPath: metaURL.path) else { throw StageError.missingDatabase }
        do {
            let manifest = try JSONDecoder().decode(RootfsManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.verify(bundleRoot: bundleRoot, fileManager: fileManager)
            return manifest
        } catch let error as RootfsManifest.VerificationError {
            throw StageError.verificationFailed(error.localizedDescription)
        } catch {
            throw StageError.verificationFailed(error.localizedDescription)
        }
    }

    /// Guest subtrees (and single files) that belong to the user and survive a
    /// rootfs upgrade. No Alpine package owns anything below these, so
    /// replacing the pristine bundled copies with the old ones cannot shadow
    /// system files. The /etc entries keep the user's DNS and mirror choices.
    static let userDataPrefixes = [
        "/root", "/home", "/usr/local", "/opt", "/var/oases",
        "/etc/resolv.conf", "/etc/apk/repositories", "/etc/pip",
    ]

    /// Guest path of the list of packages the previous rootfs had in
    /// `/etc/apk/world` that the new bundle does not ship.
    static let previousWorldGuestPath = "/root/.ogent/rootfs-profiles/previous-world.txt"

    struct MigrationReport: Equatable {
        var carriedRows = 0
        var skippedRows = 0
        var droppedPackages: [String] = []
    }

    /// Copies and verifies into a sibling staging directory, then swaps the
    /// directory. If the second move fails, the previous rootfs is restored.
    ///
    /// With `migrateUserData`, the active rootfs's user subtrees
    /// (`userDataPrefixes`) are carried into the staged tree — host files and
    /// their meta.db rows together — before the swap. Any migration failure
    /// aborts the swap and leaves the active rootfs untouched.
    @discardableResult
    static func stage(
        bundleRoot: URL,
        activeRoot: URL,
        migrateUserData: Bool = false,
        fileManager: FileManager = .default
    ) throws -> RootfsManifest {
        let manifest = try verifyBundle(at: bundleRoot, fileManager: fileManager)
        let parent = activeRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Worst case the copy is not an APFS clone and needs the full tree
        // once more; check before copying, not after.
        let requiredBytes = treeSize(of: bundleRoot, fileManager: fileManager) + reserveBytes
        guard hasReasonableFreeSpace(at: parent, requiredBytes: requiredBytes) else {
            throw StageError.insufficientDiskSpace
        }
        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let previous = parent.appendingPathComponent(previousPrefix + UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: previous)
        }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundleRoot.appendingPathComponent("data"), to: staging.appendingPathComponent("data"))
            try fileManager.copyItem(at: bundleRoot.appendingPathComponent("meta.db"), to: staging.appendingPathComponent("meta.db"))
            try fileManager.copyItem(at: bundleRoot.appendingPathComponent("rootfs-manifest.json"), to: staging.appendingPathComponent("rootfs-manifest.json"))
            try manifest.verify(bundleRoot: bundleRoot, fileManager: fileManager)
            materializeDirectories(in: staging, fileManager: fileManager)
            if migrateUserData, fileManager.fileExists(atPath: activeRoot.appendingPathComponent("meta.db").path) {
                let report = try Self.migrateUserData(from: activeRoot, into: staging, bundledPackages: manifest.packages, fileManager: fileManager)
                NSLog("[ISHRootfs] migrated user data rows=\(report.carriedRows) skipped=\(report.skippedRows) droppedPackages=\(report.droppedPackages.count)")
            }
            let hadPrevious = fileManager.fileExists(atPath: activeRoot.path)
            if hadPrevious { try fileManager.moveItem(at: activeRoot, to: previous) }
            do {
                try fileManager.moveItem(at: staging, to: activeRoot)
            } catch {
                if hadPrevious, fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.moveItem(at: previous, to: activeRoot)
                }
                throw StageError.replacementFailed(error.localizedDescription)
            }
            return manifest
        } catch let error as StageError {
            throw error
        } catch {
            throw StageError.replacementFailed(error.localizedDescription)
        }
    }

    private static let stagingPrefix = ".iSH-rootfs-staging-"
    private static let previousPrefix = ".iSH-rootfs-previous-"
    private static let reserveBytes: Int64 = 100 * 1024 * 1024

    /// Repairs what an interrupted `stage` can leave behind (the app killed
    /// between the two moves, or before the deferred cleanup): if the active
    /// tree is gone, the newest `.iSH-rootfs-previous-*` is moved back; every
    /// other staging/previous leftover is removed. Call before mounting.
    @discardableResult
    static func recoverInterruptedStage(activeRoot: URL, fileManager: FileManager = .default) -> Bool {
        let parent = activeRoot.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
        let leftovers = names.filter { $0.hasPrefix(stagingPrefix) || $0.hasPrefix(previousPrefix) }
            .map { parent.appendingPathComponent($0, isDirectory: true) }
        guard !leftovers.isEmpty else { return false }

        var restored = false
        let activeIntact = fileManager.fileExists(atPath: activeRoot.appendingPathComponent("meta.db").path)
            && fileManager.fileExists(atPath: activeRoot.appendingPathComponent("data").path)
        if !activeIntact {
            let candidates = leftovers
                .filter { $0.lastPathComponent.hasPrefix(previousPrefix) }
                .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("meta.db").path) }
                .sorted { modificationDate($0, fileManager) > modificationDate($1, fileManager) }
            if let newest = candidates.first {
                if fileManager.fileExists(atPath: activeRoot.path) {
                    try? fileManager.removeItem(at: activeRoot)
                }
                restored = (try? fileManager.moveItem(at: newest, to: activeRoot)) != nil
                NSLog("[ISHRootfs] restored rootfs from interrupted stage: \(restored)")
            }
        }
        for url in leftovers where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        return restored
    }

    private static func modificationDate(_ url: URL, _ fileManager: FileManager) -> Date {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func treeSize(of root: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Recreates host directories that meta.db knows about but the host tree
    /// lacks. git (and anything else that drops empty directories) loses
    /// `/tmp`, `/home`, `/var/cache/apk`, …; without this, the kernel's first
    /// mount (`fakefs_rebuild`) silently deletes their rows. Best effort: a
    /// tree without a readable meta.db is left alone.
    @discardableResult
    static func materializeDirectories(in root: URL, fileManager: FileManager = .default) -> Int {
        guard let store = try? FakefsMetadataStore(url: root.appendingPathComponent("meta.db")) else { return 0 }
        defer { store.close() }
        guard let directories = try? store.directoryPaths() else { return 0 }
        let data = root.appendingPathComponent("data", isDirectory: true)
        var created = 0
        for path in directories where !path.isEmpty {
            let url = data.appendingPathComponent(String(path.dropFirst()), isDirectory: true)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            if (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                created += 1
            }
        }
        return created
    }

    /// Carries `userDataPrefixes` from `oldRoot` into the not-yet-mounted
    /// `newRoot`. The whole host subtree is copied (APFS clones, so large
    /// models cost nothing) — including files the app wrote host-side — and
    /// the new tree's rows for that subtree are replaced by the old rows, so
    /// the guest sees exactly what it saw before. Packages from the old
    /// `/etc/apk/world` that the bundle does not ship are listed at
    /// `previousWorldGuestPath` for `ogent-need` to reinstall on demand.
    static func migrateUserData(
        from oldRoot: URL,
        into newRoot: URL,
        bundledPackages: [String]?,
        prefixes: [String] = userDataPrefixes,
        fileManager: FileManager = .default
    ) throws -> MigrationReport {
        let oldStore = try FakefsMetadataStore(url: oldRoot.appendingPathComponent("meta.db"))
        defer { oldStore.close() }
        let newStore = try FakefsMetadataStore(url: newRoot.appendingPathComponent("meta.db"))
        defer { newStore.close() }
        let oldData = oldRoot.appendingPathComponent("data", isDirectory: true)
        let newData = newRoot.appendingPathComponent("data", isDirectory: true)
        func host(_ data: URL, _ guestPath: String) -> URL {
            data.appendingPathComponent(String(guestPath.dropFirst()))
        }

        var report = MigrationReport()
        try newStore.transaction {
            for prefix in prefixes {
                let rows = try oldStore.rows(under: prefix)
                guard !rows.isEmpty else { continue }
                let source = host(oldData, prefix)
                let destination = host(newData, prefix)
                if fileManager.fileExists(atPath: source.path) {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: source, to: destination)
                }
                try newStore.deleteRows(under: prefix)
                try newStore.ensureDirectory((prefix as NSString).deletingLastPathComponent)
                for row in rows {
                    let url = host(newData, row.path)
                    if row.isDirectory {
                        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    } else if !row.isHostFile || !fileManager.fileExists(atPath: url.path) {
                        // Devices/FIFOs, or a row whose host file already vanished
                        // (the guest could not open it either).
                        report.skippedRows += 1
                        continue
                    }
                    try newStore.upsert(path: row.path, stat: row.stat)
                    report.carriedRows += 1
                }
            }

            let oldNames = Self.worldPackages(at: oldData.appendingPathComponent("etc/apk/world")).map(Self.packageName)
            let newNames = Set((bundledPackages ?? Self.worldPackages(at: newData.appendingPathComponent("etc/apk/world"))).map(Self.packageName))
            report.droppedPackages = Set(oldNames).subtracting(newNames).sorted()
            if !report.droppedPackages.isEmpty {
                let guestPath = Self.previousWorldGuestPath
                let url = host(newData, guestPath)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let body = "# Packages the previous Ogent rootfs had installed (not bundled any more).\n"
                    + "# Reinstall on demand: ogent-need <package>\n"
                    + report.droppedPackages.joined(separator: "\n") + "\n"
                try Data(body.utf8).write(to: url)
                try newStore.ensureDirectory((guestPath as NSString).deletingLastPathComponent)
                try newStore.upsert(path: guestPath, stat: FakefsMetadataStore.stat(mode: 0o100644))
            }
        }
        return report
    }

    private static func worldPackages(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `python3~3.12` / `foo>=1` / `bar=2` → the bare package name.
    private static func packageName(_ entry: String) -> String {
        String(entry.prefix { !"<>=~".contains($0) })
    }

    private static func hasReasonableFreeSpace(at url: URL, requiredBytes: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= requiredBytes
    }
}
