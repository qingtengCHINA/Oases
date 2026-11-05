import CryptoKit
import XCTest
@testable import Oases_Chat

final class BuiltinSkillSynchronizerTests: XCTestCase {
    private var root: URL!
    private var skillsDir: URL!
    private var stateURL: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("builtin-skills-\(UUID().uuidString)", isDirectory: true)
        skillsDir = root.appendingPathComponent("skills", isDirectory: true)
        stateURL = root.appendingPathComponent("state/builtin-skills-state.json")
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Synchronizer

    func testFreshInstallCopiesFilesAndRecordsState() throws {
        let sync = try makeSynchronizer("v1", [
            "alpha": ["SKILL.md": skillMD("alpha"), "scripts/run.py": "print(1)\n"],
            "beta": ["SKILL.md": skillMD("beta")],
        ])
        XCTAssertFalse(sync.isUpToDate(nil))

        let result = sync.sync(previous: nil)

        XCTAssertEqual(try read("alpha/scripts/run.py"), "print(1)\n")
        XCTAssertEqual(try read("beta/SKILL.md"), skillMD("beta"))
        XCTAssertEqual(result.reports["alpha"]?.installed.sorted(), ["SKILL.md", "scripts/run.py"])
        XCTAssertEqual(result.state.bundleHash, sync.manifest.bundleHash)
        XCTAssertEqual(result.state.skills["alpha"]?.files, sync.manifest.skill(id: "alpha")?.files)

        try sync.saveState(result.state)
        XCTAssertEqual(sync.loadState(), result.state)
        XCTAssertTrue(sync.isUpToDate(sync.loadState()))
    }

