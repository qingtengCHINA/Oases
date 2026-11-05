import Foundation
import os

/// Stage 0.1 — Single source of truth for the App Group identifier shared by
/// the host app and all extensions (FileProvider / ShareExtension / Widget).
///
/// Why this is a constant and not scattered across files: OpenMinis hard-codes
/// `com.openminis.app` / `group.com.openminis.app` in dozens of places; once you
/// copy more over, having one anchor here lets later diffs stay minimal. The
/// identifier on the entitlements side must match `AppGroup.id` exactly.
///
/// OasesChat uses `dev.oases.chat.ios` as the bundle-prefix and a single App
/// Group `group.dev.oases.chat.ios`. Other code should never reach into the
/// string literal directly — always go through `AppGroup`.
enum AppGroup {
    /// Must mirror `OasesChat.entitlements::com.apple.security.application-groups`.
    static let id = "group.dev.oases.chat.ios"

    /// Shared container URL returned by FileManager. Falls back to a per-app
    /// directory when the App Group provisioning profile isn't installed
    /// (e.g. running on a simulator without proper entitlements, or while a
    /// developer is iterating before the Apple Developer portal has the App
    /// Group registered). Callers must not assume `container` exists; we
    /// always create it lazily on first write.
    static var container: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        return fallbackContainer
    }

    /// Keeps simulators / unsigned builds working. Application Support, not
    /// Caches: the system may purge Caches, and `configRoot` (MCP server
    /// configs with credentials) lives in here. Extensions can't see this
    /// directory, so the fallback is logged (once) instead of being silent.
    private static let fallbackContainer: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let nested = base.appendingPathComponent("AppGroupFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        Logger(subsystem: "dev.oases.chat.ios", category: "AppGroup").error(
            "App Group \(id, privacy: .public) unavailable — falling back to \(nested.path, privacy: .public); extensions will not see this data"
        )
        return nested
    }()

    // MARK: - FileProvider roots (P0-3)

    /// Everything the FileProvider extension exposes to the iOS Files app.
    /// Mirrors OpenMinis `AIChatViewModel.minisAppGroupRoot` and must match
    /// `Extensions/FileProvider/FileProviderExtension.swift::rootDirectory`.
    static var fileProviderRoot: URL {
        container.appendingPathComponent("OasesFileProvider", isDirectory: true)
    }

    static var fileProviderShared: URL {
        fileProviderRoot.appendingPathComponent("shared", isDirectory: true)
    }

    static var fileProviderSkills: URL {
        fileProviderRoot.appendingPathComponent("skills", isDirectory: true)
    }

    static var fileProviderMemory: URL {
        fileProviderRoot.appendingPathComponent("memory", isDirectory: true)
    }

    /// Private metadata sibling of `fileProviderRoot` that must NOT surface in
    /// iOS Files (mounted-folders.json, extension logs, MCP server configs
    /// carrying credentials). The extension reaches it by literal path.
    static var configRoot: URL {
        let url = container.appendingPathComponent("OasesConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}