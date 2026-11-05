import Foundation

struct ISHRootfsStatus: Equatable {
    let installed: Bool
    let runtimeReady: Bool
    let pendingReset: Bool
    let rootURL: URL
    let dataURL: URL
    let backupURL: URL
    let totalBytes: Int64
    let dataBytes: Int64
    let fileCount: Int
    let alpineVersion: String?
    let lastModified: Date?

    var totalSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var dataSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: dataBytes, countStyle: .file)
    }
}

struct ISHRootfsActionResult: Equatable {
    let message: String
    let requiresRestart: Bool
    let backupURL: URL?
}

struct ISHExportedArtifact: Equatable {
    let sourceGuestPath: String
    let destinationURL: URL
    let byteCount: Int64

    var filename: String {
        destinationURL.lastPathComponent
    }
}

struct ISHImportedModel: Equatable {
    let guestPath: String
    let hostURL: URL
    let byteCount: Int64

    var filename: String {
        hostURL.lastPathComponent
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum RootfsModelImportError: LocalizedError {
    case unsupportedFileType
    case invalidGGUFMagic
    case unsupportedRunnerType

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return String(localized: "请选择 .gguf 模型文件。", comment: "Local model import error: the picked file is not .gguf")
        case .invalidGGUFMagic:
            return String(localized: "所选文件不是有效 GGUF 模型（缺少 GGUF magic）。", comment: "Local model import error: the file is not a valid GGUF model")
        case .unsupportedRunnerType:
            return String(localized: "请选择当前 iSH Alpine guest 架构可执行的 Linux ELF llama-server（本项目为 aarch64）。iOS/macOS Mach-O、x86_64 Linux ELF、32-bit ARM ELF 或脚本不能作为 runner 使用。", comment: "Local model runner import error: the picked file is not an aarch64 Linux executable")
        }
    }
}

enum ISHRootfsManager {
    private static let rootDirectoryName = "iSH-rootfs"
    private static let backupDirectoryName = "OgentRootfsBackups"
    private static let stampFilename = ".oases-rootfs-initialised"
    private static let pendingResetFilename = ".oases-rootfs-reset-pending"

