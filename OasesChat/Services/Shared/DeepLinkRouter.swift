import Foundation

private let deepLinkLog = AppLogger(category: "DeepLink")

/// Pared-down port of OpenMinis `Shared/DeepLinkRouter.swift`. Routes the
/// `oases://` surface into the coordinators the mounted UI observes
/// (`ShareCoordinator`, `DeepLinkCoordinator`, notifications picked up by
/// `AppIntakeCoordinator` / RootView). The scheme is `oases://` rather than
/// `minis://` to avoid colliding with installs that ship the OpenMinis
/// launcher.
///
///   oases://share                          → pending Share Extension hand-off
///   oases://open?session=…&path=…          → pinned WebApp tile (must match a
///                                            shortcut the user created)
///   oases://open_terminal[?init_command=…] → terminal, command pre-filled
///   oases://ask | chat | camera | voice    → composer / camera / dictation
///   oases://session/<id>  (or ?id=<id>)    → open that conversation
///   oases://sessions                       → session list (sidebar)
///   oases://settings[/<page>[/<id>]][?focus=…&tab=…] → Settings
extension Notification.Name {
    /// Posted by `DeepLinkRouter` when an `oases://open?session=…&path=…`
    /// URL lands from a launcher round-trip and matches a persisted pin.
    /// `userInfo["shortcut"]` is that `WebAppShortcut`.
    static let openWebAppDeepLink = Notification.Name("openWebAppDeepLink")

    /// Posted for `oases://sessions` — reveal the session list.
    static let oasesShowSessionList = Notification.Name("oasesShowSessionList")

    /// Posted for `oases://open_terminal`. `userInfo["initCommand"]` carries an
    /// optional command to pre-fill (never auto-run).
    static let openTerminalRequested = Notification.Name("openTerminalRequested")
}

enum DeepLinkRouter {

    /// Oases-only scheme (kept distinct from OpenMinis `minis://`).
    static let scheme = "oases"