    func testUnmodifiedFileIsUpdated() throws {
        let v1 = try makeSynchronizer("v1", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo v1\n"]])
        let state1 = v1.sync(previous: nil).state

        let v2 = try makeSynchronizer("v2", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo v2\n"]])
        XCTAssertFalse(v2.isUpToDate(state1))
        let result = v2.sync(previous: state1)

        XCTAssertEqual(try read("alpha/run.sh"), "echo v2\n")
        XCTAssertEqual(result.reports["alpha"]?.updated, ["run.sh"])
        XCTAssertEqual(result.state.skills["alpha"]?.files["run.sh"], sha("echo v2\n"))
    }

    func testUserModifiedFileIsKept() throws {
        let v1 = try makeSynchronizer("v1", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo v1\n"]])
        let state1 = v1.sync(previous: nil).state
        try write("alpha/run.sh", "echo mine\n")

        let v2 = try makeSynchronizer("v2", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo v2\n"]])
        let result = v2.sync(previous: state1)

        XCTAssertEqual(try read("alpha/run.sh"), "echo mine\n")
        XCTAssertEqual(result.reports["alpha"]?.keptUserModified, ["run.sh"])
        XCTAssertTrue(result.reports["alpha"]?.updated.isEmpty ?? false)
        // State keeps what we last installed, so reverting to it re-enables updates.
        XCTAssertEqual(result.state.skills["alpha"]?.files["run.sh"], sha("echo v1\n"))

        // Same bundle again: still the user's file.
        _ = v2.sync(previous: result.state)
        XCTAssertEqual(try read("alpha/run.sh"), "echo mine\n")
    }

    func testPreexistingFileWithoutStateIsNeverClobbered() throws {
        try write("alpha/SKILL.md", "---\nname: alpha\n---\nmy own alpha\n")
        let sync = try makeSynchronizer("v1", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo v1\n"]])

        let result = sync.sync(previous: nil)

        XCTAssertEqual(try read("alpha/SKILL.md"), "---\nname: alpha\n---\nmy own alpha\n")
        XCTAssertEqual(try read("alpha/run.sh"), "echo v1\n")
        XCTAssertEqual(result.reports["alpha"]?.keptUserModified, ["SKILL.md"])
        XCTAssertNil(result.state.skills["alpha"]?.files["SKILL.md"])
    }

    func testUpstreamDeletedFileRemovedOnlyIfUnmodified() throws {
        let v1 = try makeSynchronizer("v1", ["alpha": [
            "SKILL.md": skillMD("alpha"),
            "old/a.txt": "a\n",
            "old/b.txt": "b\n",
            "refs/only.md": "gone\n",
        ]])
        let state1 = v1.sync(previous: nil).state
        try write("alpha/old/b.txt", "b edited\n")

        let v2 = try makeSynchronizer("v2", ["alpha": ["SKILL.md": skillMD("alpha")]])
        let result = v2.sync(previous: state1)

        XCTAssertFalse(exists("alpha/old/a.txt"))
        XCTAssertEqual(try read("alpha/old/b.txt"), "b edited\n")
        XCTAssertFalse(exists("alpha/refs"), "emptied directories are pruned")
        XCTAssertTrue(exists("alpha/old"), "directory with a kept user file stays")
        XCTAssertEqual(result.reports["alpha"]?.removed.sorted(), ["old/a.txt", "refs/only.md"])
        XCTAssertEqual(result.reports["alpha"]?.keptAfterUpstreamRemoval, ["old/b.txt"])
        XCTAssertNil(result.state.skills["alpha"]?.files["old/b.txt"], "kept file is no longer tracked")
    }

    func testVenvAndUserFilesAreNeverTouched() throws {
        let v1 = try makeSynchronizer("v1", ["alpha": ["SKILL.md": skillMD("alpha"), "run.py": "v1\n"]])
        let state1 = v1.sync(previous: nil).state
        try write("alpha/.venv/lib/site.py", "venv\n")
        try write("alpha/notes.md", "user notes\n")

        let v2 = try makeSynchronizer("v2", ["alpha": ["SKILL.md": skillMD("alpha", "2.0.0")]])
        let state2 = v2.sync(previous: state1).state
        XCTAssertFalse(exists("alpha/run.py"))
        XCTAssertEqual(try read("alpha/.venv/lib/site.py"), "venv\n")
        XCTAssertEqual(try read("alpha/notes.md"), "user notes\n")

        // Skill dropped upstream entirely: our files go, the user's stay.
        let v3 = try makeSynchronizer("v3", ["beta": ["SKILL.md": skillMD("beta")]])
        let result = v3.sync(previous: state2)
        XCTAssertEqual(result.retired["alpha"]?.removed, ["SKILL.md"])
        XCTAssertEqual(try read("alpha/.venv/lib/site.py"), "venv\n")
        XCTAssertEqual(try read("alpha/notes.md"), "user notes\n")
        XCTAssertNil(result.state.skills["alpha"])
    }

    func testRetiredUnmodifiedSkillIsRemovedCompletely() throws {
        let v1 = try makeSynchronizer("v1", [
            "alpha": ["SKILL.md": skillMD("alpha"), "scripts/x.sh": "x\n"],
            "beta": ["SKILL.md": skillMD("beta")],
        ])
        let state1 = v1.sync(previous: nil).state

        let v2 = try makeSynchronizer("v2", ["beta": ["SKILL.md": skillMD("beta")]])
        let result = v2.sync(previous: state1)

        XCTAssertFalse(exists("alpha"))
        XCTAssertEqual(Set(result.retired.keys), ["alpha"])
        XCTAssertTrue(exists("beta/SKILL.md"))
    }

    func testDeletedSkillFolderIsReinstalled() throws {
        let sync = try makeSynchronizer("v1", ["alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo\n"]])
        let state = sync.sync(previous: nil).state
        XCTAssertTrue(sync.isUpToDate(state))

        try fm.removeItem(at: skillsDir.appendingPathComponent("alpha"))
        XCTAssertFalse(sync.isUpToDate(state), "missing SKILL.md defeats the fast path")

        let result = sync.sync(previous: state)
        XCTAssertEqual(result.reports["alpha"]?.installed.sorted(), ["SKILL.md", "run.sh"])
        XCTAssertTrue(sync.isUpToDate(result.state))
    }

    func testSameNameUserSkillIsSkipped() throws {
        let sources = [
            "alpha": "url:https://github.com/someone/alpha/blob/main/SKILL.md",
            "beta": SkillImportSource.builtin.dbValue,
            "unrelated": "file",
        ]
        let owned = BuiltinSkillSynchronizer.userOwnedIds(among: ["alpha", "beta", "gamma"], importSources: sources)
        XCTAssertEqual(owned, ["alpha"])

        try write("alpha/SKILL.md", "---\nname: alpha\n---\nuser alpha\n")
        let sync = try makeSynchronizer("v1", [
            "alpha": ["SKILL.md": skillMD("alpha"), "run.sh": "echo\n"],
            "beta": ["SKILL.md": skillMD("beta")],
        ])
        let result = sync.sync(previous: nil, skipping: owned)

        XCTAssertEqual(result.skipped, ["alpha"])
        XCTAssertEqual(try read("alpha/SKILL.md"), "---\nname: alpha\n---\nuser alpha\n")
        XCTAssertFalse(exists("alpha/run.sh"), "no built-in file lands in a user-owned skill")
        XCTAssertNil(result.state.skills["alpha"])
        XCTAssertNotNil(result.state.skills["beta"])
    }

    func testRejectsUnsafeManifestPaths() {
        XCTAssertTrue(BuiltinSkillSynchronizer.isSafeRelativePath("scripts/run.py"))
        XCTAssertTrue(BuiltinSkillSynchronizer.isSafeRelativePath("references/Help Documentation.md"))
        XCTAssertFalse(BuiltinSkillSynchronizer.isSafeRelativePath("../escape"))
        XCTAssertFalse(BuiltinSkillSynchronizer.isSafeRelativePath("/abs"))
        XCTAssertFalse(BuiltinSkillSynchronizer.isSafeRelativePath("a//b"))
        XCTAssertFalse(BuiltinSkillSynchronizer.isSafeRelativePath(""))
    }

    // MARK: - Guest path routing

    func testGuestSkillsPathRoutesToSkillStoreDirectory() {
        // The shell must see the same tree SkillStore installs into.
        let sid = "skills-route-\(UUID().uuidString.prefix(6))"
        let expected = AIChatViewModel.minisSkillsPersistentDir
            .appendingPathComponent("web-search/SKILL.md").standardizedFileURL.path
        for guest in ["/var/minis/skills/web-search/SKILL.md", "/var/oases/skills/web-search/SKILL.md"] {
            let host = OasesFsRouter.shared.hostURL(forGuest: guest, sessionId: sid)
            XCTAssertEqual(host?.standardizedFileURL.path, expected, guest)
        }
        XCTAssertEqual(
            OasesFsRouter.shared.hostURL(forGuest: "/var/minis/skills", sessionId: sid)?.standardizedFileURL.path,
            AIChatViewModel.minisSkillsPersistentDir.standardizedFileURL.path
        )
    }

    // MARK: - Shipped bundle

    func testShippedBundleMatchesManifest() throws {
        let bundleDir = try XCTUnwrap(SkillStore.builtinSkillsBundleURL, "BuiltinSkills folder missing from app bundle")
        let manifest = try BuiltinSkillsManifest.load(from: bundleDir)

        XCTAssertEqual(manifest.upstream.repo, "https://github.com/OpenMinis/MinisSkills")
        XCTAssertEqual(manifest.upstream.commit, "7ac4068b36bbc961a4d6f0a4a06456d90e2b6f55")
        XCTAssertEqual(manifest.skills.count, 48)
        // ChatGPT-account skills are not bundled in the mainland-China build.
        XCTAssertNil(manifest.skill(id: "codex-image"))
        XCTAssertNil(manifest.skill(id: "codex-on-ish"))
        // The app ships no HealthKit, so the sleep-analysis skill is left out.
        XCTAssertNil(manifest.skill(id: "health-sleep-analysis"))
        XCTAssertNil(manifest.skill(id: "scripts"))
        XCTAssertNil(manifest.skill(id: "today-eats"), "nested sub-skill stays inside todoocard")
        XCTAssertNotNil(manifest.skill(id: "todoocard")?.files["today-eats/SKILL.md"])

        let disabled = Set(manifest.skills.filter { !$0.defaultEnabled }.map(\.id))
        XCTAssertEqual(disabled, ["android-dev", "android-ui-automation", "hyperframes"])
        for skill in manifest.skills {
            XCTAssertEqual(skill.disabledReason != nil, !skill.defaultEnabled, skill.id)
            XCTAssertNotNil(skill.files["SKILL.md"], skill.id)
            for (rel, expected) in skill.files {
                let url = bundleDir.appendingPathComponent(skill.id).appendingPathComponent(rel)
                XCTAssertEqual(BuiltinSkillSynchronizer.sha256Hex(of: url), expected, "\(skill.id)/\(rel)")
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: bundleDir.appendingPathComponent("LICENSE").path))
        XCTAssertTrue(fm.fileExists(atPath: bundleDir.appendingPathComponent("NOTICE").path))
    }

    /// The Skills list shows `description`; the detail page previews the first
    /// 5 non-empty body lines. Neither may name the OpenAI / ChatGPT / GPT brand.
    @MainActor
    func testShippedSkillTextShownInTheUIIsBrandFree() throws {
        let bundleDir = try XCTUnwrap(SkillStore.builtinSkillsBundleURL)
        let manifest = try BuiltinSkillsManifest.load(from: bundleDir)
        for skill in manifest.skills {
            let url = bundleDir.appendingPathComponent(skill.id).appendingPathComponent("SKILL.md")
            let parsed = SkillStore.parse(skillMD: try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(BrandNeutralCopy.containsBrand(parsed.name), "\(skill.id) name")
            XCTAssertFalse(BrandNeutralCopy.containsBrand(parsed.description), "\(skill.id) description")
            XCTAssertFalse(BrandNeutralCopy.containsBrand(skill.disabledReason ?? ""), "\(skill.id) disabledReason")
            let preview = parsed.body.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(5)
            for line in preview {
                XCTAssertFalse(BrandNeutralCopy.containsBrand(line), "\(skill.id) preview: \(line)")
            }
        }
    }

    @MainActor
    func testSkillStoreRegistersBuiltinSkills() throws {
        let store = SkillStore.shared
        store.syncBuiltinSkills()
        store.reload()
        let manifest = try BuiltinSkillsManifest.load(from: XCTUnwrap(SkillStore.builtinSkillsBundleURL))

        for entry in manifest.skills {
            guard let skill = store.skills.first(where: { $0.id == entry.id }) else {
                XCTFail("\(entry.id) not registered")
                continue
            }
            // A user skill that already owned the id keeps it; otherwise it is ours.
            guard skill.importSource == .builtin else { continue }
            XCTAssertEqual(skill.version, entry.version)
            XCTAssertNotNil(store.readSkillContent(entry.id))
            XCTAssertEqual(store.builtinDisabledReason(for: entry.id), entry.disabledReason)
        }

        // "Delete" on a built-in skill only switches it off.
        if let target = store.skills.first(where: { $0.importSource == .builtin }) {
            let wasEnabled = target.isEnabled
            store.deleteSkill(target.id)
            let after = store.skills.first(where: { $0.id == target.id })
            XCTAssertNotNil(after)
            XCTAssertEqual(after?.isEnabled, false)
            XCTAssertTrue(fm.fileExists(atPath: store.skillDirectoryURL(for: target.id).appendingPathComponent("SKILL.md").path))
            store.setEnabled(target.id, enabled: wasEnabled)
        }

        // Prompt disclosure with the real library never exceeds the cap.
        let fragment = store.skillPromptFragment(for: "builtin-test-\(UUID().uuidString)") ?? ""
        XCTAssertLessThanOrEqual(fragment.components(separatedBy: "<skill>").count - 1, SkillStore.maxSkillMetadataCount)
    }

    // MARK: - Prompt fragment

    func testPromptFragmentWith52BuiltinSkillsCapsAt20() throws {
        let skills = (0..<52).map { makeSkill(id: "builtin-\($0)", source: .builtin) }
        let fragment = try XCTUnwrap(SkillStore.skillPromptFragment(enabledSkills: skills))
        XCTAssertEqual(skillCount(in: fragment), 20)
        XCTAssertTrue(fragment.contains("32 more skills not shown above"))
    }

    func testPromptFragmentSurvivesMoreBundledSkillsThanTheCap() throws {
        // The old Priority-1 loop took every `.bundled` skill, so >20 of them
        // made `min(10, 20 - picked.count)` negative and `prefix(_:)` trapped.
        let skills = (0..<25).map { makeSkill(id: "bundled-\($0)", source: .bundled) }
            + (0..<5).map { makeSkill(id: "user-\($0)", source: .file) }
        let fragment = try XCTUnwrap(SkillStore.skillPromptFragment(enabledSkills: skills))
        XCTAssertEqual(skillCount(in: fragment), 20)
    }

    func testBuiltinSkillsDoNotCrowdOutRecentUserSkills() throws {
        let now = Date()
        let builtins = (0..<52).map { makeSkill(id: "builtin-\($0)", source: .builtin, updatedAt: now) }
        let users = (0..<3).map { makeSkill(id: "mine-\($0)", source: .session, updatedAt: now.addingTimeInterval(-3600)) }
        let fragment = try XCTUnwrap(SkillStore.skillPromptFragment(enabledSkills: builtins + users, now: now))
        for user in users {
            XCTAssertTrue(fragment.contains("<name>\(user.name)</name>"), user.id)
        }
        XCTAssertEqual(skillCount(in: fragment), 20)
    }

    // MARK: - Helpers

    private func makeSynchronizer(_ label: String, _ skills: [String: [String: String]]) throws -> BuiltinSkillSynchronizer {
        let bundleDir = root.appendingPathComponent("bundle-\(label)", isDirectory: true)
        var entries: [BuiltinSkillsManifest.Skill] = []
        for (id, files) in skills.sorted(by: { $0.key < $1.key }) {
            var hashes: [String: String] = [:]
            for (rel, content) in files {
                let url = bundleDir.appendingPathComponent(id).appendingPathComponent(rel)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url)
                hashes[rel] = sha(content)
            }
            let contentHash = sha(hashes.sorted { $0.key < $1.key }.map { "\($0.key)\u{0}\($0.value)\n" }.joined())
            entries.append(.init(id: id, name: id, version: "1.0.0", defaultEnabled: true,
                                 disabledReason: nil, contentHash: contentHash, files: hashes))
        }
        let bundleHash = sha(entries.map { "\($0.id)\u{0}\($0.contentHash)\n" }.joined())
        let manifest = BuiltinSkillsManifest(
            schemaVersion: 1,
            upstream: .init(repo: "https://example.invalid/skills", commit: label),
            bundleHash: bundleHash,
            skills: entries
        )
        try JSONEncoder().encode(manifest).write(to: bundleDir.appendingPathComponent(BuiltinSkillsManifest.fileName))
        XCTAssertEqual(try BuiltinSkillsManifest.load(from: bundleDir), manifest)
        return BuiltinSkillSynchronizer(bundleDir: bundleDir, manifest: manifest, skillsDir: skillsDir, stateURL: stateURL)
    }

    private func makeSkill(id: String, source: SkillImportSource, updatedAt: Date = Date()) -> Skill {
        Skill(id: id, name: id, description: "desc \(id)", version: "1.0.0", importSource: source,
              isEnabled: true, installedAt: updatedAt, updatedAt: updatedAt, body: "")
    }

    private func skillCount(in fragment: String) -> Int {
        fragment.components(separatedBy: "<skill>").count - 1
    }

    private func skillMD(_ name: String, _ version: String = "1.0.0") -> String {
        "---\nname: \(name)\nversion: \(version)\ndescription: \(name) skill\n---\n\n# \(name)\n"
    }

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ rel: String) throws -> String {
        try String(contentsOf: skillsDir.appendingPathComponent(rel), encoding: .utf8)
    }

    private func write(_ rel: String, _ content: String) throws {
        let url = skillsDir.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func exists(_ rel: String) -> Bool {
        fm.fileExists(atPath: skillsDir.appendingPathComponent(rel).path)
    }
}
