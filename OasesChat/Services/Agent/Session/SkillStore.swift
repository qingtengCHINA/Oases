//
//  SkillStore.swift
//  OasesChatApp
//
//  Manages AI skill (SKILL.md) lifecycle: import, storage, session overrides,
//  and system prompt injection.  All metadata is stored in a SQLite database
//  (skills.db) so SKILL.md files stay untouched and compatible with the
//  official Anthropic skill format.
//

import Foundation
import SQLite3
import Compression

// MARK: - Skill Model

enum SkillImportSource: Codable, Equatable {
    case url(String)
    case file       // imported via file picker / paste
    case bundled     // shipped with app
    case session     // created by the AI agent during a chat session
    case builtin     // vendored OpenMinis/MinisSkills, see BuiltinSkillSynchronizer

    /// Encode to a simple string for DB storage: "url:<value>", "file", "bundled", "session", "builtin"
    var dbValue: String {
        switch self {
        case .url(let u): return "url:\(u)"
        case .file: return "file"
        case .bundled: return "bundled"
        case .session: return "session"
        case .builtin: return "builtin"
        }
    }

    static func fromDB(_ value: String) -> SkillImportSource {
        if value.hasPrefix("url:") {
            return .url(String(value.dropFirst(4)))
        } else if value == "bundled" {
            return .bundled
        } else if value == "session" {
            return .session
        } else if value == "builtin" {
            return .builtin
        }
        return .file
    }
}

struct Skill: Identifiable {
    let id: String
    var name: String
    var description: String
    var version: String
    var importSource: SkillImportSource
    var isEnabled: Bool
    var installedAt: Date
    var updatedAt: Date

    /// Raw body content (everything after YAML frontmatter)
    var body: String

    /// Normalized usage count (0–100 range after normalization, raw count before).
    var useCount: Double = 0

    var sourceURL: String? {
        if case .url(let u) = importSource { return u }
        return nil
    }
}

