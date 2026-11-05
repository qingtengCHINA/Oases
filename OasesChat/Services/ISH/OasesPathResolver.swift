import Foundation

/// Linux-path contract for engineering mode, aligned with OpenMinis `/var/minis/*`.
///
/// Session-scoped buckets (`workspace`, `attachments`, `offloads`, `browser`) resolve
/// through `OasesFsRouter` into `Library/MinisChat/minis/<sessionId>/…` (the same tree
/// uploads, offloads and `minis://` rendering use) so two sessions never share one
/// physical tree. Global memory/skills/shared/mcp-servers resolve to the App Group
/// dirs. `/var/minis` is a guest symlink to `/var/oases`. Other absolute guest paths
/// fall through to the Alpine fakefs `data/` tree.
enum OasesPathResolver {
    static let guestBase = "/var/oases"
    static let minisAliasBase = "/var/minis"

    static let workspace = "\(guestBase)/workspace"
    static let attachments = "\(guestBase)/attachments"
    static let offloads = "\(guestBase)/offloads"
    static let browser = "\(guestBase)/browser"
    static let memory = "\(guestBase)/memory"
    static let skills = "\(guestBase)/skills"

    static let sessionBuckets = ["workspace", "attachments", "offloads", "browser"]
    static let globalBuckets = ["memory", "skills"]

    // MARK: - Thread-local / task-local session for file tools

    /// Active engineering session id used by file tools when callers do not pass one.
    enum ActiveSession {
        @TaskLocal static var id: String?
    }

    // MARK: - Normalize

    static func normalizeGuestPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("..") else { return nil }

        if trimmed.hasPrefix(minisAliasBase + "/") || trimmed == minisAliasBase {
            let rest = String(trimmed.dropFirst(minisAliasBase.count))
            return rest.isEmpty ? guestBase : guestBase + rest
        }

        if trimmed.hasPrefix("/") {
            return cleanedAbsolute(trimmed)
        }

        let relative = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        guard !relative.isEmpty else { return workspace }
        return cleanedAbsolute("\(workspace)/\(relative)")
    }

    private static func cleanedAbsolute(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    // MARK: - Host mapping

    /// Prefer session-aware router; falls back to rootfs for non-bucket paths.
    static func hostURL(forGuest guestPath: String, sessionId: String? = ActiveSession.id) -> URL? {
        OasesFsRouter.shared.hostURL(forGuest: guestPath, sessionId: sessionId)
    }

    /// Alpine fakefs `data/` mapping (no session rewrite).
    static func hostURLInRootfs(forGuest guestPath: String) -> URL? {
        guard let normalized = normalizeGuestPath(guestPath) else { return nil }
        let relative = String(normalized.dropFirst())
        if relative.isEmpty { return ISHRootfsManager.dataURL }
        return ISHRootfsManager.dataURL.appendingPathComponent(relative)
    }

    static func oasesURL(forGuest guestPath: String) -> String? {
        guard let normalized = normalizeGuestPath(guestPath) else { return nil }
        guard normalized.hasPrefix(guestBase + "/") else { return nil }
        let rest = String(normalized.dropFirst(guestBase.count + 1))
        guard let slash = rest.firstIndex(of: "/") else {
            return "oases://\(rest)/"
        }
        let ns = String(rest[..<slash])
        let file = String(rest[rest.index(after: slash)...])
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return "oases://\(ns)/\(encoded)"
    }

    // MARK: - Materialize

    @discardableResult
    static func materializeGuestLayout() -> Bool {
        // Global host trees are created on first use by `OasesFsRouter`.
        // Placeholder under rootfs for non-session fallback visibility
        for dir in [guestBase] + sessionBuckets.map { "\(guestBase)/\($0)" } + globalBuckets.map { "\(guestBase)/\($0)" } {
            if let host = hostURLInRootfs(forGuest: dir) {
                try? FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
            }
        }

        OasesFsRouter.shared.installHookIfNeeded()

        // Guest fakefs mkdir / ln MUST run on the dedicated iSH pthread.
        // Calling ish_runtime_ensure_guest_directory off-thread (e.g. XCTest
        // setUp on main) crashes with EXC_BAD_ACCESS in path_normalize when
        // the runtime is already warm — that looked like launch freezes /
        // crash loops under the debugger.
        guard ish_runtime_is_ready() != 0 else { return true }

        return ISHRuntimeQueue.sync {
            let dirs = [guestBase]
                + sessionBuckets.map { "\(guestBase)/\($0)" }
                + globalBuckets.map { "\(guestBase)/\($0)" }
                + ["\(guestBase)/sessions"]
            for dir in dirs {
                _ = dir.withCString { ish_runtime_ensure_guest_directory($0) }
            }
            _ = ISHShellExecutor.executeCommandSync(
                "mkdir -p /var && ln -sfn /var/oases /var/minis 2>/dev/null || true",
                timeout: 10,
                lineCallback: nil
            )
            return true
        }
    }

    static func ensureParentDirectories(forGuestFile path: String, sessionId: String? = ActiveSession.id) throws {
        guard let guestPath = normalizeGuestPath(path) else {
            throw PathError.invalidPath(path)
        }
        let parent = (guestPath as NSString).deletingLastPathComponent
        guard parent != "/", !parent.isEmpty else { return }
        if let host = hostURL(forGuest: parent, sessionId: sessionId) {
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        }
    }

    static func writeGuestFile(path: String, content: String, sessionId: String? = ActiveSession.id, mode: Int = 0o644) throws {
        guard let guestPath = normalizeGuestPath(path) else {
            throw PathError.invalidPath(path)
        }
        guard let data = content.data(using: .utf8) else {
            throw PathError.notUTF8
        }
        try ensureParentDirectories(forGuestFile: guestPath, sessionId: sessionId)
        guard let host = hostURL(forGuest: guestPath, sessionId: sessionId) else {
            throw PathError.invalidPath(guestPath)
        }
        try data.write(to: host, options: .atomic)

        // Best-effort: also mirror into rootfs data/ for tools that ignore fs_context
        // when writing outside session buckets — skip if session-routed (different path).
        if let rootfs = hostURLInRootfs(forGuest: guestPath),
           rootfs.standardizedFileURL.path != host.standardizedFileURL.path,
           sessionId == nil {
            try? FileManager.default.createDirectory(
                at: rootfs.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: rootfs, options: .atomic)
            if ish_runtime_is_ready() != 0 {
                _ = data.withUnsafeBytes { bytes in
                    ish_runtime_write_guest_file(guestPath, bytes.baseAddress, data.count, Int32(mode))
                }
            }
        }
    }

    enum PathError: LocalizedError {
        case invalidPath(String)
        case notUTF8
        case notFound(String)
        case binaryFile(String)
        case notUTF8File(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let p): return "Invalid path: \(p)"
            case .notUTF8: return "Content is not valid UTF-8"
            case .notFound(let p): return "No such file: \(p)"
            case .binaryFile(let p): return "Binary file refused: \(p)"
            case .notUTF8File(let p): return "Not valid UTF-8 text: \(p)"
            }
        }
    }
}
