import Foundation
import SwiftUI
import UIKit

// MARK: - Types

enum OffloadPermissionLevel: Int, CaseIterable {
    case bypass = 0
    case askOnce = 1
    case notAllowed = 2

    var displayName: String {
        switch self {
        case .bypass: return SettingsCopy.t("始终允许", "Bypass")
        case .askOnce: return SettingsCopy.t("询问一次", "Ask Once")
        case .notAllowed: return SettingsCopy.t("不允许", "Not Allowed")
        }
    }
}

enum PermissionResult: Sendable {
    case allowed
    case denied(String)
}

struct PermissionRequest: Identifiable {
    let id: String
    let commandName: String
    let displayLabel: String
    let description: String
    /// The full shell command string, e.g. "apple-calendar list --today"
    let fullCommand: String
    /// What an approval covers: the action (subcommand) it is keyed by, ""
    /// when the command has none. See `OffloadCommandPolicy.action`.
    var action: String = ""
    /// Irreversible action: the approval covers this one call and is not
    /// remembered for the session.
    var asksEveryTime: Bool = false
    let continuation: CheckedContinuation<Bool, Never>

    /// Parse the command arguments into displayable key-value pairs.
    /// Handles patterns like: `command subcommand --key value --flag`.
    ///
    /// Only the FIRST shell command's tokens are surfaced — anything past a
    /// pipe / chain operator (`&&`, `||`, `;`, `|`) or a redirect (`>`,
    /// `>>`, `<`) belongs to a separate process or is plumbing the user
    /// shouldn't have to skim through to grant a permission. Without this
    /// gate the previous parser dumped the redirect target, the chained
    /// `python3 -c "..."` blob, and every word inside the quoted python
    /// snippet as `arg` rows, pushing the Allow / Deny buttons below the
    /// sheet's bottom edge.
    var parsedArguments: [(key: String, value: String)] {
        let parts = Self.firstCommandTokens(fullCommand)
        guard parts.count > 1 else { return [] }

        var result: [(key: String, value: String)] = []
        // First non-command token is the subcommand
        var idx = 1
        if idx < parts.count && !parts[idx].hasPrefix("-") {
            result.append((key: String(localized: "Action", comment: "Permission prompt: label for the subcommand the agent wants to run"), value: parts[idx]))
            idx += 1
        }
        while idx < parts.count {
            let token = parts[idx]
            if token.hasPrefix("--") || token.hasPrefix("-") {
                let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if idx + 1 < parts.count && !parts[idx + 1].hasPrefix("-") {
                    result.append((key: key, value: parts[idx + 1]))
                    idx += 2
                } else {
                    result.append((key: key, value: "true"))
                    idx += 1
                }
            } else {
                result.append((key: "arg", value: token))
                idx += 1
            }
        }
        return result
    }

    /// Whitespace-split the command but stop at the first shell separator so
    /// only the head command's tokens are returned. This is permissive about
    /// quoting (we don't try to honour `'...'` / `"..."` boundaries) — good
    /// enough for the permission-row preview where we just want to suppress
    /// the long tail past `&&`, redirects, etc. that confused users.
    private static let shellSeparators: Set<String> = [
        "&&", "||", ";", "|", ">", ">>", "<", "<<", "&",
    ]

    private static func firstCommandTokens(_ command: String) -> [String] {
        let raw = command.split(separator: " ").map(String.init)
        var head: [String] = []
        for token in raw {
            if shellSeparators.contains(token) { break }
            head.append(token)
        }
        return head
    }
}

// MARK: - Command Definitions

enum OffloadCommandCategory: String, CaseIterable {
    case privacy = "Privacy"
    case media = "Media"
    case system = "System"
}

struct OffloadCommandInfo {
    let name: String
    let displayLabel: String
    let description: String
    let category: OffloadCommandCategory
    /// Only commands the user can configure appear in Settings
    let showInSettings: Bool
    /// Level used until the user picks one in Settings. Commands with any
    /// privacy-reading or side-effect subcommand start at `.askOnce`; purely
    /// local or informational ones stay `.bypass`.
    let defaultLevel: OffloadPermissionLevel
}

/// What one offload invocation does, decided per subcommand by
/// `OffloadCommandPolicy.classify`. Drives the handler-level gate.
enum OffloadAccessKind: Equatable, Sendable {
    /// `--help` / `-h`: every handler prints usage and exits before acting.
    case help
    /// No personal data and no effect outside the app.
    case info
    /// Reads personal data (calendar, photos, location, clipboard, chats, …).
    case read
    /// Changes something or acts outside the app (create/delete, open a URL,
    /// send a prompt, call a paid model, …).
    case write
}

/// Outcome of `OffloadPermissionManager.decide`.
enum OffloadGateDecision: Equatable, Sendable {
    case allow
    case deny(String)
    /// Ask the user. Only returned when a prompt can be shown.
    case prompt
}

