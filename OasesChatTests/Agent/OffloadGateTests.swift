import XCTest
@testable import Oases_Chat

/// Code review 2026-09-29 (二#3, 3.6 P0): the offload permission gate runs per
/// invocation at the handler, defaults privacy/side-effect commands to "Ask
/// Once", and never waits on a prompt nobody can see.
final class OffloadGateTests: XCTestCase {
    private static let touchedKeys = ["apple-calendar", "apple-device", "minis-sessions-cli", "oases-config"]
        .map { "offloadPermission.\($0)" }
    private var savedLevels: [String: Int] = [:]

    @MainActor private var manager: OffloadPermissionManager { .shared }

    override func setUp() {
        super.setUp()
        for key in Self.touchedKeys {
            if let level = UserDefaults.standard.object(forKey: key) as? Int { savedLevels[key] = level }
            UserDefaults.standard.removeObject(forKey: key)
        }
        MainActor.assumeIsolated { OffloadPermissionManager.shared.resetForTests() }
    }

    override func tearDown() {
        for key in Self.touchedKeys {
            if let level = savedLevels[key] {
                UserDefaults.standard.set(level, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        MainActor.assumeIsolated { OffloadPermissionManager.shared.resetForTests() }
        super.tearDown()
    }

    // MARK: - Detection beyond the first token

    func testExtractFindsOffloadsAnywhereInTheShellCommand() {
        let extract = OffloadPermissionManager.extractOffloadCommands(from:)
        XCTAssertEqual(extract("true; apple-calendar list"), ["apple-calendar"])
        XCTAssertEqual(extract("sh -c 'apple-photos list'"), ["apple-photos"])
        XCTAssertEqual(extract("bash -lc \"cd /tmp && apple-clipboard get\""), ["apple-clipboard"])
        XCTAssertEqual(extract("echo hi | apple-open https://example.com"), ["apple-open"])
        XCTAssertEqual(extract("FOO=1 BAR=2 apple-location current"), ["apple-location"])
        XCTAssertEqual(extract("env -i PATH=/bin /usr/local/bin/apple-reminders list"), ["apple-reminders"])
        XCTAssertEqual(extract("x=$(apple-clipboard get) && echo \"$x\""), ["apple-clipboard"])
        XCTAssertEqual(extract("echo \"$(minis-sessions-cli list)\""), ["minis-sessions-cli"])
        XCTAssertEqual(extract("nohup timeout 5 apple-nfc scan >/dev/null 2>&1 &"), ["apple-nfc"])
        XCTAssertEqual(extract("if true; then\n  apple-alarm list\nfi"), ["apple-alarm"])
        XCTAssertEqual(extract("ls | xargs -n 1 apple-vision ocr"), ["apple-vision"])
        XCTAssertEqual(extract("eval 'apple-media play'"), ["apple-media"])
        XCTAssertEqual(extract("apple-device info && oases-config set a 1"), ["apple-device", "oases-config"])
        XCTAssertEqual(OffloadPermissionManager.extractOffloadCommand(from: "cd /tmp; minis-model-use run"), "minis-model-use")
    }

    func testExtractIgnoresMentionsThatDoNotRun() {
        let extract = OffloadPermissionManager.extractOffloadCommands(from:)
        XCTAssertEqual(extract("echo 'apple-calendar list'"), [])
        XCTAssertEqual(extract("grep apple-photos notes.txt"), [])
        XCTAssertEqual(extract("apple-calendarx list"), [])
        XCTAssertEqual(extract("# apple-calendar list"), [])
        XCTAssertEqual(extract("ls -la"), [])
    }

    @MainActor
    func testPreflightFailsFastOnlyForSwitchedOffCommands() {
        manager.setPermissionLevel(.notAllowed, for: "apple-calendar")
        XCTAssertNotNil(manager.preflightDenial(forShellCommand: "true; apple-calendar list"))
        XCTAssertNil(manager.preflightDenial(forShellCommand: "apple-device info"))
        manager.setPermissionLevel(.askOnce, for: "apple-calendar")
        // "Ask Once" is left to the handler-level gate so chat mode prompts once, not twice.
        XCTAssertNil(manager.preflightDenial(forShellCommand: "apple-calendar list"))
        XCTAssertNil(manager.pendingRequest)
    }

    // MARK: - Registry and defaults

    func testEveryRegisteredOffloadIsKnownAndConfigurable() {
        // Names passed to noff_register_gated_handler in vendor/iSH/offloads.
        let registered: Set<String> = [
            "apple-alarm", "apple-bluetooth", "minis-browser-use", "apple-calendar", "apple-clipboard",
            "oases-config", "oases-debug", "apple-device", "ffmpeg",
            "apple-location", "apple-maps", "apple-media", "minis-model-use", "apple-nfc", "apple-nlp",
            "apple-notification", "apple-open", "apple-photos", "apple-player", "apple-reminders",
            "minis-sessions-cli", "apple-speak", "apple-speech", "apple-vision", "apple-weather",
        ]
        let known = Set(OffloadPermissionManager.allCommands.map(\.name))
        XCTAssertEqual(registered.subtracting(known), [])
        // HealthKit and HomeKit were removed for App Review (5.6, 2026-10-08).
        XCTAssertTrue(known.isDisjoint(with: ["apple-healthkit", "apple-homekit"]))
        for info in OffloadPermissionManager.allCommands where info.defaultLevel == .askOnce {
            XCTAssertTrue(info.showInSettings, "\(info.name) defaults to Ask Once but can't be changed in Settings")
        }
    }

    @MainActor
    func testDefaultLevels() {
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "apple-calendar"), .askOnce)
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "minis-sessions-cli"), .askOnce)
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "apple-device"), .bypass)
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "unregistered-tool"), .askOnce)
        manager.setPermissionLevel(.bypass, for: "apple-calendar")
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "apple-calendar"), .bypass)
    }

    // MARK: - Classification

    func testClassificationFollowsHandlerSubcommandParsing() {
        let classify = OffloadCommandPolicy.classify(command:arguments:)
        XCTAssertEqual(classify("apple-calendar", ["list"]), .read)
        XCTAssertEqual(classify("apple-calendar", ["create", "--title", "x"]), .write)
        XCTAssertEqual(classify("apple-calendar", ["--calendar", "Work", "delete", "--id", "1"]), .write)
        XCTAssertEqual(classify("apple-calendar", ["bogus"]), .write)
        XCTAssertEqual(classify("apple-calendar", ["create", "--help"]), .help)
        XCTAssertEqual(classify("apple-calendar", []), .info)
        XCTAssertEqual(classify("apple-clipboard", []), .read)
        XCTAssertEqual(classify("apple-clipboard", ["set", "--text", "x"]), .write)
        XCTAssertEqual(classify("apple-device", ["info"]), .info)
        XCTAssertEqual(classify("apple-weather", ["current", "--lat", "1", "--lng", "2"]), .info)
        XCTAssertEqual(classify("apple-weather", ["current"]), .read)
        XCTAssertEqual(classify("apple-speech", ["transcribe"]), .read)
        XCTAssertEqual(classify("apple-speech", ["transcribe", "--source", "/var/minis/attachments/a.m4a"]), .info)
        XCTAssertEqual(classify("apple-media", ["volume"]), .info)
        XCTAssertEqual(classify("apple-media", ["volume", "--set", "0.5"]), .write)
        XCTAssertEqual(classify("apple-open", ["https://example.com"]), .write)
        XCTAssertEqual(classify("minis-browser-use", ["--json", "{\"action\":\"get_cookies\"}"]), .read)
        XCTAssertEqual(classify("minis-browser-use", ["set_cookies", "--cookies-file", "/tmp/c.json"]), .write)
        XCTAssertEqual(classify("minis-browser-use", ["navigate", "--url", "https://example.com"]), .info)
        XCTAssertEqual(classify("minis-sessions-cli", ["send", "hi", "--attach", "/tmp/a.png"]), .write)
        XCTAssertEqual(classify("minis-sessions-cli", ["messages", "--id", "x"]), .read)
        XCTAssertEqual(classify("minis-model-use", ["run", "--model", "m"]), .write)
        XCTAssertEqual(classify("oases-config", ["set", "a.b", "1"]), .write)
        XCTAssertEqual(classify("oases-config", ["get", "a.b"]), .info)
        XCTAssertEqual(classify("unregistered-tool", ["list"]), .write)
    }

    // MARK: - Grant scope (code review 2026-11-04 S8)

    func testGrantsAreKeyedByAction() {
        let action = OffloadCommandPolicy.action(command:arguments:)
        XCTAssertEqual(action("apple-calendar", ["list", "--today"]), "list")
        XCTAssertEqual(action("apple-calendar", ["--calendar", "Work", "delete", "--id", "1"]), "delete")
        XCTAssertEqual(action("apple-calendar", []), "")
        XCTAssertEqual(action("apple-open", ["https://example.com/a?b=c"]), "https")
        XCTAssertEqual(action("apple-open", ["tel:123"]), "tel")
        XCTAssertEqual(action("minis-browser-use", ["--json", "{\"action\":\"get_cookies\"}"]), "get_cookies")
        XCTAssertTrue(OffloadCommandPolicy.asksEveryTime(kind: .write, action: "delete"))
        XCTAssertTrue(OffloadCommandPolicy.asksEveryTime(kind: .write, action: "delete-reminder"))
        XCTAssertFalse(OffloadCommandPolicy.asksEveryTime(kind: .write, action: "create"))
        XCTAssertFalse(OffloadCommandPolicy.asksEveryTime(kind: .read, action: "list"))
    }

    // MARK: - Decision table

    func testDecisionTable() {
        func decide(_ command: String, _ kind: OffloadAccessKind, _ level: OffloadPermissionLevel,
                    granted: Bool = false, ui: Bool) -> OffloadGateDecision {
            OffloadPermissionManager.decide(command: command, kind: kind, level: level,
                                            granted: granted, interactiveUIAvailable: ui)
        }
        func isDenied(_ decision: OffloadGateDecision) -> Bool {
            if case .deny = decision { return true }
            return false
        }

        XCTAssertEqual(decide("apple-calendar", .read, .askOnce, ui: true), .prompt)
        XCTAssertTrue(isDenied(decide("apple-calendar", .read, .askOnce, ui: false)))
        XCTAssertEqual(decide("apple-calendar", .read, .askOnce, granted: true, ui: false), .allow)
        XCTAssertTrue(isDenied(decide("apple-calendar", .write, .askOnce, granted: true, ui: false)))
        XCTAssertEqual(decide("apple-calendar", .write, .askOnce, granted: true, ui: true), .allow)
        XCTAssertEqual(decide("apple-calendar", .write, .bypass, ui: false), .allow)
        XCTAssertTrue(isDenied(decide("apple-calendar", .read, .notAllowed, ui: true)))
        XCTAssertTrue(isDenied(decide("apple-calendar", .info, .notAllowed, ui: true)))
        XCTAssertEqual(decide("apple-calendar", .help, .notAllowed, ui: false), .allow)
        XCTAssertEqual(decide("apple-calendar", .info, .askOnce, ui: false), .allow)
        XCTAssertTrue(isDenied(decide("oases-config", .write, .bypass, ui: false)))
        XCTAssertEqual(decide("oases-config", .write, .bypass, ui: true), .allow)
        XCTAssertEqual(decide("oases-config", .info, .bypass, ui: false), .allow)
    }

    // MARK: - Gate behaviour

    @MainActor
    private func nextPrompt() async throws -> PermissionRequest {
        for _ in 0..<200 {
            if let pending = manager.pendingRequest { return pending }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(manager.pendingRequest)
    }

    @MainActor
    func testGateDeniesWithoutUIAndPromptsOncePerSessionAndAction() async throws {
        let sessionId = "gate-test-\(UUID().uuidString)"

        manager.isInteractiveUIAvailable = { false }
        let background = await manager.authorizeOffload(command: "apple-calendar", arguments: ["list"], sessionId: sessionId)
        guard case .denied = background else { return XCTFail("expected a denial without UI") }
        XCTAssertNil(manager.pendingRequest, "must not wait on a prompt nobody can see")

        manager.isInteractiveUIAvailable = { true }
        async let read = manager.authorizeOffload(command: "apple-calendar", arguments: ["list"], sessionId: sessionId)
        async let sameRead = manager.authorizeOffload(command: "apple-calendar", arguments: ["list", "--today"], sessionId: sessionId)
        let shown = try await nextPrompt()
        XCTAssertEqual(shown.commandName, "apple-calendar")
        XCTAssertEqual(shown.action, "list")
        manager.respond(to: shown.id, allowed: true)
        let (readResult, sameReadResult) = await (read, sameRead)
        guard case .allowed = readResult, case .allowed = sameReadResult else {
            return XCTFail("calls for the same action share the single prompt")
        }
        XCTAssertNil(manager.pendingRequest)

        // Approving `list` does not approve `create`: it asks on its own.
        async let write = manager.authorizeOffload(command: "apple-calendar", arguments: ["create", "--title", "x"], sessionId: sessionId)
        let writePrompt = try await nextPrompt()
        XCTAssertEqual(writePrompt.action, "create")
        XCTAssertFalse(writePrompt.asksEveryTime)
        manager.respond(to: writePrompt.id, allowed: true)
        guard case .allowed = await write else { return XCTFail("approved write must run") }

        // A delete is asked on every call, even right after one was approved.
        for _ in 0..<2 {
            async let delete = manager.authorizeOffload(command: "apple-calendar", arguments: ["delete", "--id", "1"], sessionId: sessionId)
            let deletePrompt = try await nextPrompt()
            XCTAssertTrue(deletePrompt.asksEveryTime)
            manager.respond(to: deletePrompt.id, allowed: true)
            guard case .allowed = await delete else { return XCTFail("approved delete must run") }
        }

        // Granted for this session: reads keep working in the background,
        // writes need the app in the foreground.
        manager.isInteractiveUIAvailable = { false }
        let laterRead = await manager.authorizeOffload(command: "apple-calendar", arguments: ["list"], sessionId: sessionId)
        guard case .allowed = laterRead else { return XCTFail("granted read should run in background") }
        let laterWrite = await manager.authorizeOffload(command: "apple-calendar", arguments: ["create", "--title", "y"], sessionId: sessionId)
        guard case .denied = laterWrite else { return XCTFail("background write must be denied") }
        let otherRead = await manager.authorizeOffload(command: "apple-calendar", arguments: ["calendars"], sessionId: sessionId)
        guard case .denied = otherRead else { return XCTFail("an action never approved must not run unasked") }

        // Another session still has to ask.
        manager.isInteractiveUIAvailable = { true }
        async let other = manager.authorizeOffload(command: "apple-calendar", arguments: ["list"], sessionId: sessionId + "-other")
        let otherRequest = try await nextPrompt()
        manager.respond(to: otherRequest.id, allowed: false)
        guard case .denied = await other else { return XCTFail("declined prompt must deny") }
    }

    @MainActor
    func testHandlerLevelBypassNeedsNoPrompt() async {
        manager.isInteractiveUIAvailable = { false }
        let device = await manager.authorizeOffload(command: "apple-device", arguments: ["info"], sessionId: nil)
        guard case .allowed = device else { return XCTFail("apple-device is harmless by default") }
        let help = await manager.authorizeOffload(command: "apple-calendar", arguments: ["--help"], sessionId: nil)
        guard case .allowed = help else { return XCTFail("help never needs a grant") }
        XCTAssertNil(manager.pendingRequest)
    }
}