    static var rootURL: URL {
        applicationSupportURL.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    static var dataURL: URL {
        rootURL.appendingPathComponent("data", isDirectory: true)
    }

    static var metaDatabaseURL: URL {
        rootURL.appendingPathComponent("meta.db")
    }

    static var manifestURL: URL {
        rootURL.appendingPathComponent("rootfs-manifest.json")
    }

    static var backupsURL: URL {
        documentsURL.appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    static var exportsURL: URL {
        documentsURL.appendingPathComponent("Ogent Artifacts", isDirectory: true)
    }

    static var ogentModelsURL: URL {
        dataURL.appendingPathComponent("root/.ogent/models", isDirectory: true)
    }

    static var ogentModelBinariesURL: URL {
        ogentModelsURL.appendingPathComponent("bin", isDirectory: true)
    }

    static var pendingResetURL: URL {
        rootURL.appendingPathComponent(pendingResetFilename)
    }

    static var stampURL: URL {
        rootURL.appendingPathComponent(stampFilename)
    }

    static func status() -> ISHRootfsStatus {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: stampURL.path)
            && fm.fileExists(atPath: dataURL.path)
            && fm.fileExists(atPath: metaDatabaseURL.path)
            && fm.fileExists(atPath: manifestURL.path)
        let dataScan = directoryScan(dataURL)
        let rootScan = directoryScan(rootURL)
        let attrs = try? fm.attributesOfItem(atPath: dataURL.path)
        let alpineVersionURL = dataURL.appendingPathComponent("etc/alpine-release")
        let version = try? String(contentsOf: alpineVersionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ISHRootfsStatus(
            installed: installed,
            runtimeReady: ish_runtime_is_ready() != 0,
            pendingReset: fm.fileExists(atPath: pendingResetURL.path),
            rootURL: rootURL,
            dataURL: dataURL,
            backupURL: backupsURL,
            totalBytes: rootScan.bytes,
            dataBytes: dataScan.bytes,
            fileCount: dataScan.files,
            alpineVersion: version?.isEmpty == true ? nil : version,
            lastModified: attrs?[.modificationDate] as? Date
        )
    }

    /// Serializes rootfs staging and kernel initialization across every boot
    /// path (`ISHRuntimeBootstrap.bootstrap`, `ISHKernel.boot`, the legacy
    /// `RootfsManager`). Without it two launch paths could stage at once and
    /// the loser's swap deleted the tree — meta.db included — that the
    /// winner's kernel had just mounted. Recursive: boot paths hold it while
    /// calling `stageBundledRootfsIfNeeded()`, which takes it too.
    static let bootLock = NSRecursiveLock()

    @discardableResult
    static func stageBundledRootfsIfNeeded() -> String? {
        bootLock.lock()
        defer { bootLock.unlock() }
        let fm = FileManager.default
        // Never swap or restage the tree under a mounted kernel; resets and
        // upgrades are applied on the next cold launch.
        if ish_runtime_is_ready() != 0 {
            ensureOgentLayout(in: dataURL)
            return dataURL.path
        }
        ISHRootfsService.recoverInterruptedStage(activeRoot: rootURL, fileManager: fm)
        if fm.fileExists(atPath: stampURL.path),
           fm.fileExists(atPath: dataURL.path),
           fm.fileExists(atPath: metaDatabaseURL.path),
           fm.fileExists(atPath: manifestURL.path),
           !fm.fileExists(atPath: pendingResetURL.path) {
            if bundledRootfsIsNewer(), upgradeBundledRootfs() {
                return dataURL.path
            }
            ensureOgentLayout(in: dataURL)
            return dataURL.path
        }

        return stageBundledRootfs()
    }

    private static var bundledRootfsURL: URL? {
        Bundle.main.url(forResource: "AlpineFakefs", withExtension: nil)
    }

    /// True when the app ships a newer rootfs (e.g. more preinstalled tools)
    /// than the one staged on this device.
    static func bundledRootfsIsNewer() -> Bool {
        guard let bundledRoot = bundledRootfsURL,
              let bundled = RootfsManifest.load(from: bundledRoot) else { return false }
        let active = RootfsManifest.load(from: rootURL)?.effectiveRootfsVersion ?? 1
        return bundled.effectiveRootfsVersion > active
    }

    private static let maxUpgradeAttempts = 3

    /// Swaps in the newer bundled rootfs while carrying the user's data
    /// (`ISHRootfsService.userDataPrefixes`) across. Must run before the
    /// kernel mounts the rootfs. On failure the current rootfs stays active;
    /// a version that keeps failing is given up after a few launches.
    private static func upgradeBundledRootfs() -> Bool {
        guard let bundledRoot = bundledRootfsURL,
              let target = RootfsManifest.load(from: bundledRoot)?.effectiveRootfsVersion else { return false }
        let attemptsKey = "ish.rootfsUpgradeAttempts.v\(target)"
        let attempts = UserDefaults.standard.integer(forKey: attemptsKey)
        guard attempts < maxUpgradeAttempts else { return false }
        UserDefaults.standard.set(attempts + 1, forKey: attemptsKey)

        do {
            let started = Date()
            let manifest = try ISHRootfsService.stage(bundleRoot: bundledRoot, activeRoot: rootURL, migrateUserData: true)
            ensureOgentLayout(in: dataURL)
            FileManager.default.createFile(atPath: stampURL.path, contents: nil)
            UserDefaults.standard.removeObject(forKey: attemptsKey)
            let elapsed = Date().timeIntervalSince(started)
            NSLog("[ISHRootfs] upgraded rootfs to v\(manifest.effectiveRootfsVersion) alpine=\(manifest.alpineVersion) in \(String(format: "%.2fs", elapsed))")
            return true
        } catch {
            NSLog("[ISHRootfs] rootfs upgrade to v\(target) failed (attempt \(attempts + 1)); keeping the current rootfs: \(error)")
            return false
        }
    }

    @discardableResult
    static func stageBundledRootfs() -> String? {
        bootLock.lock()
        defer { bootLock.unlock() }
        let fm = FileManager.default
        guard let bundledRoot = bundledRootfsURL else {
            NSLog("[ISHRootfs] bundled AlpineFakefs not found in app bundle")
            return nil
        }
        do {
            let started = Date()
            let manifest = try ISHRootfsService.stage(bundleRoot: bundledRoot, activeRoot: rootURL)
            ensureOgentLayout(in: dataURL)
            fm.createFile(atPath: stampURL.path, contents: nil)
            try? fm.removeItem(at: pendingResetURL)
            // Lets MirrorSpeedTestViewModel pick the fastest apk/pip mirror once.
            UserDefaults.standard.set(true, forKey: "rootfs.freshInstall")
            let elapsed = Date().timeIntervalSince(started)
            NSLog("[ISHRootfs] staged bundled rootfs schema=\(manifest.schemaVersion) alpine=\(manifest.alpineVersion) in \(String(format: "%.2fs", elapsed)) at \(rootURL.path)")
            return dataURL.path
        } catch {
            NSLog("[ISHRootfs] rootfs verification/staging failed; active rootfs preserved: \(error)")
            return nil
        }
    }

    static func createSnapshot() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let target = backupsURL.appendingPathComponent("rootfs-snapshot-\(timestamp())", isDirectory: true)
        try fm.copyItem(at: rootURL, to: target)
        return target
    }

    static func backupUserData() throws -> URL? {
        let fm = FileManager.default
        let sources = [
            ("root-ogent", dataURL.appendingPathComponent("root/.ogent", isDirectory: true)),
            ("root-ogent-runtime", dataURL.appendingPathComponent("root/.minis", isDirectory: true)),
            ("root", dataURL.appendingPathComponent("root", isDirectory: true)),
            ("home", dataURL.appendingPathComponent("home", isDirectory: true)),
            ("apk-repositories", dataURL.appendingPathComponent("etc/apk/repositories"))
        ].filter { fm.fileExists(atPath: $0.1.path) }

        guard !sources.isEmpty else { return nil }
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let target = backupsURL.appendingPathComponent("user-data-\(timestamp())", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for (name, source) in sources {
            try fm.copyItem(at: source, to: target.appendingPathComponent(name))
        }
        return target
    }

    static func resetRootfsBackingUpUserData() throws -> ISHRootfsActionResult {
        let backup = try backupUserData()
        let fm = FileManager.default

        if ish_runtime_is_ready() != 0 {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            fm.createFile(atPath: pendingResetURL.path, contents: Data())
            return ISHRootfsActionResult(
                message: String(localized: "已备份用户数据，并标记下次启动重置 Rootfs。", comment: "Rootfs reset result: data backed up, reset scheduled for next launch"),
                requiresRestart: true,
                backupURL: backup
            )
        }

        bootLock.lock()
        defer { bootLock.unlock() }
        guard ish_runtime_is_ready() == 0 else {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            fm.createFile(atPath: pendingResetURL.path, contents: Data())
            return ISHRootfsActionResult(
                message: String(localized: "已备份用户数据，并标记下次启动重置 Rootfs。", comment: "Rootfs reset result: data backed up, reset scheduled for next launch"),
                requiresRestart: true,
                backupURL: backup
            )
        }
        try? fm.removeItem(at: rootURL)
        guard stageBundledRootfs() != nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        return ISHRootfsActionResult(
            message: String(localized: "Rootfs 已重置为内置 Alpine 镜像。", comment: "Rootfs reset result: reset completed"),
            requiresRestart: false,
            backupURL: backup
        )
    }

    static func exportArtifact(guestPath: String, destinationRelativePath: String? = nil) throws -> ISHExportedArtifact {
        let trimmed = guestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard Self.isExportableGuestPath(trimmed) else {
            throw CocoaError(.fileReadNoPermission)
        }

        var source = dataURL.appendingPathComponent(String(trimmed.dropFirst()))
        let rootPath = dataURL.standardizedFileURL.path
        var sourcePath = source.standardizedFileURL.path
        guard sourcePath == rootPath || sourcePath.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        var exists = fm.fileExists(atPath: sourcePath, isDirectory: &isDirectory)
        if (!exists || isDirectory.boolValue), trimmed.hasPrefix("/root/.ogent/") {
            let suffix = String(trimmed.dropFirst("/root/.ogent/".count))
            let fallback = dataURL.appendingPathComponent("root/.minis/" + suffix)
            let fallbackPath = fallback.standardizedFileURL.path
            var fallbackIsDirectory: ObjCBool = false
            if fallbackPath.hasPrefix(rootPath + "/"),
               fm.fileExists(atPath: fallbackPath, isDirectory: &fallbackIsDirectory),
               !fallbackIsDirectory.boolValue {
                source = fallback
                sourcePath = fallbackPath
                isDirectory = fallbackIsDirectory
                exists = true
            }
        } else if (!exists || isDirectory.boolValue), trimmed.hasPrefix("/root/.minis/") {
            let suffix = String(trimmed.dropFirst("/root/.minis/".count))
            let fallback = dataURL.appendingPathComponent("root/.ogent/" + suffix)
            let fallbackPath = fallback.standardizedFileURL.path
            var fallbackIsDirectory: ObjCBool = false
            if fallbackPath.hasPrefix(rootPath + "/"),
               fm.fileExists(atPath: fallbackPath, isDirectory: &fallbackIsDirectory),
               !fallbackIsDirectory.boolValue {
                source = fallback
                sourcePath = fallbackPath
                isDirectory = fallbackIsDirectory
                exists = true
            }
        }
        guard exists, !isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }

        let targetDirectory = exportsURL
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let requestedName = destinationRelativePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)
        let filename = requestedName?.isEmpty == false ? requestedName! : source.lastPathComponent
        let target = uniqueDestination(in: targetDirectory, filename: filename)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: URL(fileURLWithPath: sourcePath), to: target)