// MARK: - Subcommand policy

/// Per-subcommand classification for every registered native offload.
///
/// Parsing mirrors `NativeOffloadUtils.m` (`noff_get_subcommand`,
/// `noff_find_arg`, `noff_has_flag`) and runs on the same argv the handler
/// gets, so the gate sees the subcommand the handler will dispatch on.
/// Unknown subcommands classify as `.write`: the handler rejects them anyway,
/// and a list that drifts from the handler must never under-classify.
enum OffloadCommandPolicy {
    static func classify(command: String, arguments: [String]) -> OffloadAccessKind {
        if arguments.contains("--help") || arguments.contains("-h") { return .help }
        let sub = subcommand(in: arguments)

        switch command {
        case "apple-device", "apple-speak", "apple-nlp", "apple-vision", "apple-maps",
             "apple-player", "ffmpeg", "oases-debug":
            // Device info, local text/image/media processing, explicit-coordinate map
            // lookups and the app's own player. oases-debug only acts in Debug builds.
            return .info
        case "apple-calendar":
            return kind(of: sub,
                        read: ["calendars", "list", "reminders", "freebusy"],
                        write: ["create", "update", "delete", "remind",
                                "complete-reminder", "update-reminder", "delete-reminder"])
        case "apple-reminders":
            return kind(of: sub, read: ["list"], write: ["create", "update", "delete", "complete"])
        case "apple-photos":
            return kind(of: sub,
                        read: ["list", "near", "albums", "album", "stats", "export"],
                        write: ["import", "save", "create-album", "add-to-album", "favorite", "delete"])
        case "apple-location":
            return kind(of: sub, read: ["current"], info: ["geocode", "forward"], none: .read)
        case "apple-contacts":
            // Swift-only capability (the `contact_search` tool): no guest offload.
            return kind(of: sub, read: ["search"], none: .read)
        case "apple-clipboard":
            // Reads count as private: the clipboard routinely holds passwords and
            // one-time codes.
            return kind(of: sub, read: ["get", "status"], write: ["set", "clear"], none: .read)
        case "apple-weather":
            // Explicit coordinates reveal nothing; without them the handler looks up
            // the current location.
            if let sub, !["current", "hourly", "daily", "alerts", "report"].contains(sub) {
                return .write
            }
            let hasCoordinates = value(of: "--lat", in: arguments) != nil
                && value(of: "--lng", in: arguments) != nil
            return hasCoordinates ? .info : .read
        case "apple-speech":
            guard sub == "transcribe" else { return kind(of: sub, info: ["languages", "status"]) }
            return isMicrophoneSource(value(of: "--source", in: arguments)) ? .read : .info
        case "apple-media":
            if sub == "volume" { return value(of: "--set", in: arguments) == nil ? .info : .write }
            return kind(of: sub,
                        read: ["now-playing", "search"],
                        write: ["play", "pause", "toggle", "next", "prev", "play-search"],
                        none: .read)
        case "apple-notification":
            return kind(of: sub, write: ["schedule", "cancel"], info: ["pending", "delivered", "settings"])
        case "apple-alarm":
            return kind(of: sub, write: ["set", "timer", "cancel"], info: ["list"])
        case "apple-open":
            // The URL sits in subcommand position; without one the handler errors out.
            return sub == nil ? .info : .write
        case "apple-bluetooth":
            return kind(of: sub,
                        read: ["scan", "services", "read", "notify"],
                        write: ["connect", "disconnect", "write"],
                        info: ["status"])
        case "apple-nfc":
            return kind(of: sub,
                        read: ["scan", "tag-info", "tag-read", "read-emv", "felica"],
                        write: ["write", "tag-write", "apdu"],
                        info: ["status", "lookup-aid", "lookup-tag", "search"])
        case "minis-sessions-cli":
            return kind(of: sub,
                        read: ["list", "search", "messages", "status"],
                        write: ["send", "retry"],
                        info: ["open"],
                        none: .read)
        case "minis-model-use":
            return kind(of: sub, write: ["run"], info: ["list", "search"])
        case "minis-browser-use":
            // Same surface as the built-in browser_use tool, except cookie access.
            switch browserAction(in: arguments) {
            case "get_cookies": return .read
            case "set_cookies": return .write
            default: return .info
            }
        case "oases-config":
            // Enforced by ConfigOffloadBridge (master switch + confirmation sheet);
            // the gate only needs to know which calls wait on that sheet.
            return kind(of: sub,
                        write: ["set", "set-batch", "add", "audit-revert"],
                        info: ["list-topics", "topic-help", "get", "audit-list", "audit-get"])
        default:
            return .write
        }
    }

