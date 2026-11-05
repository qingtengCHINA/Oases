//
//  OffloadPathGuard.swift
//  OasesChat
//
//  Strict path policy for native offloads (code review 2026-09-29, 3.6 P0/P1).
//
//  The iSH kernel rewrites every absolute argv path to its host location before
//  an offload handler runs (`native_offload.c: build_host_path_for_guest`), and
//  the handler runs with the host equivalent of the guest CWD, so relative
//  paths land on the host too. Neither step stops `..` or a host symlink from
//  leaving the guest-visible tree: `--output /../meta.db` arrived as
//  `<data>/../meta.db`, and `minis-sessions-cli --attach` read any file in the
//  app sandbox and sent it to the model.
//
//  Every path an offload reads or writes now goes through `resolve`: normalise
//  it, resolve symlinks, and require the result to stay inside the allowed
//  roots. `NativeOffloadUtils.m` (`noff_resolve_guest_path_strict`) supplies the
//  roots for the calling guest task — the rootfs data dir plus that session's
//  `/var/minis` buckets — and callers must use the returned path, never the raw
//  argument.
//

import Foundation

@objc(OffloadPathGuard)
public final class OffloadPathGuard: NSObject {

    enum Failure: LocalizedError, Equatable {
        case empty
        case outsideSandbox(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Empty path."
            case .outsideSandbox(let path):
                return "Path '\(path)' is outside the Linux sandbox. Use a guest path such as /var/minis/workspace/<file>."
            }
        }
    }

    /// Live rootfs data directory. `NativeOffloadUtils.m` prefers the kernel's
    /// mount source and only falls back to this before the kernel is mounted.
    @objc public static var rootfsDataPath: String { ISHRootfsManager.dataURL.path }

    /// Resolve an offload path argument to a canonical host path inside
    /// `allowedRoots`, or throw.
    ///
    /// - `path` is what the handler received: a host path the kernel already
    ///   translated, a raw guest path (option values the kernel did not
    ///   rewrite, comma lists, JSON), or a path relative to `cwd`.
    /// - `translateGuestPath` maps a guest absolute path to its host path for
    ///   the calling task (bind mounts and per-session routing first).
    /// - `isGuestVisibleMount` optionally admits host paths that reverse-map to
    ///   a user-mounted folder (read access only).
    ///
    /// The returned path has `.`/`..` collapsed and symlinks resolved, so the
    /// caller must read or write exactly that path.
    @objc(resolvePath:cwd:allowedRoots:translateGuestPath:isGuestVisibleMount:error:)
    public static func resolve(
        path: String,
        cwd: String?,
        allowedRoots: [String],
        translateGuestPath: (String) -> String?,
        isGuestVisibleMount: ((String) -> Bool)?
    ) throws -> String {
        guard !path.isEmpty else { throw Failure.empty }
        let roots = allowedRoots.filter { $0.hasPrefix("/") }.map(canonicalPath)

        let candidate: String
        if path.hasPrefix("/") {
            let lexical = lexicallyNormalized(path)
            if isHostPath(lexical, roots: roots) || isGuestVisibleMount?(lexical) == true {
                candidate = lexical
            } else if let translated = translateGuestPath(lexical), translated.hasPrefix("/") {
                candidate = translated
            } else {
                throw Failure.outsideSandbox(path)
            }
        } else {
            guard let cwd, cwd.hasPrefix("/") else { throw Failure.outsideSandbox(path) }
            candidate = cwd + "/" + path
        }

        guard let canonical = canonicalize(candidate, rejectDangling: true) else {
            throw Failure.outsideSandbox(path)
        }
        if roots.contains(where: { isContained(canonical, in: $0) })
            || isGuestVisibleMount?(canonical) == true {
            return canonical
        }
        throw Failure.outsideSandbox(path)
    }

    // MARK: - Attachment backstop

    /// Per-session buckets a `--attach` file may come from.
    static let attachmentBuckets: Set<String> = ["workspace", "attachments", "offloads", "browser"]

    /// Swift-side backstop for `minis-sessions-cli --attach`: the `.m` handler
    /// already resolved the paths through `noff_resolve_guest_path_strict`, but
    /// the bridge re-checks before reading, because whatever passes is sent to
    /// the model. Allowed: the rootfs data dir, the shared dir, and
    /// `<sessionBase>/<sid>/<bucket>/…` for the buckets above.
    static func isAllowedAttachmentHostPath(
        _ path: String,
        dataRoot: String,
        sessionBases: [String],
        sharedRoots: [String]
    ) -> Bool {
        guard path.hasPrefix("/"), let canonical = canonicalize(path, rejectDangling: true) else {
            return false
        }
        for root in [dataRoot] + sharedRoots where root.hasPrefix("/") {
            if isContained(canonical, in: canonicalPath(root)) { return true }
        }
        for base in sessionBases where base.hasPrefix("/") {
            let basePath = canonicalPath(base)
            guard canonical.hasPrefix(basePath + "/") else { continue }
            // <sid>/<bucket>/<file…>
            let rest = canonical.dropFirst(basePath.count + 1)
                .split(separator: "/", omittingEmptySubsequences: true)
            if rest.count >= 3, attachmentBuckets.contains(String(rest[1])) {
                return true
            }
        }
        return false
    }

    static func isAllowedAttachmentHostPath(_ path: String) -> Bool {
        isAllowedAttachmentHostPath(
            path,
            dataRoot: ISHRootfsManager.dataURL.path,
            sessionBases: [
                AIChatViewModel.minisPersistentBase.path,
                OasesFsRouter.shared.sessionsBaseURL.path,
            ],
            sharedRoots: [AIChatViewModel.minisSharedPersistentDir.path]
        )
    }

    // MARK: - Path helpers

    /// Collapse `.`, `..` and repeated slashes. `..` never climbs above `/`.
    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Canonical form used for comparisons: lexically normalised, symlinks in
    /// the longest existing prefix resolved, `/private/var` folded to `/var`.
    static func canonicalPath(_ path: String) -> String {
        canonicalize(path, rejectDangling: false) ?? stripPrivatePrefix(lexicallyNormalized(path))
    }

    static func isContained(_ path: String, in root: String) -> Bool {
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Resolve symlinks in the longest existing prefix of `path` and append
    /// the not-yet-existing tail (write targets). With `rejectDangling`, an
    /// entry that exists but cannot be resolved (dangling symlink, loop)
    /// makes the whole path invalid — following it on write could create a
    /// file anywhere.
    private static func canonicalize(_ path: String, rejectDangling: Bool) -> String? {
        var existing = lexicallyNormalized(path)
        var tail: [String] = []
        while true {
            if let real = realPath(existing) {
                var result = real
                for component in tail.reversed() {
                    result = result == "/" ? "/" + component : result + "/" + component
                }
                return stripPrivatePrefix(result)
            }
            if rejectDangling, entryExists(existing) { return nil }
            if existing == "/" { return nil }
            let ns = existing as NSString
            tail.append(ns.lastPathComponent)
            existing = ns.deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// iOS reports the container both as `/var/…` and `/private/var/…`.
    private static func stripPrivatePrefix(_ path: String) -> String {
        for folded in ["/private/var", "/private/tmp", "/private/etc"]
        where path == folded || path.hasPrefix(folded + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Host trees a guest path never starts with. A match means the kernel
    /// already translated the argument, so it must not be translated again.
    private static let hostPrefixes: [String] = {
        var prefixes = ["/var/mobile", "/private", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        // `<…>/Containers/Data/Application/<UUID>` → `<…>/Containers` covers
        // the app container and its App Group containers wherever they live.
        var containers = NSHomeDirectory() as NSString
        for _ in 0..<3 { containers = containers.deletingLastPathComponent as NSString }
        if containers.hasPrefix("/"), containers.length > 1 {
            prefixes.append(stripPrivatePrefix(containers as String))
        }
        return prefixes
    }()

    private static func isHostPath(_ path: String, roots: [String]) -> Bool {
        let folded = stripPrivatePrefix(path)
        if roots.contains(where: { isContained(folded, in: $0) }) { return true }
        return hostPrefixes.contains { isContained(folded, in: $0) }
    }
}
