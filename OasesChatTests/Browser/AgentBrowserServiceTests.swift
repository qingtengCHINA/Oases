import XCTest
@testable import Oases_Chat

@MainActor
final class AgentBrowserServiceTests: XCTestCase {
    private let service = AgentBrowserService()

    func testProfilesAreStableAndIsolatedByWorkspace() {
        let first = service.profile(for: "Workspace A")
        let again = service.profile(for: "Workspace A")
        let second = service.profile(for: "Workspace B")

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first.storageIdentifier, second.storageIdentifier)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testPolicyAllowsPublicHTTPAndHTTPS() throws {
        try service.validateNavigation(url: URL(string: "https://example.com/path")!)
        try service.validateNavigation(url: URL(string: "http://198.51.100.10")!)
    }

    func testPolicyBlocksUnsafeSchemesAndPrivateDestinations() {
        XCTAssertThrowsError(try service.validateNavigation(url: URL(string: "file:///etc/passwd")!))
        XCTAssertThrowsError(try service.validateNavigation(url: URL(string: "https://localhost/admin")!))
        XCTAssertThrowsError(try service.validateNavigation(url: URL(string: "http://192.168.1.1")!))
        XCTAssertThrowsError(try service.validateNavigation(url: URL(string: "http://[::1]/")!))
        XCTAssertThrowsError(try service.validateNavigation(url: URL(string: "https://printer.local/")!))
    }

    func testExplicitLocalCapabilityCanOpenPrivateDestination() throws {
        try service.validateNavigation(url: URL(string: "http://127.0.0.1:11434")!, allowLocalCapability: true)
    }

    func testSnapshotIsStructuredAndDetectsChallenge() throws {
        let snapshot = service.snapshot(
            url: "https://example.com/login",
            title: "Sign in",
            text: "Enter your password",
            links: [["text": "Help", "href": "https://example.com/help"]],
            forms: [["selector": "form", "label": "Login"]],
            strategy: .webKit,
            maxTextBytes: 12
        )

        XCTAssertEqual(snapshot.strategy, .webKit)
        XCTAssertEqual(snapshot.challenge, .login)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.links.count, 1)
        XCTAssertTrue(snapshot.stableMetadataLine.contains("challenge=login"))
    }

    func testChallengeClassifierDistinguishesCaptchaPaymentAndDestructiveAction() {
        XCTAssertEqual(AgentBrowserService.detectChallenge(title: "", text: "验证码"), .captcha)
        XCTAssertEqual(AgentBrowserService.detectChallenge(title: "Checkout", text: "credit card"), .payment)
        XCTAssertEqual(AgentBrowserService.detectChallenge(title: "", text: "Delete permanently"), .destructiveAction)
        XCTAssertNil(AgentBrowserService.detectChallenge(title: "Public article", text: "Read more"))
    }

    func testApprovalIsQueuedAcrossForegroundLifecycle() async throws {
        let center = BrowserApprovalCenter(timeoutNanoseconds: 10_000_000_000)
        center.setPresentationAvailable(false)
        let request = BrowserApprovalRequest(
            sessionID: "test",
            challenge: .login,
            url: "https://example.com/login",
            title: "Sign in"
        )

        let approvalTask = Task { () throws -> Bool in
            try await center.waitForApproval(request)
        }

        for _ in 0..<100 where center.pending != request {
            await Task.yield()
        }
        XCTAssertEqual(center.pending, request)

        center.setPresentationAvailable(true)
        center.approve()
        let approved = try await approvalTask.value
        XCTAssertTrue(approved)
        XCTAssertNil(center.pending)
    }

    func testApprovalTimeoutIsTypedAndClearsPendingRequest() async {
        let center = BrowserApprovalCenter(timeoutNanoseconds: 1_000_000)
        let request = BrowserApprovalRequest(
            sessionID: "test",
            challenge: .captcha,
            url: "https://example.com/verify",
            title: "Verify"
        )

        do {
            _ = try await center.waitForApproval(request)
            XCTFail("Expected approval timeout")
        } catch let error as BrowserApprovalError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(center.pending)
    }

    func testApprovalRequestPersistsSafeResumeMetadataWithoutURLCredentials() async throws {
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oaseschat-browser-approval-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let runID = UUID()
        let center = BrowserApprovalCenter(
            timeoutNanoseconds: 10_000_000_000,
            persistenceURL: persistenceURL
        )
        let request = BrowserApprovalRequest(
            runID: runID,
            callID: "call-login",
            sessionID: "project",
            challenge: .login,
            url: "https://example.com/login?access_token=should-not-persist#fragment",
            title: "Sign in"
        )

        let approvalTask = Task { () throws -> Bool in
            try await center.waitForApproval(request)
        }
        for _ in 0..<100 where center.pending != request {
            await Task.yield()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: persistenceURL.path))
        let restored = BrowserApprovalCenter(
            timeoutNanoseconds: 10_000_000_000,
            persistenceURL: persistenceURL
        )
        XCTAssertEqual(restored.pending?.runID, runID)
        XCTAssertEqual(restored.pending?.sessionID, "project")
        XCTAssertEqual(restored.pending?.url, "https://example.com/login")
        XCTAssertFalse(String(data: try Data(contentsOf: persistenceURL), encoding: .utf8)?.contains("access_token") == true)

        center.cancel()
        _ = try? await approvalTask.value
    }

    func testRestoredApprovalCanReattachAndConsumeDecisionAfterColdLaunch() async throws {
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oaseschat-browser-approval-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let request = BrowserApprovalRequest(
            runID: UUID(),
            callID: "call-restore",
            sessionID: "project",
            challenge: .captcha,
            url: "https://example.com/verify?token=do-not-store",
            title: "Verify"
        )
        let firstCenter = BrowserApprovalCenter(
            timeoutNanoseconds: 10_000_000_000,
            persistenceURL: persistenceURL
        )
        let firstTask = Task { () throws -> Bool in
            try await firstCenter.waitForApproval(request)
        }
        for _ in 0..<100 where firstCenter.pending == nil {
            await Task.yield()
        }
        XCTAssertNotNil(firstCenter.pending)

        // Simulate a process restart: the original waiter is no longer the
        // owner of the restored state, but the request must remain visible.
        let restoredCenter = BrowserApprovalCenter(
            timeoutNanoseconds: 10_000_000_000,
            persistenceURL: persistenceURL
        )
        XCTAssertEqual(restoredCenter.pending?.approvalKey, request.approvalKey)

        XCTAssertTrue(FileManager.default.fileExists(atPath: persistenceURL.path))
        XCTAssertEqual(restoredCenter.pending?.approvalKey, request.approvalKey)

        // A decision made from the restored sheet is persisted until the
        // resumed executor consumes it.
        restoredCenter.approve()
        XCTAssertNil(restoredCenter.pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistenceURL.path))
        let resumedCenter = BrowserApprovalCenter(
            timeoutNanoseconds: 10_000_000_000,
            persistenceURL: persistenceURL
        )
        XCTAssertNil(resumedCenter.pending)
        let resumedApproval = try await resumedCenter.waitForApproval(request)
        XCTAssertTrue(resumedApproval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistenceURL.path))

        firstCenter.cancel()
        _ = try? await firstTask.value
    }
}