    /// The action an "Ask Once" approval is keyed by, so approving one action
    /// never approves another (allowing `apple-calendar list` used to let a
    /// later `apple-calendar delete` run unasked). Normally the subcommand;
    /// for `minis-browser-use` the JSON `action`; for `apple-open`, whose
    /// subcommand slot holds the URL itself, the URL's scheme, so approving a
    /// web link does not approve `tel:` or another app's scheme. "" when the
    /// call names no action.
    static func action(command: String, arguments: [String]) -> String {
        switch command {
        case "minis-browser-use":
            return browserAction(in: arguments) ?? ""
        case "apple-open":
            guard let target = subcommand(in: arguments) else { return "" }
            let scheme = URL(string: target)?.scheme?.lowercased() ?? ""
            return scheme.isEmpty ? "url" : scheme
        default:
            return subcommand(in: arguments) ?? ""
        }
    }

    /// Irreversible writes are asked on every call and never remembered for
    /// the session: once a delete is approved, a prompt injection must not be
    /// able to delete everything else unasked. Covers calendar events and
    /// reminders (`delete`, `delete-reminder`) and photos (`delete`).
    static func asksEveryTime(kind: OffloadAccessKind, action: String) -> Bool {
        kind == .write && (action == "delete" || action.hasPrefix("delete-"))
    }

    /// `minis-browser-use` takes its action either as `--json '{"action":…}'`
    /// or as the subcommand.
    private static func browserAction(in arguments: [String]) -> String? {
        if let json = value(of: "--json", in: arguments) {
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            return object?["action"] as? String
        }
        return subcommand(in: arguments)
    }

    /// Mirrors `noff_get_subcommand`: the first argument not starting with `-`,
    /// where a `--option` swallows the following non-dash argument as its value.
    static func subcommand(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if !arg.hasPrefix("-") { return arg }
            if arg.hasPrefix("--"), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                index += 1
            }
            index += 1
        }
        return nil
    }

    /// Mirrors `noff_find_arg`: the value after the first exact `option`.
    static func value(of option: String, in arguments: [String]) -> String? {
        guard arguments.count >= 2 else { return nil }
        for index in 0..<(arguments.count - 1) where arguments[index] == option {
            return arguments[index + 1]
        }
        return nil
    }

    /// Mirrors `source_is_mic` in SpeechOffload.m (no `--source` means the mic).
    private static func isMicrophoneSource(_ source: String?) -> Bool {
        guard let source else { return true }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || ["mic", "system-mic", "system_mic", "microphone"].contains(normalized)
    }

    private static func kind(
        of sub: String?,
        read: Set<String> = [],
        write: Set<String> = [],
        info: Set<String> = [],
        none: OffloadAccessKind = .info,
        unknown: OffloadAccessKind = .write
    ) -> OffloadAccessKind {
        guard let sub else { return none }
        if write.contains(sub) { return .write }
        if read.contains(sub) { return .read }
        if info.contains(sub) { return .info }
        return unknown
    }
}

// MARK: - Automation policy

/// Settings → 自动化 (Automation). Background automations — scheduled Ogent
/// tasks and Shortcuts / App Intents — run with nobody to answer an
/// "Ask Once" prompt, so under Ask Once their side-effect calls are denied.
/// A command runs unattended only at `.bypass`; this maps the page's
/// per-command switch onto that single stored level, so the Permissions page
/// and the Automation page always agree.
enum OffloadAutomationPolicy {
    enum Group: CaseIterable {
        /// Reads (and may change) personal data: calendar, photos, location, …
        case privacy
        /// Acts outside the app: notifications, alarms, opening URLs, playback,
        /// paid model calls.
        case externalActions
    }

    /// The commands the Automation page lists: every command configurable in
    /// Settings.
    static var commands: [OffloadCommandInfo] {
        OffloadPermissionManager.allCommands.filter(\.showInSettings)
    }

    static func group(of command: OffloadCommandInfo) -> Group {
        command.category == .privacy ? .privacy : .externalActions
    }

    static func commands(in group: Group) -> [OffloadCommandInfo] {
        commands.filter { self.group(of: $0) == group }
    }

    /// The switch ("在后台自动化中始终允许") is on exactly at `.bypass`.
    static func runsUnattended(_ level: OffloadPermissionLevel) -> Bool {
        level == .bypass
    }

    /// The level to store when the switch changes. On → `.bypass`. Off →
    /// `.askOnce`, but only from `.bypass`: a command the user set to
    /// "Not Allowed" on the Permissions page stays that way.
    static func level(afterSettingUnattended enabled: Bool,
                      from current: OffloadPermissionLevel) -> OffloadPermissionLevel {
        if enabled { return .bypass }
        return current == .bypass ? .askOnce : current
    }
}

// MARK: - Manager