// MARK: - SkillStore

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [Skill] = []

    private let fm = FileManager.default
    private var db: OpaquePointer?

    private var skillsDir: URL {
        AIChatViewModel.minisSkillsPersistentDir
    }

    func skillDirectoryURL(for skillId: String) -> URL {
        return skillsDir.appendingPathComponent(skillId)
    }

    private var dbPath: String {
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("MinisChat/skills.db").path
    }

    // Skill files live only in `skillsDir`. The guest reaches them through
    // the `/var/minis/skills` mapping (ISHExecutionCoordinator bind mount /
    // OasesFsRouter hook); nothing is mirrored into a rootfs copy anymore.

    private init() {
        openDatabase()
        createTables()
        migrateLegacyGuestSkills()
        // Before loadSkills(): otherwise discoverNewSkillsOnDisk would
        // register built-in folders as `.session` skills.
        syncBuiltinSkills()
        loadSkills()
        installBundledSkills()
        migrateMarkBundledSkillsDirty()
    }

    /// Until 1.0.3 the guest shell's `/var/minis/skills` resolved to
    /// `Library/OasesChat/oases/_global/skills` (see
    /// `OasesFsRouter.skillsHostURL`), so skills the agent created from the
    /// shell landed there instead of `skillsDir`. Move them over so they stay
    /// visible (loadSkills then registers them as session skills). Never
    /// overwrites a folder that already exists in `skillsDir`.
    private func migrateLegacyGuestSkills() {
        let legacyDir = OasesFsRouter.shared.legacyGlobalSkillsURL
        guard legacyDir.standardizedFileURL != skillsDir.standardizedFileURL,
              let entries = try? fm.contentsOfDirectory(
                at: legacyDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              ), !entries.isEmpty else { return }
        let logger = AppLogger(category: "SkillStore")
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let dest = skillsDir.appendingPathComponent(entry.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else {
                logger.info("[Migrate] legacy guest skill '\(entry.lastPathComponent)' left in place — already exists in skills dir")
                continue
            }
            do {
                try fm.moveItem(at: entry, to: dest)
                logger.info("[Migrate] moved legacy guest skill '\(entry.lastPathComponent)' into skills dir")
            } catch {
                logger.warning("[Migrate] could not move legacy guest skill '\(entry.lastPathComponent)': \(error.localizedDescription)")
            }
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Reload / Close (for backup & restore)

    func closeDatabase() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func reloadDatabase() {
        closeDatabase()
        openDatabase()
        createTables()
        syncBuiltinSkills()
        loadSkills()
    }

    // MARK: - Database

    private func openDatabase() {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[SkillStore] Failed to open skills.db")
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS skills (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            version TEXT NOT NULL DEFAULT '1.0.0',
            import_source TEXT NOT NULL DEFAULT 'file',
            is_enabled INTEGER NOT NULL DEFAULT 1,
            installed_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session_skill_overrides (
            session_id TEXT NOT NULL,
            skill_id TEXT NOT NULL,
            is_enabled INTEGER NOT NULL,
            PRIMARY KEY (session_id, skill_id)
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
        migrateAddUseCount()
    }

    /// Add use_count column if it doesn't exist (migration).
    private func migrateAddUseCount() {
        let sql = "ALTER TABLE skills ADD COLUMN use_count REAL NOT NULL DEFAULT 0"
        sqlite3_exec(db, sql, nil, nil, nil) // silently fails if column already exists
    }

    // MARK: - DB Operations

    private static let SQLITE_TRANSIENT_DB = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func dbInsertSkill(id: String, name: String, description: String, version: String,
                               importSource: SkillImportSource, isEnabled: Bool,
                               installedAt: Date, updatedAt: Date) {
        // Use INSERT … ON CONFLICT to preserve use_count (local-only, not synced).
        let sql = """
        INSERT INTO skills (id, name, description, version, import_source, is_enabled, installed_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            description = excluded.description,
            version = excluded.version,
            import_source = excluded.import_source,
            is_enabled = excluded.is_enabled,
            updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 3, (description as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 4, (version as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 5, (importSource.dbValue as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_int(stmt, 6, isEnabled ? 1 : 0)
        sqlite3_bind_double(stmt, 7, installedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 8, updatedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func dbUpdateSkillMeta(id: String, name: String, description: String, version: String, updatedAt: Date) {
        let sql = "UPDATE skills SET name = ?, description = ?, version = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (description as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 3, (version as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)
    }

    /// Bump only the updatedAt timestamp (in-memory + DB) without changing other metadata.
    /// Called by CloudSyncEngine when filesystem files are newer than the DB timestamp.
    func bumpUpdatedAt(skillId: String, to date: Date) {
        if let idx = skills.firstIndex(where: { $0.id == skillId }) {
            skills[idx].updatedAt = date
            let sql = "UPDATE skills SET updated_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
            sqlite3_step(stmt)
        }
    }

    private func dbSetEnabled(skillId: String, enabled: Bool) {
        let sql = "UPDATE skills SET is_enabled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)
    }

    private func dbSetImportSource(skillId: String, source: SkillImportSource) {
        let sql = "UPDATE skills SET import_source = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (source.dbValue as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)
    }

    /// Raw `import_source` + `updated_at` of every row, keyed by id. Used by
    /// the built-in sync, which runs before `skills` is loaded.
    private func dbSkillRows() -> [String: (importSource: String, updatedAt: Date)] {
        var rows: [String: (importSource: String, updatedAt: Date)] = [:]
        let sql = "SELECT id, import_source, updated_at FROM skills"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let source = String(cString: sqlite3_column_text(stmt, 1))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            rows[id] = (source, updatedAt)
        }
        return rows
    }

    private func dbDeleteSkill(id: String) {
        let sql = "DELETE FROM skills WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)

        // Also clean session overrides
        let sql2 = "DELETE FROM session_skill_overrides WHERE skill_id = ?"
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt2) }
        sqlite3_bind_text(stmt2, 1, (id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt2)
    }

    private func dbSetSessionOverride(sessionId: String, skillId: String, enabled: Bool) {
        let sql = "INSERT OR REPLACE INTO session_skill_overrides (session_id, skill_id, is_enabled) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_int(stmt, 3, enabled ? 1 : 0)
        sqlite3_step(stmt)
    }

    private func dbDeleteSessionOverride(sessionId: String, skillId: String) {
        let sql = "DELETE FROM session_skill_overrides WHERE session_id = ? AND skill_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)
    }

    private func dbSessionOverride(sessionId: String, skillId: String) -> Bool? {
        let sql = "SELECT is_enabled FROM session_skill_overrides WHERE session_id = ? AND skill_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_bind_text(stmt, 2, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(stmt, 0) != 0
    }

    // MARK: - Bundled Skills

    private static let skillCreatorVersion = "2.1.0"
    private static let skillCreatorContent = """
---
name: skill-creator
version: 2.1.0
description: Guide for creating effective skills. This skill should be used when users want to create a new skill (or update an existing skill) that extends the agent's capabilities with specialized knowledge, workflows, or tool integrations.
---

# Skill Creator

This skill provides guidance for creating effective skills.

## About Skills

Skills are modular, self-contained packages that extend the agent's capabilities by providing
specialized knowledge, workflows, and tools. Think of them as "onboarding guides" for specific
domains or tasks—they transform the agent from a general-purpose agent into a specialized agent
equipped with procedural knowledge that no model can fully possess.

### What Skills Provide

1. Specialized workflows - Multi-step procedures for specific domains
2. Tool integrations - Instructions for working with specific file formats or APIs
3. Domain expertise - Company-specific knowledge, schemas, business logic
4. Bundled resources - Scripts, references, and assets for complex and repetitive tasks

## Core Principles

### Concise is Key

The context window is a public good. Skills share the context window with everything else the agent needs: system prompt, conversation history, other Skills' metadata, and the actual user request.

**Default assumption: the agent is already very smart.** Only add context the agent doesn't already have. Challenge each piece of information: "Does the agent really need this explanation?" and "Does this paragraph justify its token cost?"

Prefer concise examples over verbose explanations.

### Set Appropriate Degrees of Freedom

Match the level of specificity to the task's fragility and variability:

- **High freedom (text-based instructions)**: Use when multiple approaches are valid.
- **Medium freedom (pseudocode or scripts with parameters)**: Use when a preferred pattern exists.
- **Low freedom (specific scripts, few parameters)**: Use when operations are fragile, consistency is critical, or a specific sequence must be followed.

### Anatomy of a Skill

Every skill consists of a required SKILL.md file and optional bundled resources:

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name + description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/       - Executable code
    ├── references/    - Documentation loaded as needed
    └── assets/        - Files used in output (templates, icons, etc.)
```

#### SKILL.md Frontmatter

- `name` (required): The skill name
- `description` (required): What the skill does and when to trigger it. Be comprehensive—this is the primary triggering mechanism.

#### SKILL.md Body

Instructions and guidance, loaded after the skill triggers. Keep under 500 lines; split into reference files when approaching this limit.

### Progressive Disclosure

Skills use three loading levels:
1. **Metadata** - Always in context (~100 words)
2. **SKILL.md body** - When skill triggers (<5k words)
3. **Bundled resources** - As needed (unlimited)

## Skill Creation Process

1. **Understand** the skill with concrete examples from the user
2. **Plan** reusable contents (scripts, references, assets)
3. **Create** the SKILL.md with proper frontmatter and instructions
4. **Test** by using the skill on real tasks
5. **Iterate** based on actual usage

### Writing the SKILL.md

- Use imperative/infinitive form
- `description` field should include all "when to use" triggers (body is loaded after triggering)
- Only add context the agent doesn't already have
- Prefer concise examples over verbose explanations
- Keep essential workflow in SKILL.md; move detailed reference material to separate files

### What NOT to Include

Do not create extraneous files: README.md, INSTALLATION_GUIDE.md, CHANGELOG.md, etc. The skill should only contain what an AI agent needs to do the job.
"""

    private func installBundledSkills() {
        let bundledId = "skill-creator"
        if let existing = skills.first(where: { $0.id == bundledId }) {
            // Upgrade if the bundled version is newer
            guard existing.version < Self.skillCreatorVersion else { return }
        }
        _ = try? importSkill(content: Self.skillCreatorContent, source: .bundled)
    }

    // MARK: - Built-in Skills (OpenMinis/MinisSkills)

    /// `BuiltinSkills/` folder reference in the app bundle.
    nonisolated static var builtinSkillsBundleURL: URL? {
        Bundle.main.url(forResource: "BuiltinSkills", withExtension: nil)
    }

    /// Kept outside the skill folders so users (and the agent) never see or
    /// edit it, and so it never rides along in a skill's iCloud ZIP.
    private var builtinStateURL: URL {
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("MinisChat/builtin-skills-state.json")
    }

    private lazy var builtinManifest: BuiltinSkillsManifest? = {
        guard let dir = Self.builtinSkillsBundleURL else {
            AppLogger(category: "BuiltinSkills").warning("[Builtin] BuiltinSkills folder missing from bundle")
            return nil
        }
        do {
            return try BuiltinSkillsManifest.load(from: dir)
        } catch {
            AppLogger(category: "BuiltinSkills").error("[Builtin] manifest unreadable: \(error.localizedDescription)")
            return nil
        }
    }()

    /// True when `skillId` is a built-in skill the app owns (not a user
    /// skill that happens to share the id).
    func isBuiltinSkill(_ skillId: String) -> Bool {
        skills.first(where: { $0.id == skillId })?.importSource == .builtin
    }

    /// Why a built-in skill ships disabled (e.g. Android-only), or nil.
    func builtinDisabledReason(for skillId: String) -> String? {
        guard isBuiltinSkill(skillId) else { return nil }
        return builtinManifest?.skill(id: skillId)?.disabledReason
    }

    /// Install / update the bundled built-in skills. Runs from `init` (and
    /// after a DB restore) before `loadSkills()`. Cheap when nothing changed:
    /// one manifest decode, one state read, one SELECT and a stat per skill.
    ///
    /// DB rules: an id whose row has any source other than `builtin` belongs
    /// to the user and is skipped entirely (files included). Missing rows are
    /// inserted with the manifest's `defaultEnabled`; existing built-in rows
    /// keep the user's enable/disable choice. A row that vanished (e.g. the
    /// agent `rm -rf`'d the folder) is reinstalled like a fresh one.
    func syncBuiltinSkills() {
        let logger = AppLogger(category: "BuiltinSkills")
        guard let bundleDir = Self.builtinSkillsBundleURL, let manifest = builtinManifest else { return }

        let synchronizer = BuiltinSkillSynchronizer(
            bundleDir: bundleDir, manifest: manifest,
            skillsDir: skillsDir, stateURL: builtinStateURL
        )
        let previous = synchronizer.loadState()
        let rows = dbSkillRows()
        let sources = rows.mapValues { $0.importSource }
        let candidateIds = Set(manifest.skills.map(\.id)).union(previous.map { Array($0.skills.keys) } ?? [])
        let userOwned = BuiltinSkillSynchronizer.userOwnedIds(among: candidateIds, importSources: sources)

        let rowsComplete = manifest.skills.allSatisfy {
            userOwned.contains($0.id) || sources[$0.id] == SkillImportSource.builtin.dbValue
        }
        if rowsComplete, synchronizer.isUpToDate(previous) { return }

        let started = CFAbsoluteTimeGetCurrent()
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let result = synchronizer.sync(previous: previous, skipping: userOwned)
        let now = Date()

        for skill in manifest.skills where !userOwned.contains(skill.id) {
            let skillFile = skillsDir.appendingPathComponent(skill.id).appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
                logger.warning("[Builtin] '\(skill.id)' has no SKILL.md after sync — not registering")
                continue
            }
            let parsed = Self.parse(skillMD: content)
            let name = parsed.name == Self.defaultSkillName ? skill.name : parsed.name
            let description = parsed.description
            if let row = rows[skill.id] {
                let changed = result.reports[skill.id]?.changedFiles ?? false
                dbUpdateSkillMeta(id: skill.id, name: name, description: description,
                                  version: skill.version, updatedAt: changed ? now : row.updatedAt)
            } else {
                dbInsertSkill(id: skill.id, name: name, description: description,
                              version: skill.version, importSource: .builtin,
                              isEnabled: skill.defaultEnabled, installedAt: now, updatedAt: now)
            }
        }

        // Skills dropped upstream: forget the row once its SKILL.md is gone;
        // if the user edited SKILL.md it stays, now as their own skill.
        for id in result.retired.keys where sources[id] == SkillImportSource.builtin.dbValue {
            let skillFile = skillsDir.appendingPathComponent(id).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillFile.path) {
                dbSetImportSource(skillId: id, source: .file)
            } else {
                dbDeleteSkill(id: id)
            }
        }

        do {
            try synchronizer.saveState(result.state)
        } catch {
            logger.error("[Builtin] failed to save state: \(error.localizedDescription)")
        }
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        logger.info("[Builtin] synced \(result.reports.count) skills (skipped \(result.skipped.count), retired \(result.retired.count)) from \(manifest.upstream.commit.prefix(8)) in \(elapsedMs)ms")
    }

    /// Queue an iCloud upsert/delete for a skill. Built-in skills ship with
    /// every install, so they are never pushed or deleted remotely.
    private func markSkillDirty(_ skillId: String, operation: String = "upsert") {
        guard !isBuiltinSkill(skillId) else { return }
        Task { await ChatStore.shared.markDirty(recordType: "Skill", recordId: skillId, operation: operation) }
    }

    // MARK: - One-time Migration: re-sync skills with bundled files

    /// On first launch after the bundle-sync update, mark all skills that have bundled files
    /// (scripts, references, assets) as dirty so they get re-uploaded with the ZIP asset.
    /// Without this, skills synced by the old code (SKILL.md only) would never re-sync.
    private func migrateMarkBundledSkillsDirty() {
        let key = "skillStore.didMigrateBundleSync"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        var count = 0
        for skill in skills where skill.importSource != .builtin {
            let skillDir = skillsDir.appendingPathComponent(skill.id)
            let bundledFiles = collectRelativePaths(in: skillDir)  // excludes SKILL.md
            if !bundledFiles.isEmpty {
                AppLogger(category: "SkillSync").info("[MIGRATE] '\(skill.name)' has \(bundledFiles.count) bundled files — marking dirty for re-sync")
                markSkillDirty(skill.id)
                count += 1
            }
        }
        if count > 0 {
            AppLogger(category: "SkillSync").info("[MIGRATE] Marked \(count) skills with bundled files for re-sync")
        }
    }

    // MARK: - YAML Frontmatter Parser

    nonisolated static let defaultSkillName = "Untitled Skill"

    struct ParsedSkillMD {
        var name: String = SkillStore.defaultSkillName
        var description: String = ""
        var version: String = "1.0.0"
        var body: String = ""
    }

    static func parse(skillMD content: String) -> ParsedSkillMD {
        var result = ParsedSkillMD()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = content.components(separatedBy: "\n")
        let hasOpeningFence = trimmed.hasPrefix("---")

        // Locate the closing `---` fence. When the file starts with `---` we
        // skip the opening line; otherwise we accept a "headless" frontmatter
        // (a leading run of `key: value` lines followed by a `---` separator)
        // so files generated by tools that omit the opening fence still parse
        // — observed in the wild on user-imported SKILL.md files where the
        // opening `---` was stripped during copy/paste, leaving the entire
        // frontmatter to fall through into `body` and the skill to land as
        // "Untitled Skill" with the raw YAML rendered as the description.
        var frontmatterEnd: Int?
        let scanStart = hasOpeningFence ? 1 : 0
        if scanStart < lines.count {
            for i in scanStart..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    frontmatterEnd = i
                    break
                }
            }
        }

        guard let endIdx = frontmatterEnd else {
            result.body = content
            return result
        }

        // For the headless variant, only treat the leading block as
        // frontmatter when it actually looks like one — every non-blank line
        // before the fence must start with `key:`, AND at least one of those
        // keys must be a recognized frontmatter field (name / description /
        // version). The recognized-key gate keeps a regular markdown file
        // that just happens to open with a `Author: foo\n\n---` style intro
        // from being silently swallowed as frontmatter.
        if !hasOpeningFence {
            var sawRecognizedKey = false
            let looksLikeFrontmatter = (scanStart..<endIdx).allSatisfy { idx in
                let line = lines[idx]
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { return true }
                if line.first?.isWhitespace == true { return true } // continuation of a previous block scalar
                guard let colon = line.firstIndex(of: ":") else { return false }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    return false
                }
                let lowered = key.lowercased()
                if lowered == "name" || lowered == "description" || lowered == "version" {
                    sawRecognizedKey = true
                }
                return true
            }
            guard looksLikeFrontmatter, sawRecognizedKey else {
                result.body = content
                return result
            }
        }

        var i = scanStart
        while i < endIdx {
            let line = lines[i]
            guard let colonIdx = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            // Handle YAML block scalars. Indicator is a leading `|` or `>`,
            // optionally followed by a chomping suffix (`-` strip, `+` keep)
            // and/or a 1-9 indentation digit, e.g. `|`, `|-`, `>-`, `>2`,
            // `|+`, `>-2`. All of these were previously falling through as
            // literal values, surfacing tokens like ">-" in skill picker
            // descriptions when authors wrote `description: >-`.
            let resolvedValue: String
            let isBlockScalar: Bool = {
                guard let first = value.first, first == "|" || first == ">" else { return false }
                let rest = value.dropFirst()
                // Each remaining char must be a chomping indicator or digit.
                return rest.allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
            }()
            if isBlockScalar, i + 1 < endIdx {
                let fold = (value.first == ">")
                var blockLines: [String] = []
                var j = i + 1
                while j < endIdx {
                    let next = lines[j]
                    // Block continues while line is indented (starts with whitespace) or is empty
                    if next.isEmpty || next.first?.isWhitespace == true {
                        blockLines.append(next.trimmingCharacters(in: .whitespaces))
                    } else {
                        break
                    }
                    j += 1
                }
                if fold {
                    // > folds newlines into spaces
                    resolvedValue = blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                } else {
                    // | preserves newlines
                    resolvedValue = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                i = j
            } else {
                resolvedValue = String(value)
                i += 1
            }

            switch key {
            case "name": result.name = resolvedValue
            case "description": result.description = resolvedValue
            case "version": result.version = resolvedValue
            default: break
            }
        }

        let bodyLines = Array(lines[(endIdx + 1)...])
        result.body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)

        return result
    }

    // MARK: - Import

    @discardableResult
    func importSkill(content: String, source: SkillImportSource = .file) throws -> Skill {
        var parsed = Self.parse(skillMD: content)

        // Fallback: use source path as name when frontmatter has no name
        if parsed.name == Self.defaultSkillName {
            if case .url(let urlString) = source {
                parsed.name = Self.nameFromURL(urlString)
            }
        }

        let id = Self.slugify(parsed.name)
        // A name with no letters/digits slugs to "", which would make the
        // skills root itself the skill directory (and let bundled archive
        // files overwrite other skills).
        guard !id.isEmpty else { throw SkillError.invalidContent }
        let now = Date()

        // Preserve enabled state if skill already exists
        let existingEnabled = skills.first(where: { $0.id == id })?.isEnabled ?? true

        let skill = Skill(
            id: id,
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            importSource: source,
            isEnabled: existingEnabled,
            installedAt: skills.first(where: { $0.id == id })?.installedAt ?? now,
            updatedAt: now,
            body: parsed.body
        )

        // Write SKILL.md to disk only if content changed
        let skillDir = skillsDir.appendingPathComponent(id)
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        let existingContent = try? String(contentsOf: skillFile, encoding: .utf8)
        let contentChanged = existingContent != content
        if contentChanged {
            try content.write(to: skillFile, atomically: true, encoding: .utf8)
        }

        // Save to DB (always update metadata like version/description)
        dbInsertSkill(id: id, name: parsed.name, description: parsed.description,
                      version: parsed.version, importSource: source,
                      isEnabled: skill.isEnabled, installedAt: skill.installedAt, updatedAt: now)

        // Update in-memory list
        if let idx = skills.firstIndex(where: { $0.id == id }) {
            skills[idx] = skill
        } else {
            skills.append(skill)
        }

        // Mark dirty for iCloud sync only if content changed
        if contentChanged {
            markSkillDirty(id)
        }

        return skill
    }

    /// Import a skill from iCloud sync using the remote's exact ID and metadata.
    /// Unlike `importSkill`, this preserves the remote `skillId` (no re-slugify)
    /// and does NOT mark dirty (to avoid sync ping-pong).
    /// Returns `true` if the remote skill was applied, `false` if it was
    /// skipped because the local copy is newer (LWW). Callers that also
    /// process a bundled-file ZIP (importSkillFromSyncWithAsset) MUST honour
    /// a `false` return and abort the ZIP unpack/prune — otherwise the prune
    /// step would still delete local bundled files against a stale record.
    @discardableResult
    func importSkillFromSync(
        skillId: String, content: String, source: SkillImportSource,
        isEnabled: Bool, installedAt: Date, updatedAt: Date
    ) -> Bool {
        // The remote id becomes a directory name under skillsDir.
        guard Self.isSafeSkillId(skillId) else {
            AppLogger(category: "SkillSync").error("[IMPORT] SKIP — unsafe remote skill id '\(skillId)'")
            return false
        }
        // Built-in skills ship with every install and are never synced; a
        // peer record (or one claiming to be built-in) must not overwrite them.
        if isBuiltinSkill(skillId) || source == .builtin {
            AppLogger(category: "SkillSync").info("[IMPORT] '\(skillId)' SKIP — built-in skill is not synced")
            return false
        }
        // [T-icloud-cloud-overwrites-local-edits] Local-newer guard. Skill
        // files (SKILL.md + bundled files) are user-editable; below we
        // overwrite the on-disk SKILL.md + rootfs copy + DB row
        // unconditionally. A stale cloud record arriving during the window
        // between a local edit and its push would silently revert the
        // user's just-saved skill (issue #41, same root cause as the
        // SessionFile path). Mirror the LWW used by mergeRemoteSession: if
        // the local skill's updated_at is newer than the inbound record
        // (+ slack for clock drift), keep local and skip. A skill that
        // doesn't exist locally always applies.
        if let local = skills.first(where: { $0.id == skillId }) {
            let slack: TimeInterval = 5
            if local.updatedAt.timeIntervalSince(updatedAt) > slack {
                AppLogger(category: "SkillSync").info("[IMPORT] '\(skillId)' SKIP (local newer): localUpdatedAt=\(local.updatedAt) remoteUpdatedAt=\(updatedAt)")
                return false
            }
        }
        let parsed = Self.parse(skillMD: content)

        // If a local skill exists with the same slugified name but a different ID,
        // remove the old one to prevent duplicates.
        let slugId = Self.slugify(parsed.name)
        if slugId != skillId, let oldIdx = skills.firstIndex(where: { $0.id == slugId }),
           skills[oldIdx].importSource != .builtin {
            let oldId = skills[oldIdx].id
            skills.remove(at: oldIdx)
            dbDeleteSkill(id: oldId)
            let oldDir = skillsDir.appendingPathComponent(oldId)
            try? fm.removeItem(at: oldDir)
        }

        // Preserve local enabled state if skill already exists
        let existingEnabled = skills.first(where: { $0.id == skillId })?.isEnabled ?? isEnabled

        let skill = Skill(
            id: skillId,
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            importSource: source,
            isEnabled: existingEnabled,
            installedAt: skills.first(where: { $0.id == skillId })?.installedAt ?? installedAt,
            updatedAt: updatedAt,
            body: parsed.body
        )

        // Write SKILL.md to disk
        let skillDir = skillsDir.appendingPathComponent(skillId)
        try? fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try? content.write(to: skillFile, atomically: true, encoding: .utf8)

        // Save to DB
        dbInsertSkill(id: skillId, name: parsed.name, description: parsed.description,
                      version: parsed.version, importSource: source,
                      isEnabled: skill.isEnabled, installedAt: skill.installedAt, updatedAt: updatedAt)

        // Update in-memory list
        if let idx = skills.firstIndex(where: { $0.id == skillId }) {
            skills[idx] = skill
        } else {
            skills.append(skill)
        }

        // Do NOT markDirty — this came from sync, avoid ping-pong
        return true
    }

    /// Download and parse SKILL.md without importing. Returns (name, id, content) for preflight checks.
    func preflightGitHubImport(urlString: String) async throws -> (name: String, id: String, content: String) {
        let rawURL = try Self.githubToRawURL(urlString)
        let (data, response) = try await URLSession.shared.data(from: rawURL)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SkillError.downloadFailed(statusCode: httpResponse.statusCode)
        }

        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            throw SkillError.invalidContent
        }

        var parsed = Self.parse(skillMD: content)
        if parsed.name == Self.defaultSkillName {
            parsed.name = Self.nameFromURL(urlString)
        }
        let id = Self.slugify(parsed.name)
        return (name: parsed.name, id: id, content: content)
    }

    func importFromGitHub(urlString: String) async throws -> Skill {
        let preflight = try await preflightGitHubImport(urlString: urlString)
        return try await commitGitHubImport(urlString: urlString, content: preflight.content)
    }

    /// Commit import after preflight (or confirmation). Reuses already-downloaded content.
    /// The sibling-file recursion is detached to a top-level Task so leaving
    /// the import screen mid-download doesn't cancel it (T152). The user-
    /// facing return is the imported Skill — sibling-download progress lands
    /// in AppLogger and (via the next manual `Update from URL`) gets a
    /// chance to be surfaced as PartialSuccess.
    func commitGitHubImport(urlString: String, content: String) async throws -> Skill {
        let skill = try importSkill(content: content, source: .url(urlString))

        // After importing SKILL.md, discover and download sibling files from the same directory.
        // Uses the GitHub Contents API (no auth required for public repos).
        if let ghInfo = Self.parseGitHubURL(urlString) {
            let skillDir = skillsDir.appendingPathComponent(skill.id)
            // Detach: this used to run inline on the caller's Task. If the
            // SwiftUI .task was cancelled (sheet dismiss, navigation away)
            // mid-recursion, the sibling files were silently abandoned and
            // only SKILL.md persisted — that's the T152 root cause.
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let outcome = await self.downloadSiblingFiles(ghInfo: ghInfo, destDir: skillDir, skill: skill)
                await MainActor.run {
                    if let idx = self.skills.firstIndex(where: { $0.id == skill.id }) {
                        self.skills[idx].updatedAt = Date()
                        self.dbUpdateSkillMeta(id: skill.id, name: self.skills[idx].name, description: self.skills[idx].description,
                                               version: self.skills[idx].version, updatedAt: self.skills[idx].updatedAt)
                    }
                    self.markSkillDirty(skill.id)
                }
                if !outcome.isComplete {
                    AppLogger(category: "SkillStore").warning(
                        "[siblings] importFromGitHub partial for \(skill.id): \(outcome.reason ?? "\(outcome.filesFailed) file(s) failed")"
                    )
                }
            }
        }

        return skill
    }

    /// Outcome of a `Update from URL` press — either a clean re-fetch or
    /// SKILL.md updated but sibling files (scripts/, references/, …) had
    /// trouble. Mirrors Android `UpdateResult.PartialSuccess`.
    enum UpdateFromURLOutcome {
        case success
        case partialSuccess(reason: String)
    }

    /// Re-fetch SKILL.md AND sibling files for an existing URL-imported
    /// skill. Throws on hard failures (skill not found, source URL missing,
    /// network down for SKILL.md itself); returns a `partialSuccess` when
    /// SKILL.md updated cleanly but the sibling-file recursion didn't.
    @discardableResult
    func updateFromURL(_ skillId: String) async throws -> UpdateFromURLOutcome {
        guard let skill = skills.first(where: { $0.id == skillId }),
              case .url(let urlString) = skill.importSource else { return .success }

        // Refresh SKILL.md content first via the existing import path. Keep
        // the throw so SKILL.md-level failures (auth, parse, network) still
        // bubble — they're meaningful "the update did not happen at all".
        let preflight = try await preflightGitHubImport(urlString: urlString)
        _ = try importSkill(content: preflight.content, source: .url(urlString))

        // Now re-run sibling download synchronously (the user is looking at
        // a spinner) so we can return the partial-success state directly.
        guard let ghInfo = Self.parseGitHubURL(urlString) else { return .success }
        let skillDir = skillsDir.appendingPathComponent(skill.id)
        let outcome = await downloadSiblingFiles(ghInfo: ghInfo, destDir: skillDir, skill: skill)

        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[idx].updatedAt = Date()
            dbUpdateSkillMeta(id: skill.id, name: skills[idx].name, description: skills[idx].description,
                              version: skills[idx].version, updatedAt: skills[idx].updatedAt)
        }
        markSkillDirty(skill.id)

        if !outcome.isComplete {
            let reason = outcome.reason ?? String(localized: "\(outcome.filesFailed) sibling file(s) failed to download", comment: "Skill import warning; argument is the number of bundled files that failed to download")
            return .partialSuccess(reason: reason)
        }
        return .success
    }

    @discardableResult
    func importFromArchive(at url: URL) throws -> Skill {
        let archiveSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard archiveSize <= ZipLimits.maxArchiveBytes else { throw SkillError.archiveTooLarge }
        let data = try Data(contentsOf: url)
        // Validate every entry (sizes, paths) before anything is written.
        let files = try Self.bundledZipFiles(Self.readZipEntries(data: data))

        guard let skillMDFile = files.first(where: {
            let name = $0.path
            return name == "SKILL.md" || (name.hasSuffix("/SKILL.md") && name.components(separatedBy: "/").count == 2)
        }) else {
            throw SkillError.noSkillMDInArchive
        }

        guard let skillContent = String(data: skillMDFile.data, encoding: .utf8), !skillContent.isEmpty else {
            throw SkillError.invalidContent
        }

        let skill = try importSkill(content: skillContent, source: .file)

        let prefix: String
        if skillMDFile.path == "SKILL.md" {
            prefix = ""
        } else {
            prefix = String(skillMDFile.path.dropLast("SKILL.md".count))
        }

        let skillDir = skillsDir.appendingPathComponent(skill.id)

        for file in files {
            var relativePath = file.path
            if !prefix.isEmpty && relativePath.hasPrefix(prefix) {
                relativePath = String(relativePath.dropFirst(prefix.count))
            }
            if relativePath == "SKILL.md" { continue }
            if relativePath.hasPrefix(".") { continue }

            let destFile = try ArchivePathGuard.destination(for: relativePath, under: skillDir)
            try fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destFile)
        }

        // Re-mark dirty after all bundled files are written so the sync cycle
        // picks up the complete skill (SKILL.md + scripts/assets).
        // The stability check (isSkillStable) ensures sync waits until writes settle.
        let hasBundledFiles = files.contains { $0.path != "SKILL.md" && !$0.path.hasPrefix(".") }
        if hasBundledFiles {
            if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[idx].updatedAt = Date()
                dbUpdateSkillMeta(id: skill.id, name: skills[idx].name, description: skills[idx].description,
                                  version: skills[idx].version, updatedAt: skills[idx].updatedAt)
            }
            markSkillDirty(skill.id)
        }

        return skill
    }

    func updateSkillContent(_ skillId: String, newContent: String) throws {
        guard let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }

        let parsed = Self.parse(skillMD: newContent)
        let now = Date()
        skills[idx].name = parsed.name
        skills[idx].description = parsed.description
        skills[idx].version = parsed.version
        skills[idx].body = parsed.body
        skills[idx].updatedAt = now

        let skillFile = skillsDir.appendingPathComponent(skillId).appendingPathComponent("SKILL.md")
        try newContent.write(to: skillFile, atomically: true, encoding: .utf8)

        dbUpdateSkillMeta(id: skillId, name: parsed.name, description: parsed.description,
                          version: parsed.version, updatedAt: now)

        markSkillDirty(skillId)
    }

    /// Rename a skill (updates in-memory, DB, and SKILL.md frontmatter on disk).
    func renameSkill(_ skillId: String, newName: String) {
        guard let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }
        skills[idx].name = newName
        skills[idx].updatedAt = Date()
        dbUpdateSkillMeta(id: skillId, name: newName, description: skills[idx].description,
                          version: skills[idx].version, updatedAt: skills[idx].updatedAt)

        // Also update the SKILL.md frontmatter on disk
        if var content = readSkillContent(skillId) {
            let parsed = Self.parse(skillMD: content)
            if parsed.name != newName {
                // Replace name in frontmatter
                if content.contains("name:") {
                    content = content.replacingOccurrences(
                        of: #"(?m)^name:.*$"#,
                        with: "name: \(newName)",
                        options: .regularExpression
                    )
                }
                let skillFile = skillsDir.appendingPathComponent(skillId).appendingPathComponent("SKILL.md")
                try? content.write(to: skillFile, atomically: true, encoding: .utf8)
            }
        }

        markSkillDirty(skillId)
    }

    /// Re-read SKILL.md from disk and update metadata (name, description, version, body).
    /// Useful when the AI agent has modified the file or when the user wants to refresh.
    func rescanFromDisk(_ skillId: String) {
        guard let content = readSkillContent(skillId),
              let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }
        let parsed = Self.parse(skillMD: content)
        let old = skills[idx]

        // Frontmatter parse failure detection: parse(...) returns the default
        // name ("Untitled Skill") and an empty description when it can't find
        // a valid frontmatter block. In that case, keep the existing skill's
        // name / description / version so a rescan over a temporarily broken
        // SKILL.md (mid-edit save, accidental fence deletion, etc.) doesn't
        // wipe metadata the user has been relying on. The body is still
        // refreshed because that's the actual file content the user wants
        // re-synced to rootfs.
        let parseFailed = parsed.name == Self.defaultSkillName && parsed.description.isEmpty
        let resolvedName = parseFailed ? old.name : parsed.name
        let resolvedDescription = parseFailed ? old.description : parsed.description
        let resolvedVersion = parseFailed ? old.version : parsed.version

        let changed = old.name != resolvedName || old.description != resolvedDescription
                   || old.version != resolvedVersion || old.body != parsed.body
        skills[idx].name = resolvedName
        skills[idx].description = resolvedDescription
        skills[idx].version = resolvedVersion
        skills[idx].body = parsed.body
        if changed {
            let now = Date()
            skills[idx].updatedAt = now
            dbUpdateSkillMeta(id: skillId, name: resolvedName, description: resolvedDescription,
                              version: resolvedVersion, updatedAt: now)
            markSkillDirty(skillId)
        }
    }

    /// Unconditionally mark this skill as dirty so the sync engine will
    /// push it to iCloud on the next send, even if no fields changed.
    /// Use this for skills that exist on disk (e.g. dropped in via shell)
    /// but never went through markDirty and so were silently absent from
    /// the sync queue. No-op for built-in skills (never synced).
    func forceMarkDirty(_ skillId: String) {
        guard skills.contains(where: { $0.id == skillId }) else { return }
        markSkillDirty(skillId)
    }

    /// [T-ios-shell-created-skill-not-syncing] Reconcile a skill directory that
    /// exists on disk (`<skillsDir>/<id>/SKILL.md`) but has no skills.db row and
    /// is absent from the in-memory `skills` array — e.g. a skill created purely
    /// via the iSH shell (`mkdir /var/minis/skills/<id>` + write SKILL.md),
    /// bypassing the import UI. Such orphans were registered into the DB by
    /// `discoverNewSkillsOnDisk` at launch but never `markDirty`'d, so the
    /// CloudKit upload builder found the row yet the dirty queue never carried
    /// it — the skill silently never synced to other devices.
    ///
    /// Registers the orphan (parse frontmatter → DB row with `.session` source →
    /// in-memory array) AND markDirty so it enters the upload queue. The
    /// directory name is the id (NOT a re-slugified name) so the `minis://` link
    /// keeps resolving. Idempotent: a no-op when the id is already loaded, and
    /// `dbInsertSkill`'s `ON CONFLICT` preserves `use_count`. Returns true if a
    /// new orphan was ingested.
    ///
    /// Shared by the launch reconcile (`discoverNewSkillsOnDisk`) and the
    /// `SyncDirtyScanner` backstop (skills that appear on disk mid-session).
    @discardableResult
    func reconcileOrphanSkill(id: String) -> Bool {
        // Idempotent: never duplicate an already-loaded skill.
        guard !skills.contains(where: { $0.id == id }) else { return false }

        let skillFile = skillsDir.appendingPathComponent(id).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8),
              !content.isEmpty else { return false }

        let parsed = Self.parse(skillMD: content)
        let now = Date()

        // A built-in folder without a row (e.g. restored by the agent after
        // its row was dropped) is re-registered as built-in, never as a
        // `.session` skill, and is not queued for upload.
        if let builtin = builtinManifest?.skill(id: id) {
            let name = parsed.name == Self.defaultSkillName ? builtin.name : parsed.name
            dbInsertSkill(id: id, name: name, description: parsed.description,
                          version: builtin.version, importSource: .builtin,
                          isEnabled: builtin.defaultEnabled, installedAt: now, updatedAt: now)
            skills.append(Skill(
                id: id, name: name, description: parsed.description, version: builtin.version,
                importSource: .builtin, isEnabled: builtin.defaultEnabled,
                installedAt: now, updatedAt: now, body: parsed.body
            ))
            AppLogger(category: "BuiltinSkills").info("[Reconcile] re-registered built-in skill id=\(id)")
            return true
        }

        // Written from a shell (by the agent, or by a script it ran): listed, but off until the
        // user turns it on in Settings → Skills. An enabled skill's description goes into every
        // system prompt, so an injected instruction saved as a skill would otherwise reach every
        // later conversation without anyone seeing it.
        let skill = Skill(
            id: id,
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            importSource: .session,
            isEnabled: false,
            installedAt: now,
            updatedAt: now,
            body: parsed.body
        )
        dbInsertSkill(id: id, name: parsed.name, description: parsed.description,
                      version: parsed.version, importSource: .session,
                      isEnabled: false, installedAt: now, updatedAt: now)
        skills.append(skill)
        AppLogger(category: "SkillSync").info("[Reconcile] ingested orphan shell-created skill id=\(id) (disabled until the user enables it)")
        return true
    }

    func readSkillContent(_ skillId: String) -> String? {
        let skillFile = skillsDir.appendingPathComponent(skillId).appendingPathComponent("SKILL.md")
        return try? String(contentsOf: skillFile, encoding: .utf8)
    }

    /// Collect relative file paths from a directory, excluding "SKILL.md".
    /// Enumerate regular files under `dir` and return their paths relative to `dir`.
    /// "SKILL.md" is excluded (it is always added separately by the caller).
    private func collectRelativePaths(in dir: URL) -> [String] {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let dirComponents = dir.standardizedFileURL.pathComponents
        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            let fileComponents = fileURL.standardizedFileURL.pathComponents
            guard fileComponents.count > dirComponents.count else { continue }
            let rel = fileComponents[dirComponents.count...].joined(separator: "/")
            if rel != "SKILL.md" { paths.append(rel) }
        }
        return paths
    }

    /// Returns relative paths of all files inside the skill directory.
    /// "SKILL.md" is always first; remaining files are sorted alphabetically.
    func listSkillFiles(_ skillId: String) -> [String] {
        let others = collectRelativePaths(in: skillDirectoryURL(for: skillId))
        return ["SKILL.md"] + others.sorted()
    }

    /// Reads the content of any file inside the skill directory by relative path.
    func readSkillFile(_ skillId: String, relativePath: String) -> String? {
        let fileURL = skillDirectoryURL(for: skillId).appendingPathComponent(relativePath)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Writes content to any file inside the skill directory by relative path.
    /// For SKILL.md, also updates metadata via updateSkillContent.
    func writeSkillFile(_ skillId: String, relativePath: String, content: String) throws {
        if relativePath == "SKILL.md" {
            try updateSkillContent(skillId, newContent: content)
        } else {
            let fileURL = skillDirectoryURL(for: skillId).appendingPathComponent(relativePath)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            // Update skill's updatedAt and mark dirty so bundled file changes trigger iCloud sync
            if let idx = skills.firstIndex(where: { $0.id == skillId }) {
                skills[idx].updatedAt = Date()
                dbUpdateSkillMeta(id: skillId, name: skills[idx].name, description: skills[idx].description,
                                  version: skills[idx].version, updatedAt: skills[idx].updatedAt)
            }
            markSkillDirty(skillId)
        }
    }

    func deleteSkill(_ skillId: String) {
        // Built-in skills can't be deleted (the next launch would reinstall
        // them anyway) — "delete" means switch it off.
        if isBuiltinSkill(skillId) {
            setEnabled(skillId, enabled: false)
            return
        }

        skills.removeAll { $0.id == skillId }
        dbDeleteSkill(id: skillId)

        let skillDir = skillsDir.appendingPathComponent(skillId)
        try? fm.removeItem(at: skillDir)

        // Propagate the deletion to peer devices. Earlier builds
        // intentionally suppressed this so accidental local removals
        // wouldn't nuke a shared library, but the practical UX was
        // worse: a delete on one device would silently revive next
        // time the user mutated anything else (the upsert path
        // re-pushed the skill the peer still had). markDirty op=delete
        // routes through ChatStoreSyncHydrators.applySkillDeletion on
        // the receiver.
        Task { await ChatStore.shared.markDirty(
            recordType: "Skill", recordId: skillId, operation: "delete"
        ) }
    }

    /// Hard-delete a skill locally without re-queueing a cloud delete.
    /// Called by the sync hydrator when a peer pushes op=delete for
    /// this skill id; the cloud already holds the tombstone so we
    /// must NOT echo it back. Mirrors the SessionV2 / EnvVarItem
    /// inbound-delete pattern. Built-in skills are never deleted remotely.
    func applyRemoteDeletion(id skillId: String) {
        guard skills.contains(where: { $0.id == skillId }) else { return }
        guard !isBuiltinSkill(skillId) else {
            AppLogger(category: "SkillSync").info("[IMPORT] '\(skillId)' remote delete ignored — built-in skill")
            return
        }
        skills.removeAll { $0.id == skillId }
        dbDeleteSkill(id: skillId)
        let skillDir = skillsDir.appendingPathComponent(skillId)
        try? fm.removeItem(at: skillDir)
    }

    func setEnabled(_ skillId: String, enabled: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }
        skills[idx].isEnabled = enabled
        dbSetEnabled(skillId: skillId, enabled: enabled)
        // Enable/disable is part of the skill's syncable state — peer
        // devices won't see the toggle otherwise. (Built-in skills: local only.)
        markSkillDirty(skillId)
    }

    // MARK: - Session Overrides

    func isEnabledForSession(_ skillId: String, sessionId: String) -> Bool {
        if let override = dbSessionOverride(sessionId: sessionId, skillId: skillId) {
            return override
        }
        return skills.first(where: { $0.id == skillId })?.isEnabled ?? false
    }

    /// A counter that increments on every session override change to trigger SwiftUI updates.
    @Published private(set) var sessionOverrideVersion: Int = 0

    func setSessionOverride(skillId: String, sessionId: String, enabled: Bool) {
        let defaultEnabled = skills.first(where: { $0.id == skillId })?.isEnabled ?? true
        if enabled == defaultEnabled {
            dbDeleteSessionOverride(sessionId: sessionId, skillId: skillId)
        } else {
            dbSetSessionOverride(sessionId: sessionId, skillId: skillId, enabled: enabled)
        }
        sessionOverrideVersion += 1
    }

    // MARK: - Usage Tracking

    /// Record a skill usage when its SKILL.md is read via file_read.
    /// If any skill's count exceeds 1000, all counts are normalized to 0–100.
    func recordSkillUse(_ skillId: String) {
        guard let idx = skills.firstIndex(where: { $0.id == skillId }) else { return }
        skills[idx].useCount += 1

        let sql = "UPDATE skills SET use_count = use_count + 1 WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (skillId as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
        sqlite3_step(stmt)

        // Check if normalization is needed
        if skills[idx].useCount > 1000 {
            normalizeAllUseCounts()
        }
    }

    /// Normalize all skill use_count values to 0–100, preserving relative order.
    private func normalizeAllUseCounts() {
        let maxCount = skills.map(\.useCount).max() ?? 0
        guard maxCount > 0 else { return }

        for i in skills.indices {
            skills[i].useCount = (skills[i].useCount / maxCount) * 100.0
        }

        // Batch update DB
        let sql = "UPDATE skills SET use_count = ? WHERE id = ?"
        for skill in skills {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, skill.useCount)
            sqlite3_bind_text(stmt, 2, (skill.id as NSString).utf8String, -1, Self.SQLITE_TRANSIENT_DB)
            sqlite3_step(stmt)
        }
    }

    /// Usage frequency label based on normalized distribution.
    enum UsageFrequency: String {
        case never = "Never Used"
        case low = "Low Usage"
        case regular = "Regular Usage"
        case high = "High Usage"
    }

    func usageFrequency(for skillId: String) -> UsageFrequency {
        guard let skill = skills.first(where: { $0.id == skillId }) else { return .never }
        if skill.useCount == 0 { return .never }

        let maxCount = skills.map(\.useCount).max() ?? 0
        guard maxCount > 0 else { return .never }

        let normalized = skill.useCount / maxCount * 100.0
        if normalized < 20 { return .low }
        if normalized < 60 { return .regular }
        return .high
    }

    /// Extract skill ID from a Linux path like /var/minis/skills/<skillId>/SKILL.md.
    /// Only matches SKILL.md reads (the trigger for skill usage), not sub-resource reads.
    func skillIdFromPath(_ path: String) -> String? {
        let prefix = "/var/minis/skills/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = String(path.dropFirst(prefix.count))
        guard let slashIdx = rest.firstIndex(of: "/") else { return nil }
        let candidate = String(rest[rest.startIndex..<slashIdx])
        // Only count reads of SKILL.md itself
        guard rest.hasSuffix("SKILL.md") else { return nil }
        return skills.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    // MARK: - Prompt Fragment (Claude Code style: metadata only)

    /// Maximum number of skill metadata entries to include in the prompt.
    nonisolated static let maxSkillMetadataCount = 20

    /// Build a discovery-only prompt fragment with priority-based disclosure:
    /// 1. Bundled skills (skill-creator; always included, capped at the max)
    /// 2. Recently modified/created skills within last 7 days (up to 10)
    /// 3. Frequently used skills by normalized use count (fill remaining slots)
    func skillPromptFragment(for sessionId: String) -> String? {
        let enabled = skills.filter { isEnabledForSession($0.id, sessionId: sessionId) }
        return Self.skillPromptFragment(enabledSkills: enabled)
    }

    /// Pure core of `skillPromptFragment(for:)`, testable without the DB.
    ///
    /// Built-in (MinisSkills) skills are not always-disclosed: they compete
    /// for slots like user skills. They are left out of the "recent" bucket
    /// because their timestamps come from app installs/updates, not from the
    /// user — otherwise ~50 of them would crowd out the user's own recently
    /// edited skills for a week after every update. They rank by usage.
    nonisolated static func skillPromptFragment(enabledSkills enabled: [Skill], now: Date = Date()) -> String? {
        let logger = AppLogger(category: "SkillDisclosure")
        guard !enabled.isEmpty else { return nil }

        let totalCount = enabled.count
        let selected: [Skill]
        let hasMore: Bool
        // Track reasons per skill for debug logging
        var reasons: [String: String] = [:]

        if totalCount <= Self.maxSkillMetadataCount {
            selected = enabled.sorted { $0.updatedAt > $1.updatedAt }
            for s in selected { reasons[s.id] = "all-fit" }
            hasMore = false
        } else {
            var picked: [Skill] = []
            var seen = Set<String>()

            // Priority 1: Bundled skills (never more than the cap)
            for s in enabled where s.importSource == .bundled && picked.count < Self.maxSkillMetadataCount {
                if seen.insert(s.id).inserted {
                    picked.append(s)
                    reasons[s.id] = "bundled"
                }
            }

            // Priority 2: Recently modified/created (within 7 days), up to 10
            let oneWeekAgo = now.addingTimeInterval(-7 * 24 * 3600)
            let recent = enabled
                .filter { $0.importSource != .builtin && $0.updatedAt > oneWeekAgo && !seen.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
            let recentLimit = max(0, min(10, Self.maxSkillMetadataCount - picked.count))
            for s in recent.prefix(recentLimit) {
                if seen.insert(s.id).inserted {
                    picked.append(s)
                    reasons[s.id] = "recent-7d"
                }
            }

            // Priority 3: By usage frequency (fill remaining slots, most-used first)
            if picked.count < Self.maxSkillMetadataCount {
                let remaining = Self.maxSkillMetadataCount - picked.count
                let byUsage = enabled
                    .filter { !seen.contains($0.id) }
                    .sorted { $0.useCount > $1.useCount }
                for s in byUsage.prefix(remaining) {
                    if seen.insert(s.id).inserted {
                        picked.append(s)
                        reasons[s.id] = s.useCount > 0 ? "frequent(\(String(format: "%.1f", s.useCount)))" : "fill"
                    }
                }
            }

            selected = picked
            hasMore = totalCount > selected.count
        }

        // Log skill disclosure decisions
        #if DEBUG
        for s in selected {
            logger.info("[Disclose] \(s.name) — \(reasons[s.id] ?? "?")")
        }
        if hasMore {
            let omittedNames = enabled.filter { s in !selected.contains(where: { $0.id == s.id }) }.map(\.name)
            logger.info("[Omitted] \(omittedNames.joined(separator: ", "))")
        }
        #else
        let names = selected.map(\.name).joined(separator: ", ")
        logger.info("[SkillDisclosure] \(selected.count)/\(totalCount) disclosed: \(names)")
        #endif

        // Cap each description to avoid bloating the system prompt.
        let maxDescLength = 200

        var xml = "<available_skills>\n"
        for skill in selected {
            let escapedName = skill.name.xmlEscaped
            var desc = skill.description
            if desc.count > maxDescLength {
                desc = String(desc.prefix(maxDescLength)) + "…"
            }
            let escapedDesc = desc.xmlEscaped
            xml += "  <skill>\n"
            xml += "    <name>\(escapedName)</name>\n"
            xml += "    <description>\(escapedDesc)</description>\n"
            xml += "    <path>/var/minis/skills/\(skill.id)/SKILL.md</path>\n"
            xml += "  </skill>\n"
        }
        xml += "</available_skills>"

        var fragment = "Skills:\n"
        fragment += "Reusable instruction sets stored at /var/minis/skills/<name>/SKILL.md. Read the SKILL.md file to load full instructions before using a skill.\n\n"
        fragment += xml

        if hasMore {
            let omitted = enabled.filter { s in !selected.contains(where: { $0.id == s.id }) }
            let maxUndisclosed = max(0, 100 - selected.count)
            let undisclosedNames = omitted.prefix(maxUndisclosed).map(\.name).joined(separator: ", ")
            fragment += "\n\n\(omitted.count) more skills not shown above: \(undisclosedNames). List /var/minis/skills/ or grep to search all."
        }

        return fragment
    }

    // MARK: - Load from DB

    /// Re-scan DB and disk for new/updated skills. Call after agent creates a skill file,
    /// or when returning to foreground.
    func reload() {
        loadSkills()
    }

    /// Rescan disk vs the previous in-memory snapshot, then markDirty
    /// for every skill whose on-disk state diverged (new SKILL.md
    /// appeared, contents changed, or the directory disappeared
    /// entirely). Intended to be called from the debounced fakefs
    /// notifier — a few seconds after iSH shell tools settle down.
    ///
    /// Unlike `reload()`, which only refreshes the in-memory list and
    /// silently absorbs disk changes, this method drives v2 sync:
    ///   • New SKILL.md on disk under <skillId>/ → INSERT into DB +
    ///     markDirty(Skill, op:upsert).
    ///   • Existing SKILL.md whose mtime is newer than the DB's
    ///     `updated_at` → bump updated_at and markDirty.
    ///   • DB row whose SKILL.md is gone → dbDeleteSkill + markDirty
    ///     op=delete (built-in skills: never queued; see loadSkills).
    ///   • Bundled file (non-SKILL.md content under <skillId>/) mtime
    ///     newer than DB updated_at → bump + markDirty so the ZIP
    ///     asset gets re-uploaded.
    func rescanAndMarkChangedSkillsDirty() {
        let syncLog = AppLogger(category: "SkillSync")
        // Snapshot the DB-side state before reloading so we can diff.
        var previousUpdatedAt: [String: Date] = [:]
        for skill in skills { previousUpdatedAt[skill.id] = skill.updatedAt }
        // Built-in skills are never synced; remember them before the reload
        // drops rows whose folder vanished.
        let previousBuiltinIds = Set(skills.filter { $0.importSource == .builtin }.map(\.id))

        // reload() already detects new dirs (discoverNewSkillsOnDisk)
        // and drops orphans (the dbDeleteSkill branch inside loadSkills
        // when SKILL.md is missing). It just doesn't markDirty for any of
        // it — we layer that on top here.
        let previousIds = Set(previousUpdatedAt.keys)
        loadSkills()
        let currentIds = Set(skills.map { $0.id })

        // Net new skills (likely "agent wrote SKILL.md to a fresh dir").
        let added = currentIds.subtracting(previousIds)
        for id in added where !isBuiltinSkill(id) {
            markSkillDirty(id)
            syncLog.info("[SkillSync] fakefs rescan → markDirty upsert (new): id=\(id.prefix(8))")
        }

        // Removed skills (agent rm -rf'd the dir).
        let removed = previousIds.subtracting(currentIds).subtracting(previousBuiltinIds)
        for id in removed {
            Task { await ChatStore.shared.markDirty(
                recordType: "Skill", recordId: id, operation: "delete"
            ) }
            syncLog.info("[SkillSync] fakefs rescan → markDirty delete (gone): id=\(id.prefix(8))")
        }

        // Existing skills: check if anything inside the dir is newer
        // than the recorded updated_at. Covers both SKILL.md edits and
        // bundled file additions/edits (so the next push refreshes
        // the ZIP asset too).
        for skill in skills where !added.contains(skill.id) && skill.importSource != .builtin {
            let dir = skillsDir.appendingPathComponent(skill.id)
            guard let latest = Self.latestMtime(in: dir) else { continue }
            // Compare with a small slack so we don't churn on
            // sub-second clock drift between the file write and the
            // updated_at column.
            let prev = previousUpdatedAt[skill.id] ?? .distantPast
            if latest.timeIntervalSince(prev) > 1.0 {
                // Bump the DB so subsequent passes don't keep firing,
                // and so the v2 builder serializes the new updatedAt
                // into the synced record.
                dbUpdateSkillMeta(
                    id: skill.id,
                    name: skill.name,
                    description: skill.description,
                    version: skill.version,
                    updatedAt: latest
                )
                markSkillDirty(skill.id)
                syncLog.info("[SkillSync] fakefs rescan → markDirty upsert (mtime newer): id=\(skill.id.prefix(8)) prev=\(prev) latest=\(latest)")
            }
        }
    }

    /// Walks the skill's directory and returns the latest mtime among
    /// SKILL.md + bundled files. Used by rescanAndMarkChangedSkillsDirty
    /// to decide whether a v2 push is needed. Returns nil if the dir
    /// is empty or unreadable.
    private static func latestMtime(in dir: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var latest: Date? = nil
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if latest == nil || m > latest! { latest = m }
        }
        return latest
    }

    /// [T-ios-skill-circuit-breaker] On a cold start or after a crash the skills folder can be
    /// unreadable for a moment; every custom skill then looks deleted and used to be removed
    /// from the database. Pruning is allowed only when the folder is there and not suspiciously
    /// many custom skills are missing at once (3+ and at least 40 %).
    private func missingSkillsMayBePruned() -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: skillsDir.path, isDirectory: &isDir), isDir.boolValue else {
            AppLogger(category: "SkillStore").error("skills folder unavailable — not pruning missing skills this launch")
            return false
        }
        var total = 0, missing = 0
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM skills WHERE import_source NOT IN ('bundled', '\(SkillImportSource.builtin.dbValue)')"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                total += 1
                let id = String(cString: sqlite3_column_text(stmt, 0))
                if !fm.fileExists(atPath: skillsDir.appendingPathComponent(id).appendingPathComponent("SKILL.md").path) {
                    missing += 1
                }
            }
        }
        let tripped = missing >= 3 && Double(missing) / Double(max(total, 1)) >= 0.4
        if tripped {
            AppLogger(category: "SkillStore").error("circuit breaker: \(missing)/\(total) custom skills missing at once — not pruning")
        }
        return !tripped
    }

    private func loadSkills() {
        skills.removeAll()
        let pruneAllowed = missingSkillsMayBePruned()

        // 1. Load skills already registered in the DB
        var knownIds = Set<String>()
        let sql = "SELECT id, name, description, version, import_source, is_enabled, installed_at, updated_at, use_count FROM skills"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let description = String(cString: sqlite3_column_text(stmt, 2))
                let version = String(cString: sqlite3_column_text(stmt, 3))
                let importSourceStr = String(cString: sqlite3_column_text(stmt, 4))
                let isEnabled = sqlite3_column_int(stmt, 5) != 0
                let installedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                let useCount = sqlite3_column_double(stmt, 8)

                let skillFile = skillsDir.appendingPathComponent(id).appendingPathComponent("SKILL.md")
                var resolvedName = name
                var resolvedDesc = description
                let body: String
                if let content = try? String(contentsOf: skillFile, encoding: .utf8) {
                    let parsed = Self.parse(skillMD: content)
                    body = parsed.body
                    // Re-resolve name/description from disk when DB has stale values
                    let nameStale = (name == Self.defaultSkillName && parsed.name != Self.defaultSkillName)
                    let descStale = (description == "|" || description == ">") && !parsed.description.isEmpty
                    if nameStale { resolvedName = parsed.name }
                    if descStale { resolvedDesc = parsed.description }
                    if nameStale || descStale {
                        dbUpdateSkillMeta(id: id, name: resolvedName, description: resolvedDesc, version: version, updatedAt: updatedAt)
                    }
                } else if importSourceStr == SkillImportSource.builtin.dbValue {
                    // Built-in folder removed (e.g. `rm -rf` from the shell):
                    // hide it but keep the row, so the next launch's
                    // syncBuiltinSkills() restores the files and the user's
                    // enable/disable choice survives.
                    knownIds.insert(id)
                    continue
                } else if pruneAllowed {
                    // Skill files deleted — remove from DB
                    dbDeleteSkill(id: id)
                    continue
                } else {
                    // Storage not ready, or too many skills missing at once: keep the row
                    // (hidden this launch) rather than wipe the user's skills.
                    knownIds.insert(id)
                    continue
                }

                let skill = Skill(
                    id: id,
                    name: resolvedName,
                    description: resolvedDesc,
                    version: version,
                    importSource: SkillImportSource.fromDB(importSourceStr),
                    isEnabled: isEnabled,
                    installedAt: installedAt,
                    updatedAt: updatedAt,
                    body: body,
                    useCount: useCount
                )
                skills.append(skill)
                knownIds.insert(id)
            }
        }

        // 2. Discover skills on disk that are not in the DB (e.g. created by agent in a session)
        discoverNewSkillsOnDisk(knownIds: knownIds)
    }

    /// Scan skills directory for subdirectories containing SKILL.md that aren't yet in the DB.
    /// These are treated as session-created skills.
    private func discoverNewSkillsOnDisk(knownIds: Set<String>) {
        guard let entries = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let id = entry.lastPathComponent
            guard !knownIds.contains(id) else { continue }

            // [T-ios-shell-created-skill-not-syncing] Reuse the shared reconcile
            // so a disk-only skill (e.g. shell-created) is not just registered
            // into the DB but also markDirty'd — the previous inline version
            // ingested the row yet never queued it for CloudKit upload, so
            // shell-created skills silently never synced.
            reconcileOrphanSkill(id: id)
        }
    }

    // MARK: - Helpers

    /// Derive a human-readable name from a URL path (e.g. "user/repo/path/to/SKILL.md")
    static func nameFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        // Strip "SKILL.md" leaf so the path identifies the skill location
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.last?.uppercased() == "SKILL.MD" { parts.removeLast() }
        // For GitHub URLs, drop "blob/<branch>" segment
        if url.host == "github.com", parts.count >= 4,
           parts[2] == "blob" || parts[2] == "tree" {
            parts.removeSubrange(2...3)
        }
        return parts.isEmpty ? urlString : parts.joined(separator: "/")
    }

    static func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return name
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: - GitHub Directory Discovery

    struct GitHubInfo {
        let user: String
        let repo: String
        let branch: String
        /// Directory path (without SKILL.md leaf)
        let dirPath: String
    }

    /// Parse a GitHub URL into components. Returns nil for non-GitHub URLs.
    static func parseGitHubURL(_ urlString: String) -> GitHubInfo? {
        let normalized = normalizeURL(urlString)
        // Handle raw.githubusercontent.com URLs
        if normalized.contains("raw.githubusercontent.com") {
            guard let url = URL(string: normalized) else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            // raw URL: /user/repo/branch/path/to/SKILL.md
            guard parts.count >= 3 else { return nil }
            let user = parts[0], repo = parts[1], branch = parts[2]
            let pathParts = Array(parts[3...])
            var dirParts = pathParts
            if dirParts.last?.uppercased() == "SKILL.MD" { dirParts.removeLast() }
            return GitHubInfo(user: user, repo: repo, branch: branch, dirPath: dirParts.joined(separator: "/"))
        }

        guard let url = URL(string: normalized), url.host == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // github.com/user/repo/blob|tree/branch/path/...
        guard parts.count >= 4 else { return nil }
        let user = parts[0], repo = parts[1], branch = parts[3]
        var pathParts = Array(parts[4...])
        if pathParts.last?.uppercased() == "SKILL.MD" { pathParts.removeLast() }
        return GitHubInfo(user: user, repo: repo, branch: branch, dirPath: pathParts.joined(separator: "/"))
    }

    /// Aggregate outcome of a sibling-file download walk.
    /// Mirrors Android `SiblingDownloadOutcome`. `reason` is non-nil when the
    /// recursion bailed before listing or when at least one file failed.
    struct SiblingDownloadOutcome {
        let filesWritten: Int
        let filesFailed: Int
        let reason: String?
        var isComplete: Bool { filesFailed == 0 && reason == nil }
    }

    /// Mutable accumulator threaded through the recursion. Records counts
    /// plus the FIRST human-readable reason so the UI can show one specific
    /// cause (e.g. "GitHub API 403 (rate limited)") rather than a generic
    /// "some files failed".
    private final class AggregateOutcome {
        var filesWritten = 0
        var filesFailed = 0
        var firstReason: String?
        func recordFailure(_ reason: String) {
            filesFailed += 1
            if firstReason == nil { firstReason = reason }
        }
        func recordReason(_ reason: String) {
            if firstReason == nil { firstReason = reason }
        }
    }

    /// Recursively download all files from the GitHub directory containing SKILL.md,
    /// including subdirectories.
    /// Uses the public GitHub Contents API: GET /repos/:owner/:repo/contents/:path?ref=:branch
    private func downloadSiblingFiles(ghInfo: GitHubInfo, destDir: URL, skill: Skill) async -> SiblingDownloadOutcome {
        let logger = AppLogger(category: "SkillStore")
        logger.info("[siblings] start skill=\(skill.id) dir=\(ghInfo.dirPath) repo=\(ghInfo.user)/\(ghInfo.repo)@\(ghInfo.branch)")
        let agg = AggregateOutcome()
        await downloadGitHubDirectory(
            user: ghInfo.user, repo: ghInfo.repo, branch: ghInfo.branch,
            remotePath: ghInfo.dirPath,
            localDir: destDir, relativeTo: "",
            skill: skill, depth: 0, outcome: agg
        )
        logger.info("[siblings] done skill=\(skill.id) written=\(agg.filesWritten) failed=\(agg.filesFailed) reason=\(agg.firstReason ?? "(none)")")
        return SiblingDownloadOutcome(
            filesWritten: agg.filesWritten,
            filesFailed: agg.filesFailed,
            reason: agg.firstReason
        )
    }

    /// Recursively download a GitHub directory's contents.
    /// - Parameters:
    ///   - remotePath: The full path in the repo (e.g. "bilibili-hub" or "bilibili-hub/src")
    ///   - localDir: The skill's root directory on disk
    ///   - relativeTo: The relative subdirectory path (e.g. "" or "src/utils")
    private func downloadGitHubDirectory(
        user: String, repo: String, branch: String,
        remotePath: String, localDir: URL, relativeTo: String,
        skill: Skill, depth: Int, outcome: AggregateOutcome
    ) async {
        let logger = AppLogger(category: "SkillStore")
        if depth > 5 {
            let msg = "Max recursion depth (5) at \(remotePath) — stopping"
            logger.warning("[siblings] \(msg)")
            outcome.recordReason(msg)
            return
        }

        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        let apiURL = "https://api.github.com/repos/\(user)/\(repo)/contents/\(encodedPath)?ref=\(branch)"

        // 1-shot retry on transient failures (HTTP 403/429/5xx, network exception).
        // Mirrors the Android side; 403 is almost always anonymous rate limit.
        guard let body = await fetchContentsWithRetry(apiURL: apiURL, outcome: outcome) else { return }

        let items: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
                let snippet = String(data: body, encoding: .utf8)?.prefix(160) ?? "(non-utf8)"
                let msg = "GitHub contents API returned non-array JSON for \(remotePath): \(snippet)"
                logger.warning("[siblings] \(msg)")
                outcome.recordReason(msg)
                return
            }
            items = parsed
        } catch {
            let msg = "GitHub contents API JSON decode failed for \(remotePath): \(error.localizedDescription)"
            logger.warning("[siblings] \(msg)")
            outcome.recordReason(msg)
            return
        }

        for item in items {
            guard let name = item["name"] as? String,
                  let type = item["type"] as? String else { continue }

            let relPath = relativeTo.isEmpty ? name : "\(relativeTo)/\(name)"

            if type == "dir" {
                // Recurse into subdirectory
                let subRemote = remotePath.isEmpty ? name : "\(remotePath)/\(name)"
                await downloadGitHubDirectory(
                    user: user, repo: repo, branch: branch,
                    remotePath: subRemote, localDir: localDir, relativeTo: relPath,
                    skill: skill, depth: depth + 1, outcome: outcome
                )
                continue
            }

            guard type == "file",
                  // Skip SKILL.md at root (already imported)
                  !(relativeTo.isEmpty && name.uppercased() == "SKILL.MD")
            else { continue }
            guard let downloadURL = item["download_url"] as? String, !downloadURL.isEmpty else {
                logger.warning("[siblings] missing download_url for \(relPath) — skipping")
                outcome.recordFailure("Missing download_url for \(relPath)")
                continue
            }

            guard let fileData = await fetchBytesWithRetry(downloadURL: downloadURL) else {
                let msg = "Failed to download \(relPath) from \(downloadURL)"
                logger.warning("[siblings] \(msg)")
                outcome.recordFailure(msg)
                continue
            }

            // Write to Library skill dir only if content changed or new
            let destFile = localDir.appendingPathComponent(relPath)
            try? fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existingData = try? Data(contentsOf: destFile)
            if existingData != fileData {
                try? fileData.write(to: destFile)
                logger.info("[siblings] wrote \(relPath) (\(fileData.count)B)")
            } else {
                logger.info("[siblings] kept \(relPath) (unchanged, \(fileData.count)B)")
            }
            outcome.filesWritten += 1
        }
    }

    /// Fetch a GitHub Contents-API URL, retrying once on transient failure
    /// (HTTP 403/429/5xx, URLError). Returns the response body on success or
    /// nil on permanent failure — in which case the failure reason is
    /// recorded into [outcome] so the UI can surface it.
    private func fetchContentsWithRetry(apiURL: String, outcome: AggregateOutcome) async -> Data? {
        let logger = AppLogger(category: "SkillStore")
        guard let url = URL(string: apiURL) else {
            outcome.recordReason("Invalid GitHub contents URL: \(apiURL)")
            return nil
        }
        var lastReason: String?
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse else {
                    lastReason = "GitHub contents API non-HTTP response for \(apiURL)"
                    continue
                }
                if (200..<300).contains(httpResp.statusCode) {
                    return data
                }
                let isTransient = httpResp.statusCode == 403 || httpResp.statusCode == 429 || (500..<600).contains(httpResp.statusCode)
                let hint = httpResp.statusCode == 403 ? " (likely anonymous rate limit — wait an hour or sign in)" : ""
                lastReason = "GitHub contents API HTTP \(httpResp.statusCode)\(hint) for \(apiURL)"
                if !isTransient {
                    logger.warning("[siblings] non-retryable \(lastReason ?? "?")")
                    outcome.recordReason(lastReason!)
                    return nil
                }
            } catch {
                lastReason = "GitHub contents API \(type(of: error)): \(error.localizedDescription) for \(apiURL)"
            }
            if attempt == 0 {
                logger.warning("[siblings] retrying after transient failure: \(lastReason ?? "?")")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        logger.warning("[siblings] both attempts failed: \(lastReason ?? "?")")
        outcome.recordReason(lastReason ?? "GitHub contents API unavailable")
        return nil
    }

    /// Same retry policy as `fetchContentsWithRetry`, for raw file blobs.
    private func fetchBytesWithRetry(downloadURL: String) async -> Data? {
        let logger = AppLogger(category: "SkillStore")
        guard let url = URL(string: downloadURL) else { return nil }
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) { return data }
                    let isTransient = http.statusCode == 403 || http.statusCode == 429 || (500..<600).contains(http.statusCode)
                    if !isTransient {
                        logger.warning("[siblings] HTTP \(http.statusCode) non-retryable for \(downloadURL)")
                        return nil
                    }
                    logger.warning("[siblings] HTTP \(http.statusCode) on \(downloadURL) (attempt \(attempt + 1))")
                }
            } catch {
                logger.warning("[siblings] \(type(of: error)): \(error.localizedDescription) for \(downloadURL) (attempt \(attempt + 1))")
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return nil
    }

    /// Normalize the input URL: add https:// if missing.
    private static func normalizeURL(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        return "https://\(trimmed)"
    }

    static func githubToRawURL(_ urlString: String) throws -> URL {
        let normalized = normalizeURL(urlString)
        NSLog("[SkillStore] githubToRawURL input: %@ → normalized: %@", urlString, normalized)
        if normalized.contains("raw.githubusercontent.com") {
            guard let url = URL(string: normalized) else { throw SkillError.invalidURL }
            if url.lastPathComponent != "SKILL.md" {
                return url.appendingPathComponent("SKILL.md")
            }
            return url
        }

        guard let url = URL(string: normalized),
              url.host == "github.com" else {
            throw SkillError.invalidURL
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4 else { throw SkillError.invalidURL }

        let user = parts[0]
        let repo = parts[1]
        let branch = parts[3]
        let pathParts = Array(parts[4...])
        var path = pathParts.joined(separator: "/")

        if !path.hasSuffix("SKILL.md") {
            path = path.isEmpty ? "SKILL.md" : "\(path)/SKILL.md"
        }

        let rawURLString = "https://raw.githubusercontent.com/\(user)/\(repo)/\(branch)/\(path)"
        guard let rawURL = URL(string: rawURLString) else { throw SkillError.invalidURL }
        return rawURL
    }
}

