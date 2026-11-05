import Foundation

/// Compatibility shims so OpenMinis-ported sources compile against OasesChat
/// symbols. Prefer real ported types when they exist:
///   - `RootfsManager`  → Services/ISH/OpenMinisRootfsManager.swift
///   - `AIChatViewModel` → Services/Agent/Chat/AIChatViewModel/
///   - `ChatStore`      → Services/Agent/Chat/ChatStore.swift

/// Per-session attachment/workspace/offload buckets (OpenMinis layout).
enum OasesMinisPaths {
    static let attachmentsLinuxDir = "/var/minis/attachments"
    static let workspaceLinuxDir = "/var/minis/workspace"
    static let offloadsLinuxDir = "/var/minis/offloads"
    static let browserLinuxDir = "/var/minis/browser"

    static func attachmentsPersistentDir(for sid: String) -> URL {
        OasesRootfsAdapter.dataPath.appendingPathComponent("var/minis/attachments", isDirectory: true)
    }
    static func workspacePersistentDir(for sid: String) -> URL {
        OasesRootfsAdapter.dataPath.appendingPathComponent("var/minis/workspace", isDirectory: true)
    }
    static func offloadsPersistentDir(for sid: String) -> URL {
        OasesRootfsAdapter.dataPath.appendingPathComponent("var/minis/offloads", isDirectory: true)
    }
    static func browserPersistentDir(for sid: String) -> URL {
        OasesRootfsAdapter.dataPath.appendingPathComponent("var/minis/browser", isDirectory: true)
    }
}

/// The URL-open broker and the OSC 1337 marker type live in
/// `Features/Terminal/ChatURLBrokerage.swift` as `OasesOpenURLBroker` /
/// `OasesURLMarker`. The former `MinisOpenURLBroker` / `MinisURLMarker` compat
/// aliases have been removed — every call site now uses the canonical names.

/// Path / system-info helpers used by both the Oases `ChatViewModel` surface
/// and OpenMinis `AIChatViewModel` call sites that still route through ChatViewModel.
extension ChatViewModel {
    func appendSystemInfo(_ text: String, icon: String) {
        AppLogger(category: "SystemInfo").info("[\(icon)] \(text)")
    }

    nonisolated static func resolveMinisURL(_ url: URL) -> URL? {
        guard url.scheme == "minis" else { return nil }
        let bucket: String
        switch url.host ?? "" {
        case "attachments": bucket = "var/minis/attachments"
        case "workspace":   bucket = "var/minis/workspace"
        case "offloads":    bucket = "var/minis/offloads"
        case "browser":     bucket = "var/minis/browser"
        case "shared":      bucket = "var/minis/shared"
        default: return nil
        }
        let target = OasesRootfsAdapter.dataPath
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(url.path)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    nonisolated static var minisAttachmentsLinuxDir: String { OasesMinisPaths.attachmentsLinuxDir }
    nonisolated static var minisWorkspaceLinuxDir: String { OasesMinisPaths.workspaceLinuxDir }
    nonisolated static var minisOffloadsLinuxDir: String { OasesMinisPaths.offloadsLinuxDir }
    nonisolated static var minisBrowserLinuxDir: String { OasesMinisPaths.browserLinuxDir }
    nonisolated static func minisAttachmentsPersistentDir(for sid: String) -> URL {
        OasesMinisPaths.attachmentsPersistentDir(for: sid)
    }
    nonisolated static func minisWorkspacePersistentDir(for sid: String) -> URL {
        OasesMinisPaths.workspacePersistentDir(for: sid)
    }
    nonisolated static func minisOffloadsPersistentDir(for sid: String) -> URL {
        OasesMinisPaths.offloadsPersistentDir(for: sid)
    }
    nonisolated static func minisBrowserPersistentDir(for sid: String) -> URL {
        OasesMinisPaths.browserPersistentDir(for: sid)
    }
}
