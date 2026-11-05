//
//  BuiltinSkillSynchronizer.swift
//  OasesChatApp
//
//  Installs and updates the built-in skills shipped in
//  `Resources/BuiltinSkills` (vendored from OpenMinis/MinisSkills by
//  scripts/skills/build_builtin_skills.py) into the shared skills directory,
//  without ever clobbering user data.
//
//  Per-file rules, keyed on the sha256 of the bytes this synchronizer last
//  wrote at each path (persisted in the state file, never inside the skill
//  folders):
//    • missing on disk                          → copy from the bundle
//    • on disk == previously installed != new   → overwrite (user didn't touch it)
//    • on disk != previously installed != new   → keep the user's version
//    • previously installed, gone from manifest → remove only if unmodified
//    • never listed in state or manifest        → never touched (.venv/, user files)
//
//  SkillStore owns the DB side (rows, enable state, same-name user skills);
//  this type only moves files and computes the next state, so it can be
//  exercised in tests against temporary directories.
//

import CryptoKit
import Foundation

// MARK: - Manifest

/// `BuiltinSkills/manifest.json`, written by build_builtin_skills.py.
struct BuiltinSkillsManifest: Codable, Equatable {
    struct Upstream: Codable, Equatable {
        let repo: String
        let commit: String
    }

    struct Skill: Codable, Equatable {
        let id: String
        let name: String
        let version: String
        let defaultEnabled: Bool
        let disabledReason: String?
        let contentHash: String
        /// Relative path → sha256 hex.
        let files: [String: String]
    }

    let schemaVersion: Int
    let upstream: Upstream
    let bundleHash: String
    let skills: [Skill]

    static let fileName = "manifest.json"
    static let supportedSchemaVersion = 1

    static func load(from bundleDir: URL) throws -> BuiltinSkillsManifest {
        let data = try Data(contentsOf: bundleDir.appendingPathComponent(fileName))
        let manifest = try JSONDecoder().decode(BuiltinSkillsManifest.self, from: data)
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw BuiltinSkillSyncError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    func skill(id: String) -> Skill? {
        skills.first { $0.id == id }
    }
}

enum BuiltinSkillSyncError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "Unsupported built-in skills manifest schema \(v)."
        }
    }
}

// MARK: - Persisted State

/// What the synchronizer last installed. Lives in
/// `Library/MinisChat/builtin-skills-state.json`.
struct BuiltinSkillsState: Codable, Equatable {
    struct InstalledSkill: Codable, Equatable {
        var contentHash: String
        /// Relative path → sha256 of the bytes last written there by the
        /// synchronizer. A path is absent when the user's copy was kept
        /// without ever having been installed by us.
        var files: [String: String]
    }

    var schemaVersion: Int = 1
    var bundleHash: String
    var skills: [String: InstalledSkill]
}

// MARK: - Synchronizer

struct BuiltinSkillSynchronizer {
    /// Directory holding `<id>/…` folders and `manifest.json`.
    let bundleDir: URL
    let manifest: BuiltinSkillsManifest
    /// Destination skills directory (`AIChatViewModel.minisSkillsPersistentDir`).
    let skillsDir: URL
    /// JSON state file (`Library/MinisChat/builtin-skills-state.json`).
    let stateURL: URL

    private var fm: FileManager { .default }

    /// Per-skill outcome, mostly for logging and tests.
    struct SkillReport: Equatable {
        let id: String
        var installed: [String] = []
        var updated: [String] = []
        var keptUserModified: [String] = []
        var removed: [String] = []
        var keptAfterUpstreamRemoval: [String] = []
        var failed: [String] = []

        /// True when this run wrote or removed any file of the skill.
        var changedFiles: Bool { !installed.isEmpty || !updated.isEmpty || !removed.isEmpty }
    }

    struct Result {
        /// Skills present in the manifest that were synced.
        var reports: [String: SkillReport] = [:]
        /// Skills that were installed before but are gone from the manifest.
        var retired: [String: SkillReport] = [:]
        /// Skills left alone because a user skill owns the id.
        var skipped: Set<String> = []
        /// State to persist once the caller has finished its own bookkeeping.
        var state: BuiltinSkillsState
    }

    // MARK: State I/O