// MARK: - Errors

enum SkillError: LocalizedError {
    case invalidURL
    case downloadFailed(statusCode: Int)
    case invalidContent
    case noSkillMDInArchive
    case invalidArchive
    case unsafeArchiveEntry(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "Invalid GitHub URL. Use a link to a SKILL.md file or directory.", comment: "Skill import error")
        case .downloadFailed(let code): return String(localized: "Download failed (HTTP \(code)).", comment: "Skill import error; argument is the HTTP status code")
        case .invalidContent: return String(localized: "The downloaded file is empty or not valid text.", comment: "Skill import error")
        case .noSkillMDInArchive: return String(localized: "No SKILL.md found in the archive.", comment: "Skill import error")
        case .invalidArchive: return String(localized: "Could not read the archive file.", comment: "Skill import error")
        case .unsafeArchiveEntry(let name): return String(localized: "The archive contains an unsafe path: \(name)", comment: "Skill import error; argument is the offending path inside the archive")
        case .archiveTooLarge: return String(localized: "The archive is too large.", comment: "Skill import error")
        }
    }
}

// MARK: - CloudSync Helpers

extension SkillStore {
    /// Directory names to exclude when scanning/zipping a skill for sync.
    /// Covers package managers, caches, build artifacts, and VCS directories.
    private static let excludedDirNames: Set<String> = [
        ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
        "node_modules", ".npm", "bower_components",
        ".git", ".svn", ".hg",
        ".tox", ".nox", "eggs",
        ".build", "build", "dist", "DerivedData",
        ".gradle", ".idea", ".vscode",
        "vendor", "Pods", "Carthage",
    ]