        let attrs = try? fm.attributesOfItem(atPath: target.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ISHExportedArtifact(sourceGuestPath: trimmed, destinationURL: target, byteCount: bytes)
    }

    static func exportGeneratedArtifacts(modifiedAfter: Date, limit: Int = 12) -> [ISHExportedArtifact] {
        let fm = FileManager.default
        let roots: [(guest: String, url: URL)] = [
            ("/root/.ogent/artifacts", dataURL.appendingPathComponent("root/.ogent/artifacts", isDirectory: true)),
            ("/root/.ogent/workspace", dataURL.appendingPathComponent("root/.ogent/workspace", isDirectory: true)),
            ("/root/.minis/artifacts", dataURL.appendingPathComponent("root/.minis/artifacts", isDirectory: true)),
            ("/root/.minis/workspace", dataURL.appendingPathComponent("root/.minis/workspace", isDirectory: true))
        ]
        let deliverableExtensions: Set<String> = [
            "pptx", "ppt", "key", "pdf", "docx", "xlsx",
            "zip", "tar", "gz", "tgz",
            "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav",
            "html", "htm", "md", "csv", "json", "txt",
            "png", "jpg", "jpeg", "gif", "svg"
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var candidates: [(guest: String, modified: Date)] = []

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root.url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                let ext = fileURL.pathExtension.lowercased()
                guard deliverableExtensions.contains(ext) else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                guard modified >= modifiedAfter.addingTimeInterval(-2) else { continue }
                let rel = fileURL.path.replacingOccurrences(of: root.url.path, with: "")
                let guest = root.guest + rel
                candidates.append((guest, modified))
            }
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .compactMap { try? exportArtifact(guestPath: $0.guest) }
    }

