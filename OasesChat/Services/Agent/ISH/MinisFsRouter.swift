//
//  MinisFsRouter.swift
//  OasesChatApp
//
//  LEGACY MAPPING PROVIDER for the OpenMinis guest namespace
//  `/var/minis/{offloads,attachments,workspace,browser}`.
//
//  ⚠️ This type no longer owns the fakefs hook or the fs_context token space.
//  Both are owned by `OasesFsRouter` (Services/ISH/OasesFsRouter.swift).
//
//  Why the change (fixed 2026-08-09):
//    `MinisFsRouter.installHook()` and `OasesFsRouter.installHookIfNeeded()`
//    both wrote the SAME single global fakefs slots
//    (`oases_install_path_translate_block` / `..._reverse_block` — see
//    `ISHKernelAdapter.installPathTranslateHandler`, which is just a wrapper
//    around the same C entry point). Last writer won, so entering engineering
//    mode silently disabled `/var/oases/*` per-session routing, and booting
//    chat mode first silently disabled `/var/minis/*` routing.
//
//    Worse, each router handed out fs_context tokens from its OWN counter
//    starting at 1. `ISHExecutionCoordinator` allocated from this type while
//    `ISHRuntimeService` / `DebugJSONRPC` allocated from `OasesFsRouter`, so the
//    same token value could denote two different sessions — the single live
//    hook would then resolve a task's paths into ANOTHER session's directory.
//
//  What is preserved: the host tree. `/var/minis/<bucket>` still resolves to
//  `<AIChatViewModel.minisPersistentBase>/<sid>/<bucket>` exactly as before, so
//  no existing engineering-mode session data moves. `OasesFsRouter` consults
//  this legacy mapping FIRST and only then applies its own `/var/oases/*` layout.
//

import Foundation

final class MinisFsRouter: @unchecked Sendable {
    static let shared = MinisFsRouter()

    /// Guest path prefixes that route per-session. Anything under one of these
    /// becomes ~/Library/.../minis/<sid>/<bucket>/<tail>. Paths under
    /// /var/minis/{memory,skills,shared} stay global and are NOT listed here —
    /// they fall through to `OasesFsRouter`'s global buckets / the legacy
    /// g_bind_mounts[] table.
    private let perSessionBuckets: [(linuxPrefix: String, hostSubdir: String)] = [
        (AIChatViewModel.minisOffloadsLinuxDir,    "offloads"),
        (AIChatViewModel.minisAttachmentsLinuxDir, "attachments"),
        (AIChatViewModel.minisWorkspaceLinuxDir,   "workspace"),
        (AIChatViewModel.minisBrowserLinuxDir,     "browser"),
    ]

    /// Host base URL (~/Library/MinisChat/minis). Captured once at init.
    private let minisBaseURL: URL

    private init() {
        self.minisBaseURL = AIChatViewModel.minisPersistentBase
    }

    // MARK: - fs_context tokens (delegated — single source of truth)

    /// Allocate a stable fs_context token for `sid`.
    ///
    /// Delegates to `OasesFsRouter` so there is exactly ONE token space. Two
    /// counters both starting at 1 previously produced colliding tokens across
    /// the engineering-mode and chat-mode call sites.
    func context(for sid: String) -> UInt64 {
        OasesFsRouter.shared.context(for: sid)
    }

    /// Reverse token lookup. Delegated for the same reason as `context(for:)`.
    func sid(for context: UInt64) -> String? {
        OasesFsRouter.shared.sessionId(for: context)
    }

    // MARK: - Hook installation (delegated)

    /// Install the path-translate hook. Kept as a call-compatible shim: the real
    /// installation is `OasesFsRouter.installHookIfNeeded()`, which composes this
    /// type's legacy mapping with the `/var/oases/*` layout and is idempotent.
    ///
    /// Previously this method clobbered whatever hook `OasesFsRouter` had set.
    func installHook() {
        OasesFsRouter.shared.installHookIfNeeded()
    }

    // MARK: - Legacy translation (consumed by OasesFsRouter's composed hook)

    /// Resolve a guest path under one of the legacy per-session buckets to its
    /// host URL for the given sid. Returns nil if the path is not under any
    /// legacy per-session bucket (caller falls back to the Oases layout, then to
    /// the static mount table). Used by Swift call sites that need the host path
    /// without going through iSH (e.g. NSFileCoordinator on attachments).
    func hostURL(forGuest guestPath: String, sid: String) -> URL? {
        guard let path = legacyHostPath(forGuest: guestPath, sid: sid) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Forward mapping for the legacy `/var/minis/*` per-session buckets.
    ///
    /// Called on iSH worker threads from the composed fakefs hook — MUST stay
    /// non-blocking (a few string ops, no locks, no I/O).
    func legacyHostPath(forGuest guestPath: String, sid: String) -> String? {
        for bucket in perSessionBuckets {
            let prefix = bucket.linuxPrefix
            guard guestPath.hasPrefix(prefix) else { continue }
            let prefixEnd = guestPath.index(guestPath.startIndex, offsetBy: prefix.count)
            if prefixEnd != guestPath.endIndex && guestPath[prefixEnd] != "/" {
                continue
            }
            let tail = String(guestPath[prefixEnd...])
            return minisBaseURL
                .appendingPathComponent(sid, isDirectory: true)
                .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                .path + tail
        }
        return nil
    }

    /// Reverse hook for the legacy tree: given a host APFS path under
    /// `<minisBaseURL>/<sid>/<bucket>`, return the canonical guest path
    /// `/var/minis/<bucket>/<tail>`. Returns nil if the path doesn't live under
    /// any legacy per-session bucket (caller falls back to the Oases reverse
    /// mapping, then to the static bind_mount_resolve table).
    func legacyReverse(hostPath: String) -> String? {
        let basePath = minisBaseURL.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that
        // so a single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        let rest = stripped.dropFirst(basePath.count + 1)  // "<sid>/<bucket>[/tail]"
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let sidPart = String(parts[0])
        let bucketName = String(parts[1])
        // Only translate sids we've actually issued a context for. Without this
        // guard, any path that happens to live under <basePath>/<X>/<known-bucket>/
        // would be reverse-translated even when <X> is a stale or unrelated
        // directory — harmless today but masks the cause of bugs.
        guard OasesFsRouter.shared.isKnownSession(sidPart) else { return nil }
        guard let bucket = perSessionBuckets.first(where: { $0.hostSubdir == bucketName })
        else { return nil }
        let tail = parts.count == 3 ? "/" + parts[2] : ""
        return bucket.linuxPrefix + tail
    }
}