    /// Check if a directory name should be excluded (exact match or suffix pattern like .egg-info).
    nonisolated static func isExcludedDir(_ name: String) -> Bool {
        excludedDirNames.contains(name) || name.hasSuffix(".egg-info")
    }

    /// Returns true if no file in the skill directory has been modified within the last `quietSeconds`.
    /// This prevents syncing a skill while it's still being written (e.g. mid-install or mid-edit).
    func isSkillStable(_ skillId: String, quietSeconds: TimeInterval = 60) -> Bool {
        let syncLogger = AppLogger(category: "SkillSync")
        let skillDir = skillsDir.appendingPathComponent(skillId)
        guard fm.fileExists(atPath: skillDir.path) else {
            syncLogger.info("[STABLE] '\(skillId)' directory missing — not stable")
            return false
        }

        let cutoff = Date().addingTimeInterval(-quietSeconds)

        guard let enumerator = fm.enumerator(
            at: skillDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return true }

        for case let fileURL as URL in enumerator {
            // Skip excluded directories
            let lastComponent = fileURL.lastPathComponent
            if Self.isExcludedDir(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let modDate = values?.contentModificationDate, modDate > cutoff {
                let age = Int(Date().timeIntervalSince(modDate))
                syncLogger.info("[STABLE] '\(skillId)' NOT stable — '\(lastComponent)' modified \(age)s ago (need >\(Int(quietSeconds))s)")
                return false
            }
        }
        syncLogger.info("[STABLE] '\(skillId)' is stable — all files older than \(Int(quietSeconds))s")
        return true
    }

    /// Build a ZIP archive of the skill directory for CloudSync.
    /// Includes SKILL.md and all bundled files, excluding package manager dirs.
    /// Returns nil if the skill directory doesn't exist or has no files.
    func buildSkillZipData(_ skillId: String) -> Data? {
        let syncLogger = AppLogger(category: "SkillSync")
        let skillDir = skillsDir.appendingPathComponent(skillId)
        guard fm.fileExists(atPath: skillDir.path) else {
            syncLogger.info("[ZIP] '\(skillId)' directory missing — cannot build ZIP")
            return nil
        }

        var files: [(relativePath: String, data: Data)] = []
        var skippedDirs: [String] = []

        guard let enumerator = fm.enumerator(
            at: skillDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let dirComponents = skillDir.standardizedFileURL.pathComponents

        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent
            if Self.isExcludedDir(lastComponent) {
                enumerator.skipDescendants()
                skippedDirs.append(lastComponent)
                continue
            }

            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }

            let fileComponents = fileURL.standardizedFileURL.pathComponents
            guard fileComponents.count > dirComponents.count else { continue }
            let rel = fileComponents[dirComponents.count...].joined(separator: "/")

            guard let data = try? Data(contentsOf: fileURL) else { continue }
            files.append((relativePath: rel, data: data))
        }

        if !skippedDirs.isEmpty {
            syncLogger.info("[ZIP] '\(skillId)' excluded dirs: \(skippedDirs.joined(separator: ", "))")
        }

        guard !files.isEmpty else {
            syncLogger.info("[ZIP] '\(skillId)' no files found — returning nil")
            return nil
        }

        // Sort so SKILL.md comes first
        files.sort { a, b in
            if a.relativePath == "SKILL.md" { return true }
            if b.relativePath == "SKILL.md" { return false }
            return a.relativePath < b.relativePath
        }

        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        let fileList = files.map { "\($0.relativePath) (\($0.data.count)B)" }.joined(separator: ", ")
        syncLogger.info("[ZIP] '\(skillId)' packing \(files.count) files (\(totalBytes) bytes raw): \(fileList)")

        let zipData = Self.buildZipArchive(files: files)
        syncLogger.info("[ZIP] '\(skillId)' ZIP built: \(zipData.count) bytes")
        return zipData
    }