    static func importModelFile(from sourceURL: URL) throws -> ISHImportedModel {
        let fm = FileManager.default
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "gguf" else {
            throw RootfsModelImportError.unsupportedFileType
        }
        let secureAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secureAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard try fileHasMagic(sourceURL, magic: Array("GGUF".utf8)) else {
            throw RootfsModelImportError.invalidGGUFMagic
        }
        ensureOgentLayout(in: dataURL)
        try fm.createDirectory(at: ogentModelsURL, withIntermediateDirectories: true)

        let destination = uniqueDestination(in: ogentModelsURL, filename: sourceURL.lastPathComponent)
        try fm.copyItem(at: sourceURL, to: destination)
        let attrs = try? fm.attributesOfItem(atPath: destination.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let guestPath = "/root/.ogent/models/\(destination.lastPathComponent)"
        return ISHImportedModel(guestPath: guestPath, hostURL: destination, byteCount: bytes)
    }

    static func importLocalModelRunner(from sourceURL: URL) throws -> ISHImportedModel {
        let fm = FileManager.default
        let secureAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secureAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard try fileIsISHCompatibleELF(sourceURL) else {
            throw RootfsModelImportError.unsupportedRunnerType
        }
        ensureOgentLayout(in: dataURL)
        try fm.createDirectory(at: ogentModelBinariesURL, withIntermediateDirectories: true)

        let destination = ogentModelBinariesURL.appendingPathComponent("llama-server")
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: sourceURL, to: destination)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        let attrs = try? fm.attributesOfItem(atPath: destination.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ISHImportedModel(
            guestPath: "/root/.ogent/models/bin/llama-server",
            hostURL: destination,
            byteCount: bytes
        )
    }

    static func runImportValidationSelfTest() -> String {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("ogent-import-validation-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }
            let gguf = directory.appendingPathComponent("valid.gguf")
            let badGGUF = directory.appendingPathComponent("invalid.gguf")
            let elf = directory.appendingPathComponent("llama-server")
            let elf64 = directory.appendingPathComponent("llama-server-x86_64")
            let armELF = directory.appendingPathComponent("llama-server-arm")
            let macho = directory.appendingPathComponent("llama-server-macho")
            try Data(Array("GGUFselftest".utf8)).write(to: gguf)
            try Data(Array("NOPEselftest".utf8)).write(to: badGGUF)
            try Data(Self.elfHeader(classByte: 0x02, machine: 0x00b7)).write(to: elf)
            try Data(Self.elfHeader(classByte: 0x02, machine: 0x003e)).write(to: elf64)
            try Data(Self.elfHeader(classByte: 0x01, machine: 0x0028)).write(to: armELF)
            try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: macho)

            let validGGUF = try fileHasMagic(gguf, magic: Array("GGUF".utf8))
            let rejectsBadGGUF = try !fileHasMagic(badGGUF, magic: Array("GGUF".utf8))
            let validELF = try fileIsISHCompatibleELF(elf)
            let rejectsX8664ELF = try !fileIsISHCompatibleELF(elf64)
            let rejectsARMELF = try !fileIsISHCompatibleELF(armELF)
            let rejectsMachO = try !fileIsISHCompatibleELF(macho)
            let stagedRoot = directory.appendingPathComponent("rootfs-data", isDirectory: true)
            let ogentRoot = stagedRoot.appendingPathComponent("root/.ogent", isDirectory: true)
            let bundled = directory.appendingPathComponent("OgentLocalModel", isDirectory: true)
            try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
            try fm.createDirectory(at: ogentRoot, withIntermediateDirectories: true)
            try Data(Self.elfHeader(classByte: 0x02, machine: 0x00b7)).write(to: bundled.appendingPathComponent("llama-server"))
            try Data(Array("GGUFbundled-model".utf8)).write(to: bundled.appendingPathComponent("tiny.gguf"))
            stageBundledLocalModelAssetsIfPresent(in: stagedRoot, ogentRoot: ogentRoot, bundleDirectory: bundled)
            let stagedRunner = ogentRoot.appendingPathComponent("models/bin/llama-server")
            let stagedModel = ogentRoot.appendingPathComponent("models/tiny.gguf")
            let config = try? String(contentsOf: ogentRoot.appendingPathComponent("models/config.env"), encoding: .utf8)
            let readiness = try? String(contentsOf: ogentRoot.appendingPathComponent("models/readiness.env"), encoding: .utf8)
            let bundledStageOK = fm.fileExists(atPath: stagedRunner.path)
                && fm.fileExists(atPath: stagedModel.path)
                && config?.contains("OGENT_LOCAL_MODEL_RUNTIME_KIND='llama.cpp'") == true
                && config?.contains("OGENT_LOCAL_MODEL_FILE='/root/.ogent/models/tiny.gguf'") == true
                && readiness?.contains("LOCAL_MODEL_READINESS_STATE='ready_to_start'") == true
            let ok = validGGUF
                && rejectsBadGGUF
                && validELF
                && rejectsX8664ELF
                && rejectsARMELF
                && rejectsMachO
                && bundledStageOK
            return ok ? "rootfs_import_validation_ok runner_arch=aarch64 gguf_magic=ok bundled_stage=ok" : "rootfs_import_validation_failed"
        } catch {
            return "rootfs_import_validation_failed \(error.localizedDescription)"
        }
    }

