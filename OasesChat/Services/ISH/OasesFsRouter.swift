import Foundation

/// Per-session guest→host path routing for `/var/oases/{workspace,attachments,offloads,browser}`.
final class OasesFsRouter: @unchecked Sendable {
    static let shared = OasesFsRouter()

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToSid: [UInt64: String] = [:]
    private var sidToContext: [String: UInt64] = [:]
    private var hookInstalled = false

    private let sessionBuckets: [(guestPrefix: String, subdir: String)] = [
        ("\(OasesPathResolver.guestBase)/workspace", "workspace"),
        ("\(OasesPathResolver.guestBase)/attachments", "attachments"),
        ("\(OasesPathResolver.guestBase)/offloads", "offloads"),
        ("\(OasesPathResolver.guestBase)/browser", "browser"),
        ("\(OasesPathResolver.minisAliasBase)/workspace", "workspace"),
        ("\(OasesPathResolver.minisAliasBase)/attachments", "attachments"),
        ("\(OasesPathResolver.minisAliasBase)/offloads", "offloads"),
        ("\(OasesPathResolver.minisAliasBase)/browser", "browser"),
    ]

    /// Host tree behind the per-session buckets: the Ogent engine's canonical
    /// `Library/MinisChat/minis/<sid>/<bucket>` layout, which uploads, tool-output
    /// offloads, browser captures and `minis://` rendering all use.
    ///
    /// The guest reaches it as `/var/oases/<bucket>`: `/var/minis` is a guest
    /// symlink to `/var/oases` and the kernel resolves it before this router's
    /// hook sees the path. Until 2026-09-29 the `/var/oases` buckets mapped to a
    /// second tree (`legacySessionsBaseURL`), so a video Ogent downloaded into
    /// `/var/minis/attachments` never showed up in chat and uploaded attachments
    /// were invisible to the shell.
    let sessionsBaseURL: URL = AIChatViewModel.minisPersistentBase