    /// Import a skill from iCloud sync, unpacking bundled files from a ZIP asset.
    /// Preserves the remote `updatedAt` to avoid sync ping-pong.
    func importSkillFromSyncWithAsset(
        skillId: String, content: String, zipData: Data?,
        source: SkillImportSource,
        isEnabled: Bool, installedAt: Date, updatedAt: Date
    ) {
        let syncLogger = AppLogger(category: "SkillSync")

        // The remote id becomes a directory name under skillsDir.
        guard Self.isSafeSkillId(skillId) else {
            syncLogger.error("[IMPORT] SKIP — unsafe remote skill id '\(skillId)'")
            return
        }

        // Built-in skills are owned by the app bundle: a peer record with the
        // same id must never overwrite (or prune) their files.
        if isBuiltinSkill(skillId) || source == .builtin {
            syncLogger.info("[IMPORT] '\(skillId)' SKIP — built-in skill is not synced")
            return
        }

        // [T-icloud-cloud-overwrites-local-edits] Symmetric edit-window
        // guard. The SEND (upload) path defers a skill whose files were
        // touched within the last 60s (isSkillStable) so we never push a
        // half-written skill. The IMPORT (download) path had NO such guard:
        // while the user is actively editing, the locally-newer upload keeps
        // deferring (unstable) yet a STALE cloud record keeps importing every
        // cycle — and its ZIP-as-truth prune deletes the sibling files the
        // user just created (e.g. cookies.env vanishing in the debug log,
        // issue #41 "改完又被覆盖"). Mirror the upload gate here: if the local
        // skill dir has any file modified within the stability window, the
        // user is mid-edit — skip this import entirely (SKILL.md write AND
        // ZIP unpack/prune). A later cycle, once edits settle >60s, applies
        // genuine peer changes normally. A skill that doesn't exist locally
        // has no edit window and always applies (first download on a new
        // device).
        if skills.contains(where: { $0.id == skillId }), !isSkillStable(skillId) {
            syncLogger.info("[IMPORT] '\(skillId)' SKIP — local files modified within stability window (user mid-edit); deferring inbound apply to protect local edits")
            return
        }

        // [T-icloud-local-edit-clobber] Echo short circuit. Applying a record
        // rewrites SKILL.md (+ ZIP unpack), bumping file mtimes; the dirty
        // scanner then re-pushes the skill with the SAME updatedAt, every peer
        // applies + rewrites + re-pushes in turn, and the identical record
        // ping-pongs between devices forever. An inbound record whose
        // updatedAt matches the local row (±1s) and whose body matches the
        // local SKILL.md is that echo — same version, nothing to do.
        if let local = skills.first(where: { $0.id == skillId }),
           abs(local.updatedAt.timeIntervalSince(updatedAt)) <= 1,
           readSkillContent(skillId) == content {
            syncLogger.info("[IMPORT] '\(skillId)' SKIP — echo of the local version (same updatedAt + same body)")
            return
        }

        // First import metadata + SKILL.md (reuses existing importSkillFromSync)
        syncLogger.info("[IMPORT] '\(skillId)' writing SKILL.md (\(content.count) chars) and updating DB")
        let applied = importSkillFromSync(
            skillId: skillId, content: content, source: source,
            isEnabled: isEnabled, installedAt: installedAt, updatedAt: updatedAt
        )
        // [T-icloud-cloud-overwrites-local-edits] Local copy is newer — the
        // SKILL.md write was skipped above. Abort the ZIP unpack too, or the
        // "ZIP-as-truth" prune below would delete local bundled files that
        // the user just added/edited, against this stale remote record.
        guard applied else {
            syncLogger.info("[IMPORT] '\(skillId)' skipped ZIP unpack — local newer than remote record")
            return
        }

        // If ZIP asset is provided, extract bundled files
        guard let zipData, !zipData.isEmpty else {
            syncLogger.info("[IMPORT] '\(skillId)' complete — no bundled files (SKILL.md only)")
            return
        }
        do {
            // Validates sizes and every entry path before anything is pruned
            // or written; an unsafe entry rejects the whole asset.
            let entries = try Self.readZipEntries(data: zipData)
            let bundledFiles = try Self.bundledZipFiles(entries)
                .filter { $0.path != "SKILL.md" && !$0.path.hasPrefix(".") }
            syncLogger.info("[IMPORT] '\(skillId)' unpacking ZIP: \(zipData.count) bytes, \(entries.count) entries total, \(bundledFiles.count) bundled files to extract")

            let skillDir = skillsDir.appendingPathComponent(skillId)

            // ZIP-as-truth pruning: every bundled file that exists locally
            // but isn't in the incoming ZIP must have been deleted on the
            // sender. Without this step the receiver kept stale bundled
            // files forever (the import only wrote new entries, never
            // removed obsolete ones), so a delete in scripts/ or
            // references/ on peer A would silently fail to propagate to
            // peer B. SKILL.md is excluded from this — it's written by
            // importSkillFromSync above.
            let zipPaths = Set(bundledFiles.map { $0.path })
            let localBundled = collectRelativePaths(in: skillDir).filter { $0 != "SKILL.md" }
            var prunedCount = 0
            for rel in localBundled where !zipPaths.contains(rel) {
                let libFile = skillDir.appendingPathComponent(rel)
                try? fm.removeItem(at: libFile)
                let linuxPath = "/var/minis/skills/\(skillId)/\(rel)"
                removeFakefsPathIfPresent(linuxPath)
                prunedCount += 1
                syncLogger.info("[IMPORT] '\(skillId)' pruned stale bundled file: \(rel)")
            }
            if prunedCount > 0 {
                syncLogger.info("[IMPORT] '\(skillId)' pruned \(prunedCount) local bundled file(s) missing from incoming ZIP")
            }

            // SKILL.md (already written by importSkillFromSync) and hidden
            // top-level entries were filtered out above.
            var extractedCount = 0
            for file in bundledFiles {
                let rel = file.path

                // Write to Library skill dir
                let destFile = try ArchivePathGuard.destination(for: rel, under: skillDir)
                try? fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destFile)

                extractedCount += 1
                syncLogger.info("[IMPORT] '\(skillId)' extracted: \(rel) (\(file.data.count) bytes)")
            }

            syncLogger.info("[IMPORT] '\(skillId)' complete — \(extractedCount) bundled files extracted, \(prunedCount) pruned")
        } catch {
            syncLogger.error("[IMPORT] '\(skillId)' failed to unpack ZIP: \(error)")
        }
    }

    /// Best-effort removal of a fakefs symlink/file for a given Linux
    /// guest path, mirroring how the rest of the import pipeline writes
    /// meta entries on the way in. We swallow errors because the
    /// canonical filesystem state is the Library/rootfs copy we just
    /// removed above — fakefs cleanup is a niceness, not a correctness
    /// requirement.
    private func removeFakefsPathIfPresent(_ linuxPath: String) {
        if #available(iOS 17.0, *) {
            RootfsManager.shared.removeFakefsPath(linuxPath)
        }
    }

    // MARK: - Minimal ZIP Writer

    /// Build a ZIP archive in memory from a list of (relativePath, data) pairs.
    /// Uses Store method (no compression) for simplicity and speed.
    static func buildZipArchive(files: [(relativePath: String, data: Data)]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for file in files {
            let nameData = Data(file.relativePath.utf8)
            let nameLen = UInt16(nameData.count)
            let fileSize = UInt32(file.data.count)
            let crc = crc32(file.data)

            // Local file header
            var local = Data()
            local.appendU32(0x04034B50)           // signature
            local.appendU16(20)                   // version needed
            local.appendU16(0)                    // flags
            local.appendU16(0)                    // method: Store
            local.appendU16(0)                    // mod time
            local.appendU16(0)                    // mod date
            local.appendU32(crc)                  // CRC-32
            local.appendU32(fileSize)             // compressed size
            local.appendU32(fileSize)             // uncompressed size
            local.appendU16(nameLen)              // file name length
            local.appendU16(0)                    // extra field length
            local.append(nameData)
            local.append(file.data)

            // Central directory entry
            var cd = Data()
            cd.appendU32(0x02014B50)              // signature
            cd.appendU16(20)                      // version made by
            cd.appendU16(20)                      // version needed
            cd.appendU16(0)                       // flags
            cd.appendU16(0)                       // method: Store
            cd.appendU16(0)                       // mod time
            cd.appendU16(0)                       // mod date
            cd.appendU32(crc)                     // CRC-32
            cd.appendU32(fileSize)                // compressed size
            cd.appendU32(fileSize)                // uncompressed size
            cd.appendU16(nameLen)                 // file name length
            cd.appendU16(0)                       // extra field length
            cd.appendU16(0)                       // comment length
            cd.appendU16(0)                       // disk number start
            cd.appendU16(0)                       // internal attributes
            cd.appendU32(0)                       // external attributes
            cd.appendU32(offset)                  // local header offset

            cd.append(nameData)

            archive.append(local)
            centralDirectory.append(cd)
            offset += UInt32(local.count)
        }

        let cdOffset = offset
        let cdSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        // End of central directory
        var eocd = Data()
        eocd.appendU32(0x06054B50)               // signature
        eocd.appendU16(0)                        // disk number
        eocd.appendU16(0)                        // disk with CD
        eocd.appendU16(UInt16(files.count))      // entries on disk
        eocd.appendU16(UInt16(files.count))      // total entries
        eocd.appendU32(cdSize)                   // CD size
        eocd.appendU32(cdOffset)                 // CD offset
        eocd.appendU16(0)                        // comment length
        archive.append(eocd)

        return archive
    }

    /// CRC-32 (ISO 3309 / ITU-T V.42)
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendU32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