/// Fallback session id used when an offload permission check has no chat session
/// context (e.g. invocations outside the chat flow, or before a session id has
/// been assigned). Mirrors the Android constant `OFFLOAD_GLOBAL_SESSION_ID`
/// (commit 20d8e68) so per-session grants stay wire-compatible across platforms.
let OFFLOAD_GLOBAL_SESSION_ID = "offload-global"

/// Permission levels, "Ask Once" prompts and session grants for native
/// offloads. Enforcement happens per invocation in the handler-level gate
/// (`NativeOffloadGate.m` → `OffloadGateBridge` → `authorizeOffload`), so it
/// covers chat mode, engineering mode, automations, skills, MCP and the
/// terminal alike.
@MainActor
final class OffloadPermissionManager: ObservableObject {
    static let shared = OffloadPermissionManager()

    /// Every registered native offload (`OasesChatOffloadBootstrap.m`). The gate
    /// treats a name missing here as an unconfigurable `.askOnce` command, so
    /// keep it complete.
    nonisolated static let allCommands: [OffloadCommandInfo] = [
        // Privacy — user-configurable
        .init(name: "apple-calendar", displayLabel: String(localized: "Calendar", comment: "Native capability name (apple-calendar) in permission settings and prompts"), description: String(localized: "Events, schedules, and calendar details", comment: "Native capability description (apple-calendar) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-reminders", displayLabel: String(localized: "Reminders", comment: "Native capability name (apple-reminders) in permission settings and prompts"), description: String(localized: "Tasks, due dates, and reminder lists", comment: "Native capability description (apple-reminders) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-photos", displayLabel: String(localized: "Photos", comment: "Native capability name (apple-photos) in permission settings and prompts"), description: String(localized: "Photos, videos, and album metadata", comment: "Native capability description (apple-photos) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-location", displayLabel: String(localized: "Location", comment: "Native capability name (apple-location) in permission settings and prompts"), description: String(localized: "Current GPS coordinates and location history", comment: "Native capability description (apple-location) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-contacts", displayLabel: String(localized: "Contacts", comment: "Native capability name (apple-contacts) in permission settings and prompts"), description: String(localized: "Names, phone numbers, and email addresses in your contacts", comment: "Native capability description (apple-contacts) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-clipboard", displayLabel: String(localized: "Clipboard", comment: "Native capability name (apple-clipboard) in permission settings and prompts"), description: String(localized: "Text and images copied to the clipboard", comment: "Native capability description (apple-clipboard) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-weather", displayLabel: String(localized: "Weather", comment: "Native capability name (apple-weather) in permission settings and prompts"), description: String(localized: "Weather for your current location (explicit coordinates never ask)", comment: "Native capability description (apple-weather) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-bluetooth", displayLabel: String(localized: "Bluetooth", comment: "Native capability name (apple-bluetooth) in permission settings and prompts"), description: String(localized: "Scan, connect to, and exchange data with nearby Bluetooth devices", comment: "Native capability description (apple-bluetooth) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-nfc", displayLabel: "NFC", description: String(localized: "Read and write NFC tags and cards", comment: "Native capability description (apple-nfc) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-speech", displayLabel: String(localized: "Speech", comment: "Native capability name (apple-speech) in permission settings and prompts"), description: String(localized: "Record from the microphone and transcribe it", comment: "Native capability description (apple-speech) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "minis-sessions-cli", displayLabel: String(localized: "Chat Sessions", comment: "Native capability name (minis-sessions-cli) in permission settings and prompts"), description: String(localized: "Read your other chat sessions and send prompts in them", comment: "Native capability description (minis-sessions-cli) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "minis-browser-use", displayLabel: String(localized: "Browser Cookies", comment: "Native capability name (minis-browser-use) in permission settings and prompts"), description: String(localized: "Read or set cookies in the in-app browser", comment: "Native capability description (minis-browser-use) in permission settings and prompts"), category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // Side effects outside the app — user-configurable
        .init(name: "apple-media", displayLabel: String(localized: "Media", comment: "Native capability name (apple-media) in permission settings and prompts"), description: String(localized: "Now playing, music library search, and playback control", comment: "Native capability description (apple-media) in permission settings and prompts"), category: .media, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-notification", displayLabel: String(localized: "Notification", comment: "Native capability name (apple-notification) in permission settings and prompts"), description: String(localized: "Schedule and cancel local notifications", comment: "Native capability description (apple-notification) in permission settings and prompts"), category: .system, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-alarm", displayLabel: String(localized: "Alarm", comment: "Native capability name (apple-alarm) in permission settings and prompts"), description: String(localized: "Create and cancel alarms and timers", comment: "Native capability description (apple-alarm) in permission settings and prompts"), category: .system, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "apple-open", displayLabel: String(localized: "Open URL", comment: "Native capability name (apple-open) in permission settings and prompts"), description: String(localized: "Open links and other apps through URL schemes", comment: "Native capability description (apple-open) in permission settings and prompts"), category: .system, showInSettings: true, defaultLevel: .askOnce),
        .init(name: "minis-model-use", displayLabel: String(localized: "Model Use", comment: "Native capability name (minis-model-use) in permission settings and prompts"), description: String(localized: "Call other AI models with your configured providers (may cost money)", comment: "Native capability description (minis-model-use) in permission settings and prompts"), category: .system, showInSettings: true, defaultLevel: .askOnce),
        // Media — no personal data, no effect outside the app
        .init(name: "apple-speak", displayLabel: String(localized: "Speak", comment: "Native capability name (apple-speak) in permission settings and prompts"), description: "", category: .media, showInSettings: false, defaultLevel: .bypass),
        .init(name: "apple-player", displayLabel: String(localized: "Player", comment: "Native capability name (apple-player) in permission settings and prompts"), description: "", category: .media, showInSettings: false, defaultLevel: .bypass),
        .init(name: "ffmpeg", displayLabel: "FFmpeg", description: "", category: .media, showInSettings: false, defaultLevel: .bypass),
        // System — no personal data, no effect outside the app
        .init(name: "apple-device", displayLabel: String(localized: "Device", comment: "Native capability name (apple-device) in permission settings and prompts"), description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        .init(name: "apple-maps", displayLabel: String(localized: "Maps", comment: "Native capability name (apple-maps) in permission settings and prompts"), description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        .init(name: "apple-nlp", displayLabel: "NLP", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        .init(name: "apple-vision", displayLabel: String(localized: "Vision", comment: "Native capability name (apple-vision) in permission settings and prompts"), description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        .init(name: "oases-debug", displayLabel: "Debug CLI", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        // Own consent flow: Settings → Configuration Tool + per-change confirmation.
        .init(name: "oases-config", displayLabel: "Oases Config", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
    ]

    /// Commands that enforce their own consent (oases-config: master switch in
    /// Settings plus a confirmation sheet per change). The gate only keeps
    /// their writes from waiting on a sheet nobody can see.
    nonisolated static let delegatedCommands: Set<String> = ["oases-config"]

    /// How long an "Ask Once" prompt waits for an answer.
    nonisolated static let promptTimeoutSeconds: UInt64 = 30

    @Published var pendingRequest: PermissionRequest?

    /// Whether a prompt can reach the user right now. Overridable in tests.
    var isInteractiveUIAvailable: @MainActor () -> Bool = {
        UIApplication.shared.applicationState == .active
    }

    /// Per-session "Ask Once" grants: [sessionId: Set<grantKey>], one key per
    /// command and action (`grantKey(command:action:)`).
    private var sessionGrants: [String: Set<String>] = [:]

    /// The request whose sheet is up. Tracked apart from `pendingRequest` so a
    /// sheet dismissed without an answer still resolves on timeout.
    private var shownRequest: PermissionRequest?
    /// Requests waiting for the sheet, oldest first.
    private var queuedRequests: [PermissionRequest] = []
    /// Further callers waiting on an open request for the same grant and session.
    private var coalescedWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// "<session>|<grant key>" (plus the full command for every-time actions)
    /// → id of the open (shown or queued) request.
    private var openRequestIds: [String: String] = [:]

    private let logger = AppLogger(category: "OffloadPermission")

    private init() {}

    // MARK: - Storage

    nonisolated private static func defaultsKey(for command: String) -> String {
        "offloadPermission.\(command)"
    }

    /// The user's stored level, else the command's default. Thread-safe: the
    /// gate reads it from guest threads.
    nonisolated static func storedLevel(for command: String) -> OffloadPermissionLevel {
        if let raw = UserDefaults.standard.object(forKey: defaultsKey(for: command)) as? Int,
           let level = OffloadPermissionLevel(rawValue: raw) {
            return level
        }
        return allCommands.first(where: { $0.name == command })?.defaultLevel ?? .askOnce
    }

    func permissionLevel(for command: String) -> OffloadPermissionLevel {
        Self.storedLevel(for: command)
    }

    /// The single write path for a command's level. Publishes so the
    /// Permissions and Automation pages, which both observe the manager,
    /// always show the stored value.
    func setPermissionLevel(_ level: OffloadPermissionLevel, for command: String) {
        objectWillChange.send()
        UserDefaults.standard.set(level.rawValue, forKey: Self.defaultsKey(for: command))
    }

    /// Settings → 自动化: whether `command` may run unattended (background
    /// automations, Shortcuts). See `OffloadAutomationPolicy`.
    func runsUnattended(_ command: String) -> Bool {
        OffloadAutomationPolicy.runsUnattended(permissionLevel(for: command))
    }

    func setRunsUnattended(_ enabled: Bool, for command: String) {
        let current = permissionLevel(for: command)
        let next = OffloadAutomationPolicy.level(afterSettingUnattended: enabled, from: current)
        guard next != current else { return }
        setPermissionLevel(next, for: command)
    }

    func setAllBypass() {
        for cmd in Self.allCommands {
            setPermissionLevel(.bypass, for: cmd.name)
        }
        sessionGrants.removeAll()
    }

    // MARK: - Command Extraction

    /// Every known offload that `shellCommand` would run. Best-effort shell
    /// parsing (see `OffloadShellScanner`); only used to fail fast, the
    /// handler-level gate is the enforcement point.
    nonisolated static func extractOffloadCommands(from shellCommand: String) -> [String] {
        OffloadShellScanner.commands(in: shellCommand, known: Set(allCommands.map(\.name)))
    }

    nonisolated static func extractOffloadCommand(from shellCommand: String) -> String? {
        extractOffloadCommands(from: shellCommand).first
    }

    /// Chat-mode `shell_execute` pre-check: the hard denial for any offload the
    /// command would run, so a switched-off command fails before the shell
    /// starts. Never prompts — the handler-level gate asks, once.
    func preflightDenial(forShellCommand shellCommand: String) -> String? {
        for command in Self.extractOffloadCommands(from: shellCommand) {
            if let message = Self.hardDenialMessage(for: command, level: permissionLevel(for: command)) {
                return message
            }
        }
        return nil
    }

    // MARK: - Decision

    nonisolated static func hardDenialMessage(for command: String, level: OffloadPermissionLevel) -> String? {
        if level == .notAllowed {
            return "Permission denied: the user has disabled '\(command)'. To enable it, go to Settings > Permissions or tap: [Open Permissions](minis://settings/permissions)"
        }
        return nil
    }

    /// Pure gate policy:
    /// - help, and info-only subcommands of enabled commands, always run;
    /// - "Not Allowed" never runs;
    /// - "Bypass" runs everything, also in the background;
    /// - "Ask Once" prompts once per session and action (`granted` is the
    ///   grant for this command + action; irreversible actions never have
    ///   one); with the grant, reads run anywhere but writes only while the
    ///   app is in the foreground. Without a way to prompt the call is denied
    ///   instead of waiting for a sheet nobody sees.
    nonisolated static func decide(
        command: String,
        kind: OffloadAccessKind,
        level: OffloadPermissionLevel,
        granted: Bool,
        interactiveUIAvailable: Bool
    ) -> OffloadGateDecision {
        if kind == .help { return .allow }
        if let message = hardDenialMessage(for: command, level: level) { return .deny(message) }
        if kind == .info { return .allow }
        if delegatedCommands.contains(command) {
            return kind == .write && !interactiveUIAvailable ? .deny(foregroundRequiredMessage(command)) : .allow
        }
        switch level {
        case .bypass:
            return .allow
        case .notAllowed:
            return .deny("Permission denied: the user has disabled '\(command)'.")
        case .askOnce:
            if granted {
                return kind == .read || interactiveUIAvailable ? .allow : .deny(foregroundRequiredMessage(command))
            }
            if interactiveUIAvailable { return .prompt }
            return .deny("Permission denied: '\(command)' needs your approval, but Oases Chat can't ask right now (the app is not in the foreground). Open the app and retry, or let it run unattended in Settings > Automation: [Open Automation](minis://settings/automation)")
        }
    }

    nonisolated private static func foregroundRequiredMessage(_ command: String) -> String {
        if delegatedCommands.contains(command) {
            return "Permission denied: '\(command)' changes need your confirmation, which Oases Chat can only show while the app is open in the foreground. Open the app and retry."
        }
        return "Permission denied: '\(command)' changes data outside Oases Chat, so it only runs while the app is open in the foreground. Open the app and retry, or let it run unattended in Settings > Automation: [Open Automation](minis://settings/automation)"
    }

    /// Session grants are keyed by command AND action.
    nonisolated static func grantKey(command: String, action: String) -> String {
        "\(command) \(action)"
    }

    nonisolated static func grantBucket(for sessionId: String?) -> String {
        // Mirror Android: prefer the caller-supplied session id; fall back to the
        // global bucket when no session is bound (terminal, debug RPC, …).
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? OFFLOAD_GLOBAL_SESSION_ID : trimmed
    }

    // MARK: - Permission Check

    /// Gate entry for one offload invocation (`OffloadGateBridge`). Prompts at
    /// most once per session, command and action — every call for
    /// irreversible actions; concurrent calls for the same grant share the
    /// prompt.
    func authorizeOffload(command: String, arguments: [String], sessionId: String?) async -> PermissionResult {
        let kind = OffloadCommandPolicy.classify(command: command, arguments: arguments)
        let action = OffloadCommandPolicy.action(command: command, arguments: arguments)
        let asksEveryTime = OffloadCommandPolicy.asksEveryTime(kind: kind, action: action)
        let grantKey = Self.grantKey(command: command, action: action)
        let bucket = Self.grantBucket(for: sessionId)
        let decision = Self.decide(
            command: command,
            kind: kind,
            level: permissionLevel(for: command),
            granted: !asksEveryTime && sessionGrants[bucket]?.contains(grantKey) == true,
            interactiveUIAvailable: isInteractiveUIAvailable()
        )
        switch decision {
        case .allow:
            return .allowed
        case .deny(let message):
            logger.info("Permission denied: \(command)")
            return .denied(message)
        case .prompt:
            let info = Self.allCommands.first(where: { $0.name == command })
            let fullCommand = ([command] + arguments).joined(separator: " ")
            let allowed = await requestApproval(
                command: command,
                displayLabel: info?.displayLabel ?? command,
                description: info?.description ?? "",
                fullCommand: fullCommand,
                action: action,
                asksEveryTime: asksEveryTime,
                // An every-time prompt answers only for identical calls.
                coalesceKey: asksEveryTime ? "\(bucket)|\(grantKey)|\(fullCommand)" : "\(bucket)|\(grantKey)"
            )
            let label = action.isEmpty ? command : "\(command) \(action)"
            if allowed {
                if !asksEveryTime {
                    sessionGrants[bucket, default: []].insert(grantKey)
                }
                logger.info("Permission granted (\(asksEveryTime ? "this call" : "Ask Once")): \(label)")
                return .allowed
            }
            logger.info("Permission denied (Ask Once): \(label)")
            return .denied("Permission denied: the user declined '\(label)' or did not answer within \(Self.promptTimeoutSeconds)s. Each action is approved separately. To change permissions: [Open Permissions](minis://settings/permissions)")
        }
    }

    private func requestApproval(
        command: String,
        displayLabel: String,
        description: String,
        fullCommand: String,
        action: String,
        asksEveryTime: Bool,
        coalesceKey key: String
    ) async -> Bool {
        if let openId = openRequestIds[key] {
            return await withCheckedContinuation { continuation in
                coalescedWaiters[openId, default: []].append(continuation)
            }
        }
        return await withCheckedContinuation { continuation in
            let request = PermissionRequest(
                id: UUID().uuidString,
                commandName: command,
                displayLabel: displayLabel,
                description: description,
                fullCommand: fullCommand,
                action: action,
                asksEveryTime: asksEveryTime,
                continuation: continuation
            )
            openRequestIds[key] = request.id
            if shownRequest == nil {
                show(request)
            } else {
                queuedRequests.append(request)
            }
        }
    }

    /// One sheet at a time; the timeout starts when the sheet is shown.
    private func show(_ request: PermissionRequest) {
        shownRequest = request
        pendingRequest = request
        Haptics.warning()
        SoundEffects.shared.play(.attention)
        let id = request.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
            self?.resolve(requestId: id, allowed: false)
        }
    }

    private func resolve(requestId: String, allowed: Bool) {
        guard let request = shownRequest, request.id == requestId else { return }
        shownRequest = nil
        if pendingRequest?.id == requestId { pendingRequest = nil }
        if let key = openRequestIds.first(where: { $0.value == requestId })?.key {
            openRequestIds.removeValue(forKey: key)
        }
        request.continuation.resume(returning: allowed)
        for waiter in coalescedWaiters.removeValue(forKey: requestId) ?? [] {
            waiter.resume(returning: allowed)
        }
        if !queuedRequests.isEmpty {
            show(queuedRequests.removeFirst())
        }
    }

    // MARK: - UI Response

    func respond(to requestId: String, allowed: Bool) {
        resolve(requestId: requestId, allowed: allowed)
    }

    // MARK: - Session Reset

    func resetSessionGrants(for sessionId: String) {
        sessionGrants.removeValue(forKey: sessionId)
    }

    #if DEBUG
    /// Test hook: drop grants, prompts and the UI override.
    func resetForTests() {
        sessionGrants.removeAll()
        isInteractiveUIAvailable = { UIApplication.shared.applicationState == .active }
    }
    #endif
}

// MARK: - Shell scanning

/// Best-effort shell scanner behind `OffloadPermissionManager.extractOffloadCommands`.
/// Finds commands in command position through `;` `&&` `||` `|` `&`, newlines,
/// subshells, `$(…)` and backticks (also inside double quotes), env-var
/// prefixes, redirections, wrappers such as `env`/`exec`/`nohup`/`timeout`/
/// `xargs`, full paths, and `sh -c '…'` / `eval` bodies.
enum OffloadShellScanner {
    private enum Token: Equatable {
        case word(String)
        case separator
    }

    private static let wrappers: Set<String> = [
        "env", "exec", "command", "builtin", "nohup", "time", "nice", "sudo",
        "timeout", "xargs", "stdbuf", "busybox",
    ]
    /// Wrapper options that take a separate value.
    private static let wrapperValueOptions: [String: Set<String>] = [
        "env": ["-u", "-C", "--unset", "--chdir"],
        "nice": ["-n", "--adjustment"],
        "sudo": ["-u", "-g", "-C", "-h", "-p"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "xargs": ["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a"],
        "stdbuf": ["-i", "-o", "-e"],
    ]
    private static let reservedWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}",
    ]
    private static let shells: Set<String> = ["sh", "bash", "ash", "dash", "zsh"]

    static func commands(in script: String, known: Set<String>, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        var nested: [String] = []
        let tokens = tokenize(script, nested: &nested)
        var found: [String] = []
        var words: [String] = []
        for token in tokens {
            switch token {
            case .word(let word):
                words.append(word)
            case .separator:
                found += commandNames(in: words, known: known, depth: depth)
                words.removeAll()
            }
        }
        found += commandNames(in: words, known: known, depth: depth)
        for body in nested {
            found += commands(in: body, known: known, depth: depth + 1)
        }
        return found
    }

    /// The offload run by one simple command, if any.
    private static func commandNames(in words: [String], known: Set<String>, depth: Int) -> [String] {
        var index = 0
        var wrapper: String?
        var expectsTimeoutDuration = false
        while index < words.count {
            let word = words[index]
            if reservedWords.contains(word) || isAssignment(word) {
                index += 1
                continue
            }
            if let redirect = redirectionWidth(word) {
                index += redirect
                continue
            }
            if let current = wrapper, word.hasPrefix("-") {
                index += wrapperValueOptions[current]?.contains(word) == true ? 2 : 1
                continue
            }
            if expectsTimeoutDuration {
                expectsTimeoutDuration = false
                index += 1
                continue
            }
            let name = (word as NSString).lastPathComponent
            if wrappers.contains(name) {
                wrapper = name
                expectsTimeoutDuration = name == "timeout"
                index += 1
                continue
            }
            if known.contains(name) { return [name] }
            if shells.contains(name) {
                // sh -c 'script' (flags may be combined: -lc, -ec)
                var flagIndex = index + 1
                while flagIndex < words.count, words[flagIndex].hasPrefix("-") {
                    let flag = words[flagIndex]
                    if !flag.hasPrefix("--"), flag.dropFirst().contains("c"), flagIndex + 1 < words.count {
                        return commands(in: words[flagIndex + 1], known: known, depth: depth + 1)
                    }
                    flagIndex += 1
                }
                return []
            }
            if name == "eval" {
                return commands(in: words[(index + 1)...].joined(separator: " "), known: known, depth: depth + 1)
            }
            return []
        }
        return []
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Words to skip for a redirection (`>f`, `2>`, `< f`), or nil.
    private static func redirectionWidth(_ word: String) -> Int? {
        let operatorPart = word.prefix { "0123456789<>".contains($0) }
        guard operatorPart.contains(where: { $0 == "<" || $0 == ">" }) else { return nil }
        return operatorPart.count == word.count ? 2 : 1
    }

    private static func tokenize(_ script: String, nested: inout [String]) -> [Token] {
        let chars = Array(script)
        var tokens: [Token] = []
        var current = ""
        var inWord = false
        func flush() {
            if inWord { tokens.append(.word(current)) }
            current = ""
            inWord = false
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                flush()
            case "\n", ";", "|", "&", "(", ")", "`":
                flush()
                tokens.append(.separator)
            case "#" where !inWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            case "\\":
                if i + 1 < chars.count {
                    current.append(chars[i + 1])
                    inWord = true
                    i += 1
                }
            case "'":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" {
                    current.append(chars[i])
                    i += 1
                }
            case "\"":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        current.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                        let end = closingParen(in: chars, from: i + 2)
                        nested.append(String(chars[(i + 2)..<min(end, chars.count)]))
                        current += String(chars[i..<min(end + 1, chars.count)])
                        i = end + 1
                        continue
                    }
                    if chars[i] == "`" {
                        var end = i + 1
                        while end < chars.count, chars[end] != "`" { end += 1 }
                        nested.append(String(chars[(i + 1)..<min(end, chars.count)]))
                        i = end + 1
                        continue
                    }
                    current.append(chars[i])
                    i += 1
                }
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                // $(…): the body starts a new command.
                flush()
                tokens.append(.separator)
                i += 1
            default:
                current.append(c)
                inWord = true
            }
            i += 1
        }
        flush()
        return tokens
    }

    /// Index of the `)` closing a `(` just before `start`, or `chars.count`.
    private static func closingParen(in chars: [Character], from start: Int) -> Int {
        var depth = 1
        var i = start
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return chars.count
    }
}