    /// Pre-2026-09-29 host tree for `/var/oases` buckets; only read by
    /// `migrateLegacyHostTrees()`.
    var legacySessionsBaseURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OasesChat/oases", isDirectory: true)
    }

    /// Pre-2026-09-29 host tree for the global buckets (see `globalRoutes`).
    var globalBaseURL: URL {
        legacySessionsBaseURL.appendingPathComponent("_global", isDirectory: true)
    }

    /// Host tree behind guest `/var/{minis,oases}/skills`: the App Group
    /// skills dir that SkillStore, the file tools, the Files app and iCloud
    /// sync all use. (It used to be `_global/skills`, so skills installed via
    /// SkillStore — including the built-in ones — were readable with
    /// file_read but invisible to shell commands.) Resolved once: the
    /// translate hook runs on the hot fs path.
    let skillsHostURL: URL = AIChatViewModel.minisSkillsPersistentDir

    /// Pre-1.0.3 host tree for guest skills; see `skillsHostURL`.
    var legacyGlobalSkillsURL: URL {
        globalBaseURL.appendingPathComponent("skills", isDirectory: true)
    }

    /// Global trees under `/var/{oases,minis}/<subdir>`, identical in every
    /// fs_context: the App Group directories the app, the Files extension and
    /// the file tools use. (Static bind mounts can't provide these: they are
    /// registered as `/var/minis/...` and fail with ENOTDIR because
    /// `/var/minis` is a symlink.) Resolved once — the hook is on the hot path.
    private let globalRoutes: [(subdir: String, host: URL)] = [
        ("memory", AIChatViewModel.minisMemoryPersistentDir),
        ("skills", AIChatViewModel.minisSkillsPersistentDir),
        ("shared", AIChatViewModel.minisSharedPersistentDir),
        ("mcp-servers", AIChatViewModel.minisMcpServersPersistentDir),
    ]

    private var ensuredDirectories: Set<String> = []

    /// Creates a routed host directory once per process instead of on every
    /// fs operation.
    private func ensureDirectory(_ url: URL) {
        lock.lock()
        let isNew = ensuredDirectories.insert(url.path).inserted
        lock.unlock()
        if isNew {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func context(for sessionId: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let existing = sidToContext[sessionId] { return existing }
        let ctx = nextContext
        nextContext &+= 1
        if nextContext == 0 { nextContext = 1 }
        contextToSid[ctx] = sessionId
        sidToContext[sessionId] = ctx
        return ctx
    }

    func sessionId(for context: UInt64) -> String? {
        guard context != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToSid[context]
    }

    /// Whether a token has ever been issued for `sessionId`. Used by reverse
    /// hooks to refuse translating paths that merely *look* like they live under
    /// a session bucket.
    func isKnownSession(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sidToContext[sessionId] != nil
    }

    func hostBucketURL(sessionId: String, bucket: String) -> URL {
        let url = sessionsBaseURL
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    /// Host URL for any guest path: routed trees first, else the rootfs file.
    /// Used by the file tools; the fakefs hook uses `routedHostURL` instead.
    func hostURL(forGuest guestPath: String, sessionId: String?) -> URL? {
        guard let normalized = OasesPathResolver.normalizeGuestPath(guestPath) else { return nil }
        return routedHostURL(normalized: normalized, sessionId: sessionId)
            ?? OasesPathResolver.hostURLInRootfs(forGuest: normalized)
    }

    /// Host URL for the paths this router owns — the global trees and, with a
    /// session, the per-session buckets — and nil for everything else, so
    /// fakefs keeps its meta.db semantics (modes, symlinks) for the rootfs.
    func routedHostURL(normalized: String, sessionId: String?) -> URL? {
        for route in globalRoutes {
            for base in [OasesPathResolver.guestBase, OasesPathResolver.minisAliasBase] {
                if let tail = Self.tail(of: normalized, afterPrefix: "\(base)/\(route.subdir)") {
                    ensureDirectory(route.host)
                    return tail.isEmpty ? route.host : route.host.appendingPathComponent(tail)
                }
            }
        }
        guard let sessionId else { return nil }
        for bucket in sessionBuckets {
            if let tail = Self.tail(of: normalized, afterPrefix: bucket.guestPrefix) {
                let base = hostBucketURL(sessionId: sessionId, bucket: bucket.subdir)
                return tail.isEmpty ? base : base.appendingPathComponent(tail)
            }
        }
        return nil
    }

    /// Install the composed guest↔host path hooks. Idempotent.
    ///
    /// This is the ONLY place either hook slot is written. `oases_install_path_*_block`
    /// target a single global slot, so a second installer silently disables the
    /// first (the old `ISHKernelAdapter` wrappers were removed for that reason). `MinisFsRouter.installHook()` used to do
    /// exactly that; it now delegates here.
    ///
    /// Resolution order is legacy-first so that no existing session data moves:
    ///   1. `MinisFsRouter` legacy buckets — `/var/minis/{offloads,attachments,
    ///      workspace,browser}` → `Library/MinisChat/minis/<sid>/<bucket>`
    ///   2. this type's Oases layout — `/var/oases/*` (plus the `/var/minis/*`
    ///      alias for memory/skills) → `Library/OasesChat/oases/…`
    ///   3. rootfs fallback via `OasesPathResolver.hostURLInRootfs`
    func installHookIfNeeded() {
        lock.lock()
        let already = hookInstalled
        if !already { hookInstalled = true }
        lock.unlock()
        guard !already else { return }

        oases_install_path_translate_block { [weak self] guestPath, fsContext in
            // Only /var/{oases,minis}/… is routed; every other path keeps plain
            // fakefs semantics (and skips the work on the hot fs path).
            guard let self, guestPath.hasPrefix("/var/") else { return nil }
            let sid = self.sessionId(for: fsContext)
            // A rootfs where /var/minis is still a real directory reaches the
            // hook with literal /var/minis paths; same canonical tree.
            if let sid, let legacy = MinisFsRouter.shared.legacyHostPath(forGuest: guestPath, sid: sid) {
                return legacy
            }
            guard let normalized = OasesPathResolver.normalizeGuestPath(guestPath) else { return nil }
            return self.routedHostURL(normalized: normalized, sessionId: sid)?.path
        }

        // [Stage 0.3] Reverse hook (host → guest). Mirrors OpenMinis
        // `MinisFsRouter.swift::reverse(hostPath:)` (~30 L). Without this the
        // fakefs meta.db readdir lookup over per-session hook-routed buckets
        // silently fails: F_GETPATH on a bind-mounted fd returns the host APFS
        // path; fakefs calls the reverse hook to convert it back to the guest
        // path it keyed on, and without the hook there is no translation — the
        // readdir falls through to the static bind-mount table and finds
        // nothing.
        oases_install_path_reverse_block { [weak self] hostPath in
            guard let self else { return nil }
            if let legacy = MinisFsRouter.shared.legacyReverse(hostPath: hostPath) {
                return legacy
            }
            return self.reverse(hostPath: hostPath)
        }
    }

    /// Reverse hook: given a host APFS path under `<sessionsBaseURL>/<sid>/<bucket>`,
    /// return the canonical guest path `/var/oases/<bucket>/<tail>`.
    /// Returns nil if the path doesn't live under any per-session bucket
    /// (caller falls back to the static bind-mount table). Mirrors OpenMinis
    /// `MinisFsRouter.reverse(hostPath:)`.
    private func reverse(hostPath: String) -> String? {
        let basePath = sessionsBaseURL.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that so a
        // single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        let hostNoPrivate = Self.droppingPrivatePrefix(hostPath)
        for route in globalRoutes {
            let routePath = Self.droppingPrivatePrefix(route.host.path)
            if hostNoPrivate == routePath || hostNoPrivate.hasPrefix(routePath + "/") {
                return "\(OasesPathResolver.guestBase)/\(route.subdir)" + hostNoPrivate.dropFirst(routePath.count)
            }
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        // Drop "<basePath>/" — remaining is "<sid>/<bucket>[/tail]".
        let rest = stripped.dropFirst(basePath.count + 1)
        // Split into sid / bucket / tail (maxSplits: 2 → ["sid", "bucket", "tail..."])
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let sidPart = String(parts[0])
        let bucketName = String(parts[1])
        // Only translate sids we've actually issued a context for. Without this
        // guard, any path that happens to live under <basePath>/<X>/<known-bucket>/
        // would be reverse-translated even when <X> is a stale or unrelated
        // directory — harmless today but masks the cause of bugs.
        lock.lock()
        let known = sidToContext[sidPart] != nil
        lock.unlock()
        guard known else { return nil }
        guard let bucket = sessionBuckets.first(where: { $0.subdir == bucketName }) else { return nil }
        let tail = parts.count == 3 ? "/" + parts[2] : ""
        return bucket.guestPrefix + tail
    }

    // MARK: - Migration

    /// Moves files written while `/var/oases` mapped to `legacySessionsBaseURL`
    /// into the canonical trees (session buckets → `sessionsBaseURL`, global
    /// memory/shared/mcp-servers → the App Group dirs; skills are migrated by
    /// `SkillStore`). Idempotent and cheap once the legacy tree is empty.
    /// Never overwrites: on a name clash both are kept, the moved item gets a
    /// "-oases" suffix.
    func migrateLegacyHostTrees(fileManager: FileManager = .default) {
        let legacyRoot = legacySessionsBaseURL
        guard let entries = try? fileManager.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil),
              !entries.isEmpty else { return }
        var moved = 0
        for entry in entries {
            let name = entry.lastPathComponent
            if name == "_global" {
                for route in globalRoutes where route.subdir != "skills" {
                    moved += Self.mergeContents(of: entry.appendingPathComponent(route.subdir), into: route.host, fileManager: fileManager)
                }
                continue
            }
            for bucket in OasesPathResolver.sessionBuckets {
                moved += Self.mergeContents(
                    of: entry.appendingPathComponent(bucket),
                    into: sessionsBaseURL.appendingPathComponent(name).appendingPathComponent(bucket),
                    fileManager: fileManager
                )
            }
        }
        if moved > 0 {
            NSLog("[OasesFsRouter] migrated %ld item(s) from %@", moved, legacyRoot.path)
        }
    }

    @discardableResult
    static func mergeContents(of source: URL, into destination: URL, fileManager: FileManager) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]),
              !items.isEmpty else { return 0 }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = 0
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) {
                if (try? fileManager.moveItem(at: item, to: target)) != nil { moved += 1 }
            } else if isDirectory(item, fileManager), isDirectory(target, fileManager) {
                moved += mergeContents(of: item, into: target, fileManager: fileManager)
            } else if (try? fileManager.moveItem(at: item, to: uniqueSibling(of: target, fileManager: fileManager))) != nil {
                moved += 1
            }
        }
        return moved
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func uniqueSibling(of url: URL, fileManager: FileManager) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        var index = 1
        while true {
            let suffix = index == 1 ? "-oases" : "-oases-\(index)"
            let candidate = parent.appendingPathComponent(ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func droppingPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func tail(of path: String, afterPrefix prefix: String) -> String? {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        if path == prefix { return "" }
        return String(path.dropFirst(prefix.count + 1))
    }
}
