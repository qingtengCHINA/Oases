import XCTest
import UIKit
@testable import Oases_Chat

final class MemoryAndOffloadTests: XCTestCase {
    func testMemoryWriteThenGetRoundTrip() async throws {
        let write = MemoryWriteTool()
        let get = MemoryGetTool()
        let marker = "mem-marker-\(UUID().uuidString.prefix(8))"
        let writeResult = try await write.invoke(
            argumentsJSON: "{\"content\":\"\(marker) prefers Python\",\"title\":\"pref\"}",
            onProgress: { _ in }
        )
        XCTAssertTrue(writeResult.text?.contains("memory_write") == true, writeResult.text ?? "")

        let getResult = try await get.invoke(
            argumentsJSON: "{\"keywords\":\"\(marker)\"}",
            onProgress: { _ in }
        )
        XCTAssertTrue(getResult.text?.contains(marker) == true, getResult.text ?? "")
    }

    /// The clipboard tool follows Settings → Permissions → Clipboard, the same stored level as
    /// the guest `apple-clipboard` offload (no separate grant store).
    @MainActor
    func testClipboardToolFollowsThePermissionsPage() async throws {
        let manager = OffloadPermissionManager.shared
        let key = "offloadPermission.apple-clipboard"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            manager.resetForTests()
        }
        let tool = ClipboardOffloadTool()

        manager.setPermissionLevel(.notAllowed, for: "apple-clipboard")
        let denied = try await tool.invoke(argumentsJSON: "{\"action\":\"get\"}", onProgress: { _ in })
        XCTAssertTrue(denied.text?.contains("Permission denied") == true, denied.text ?? "")

        manager.setPermissionLevel(.bypass, for: "apple-clipboard")
        let expected = "clip-\(UUID().uuidString.prefix(6))"
        UIPasteboard.general.string = expected
        let allowed = try await tool.invoke(argumentsJSON: "{\"action\":\"get\"}", onProgress: { _ in })
        XCTAssertTrue(allowed.text?.contains("clipboard_get_ok") == true, allowed.text ?? "")
        XCTAssertTrue(allowed.text?.contains(expected) == true, allowed.text ?? "")
    }

    /// Every Swift tool that reads or changes personal data is refused when the user set its
    /// capability to Not Allowed (they used to skip the gate entirely).
    @MainActor
    func testNativePersonalDataToolsObeyNotAllowed() async throws {
        let manager = OffloadPermissionManager.shared
        let cases: [(any AgentTool, String, String)] = [
            (CalendarReadTool(), "apple-calendar", "{}"),
            (ReminderCreateTool(), "apple-reminders", "{\"title\":\"x\"}"),
            (ContactSearchTool(), "apple-contacts", "{\"query\":\"a\"}"),
            (PhotoListTool(), "apple-photos", "{}"),
            (LocationTool(), "apple-location", "{}"),
            (ClipboardOffloadTool(), "apple-clipboard", "{\"action\":\"set\",\"text\":\"x\"}"),
        ]
        var saved: [String: Any?] = [:]
        for (_, command, _) in cases {
            saved[command] = UserDefaults.standard.object(forKey: "offloadPermission.\(command)")
            manager.setPermissionLevel(.notAllowed, for: command)
        }
        defer {
            for (command, value) in saved {
                let key = "offloadPermission.\(command)"
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            manager.resetForTests()
        }
        for (tool, command, args) in cases {
            XCTAssertTrue(tool.descriptor.requiresPermission, tool.descriptor.name)
            let result = try await tool.invoke(argumentsJSON: args, onProgress: { _ in })
            XCTAssertTrue(result.text?.contains("Permission denied") == true,
                          "\(tool.descriptor.name) ran although \(command) is Not Allowed: \(result.text ?? "")")
        }
    }

    func testPlannerExposesAppleClipboardForClipboardPrompt() {
        let plan = ProjectAgentPlanner.plan(
            for: "读取剪贴板里的文本",
            iteration: 1,
            executedToolCalls: 0
        )
        XCTAssertTrue(plan.toolNames.contains("apple_clipboard"), "\(plan.toolNames)")
    }

    func testBrowserUseLandsArtifactUnderSessionBrowserTree() async throws {
        let sid = "br-\(UUID().uuidString.prefix(6))"
        let stub = StubBrowserTool(text: "page body for \(sid)")
        let browser = BrowserUseAliasTool(underlying: stub)
        let result = try await OasesPathResolver.ActiveSession.$id.withValue(sid) {
            try await browser.invoke(
                argumentsJSON: "{\"action\":\"extract\"}",
                onProgress: { _ in }
            )
        }
        XCTAssertTrue(result.text?.contains("browser_path=") == true, result.text ?? "")
        guard let line = result.text?.split(separator: "\n").first(where: { $0.hasPrefix("browser_path=") }) else {
            return XCTFail("missing browser_path")
        }
        let guestPath = String(line.dropFirst("browser_path=".count))
        let host = OasesPathResolver.hostURL(forGuest: guestPath, sessionId: sid)
        XCTAssertNotNil(host)
        XCTAssertTrue(host!.path.contains(sid))
        XCTAssertTrue(host!.path.contains("browser"))
        let onDisk = try String(contentsOf: host!, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("page body for \(sid)"))
    }

    @MainActor
    func testBrowserApprovalCancelBlocksWithoutGrant() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-\(UUID().uuidString).json")
        let center = BrowserApprovalCenter(timeoutNanoseconds: 2_000_000_000, persistenceURL: url)
        let request = BrowserApprovalRequest(
            sessionID: "s1",
            challenge: .login,
            url: "https://example.com/login",
            title: "Login"
        )
        let waitTask = Task { @MainActor in
            try await center.waitForApproval(request)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        center.cancel()
        do {
            _ = try await waitTask.value
            XCTFail("expected cancel without grant")
        } catch let error as BrowserApprovalError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTAssertTrue(error is CancellationError || error is BrowserApprovalError, "\(error)")
        }
    }

    func testBrowserUseAliasRegistered() {
        let web = WebBrowseTool()
        ToolRegistry.shared.register(web)
        ToolRegistry.shared.register(BrowserUseAliasTool(underlying: web))
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "browser_use"))
        XCTAssertEqual(ToolRegistry.shared.tool(named: "browser_use")?.descriptor.name, "browser_use")
        XCTAssertNotNil(ToolRegistry.shared.tool(named: "web_browse"))
    }
}

/// Minimal browser stand-in so BrowserUseAliasTool path-landing can be tested
/// without booting WKWebView.
private final class StubBrowserTool: AgentTool, @unchecked Sendable {
    let text: String
    init(text: String) { self.text = text }

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "web_browse",
            summary: "stub",
            displayName: "stub",
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{}}",
            surfaces: [.project]
        )
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        .textOnly(text)
    }
}
