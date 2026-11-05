import Combine
import XCTest
@testable import Oases_Chat

/// Settings → 自动化: a per-command switch that lets a native command run
/// unattended (background automations, Shortcuts). It is a view of the same
/// stored level as the Permissions page — on is `.bypass`, off returns to
/// `.askOnce` — so the two pages can never disagree.
final class AutomationPermissionTests: XCTestCase {
    private static let touchedKeys = ["apple-calendar", "apple-open"].map { "offloadPermission.\($0)" }
    private var savedLevels: [String: Int] = [:]

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

    // MARK: - Level mapping

    func testSwitchIsOnExactlyAtBypass() {
        XCTAssertTrue(OffloadAutomationPolicy.runsUnattended(.bypass))
        XCTAssertFalse(OffloadAutomationPolicy.runsUnattended(.askOnce))
        XCTAssertFalse(OffloadAutomationPolicy.runsUnattended(.notAllowed))
    }

    func testOnBypassesAndOffReturnsToAskOnceButKeepsNotAllowed() {
        let level = OffloadAutomationPolicy.level(afterSettingUnattended:from:)
        XCTAssertEqual(level(true, .askOnce), .bypass)
        XCTAssertEqual(level(true, .notAllowed), .bypass, "turning it on is an explicit choice")
        XCTAssertEqual(level(true, .bypass), .bypass)
        XCTAssertEqual(level(false, .bypass), .askOnce)
        XCTAssertEqual(level(false, .askOnce), .askOnce)
        XCTAssertEqual(level(false, .notAllowed), .notAllowed, "a switched-off command must not be re-enabled")
    }

    // MARK: - What the page lists

    func testListsEveryConfigurableCommand() {
        let names = Set(OffloadAutomationPolicy.commands.map(\.name))
        let configurable = Set(OffloadPermissionManager.allCommands.filter(\.showInSettings).map(\.name))
        XCTAssertEqual(names, configurable)
        XCTAssertFalse(names.contains("apple-device"), "info-only commands never ask, nothing to allow")
        XCTAssertFalse(names.contains("oases-config"), "has its own consent flow")
    }

    func testEveryListedCommandIsInExactlyOneGroup() {
        let privacy = OffloadAutomationPolicy.commands(in: .privacy).map(\.name)
        let external = OffloadAutomationPolicy.commands(in: .externalActions).map(\.name)
        XCTAssertTrue(Set(privacy).isDisjoint(with: external))
        XCTAssertEqual(Set(privacy).union(external), Set(OffloadAutomationPolicy.commands.map(\.name)))
        for name in ["apple-calendar", "apple-photos", "apple-location", "apple-clipboard", "minis-sessions-cli"] {
            XCTAssertTrue(privacy.contains(name), name)
        }
        for name in ["apple-open", "apple-notification", "apple-alarm", "apple-media", "minis-model-use"] {
            XCTAssertTrue(external.contains(name), name)
        }
    }

    // MARK: - Shared source of truth

    @MainActor
    func testSwitchWritesTheLevelTheGateReads() {
        let manager = OffloadPermissionManager.shared
        func backgroundWrite() -> OffloadGateDecision {
            OffloadPermissionManager.decide(
                command: "apple-calendar", kind: .write,
                level: OffloadPermissionManager.storedLevel(for: "apple-calendar"),
                granted: false, interactiveUIAvailable: false
            )
        }
        XCTAssertFalse(manager.runsUnattended("apple-calendar"))
        if case .allow = backgroundWrite() { XCTFail("Ask Once must not run unattended") }

        manager.setRunsUnattended(true, for: "apple-calendar")
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "apple-calendar"), .bypass)
        XCTAssertEqual(backgroundWrite(), .allow)

        manager.setRunsUnattended(false, for: "apple-calendar")
        XCTAssertEqual(OffloadPermissionManager.storedLevel(for: "apple-calendar"), .askOnce)
        if case .allow = backgroundWrite() { XCTFail("back to Ask Once") }

        // Chosen on the Permissions page, reflected here.
        manager.setPermissionLevel(.bypass, for: "apple-calendar")
        XCTAssertTrue(manager.runsUnattended("apple-calendar"))
        manager.setPermissionLevel(.notAllowed, for: "apple-calendar")
        XCTAssertFalse(manager.runsUnattended("apple-calendar"))
        manager.setRunsUnattended(false, for: "apple-calendar")
        XCTAssertEqual(manager.permissionLevel(for: "apple-calendar"), .notAllowed)
    }

    @MainActor
    func testLevelChangesPublishSoBothPagesRefresh() {
        let manager = OffloadPermissionManager.shared
        var changes = 0
        let subscription = manager.objectWillChange.sink { _ in changes += 1 }
        defer { subscription.cancel() }

        manager.setRunsUnattended(true, for: "apple-open")
        manager.setPermissionLevel(.askOnce, for: "apple-open")
        XCTAssertEqual(changes, 2)
        manager.setRunsUnattended(false, for: "apple-open")   // already Ask Once: no write
        XCTAssertEqual(changes, 2)
    }

    /// Background denials point the agent at `minis://settings/automation`.
    func testAutomationDeepLinkOpensThePage() {
        XCTAssertEqual(DeepLinkRouter.settingsTarget(["automation"]), .automation)
        XCTAssertEqual(SettingsRoute(deepLink: .automation), .automation)
    }
}