    func loadState() -> BuiltinSkillsState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(BuiltinSkillsState.self, from: data)
    }

    func saveState(_ state: BuiltinSkillsState) throws {
        try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: Fast Path

    /// Cheap check: nothing changed since the last run and every built-in
    /// skill still has its SKILL.md on disk.
    func isUpToDate(_ state: BuiltinSkillsState?) -> Bool {
        guard let state, state.bundleHash == manifest.bundleHash else { return false }
        return manifest.skills.allSatisfy {
            fm.fileExists(atPath: skillsDir.appendingPathComponent($0.id).appendingPathComponent("SKILL.md").path)
        }
    }

    /// Ids (among `ids`) whose skills.db row belongs to the user — any
    /// import source other than `builtin`. Those skills are never touched.
    static func userOwnedIds<S: Sequence>(among ids: S, importSources: [String: String]) -> Set<String>
    where S.Element == String {
        Set(ids.filter { id in
            guard let source = importSources[id] else { return false }
            return source != SkillImportSource.builtin.dbValue
        })
    }

    // MARK: Full Sync

    func sync(previous: BuiltinSkillsState?, skipping: Set<String> = []) -> Result {
        var result = Result(state: BuiltinSkillsState(bundleHash: manifest.bundleHash, skills: [:]))
        let logger = AppLogger(category: "BuiltinSkills")

        for skill in manifest.skills {
            if skipping.contains(skill.id) {
                result.skipped.insert(skill.id)
                logger.info("[Builtin] skip '\(skill.id)': a user skill owns this id")
                continue
            }
            let previousFiles = previous?.skills[skill.id]?.files ?? [:]
            let (report, installed) = syncSkill(skill, previousFiles: previousFiles)
            result.reports[skill.id] = report
            result.state.skills[skill.id] = BuiltinSkillsState.InstalledSkill(
                contentHash: skill.contentHash, files: installed
            )
            log(report, logger: logger)
        }

        for (id, installed) in previous?.skills ?? [:] where manifest.skill(id: id) == nil {
            if skipping.contains(id) {
                result.skipped.insert(id)
                continue
            }
            var report = SkillReport(id: id)
            removeUnmodified(installed.files, keeping: [:], skillDir: skillDir(id), report: &report)
            removeIfEmpty(skillDir(id))
            result.retired[id] = report
            log(report, logger: logger)
        }

        return result
    }

    // MARK: Per-skill

    private func skillDir(_ id: String) -> URL {
        skillsDir.appendingPathComponent(id, isDirectory: true)
    }

    private func syncSkill(
        _ skill: BuiltinSkillsManifest.Skill,
        previousFiles: [String: String]
    ) -> (SkillReport, [String: String]) {
        var report = SkillReport(id: skill.id)
        var installed: [String: String] = [:]
        let destRoot = skillDir(skill.id)
        let srcRoot = bundleDir.appendingPathComponent(skill.id, isDirectory: true)

        for (rel, newSha) in skill.files.sorted(by: { $0.key < $1.key }) {
            guard Self.isSafeRelativePath(rel) else {
                report.failed.append(rel)
                continue
            }
            let dest = destRoot.appendingPathComponent(rel)
            let src = srcRoot.appendingPathComponent(rel)
            let prevSha = previousFiles[rel]

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dest.path, isDirectory: &isDir)

            if !exists {
                if install(src, to: dest) {
                    installed[rel] = newSha
                    report.installed.append(rel)
                } else {
                    report.failed.append(rel)
                }
                continue
            }
            if isDir.boolValue {
                // Something else lives at this path — treat it as user data.
                if let prevSha { installed[rel] = prevSha }
                report.keptUserModified.append(rel)
                continue
            }
            // Unchanged upstream and present on disk: whatever is there is
            // either our bytes or the user's edit — keep it without hashing.
            if prevSha == newSha {
                installed[rel] = newSha
                continue
            }
            let diskSha = Self.sha256Hex(of: dest)
            if diskSha == newSha {
                installed[rel] = newSha
            } else if let prevSha, diskSha == prevSha {
                if install(src, to: dest) {
                    installed[rel] = newSha
                    report.updated.append(rel)
                } else {
                    installed[rel] = prevSha
                    report.failed.append(rel)
                }
            } else {
                if let prevSha { installed[rel] = prevSha }
                report.keptUserModified.append(rel)
            }
        }

        removeUnmodified(previousFiles, keeping: skill.files, skillDir: destRoot, report: &report)
        return (report, installed)
    }

    /// Remove files we installed earlier that are no longer in `keeping`,
    /// but only when their bytes are still exactly what we wrote.
    private func removeUnmodified(
        _ previousFiles: [String: String],
        keeping: [String: String],
        skillDir: URL,
        report: inout SkillReport
    ) {
        for (rel, prevSha) in previousFiles.sorted(by: { $0.key < $1.key }) where keeping[rel] == nil {
            guard Self.isSafeRelativePath(rel) else { continue }
            let dest = skillDir.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dest.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard Self.sha256Hex(of: dest) == prevSha else {
                report.keptAfterUpstreamRemoval.append(rel)
                continue
            }
            do {
                try fm.removeItem(at: dest)
                report.removed.append(rel)
                pruneEmptyParents(of: dest, stoppingAt: skillDir)
            } catch {
                report.failed.append(rel)
            }
        }
    }

    /// Copy via a sibling temp file + rename(2) so a crash never leaves a
    /// half-written file behind.
    private func install(_ src: URL, to dest: URL) -> Bool {
        guard fm.fileExists(atPath: src.path) else { return false }
        let parent = dest.deletingLastPathComponent()
        let tmp = parent.appendingPathComponent(".\(dest.lastPathComponent).builtin-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: tmp)
            guard rename(tmp.path, dest.path) == 0 else {
                try? fm.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
    }

    private func pruneEmptyParents(of file: URL, stoppingAt root: URL) {
        let rootPath = root.standardizedFileURL.path
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(rootPath + "/") {
            guard (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true else { return }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    private func removeIfEmpty(_ dir: URL) {
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    private func log(_ report: SkillReport, logger: AppLogger) {
        if !report.installed.isEmpty || !report.updated.isEmpty || !report.removed.isEmpty {
            logger.info("[Builtin] '\(report.id)': installed=\(report.installed.count) updated=\(report.updated.count) removed=\(report.removed.count)")
        }
        for rel in report.keptUserModified {
            logger.info("[Builtin] '\(report.id)': keeping user-modified \(rel)")
        }
        for rel in report.keptAfterUpstreamRemoval {
            logger.info("[Builtin] '\(report.id)': upstream removed \(rel) but it was modified — keeping")
        }
        for rel in report.failed {
            logger.warning("[Builtin] '\(report.id)': failed to sync \(rel)")
        }
    }

    // MARK: Helpers

    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Manifest paths are relative, slash-separated and never escape the
    /// skill folder.
    static func isSafeRelativePath(_ rel: String) -> Bool {
        guard !rel.isEmpty, !rel.hasPrefix("/") else { return false }
        return !rel.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