    private static var applicationSupportURL: URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private static var documentsURL: URL {
        (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? applicationSupportURL
    }

    private static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = directory.appendingPathComponent(cleaned)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func fileHasMagic(_ url: URL, magic: [UInt8]) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: magic.count) ?? Data()
        return Array(data) == magic
    }

    private static func fileIsISHCompatibleELF(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 20) ?? Data()
        let bytes = Array(data)
        guard bytes.count >= 20 else { return false }
        guard Array(bytes[0..<4]) == [0x7f, 0x45, 0x4c, 0x46] else { return false }

        let elfClass = bytes[4]
        let dataEncoding = bytes[5]
        guard dataEncoding == 0x01 else { return false }

        let type = UInt16(bytes[16]) | (UInt16(bytes[17]) << 8)
        let machine = UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
        let executableOrSharedObject = type == 0x0002 || type == 0x0003
        guard executableOrSharedObject else { return false }
        return elfClass == expectedGuestELFClass && machine == expectedGuestELFMachine
    }

    private static var expectedGuestELFClass: UInt8 { 0x02 }

    private static var expectedGuestELFMachine: UInt16 { 0x00b7 }

    private static func elfHeader(classByte: UInt8, machine: UInt16, type: UInt16 = 0x0002) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 52)
        bytes[0] = 0x7f
        bytes[1] = 0x45
        bytes[2] = 0x4c
        bytes[3] = 0x46
        bytes[4] = classByte
        bytes[5] = 0x01
        bytes[6] = 0x01
        bytes[16] = UInt8(type & 0x00ff)
        bytes[17] = UInt8((type >> 8) & 0x00ff)
        bytes[18] = UInt8(machine & 0x00ff)
        bytes[19] = UInt8((machine >> 8) & 0x00ff)
        return bytes
    }

    private static func ensureOgentLayout(in dataURL: URL) {
        let fm = FileManager.default
        let root = dataURL.appendingPathComponent("root", isDirectory: true)
        let ogentRoot = root.appendingPathComponent(".ogent", isDirectory: true)
        let legacyRoot = root.appendingPathComponent(".minis", isDirectory: true)
        let profileD = dataURL.appendingPathComponent("etc/profile.d", isDirectory: true)
        let apkDir = dataURL.appendingPathComponent("etc/apk", isDirectory: true)
        let localBin = dataURL.appendingPathComponent("usr/local/bin", isDirectory: true)

        [
            root,
            profileD,
            apkDir,
            localBin
        ].forEach { try? fm.createDirectory(at: $0, withIntermediateDirectories: true) }

        if symlinkDestination(at: legacyRoot) != nil {
            try? fm.removeItem(at: legacyRoot)
        }
        if symlinkDestination(at: ogentRoot) != nil {
            try? fm.removeItem(at: ogentRoot)
        }
        if !fm.fileExists(atPath: ogentRoot.path) {
            try? fm.createDirectory(at: ogentRoot, withIntermediateDirectories: true)
            if fm.fileExists(atPath: legacyRoot.path) {
                try? copyContents(from: legacyRoot, to: ogentRoot, using: fm)
            }
        }
        try? fm.createDirectory(at: ogentRoot, withIntermediateDirectories: true)
        [
            "workspace", "artifacts", "tasks", "tasks/automations", "memory", "memory/wiki",
            "memory/wiki/topics", "skills", "subagents", "automations", "inbox", "logs", "tmp",
            "sessions", "project-manifests", "checkpoints", "env.d", "models", "models/bin",
            "rootfs-profiles", "mcp-sessions"
        ].forEach { child in
            try? fm.createDirectory(
                at: ogentRoot.appendingPathComponent(child, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        stageBundledLocalModelAssetsIfPresent(in: dataURL, ogentRoot: ogentRoot)

        writeIfMissing("Ogent on iSH\n", to: dataURL.appendingPathComponent("etc/hostname"))
        writeIfMissing("Welcome to Ogent Alpine Linux.\n", to: dataURL.appendingPathComponent("etc/motd"))

        let profile = """
        export OGENT_ROOT=/root/.ogent
        export MINIS_ROOT=/root/.ogent
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export PAGER=cat
        export EDITOR=vi
        export PS1='root@ogent:\\w# '
        cd /root 2>/dev/null || cd /
        """
        write(profile + "\n", to: profileD.appendingPathComponent("oases-ogent.sh"))
        write(profile + "\n", to: root.appendingPathComponent(".profile"))

        let repositories = dataURL.appendingPathComponent("etc/apk/repositories")
        writeIfMissing("""
        https://dl-cdn.alpinelinux.org/alpine/v3.21/main
        https://dl-cdn.alpinelinux.org/alpine/v3.21/community

        """, to: repositories)

        ISHOgentAgentRuntime.install(into: dataURL)
    }

    private static func stageBundledLocalModelAssetsIfPresent(
        in dataURL: URL,
        ogentRoot: URL,
        bundleDirectory: URL? = Bundle.main.url(forResource: "OgentLocalModel", withExtension: nil)
    ) {
        guard let bundleDirectory else { return }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: bundleDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let modelDir = ogentRoot.appendingPathComponent("models", isDirectory: true)
        let binDir = modelDir.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        let runnerDestination = binDir.appendingPathComponent("llama-server")
        if !fm.fileExists(atPath: runnerDestination.path),
           let runnerSource = bundledRunnerURL(in: bundleDirectory),
           (try? fileIsISHCompatibleELF(runnerSource)) == true {
            try? fm.copyItem(at: runnerSource, to: runnerDestination)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerDestination.path)
            NSLog("[ISHRootfs] staged bundled llama-server at \(runnerDestination.path)")
        } else if let runnerSource = bundledRunnerURL(in: bundleDirectory),
                  (try? fileIsISHCompatibleELF(runnerSource)) != true {
            NSLog("[ISHRootfs] skipped bundled llama-server because it is not an iSH-compatible aarch64 Linux ELF")
        }

        let ggufSource = bundledGGUFURL(in: bundleDirectory)
        var stagedModelURL: URL?
        if let ggufSource,
           (try? fileHasMagic(ggufSource, magic: Array("GGUF".utf8))) == true {
            let destination = modelDir.appendingPathComponent(ggufSource.lastPathComponent)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: ggufSource, to: destination)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                NSLog("[ISHRootfs] staged bundled GGUF at \(destination.path)")
            }
            stagedModelURL = destination
        }

        let runnerReady = fm.fileExists(atPath: runnerDestination.path)
            && ((try? fileIsISHCompatibleELF(runnerDestination)) == true)
        guard runnerReady, let stagedModelURL else { return }

        let guestModelPath = "/root/.ogent/models/\(stagedModelURL.lastPathComponent)"
        let modelID = (stagedModelURL.lastPathComponent as NSString).deletingPathExtension
        let configURL = modelDir.appendingPathComponent("config.env")
        if !fm.fileExists(atPath: configURL.path) {
            write("""
            OGENT_LOCAL_MODEL_BASE_URL='http://127.0.0.1:11434/v1'
            OGENT_LOCAL_MODEL_ID='\(shellLiteral(modelID))'
            OGENT_LOCAL_MODEL_API_KEY=''
            OGENT_LOCAL_MODEL_START_COMMAND=''
            OGENT_LOCAL_MODEL_RUNTIME_KIND='llama.cpp'
            OGENT_LOCAL_MODEL_FILE='\(shellLiteral(guestModelPath))'
            OGENT_LOCAL_MODEL_EXTRA_ARGS='--ctx-size 4096'

            """, to: configURL)
        }

        let readinessURL = modelDir.appendingPathComponent("readiness.env")
        if !fm.fileExists(atPath: readinessURL.path) {
            write("""
            LOCAL_MODEL_READINESS_STATE='ready_to_start'
            LOCAL_MODEL_READINESS_REASON='bundled_runner_and_gguf_available'
            LOCAL_MODEL_RUNNER_STATE='available'
            LOCAL_MODEL_GGUF_STATE='available'
            LOCAL_MODEL_RUNTIME_STATE='not_probed'
            LOCAL_MODEL_NEXT_COMMAND='/bin/sh /usr/local/bin/ogent-agent model-bootstrap --require-real'
            LOCAL_MODEL_BASE_URL='http://127.0.0.1:11434/v1'
            LOCAL_MODEL_ID='\(shellLiteral(modelID))'
            LOCAL_MODEL_UPDATED_AT='bundled'

            """, to: readinessURL)
        }
    }

    private static func bundledRunnerURL(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("llama-server")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let nested = directory.appendingPathComponent("bin/llama-server")
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return nil
    }

    private static func bundledGGUFURL(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "gguf" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { return url }
        }
        return nil
    }

    private static func isExportableGuestPath(_ path: String) -> Bool {
        path.hasPrefix("/root/.ogent/artifacts/")
            || path.hasPrefix("/root/.ogent/workspace/")
            || path.hasPrefix("/root/.minis/artifacts/")
            || path.hasPrefix("/root/.minis/workspace/")
    }

    private static func symlinkDestination(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private static func copyContents(from source: URL, to destination: URL, using fm: FileManager) throws {
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                continue
            }
            try? fm.copyItem(at: item, to: target)
        }
    }

    private static func writeIfMissing(_ content: String, to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(content, to: url)
    }

    private static func write(_ content: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func shellLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func directoryScan(_ url: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (0, 0) }
        var bytes: Int64 = 0
        var files = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: nil) else {
            return (0, 0)
        }
        for case let item as URL in enumerator {
            files += 1
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
        }
        return (bytes, files)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