    @MainActor
    static func handle(url: URL, shareCoordinator: ShareCoordinator) {
        // `qtc-oases://oauth` belongs to the QingTeng sign-in under way, which
        // receives it from its own browser session; its query carries a
        // one-time result code. Dropped here, silently, so every entry point
        // (onOpenURL, a notification's `url`, in-app links) gets the same
        // guard instead of only `.onOpenURL`.
        if url.scheme?.lowercased() == OAuthSignIn.callbackScheme { return }
        // Log scheme and host only: queries carry session ids, file paths and
        // pre-filled terminal commands.
        let scheme = url.scheme ?? "nil"
        guard scheme == Self.scheme, let host = url.host else {
            deepLinkLog.info("ignored — non-oases or missing host: scheme=\(scheme) host=\(url.host ?? "nil")")
            return
        }
        deepLinkLog.info("handle scheme=\(scheme) host=\(host)")
        switch host {
        case "share":
            shareCoordinator.raisePendingShare()
        case "open":
            routeWebApp(url)
        case "open_terminal":
            // `oases://open_terminal[?init_command=<percent-encoded>]`.
            // `init_command` PRE-FILLS the prompt, it does not execute — the
            // user still presses Return. Same contract as OpenMinis.
            let initCommand = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "init_command" })?.value
            NotificationCenter.default.post(
                name: .openTerminalRequested,
                object: nil,
                userInfo: initCommand.map { ["initCommand": $0] } ?? [:]
            )
        case "ask", "chat":
            NotificationCenter.default.post(name: .oasesWidgetOpen, object: nil, userInfo: ["action": "ask"])
        case "camera":
            NotificationCenter.default.post(name: .oasesWidgetOpen, object: nil, userInfo: ["action": "camera"])
        case "voice":
            NotificationCenter.default.post(name: .oasesWidgetOpen, object: nil, userInfo: ["action": "voice"])
        case "session":
            guard let id = sessionId(from: url) else {
                deepLinkLog.info("session link without an id — ignored")
                return
            }
            DeepLinkCoordinator.shared.pendingSessionId = id
        case "sessions":
            NotificationCenter.default.post(name: .oasesShowSessionList, object: nil)
        case "settings":
            routeSettings(url)
        case "views":
            // OpenMinis "views" (custom panels) have no OasesChat counterpart.
            deepLinkLog.info("views route has no destination in OasesChat — ignored")
        default:
            deepLinkLog.info("unknown host: \(host)")
        }
    }

    // MARK: - Routes

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    /// Path components after the host, e.g. `oases://settings/providers/x`
    /// → `["providers", "x"]`.
    private static func pathSegments(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    /// `oases://session/<id>` or `oases://session?id=<id>`.
    static func sessionId(from url: URL) -> String? {
        let id = pathSegments(of: url).first ?? queryValue("id", in: url)
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    @MainActor
    private static func routeSettings(_ url: URL) {
        let segments = pathSegments(of: url)
        let coordinator = DeepLinkCoordinator.shared
        coordinator.setFocus(rawQueryValue: queryValue("focus", in: url))
        if let tab = queryValue("tab", in: url) { coordinator.pendingLogsTab = tab }
        coordinator.pendingSettingsTarget = settingsTarget(segments) ?? .home
    }

    /// Page names follow OpenMinis / Android `Routes.*` (kebab-case), with
    /// camelCase accepted too.
    static func settingsTarget(_ segments: [String]) -> SettingsDeepLinkTarget? {
        guard let page = segments.first?.lowercased() else { return nil }
        let detail = segments.dropFirst().first
        switch page {
        case "providers":
            return detail.map { .providerDetail(instanceId: $0) } ?? .providers
        case "model-groups", "modelgroups":
            return detail.map { .modelGroupDetail(groupId: $0) } ?? .modelGroups
        case "usage": return .usage
        case "skills": return .skills
        case "memory": return .memory
        case "storage": return .storage
        case "mounted-folders", "mountedfolders": return .mountedFolders
        case "shared-folders", "sharedfolders": return .sharedFolders
        case "logs": return .logs
        case "appearance": return .appearance
        case "background": return .background
        case "about": return .about
        case "permissions": return .permissions
        case "automation", "automations": return .automation
        case "environments", "env": return .environments
        case "mcp", "mcp-integrations", "mcpintegrations":
            return detail.map { .mcpServerDetail(serverId: $0) } ?? .mcpIntegrations
        case "privacy", "data-privacy", "dataprivacy": return .privacy
        default: return nil
        }
    }

    /// `oases://open?session=…&path=…` from a pinned WebApp tile. Only opens a
    /// page that matches a shortcut the user created — never an arbitrary
    /// path supplied by whoever built the URL.
    @MainActor
    private static func routeWebApp(_ url: URL) {
        guard let rawPath = queryValue("path", in: url), !rawPath.isEmpty else {
            deepLinkLog.info("open link without a path — ignored")
            return
        }
        let session = queryValue("session", in: url)
        let target: (scope: WebAppPathScope, context: String?, htmlPath: String)
        if let rest = rawPath.dropPrefix("attachments/"), let session {
            target = (.sessionAttachment, session, rest)
        } else if let rest = rawPath.dropPrefix("workspace/"), let session {
            target = (.sessionWorkspace, session, rest)
        } else if let rest = rawPath.dropPrefix("shared:") {
            target = (.shared, nil, rest)
        } else if let rest = rawPath.dropPrefix("mount:"),
                  let slash = rest.firstIndex(of: "/") {
            target = (.mount, String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
        } else {
            deepLinkLog.info("open link with unrecognised path scope — ignored")
            return
        }
        Task { @MainActor in
            let pinned = await WebAppShortcutStore.shared.all()
            guard let shortcut = pinned.first(where: {
                $0.pathScope == target.scope
                    && $0.scopeContext == target.context
                    && $0.htmlPath == target.htmlPath
            }) else {
                deepLinkLog.info("open link does not match any pinned WebApp — ignored")
                return
            }
            NotificationCenter.default.post(name: .openWebAppDeepLink, object: nil, userInfo: ["shortcut": shortcut])
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}