// MARK: - Minimal ZIP Reader (in-memory)

extension SkillStore {
    struct ZipEntry {
        let name: String
        let isDirectory: Bool
        let data: Data
    }

    /// Bounds for reading an untrusted zip (a picked archive or a skill
    /// asset from iCloud sync) fully into memory.
    struct ZipLimits {
        var maxEntries = 20_000
        var maxEntryBytes = 64 * 1024 * 1024
        var maxTotalBytes = 192 * 1024 * 1024
        /// Cap on the archive file itself, which is read whole.
        static let maxArchiveBytes = 192 * 1024 * 1024
    }

    /// Reads every entry of an in-memory zip. Malformed or truncated
    /// archives, symlink entries and archives over `limits` throw
    /// `SkillError`; every header read is bounds-checked first. Entry names
    /// are returned as stored — use `bundledZipFiles` before writing them.
    /// Entries with an unsupported compression method or encryption are
    /// skipped, as before.
    nonisolated static func readZipEntries(data input: Data, limits: ZipLimits = ZipLimits()) throws -> [ZipEntry] {
        // Zero-based indexing below; a Data slice would not be.
        let data = input.startIndex == 0 ? input : Data(input)
        let count = data.count
        guard count >= 22 else { throw SkillError.invalidArchive }

        var eocdOffset = -1
        let searchStart = max(0, count - 65557)
        for i in stride(from: count - 22, through: searchStart, by: -1) {
            if data[i] == 0x50 && data[i+1] == 0x4B && data[i+2] == 0x05 && data[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw SkillError.invalidArchive }

        let entryCount = Int(readU16(data, at: eocdOffset + 10))
        let cdSize = Int(readU32(data, at: eocdOffset + 12))
        let cdOffset = Int(readU32(data, at: eocdOffset + 16))
        guard entryCount <= limits.maxEntries else { throw SkillError.archiveTooLarge }
        // ZIP64 archives (0xFFFFFFFF sentinels) fail these checks too.
        guard cdOffset <= eocdOffset, cdSize <= eocdOffset - cdOffset else { throw SkillError.invalidArchive }
        let cdEnd = cdOffset + cdSize

        var entries: [ZipEntry] = []
        var totalBytes = 0
        var pos = cdOffset

        for _ in 0..<entryCount {
            guard cdEnd - pos >= 46, readU32(data, at: pos) == 0x02014B50 else {
                throw SkillError.invalidArchive
            }

            let flags = readU16(data, at: pos + 8)
            let method = readU16(data, at: pos + 10)
            let compSize = Int(readU32(data, at: pos + 20))
            let uncompSize = Int(readU32(data, at: pos + 24))
            let nameLen = Int(readU16(data, at: pos + 28))
            let extraLen = Int(readU16(data, at: pos + 30))
            let commentLen = Int(readU16(data, at: pos + 32))
            let externalAttributes = readU32(data, at: pos + 38)
            let localOffset = Int(readU32(data, at: pos + 42))

            let nameStart = pos + 46
            let next = nameStart + nameLen + extraLen + commentLen
            guard next <= cdEnd else { throw SkillError.invalidArchive }
            guard let name = String(data: data.subdata(in: nameStart ..< nameStart + nameLen), encoding: .utf8),
                  !name.isEmpty else {
                throw SkillError.invalidArchive
            }
            pos = next

            // Unix mode lives in the high 16 bits of the external attributes;
            // a symlink entry could redirect later writes outside the skill.
            if (externalAttributes >> 16) & 0o170000 == 0o120000 {
                throw SkillError.unsafeArchiveEntry(name)
            }

            let isDir = name.hasSuffix("/")
            guard uncompSize <= limits.maxEntryBytes, uncompSize <= limits.maxTotalBytes - totalBytes else {
                throw SkillError.archiveTooLarge
            }

            guard localOffset <= count - 30, readU32(data, at: localOffset) == 0x04034B50 else {
                throw SkillError.invalidArchive
            }
            let localNameLen = Int(readU16(data, at: localOffset + 26))
            let localExtraLen = Int(readU16(data, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart <= count, compSize <= count - dataStart else { throw SkillError.invalidArchive }

            let entryData: Data
            if isDir || uncompSize == 0 {
                entryData = Data()
            } else if flags & 0x1 != 0 {
                continue // encrypted
            } else if method == 0 {
                guard compSize == uncompSize else { throw SkillError.invalidArchive }
                entryData = data.subdata(in: dataStart ..< dataStart + compSize)
            } else if method == 8 {
                guard let decompressed = decompress(data.subdata(in: dataStart ..< dataStart + compSize),
                                                    expectedSize: uncompSize) else {
                    throw SkillError.invalidArchive
                }
                entryData = decompressed
            } else {
                continue
            }

            totalBytes += entryData.count
            entries.append(ZipEntry(name: name, isDirectory: isDir, data: entryData))
        }

        return entries
    }

    /// Regular-file entries with every name normalized to a relative path
    /// inside the skill. Throws `SkillError.unsafeArchiveEntry` for absolute
    /// names, `..` components and other names `ArchivePathGuard` refuses —
    /// directory entries included, since they signal the same intent.
    nonisolated static func bundledZipFiles(_ entries: [ZipEntry]) throws -> [(path: String, data: Data)] {
        try entries.compactMap { entry -> (path: String, data: Data)? in
            guard let path = ArchivePathGuard.sanitizedRelativePath(entry.name) else {
                throw SkillError.unsafeArchiveEntry(entry.name)
            }
            return entry.isDirectory ? nil : (path: path, data: entry.data)
        }
    }

    /// Skill ids from sync records become directory names under the skills
    /// root: accept only a single plain, non-hidden path component.
    nonisolated static func isSafeSkillId(_ id: String) -> Bool {
        !id.contains("/") && !id.hasPrefix(".") && ArchivePathGuard.sanitizedRelativePath(id) == id
    }

    nonisolated private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }

    /// Inflates a raw-DEFLATE entry into exactly `expectedSize` bytes (the
    /// central-directory size, already capped by `ZipLimits`). A stream that
    /// yields fewer bytes is truncated or corrupt and returns nil; one that
    /// would yield more is cut at `expectedSize`, so a lying header can't
    /// grow the allocation.
    nonisolated private static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        var decompressed = Data(count: expectedSize)
        let result = decompressed.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                guard let dest = destPtr.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dest, expectedSize, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard result == expectedSize else { return nil }
        return decompressed
    }
}

// MARK: - XML Escape Helper

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
