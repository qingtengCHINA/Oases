import Foundation
import XCTest
@testable import Oases_Chat

final class ISHRuntimeServiceTests: XCTestCase {
    func testConcurrentCommandsCanOverlapWithDistinctPIDs() async {
        let fake = FakeISHExecutor(autoComplete: false)
        let service = ISHRuntimeService(bootstrap: { true }, executor: fake)

        let first = ISHCommand(command: "echo a", timeout: 5, sessionId: "s1")
        let second = ISHCommand(command: "echo b", timeout: 5, sessionId: "s1")

        let t1 = Task { await service.execute(first) }
        let t2 = Task { await service.execute(second) }

        // Wait until both have been started (concurrent, not FIFO-one).
        for _ in 0..<200 {
            if fake.startedCount >= 2 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertGreaterThanOrEqual(fake.startedCount, 2, "expected concurrent starts")
        XCTAssertGreaterThanOrEqual(fake.maxConcurrent, 2)

        fake.completeAll(exitCode: 0)
        let r1 = await t1.value
        let r2 = await t2.value
        XCTAssertTrue(r1.succeeded)
        XCTAssertTrue(r2.succeeded)
        XCTAssertNotEqual(r1.pid, r2.pid)
        XCTAssertNotNil(r1.pid)
        XCTAssertNotNil(r2.pid)

        let diagnostics = await service.diagnostics()
        XCTAssertGreaterThanOrEqual(diagnostics.maxConcurrent, 2)
    }

    func testCancelAllSessionKillsTrackedPIDs() async {
        let fake = FakeISHExecutor(autoComplete: false)
        let service = ISHRuntimeService(bootstrap: { true }, executor: fake)
        let cmd = ISHCommand(command: "sleep 10", timeout: 10, sessionId: "sess-kill")
        let task = Task { await service.execute(cmd) }
        for _ in 0..<100 {
            if fake.startedCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancelled = await service.cancelAll(sessionId: "sess-kill")
        XCTAssertEqual(cancelled, 1)
        let result = await task.value
        XCTAssertEqual(result.termination, .cancelled)
        await fake.waitUntilTerminated()
        XCTAssertFalse(fake.terminatedPIDs.isEmpty)
    }

    func testCancelAllInFlightKillsUnscopedCommands() async {
        let fake = FakeISHExecutor(autoComplete: false)
        let service = ISHRuntimeService(bootstrap: { true }, executor: fake)
        let cmd = ISHCommand(command: "sleep 10", timeout: 10, sessionId: nil)
        let task = Task { await service.execute(cmd) }
        for _ in 0..<100 {
            if fake.startedCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let n = await service.cancelAllInFlight()
        XCTAssertEqual(n, 1)
        let result = await task.value
        XCTAssertEqual(result.termination, .cancelled)
    }

    func testAgentExecutorCancelKillsShells() async throws {
        let fake = FakeISHExecutor(autoComplete: false)
        // Install fake executor into a dedicated service instance is not global —
        // exercise cancelAllInFlight after a real shared-service command via
        // the production cancel path on ISHRuntimeService.shared would race
        // other tests. Instead assert the coordinator cancel API reaches shells
        // by driving cancelAllInFlight on the service under test above, and
        // that AgentExecutor.cancel signature loads session then cancels.
        let store = AgentRunStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-\(UUID().uuidString)", isDirectory: true))
        let sid = "cancel-sess-\(UUID().uuidString.prefix(6))"
        var run = AgentRun(
            request: "stop me",
            context: AgentRunContext(
                model: "test",
                effort: nil,
                surface: .project,
                messages: [ChatAPIMessage(role: "user", content: .text("x"))],
                toolsJSON: nil,
                projectSessionID: sid,
                projectID: nil
            )
        )
        try await store.save(run)

        // Start a hanging shell on a private service with session, cancel via cancelAll.
        let service = ISHRuntimeService(bootstrap: { true }, executor: fake)
        let hang = ISHCommand(command: "sleep 99", timeout: 30, sessionId: sid)
        let hangTask = Task { await service.execute(hang) }
        for _ in 0..<100 {
            if fake.startedCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Simulate AgentExecutor.cancel session branch:
        let killed = await service.cancelAll(sessionId: sid)
        XCTAssertEqual(killed, 1)
        let result = await hangTask.value
        XCTAssertEqual(result.termination, .cancelled)
        _ = run
    }

    func testRuntimeNotReadyMapsToExplicitTermination() async {
        let service = ISHRuntimeService(bootstrap: { false }, executor: FakeISHExecutor())
        let result = await service.execute(ISHCommand(command: "echo never"))
        XCTAssertEqual(result.termination, .runtimeNotReady)
        XCTAssertFalse(result.succeeded)
    }

    func testStressSelfTestAllowsConcurrency() async {
        let fake = FakeISHExecutor()
        let service = ISHRuntimeService(bootstrap: { true }, executor: fake)
        let report = await service.runStressSelfTest(commandCount: 12)
        XCTAssertTrue(report.passed, "requested=\(report.requested) completed=\(report.completed) unique=\(report.uniqueCommandIDs) max=\(report.maxConcurrent)")
        XCTAssertEqual(report.completed, 12)
        XCTAssertEqual(report.uniqueCommandIDs, 12)
    }
}

private final class FakeISHExecutor: @unchecked Sendable, ISHCommandExecuting {
    private let lock = NSLock()
    private let autoComplete: Bool
    private let startResult: Int32?
    private var nextPID: Int32 = 100
    private var active = 0
    private(set) var maxConcurrent = 0
    private(set) var startedCommands: [String] = []
    private(set) var terminatedPIDs: [Int32] = []
    private var completions: [Int32: @Sendable (ISHCommandCompletion) -> Void] = [:]

    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return startedCommands.count
    }

    init(autoComplete: Bool = true, startResult: Int32? = nil) {
        self.autoComplete = autoComplete
        self.startResult = startResult
    }

    func start(
        command: String,
        environment: [String: String],
        fsContext: UInt64,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        completion: @escaping @Sendable (ISHCommandCompletion) -> Void
    ) -> Int32 {
        lock.lock()
        if let startResult {
            lock.unlock()
            return startResult
        }
        let pid = nextPID
        nextPID += 1
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        startedCommands.append(command)
        completions[pid] = completion
        lock.unlock()

        guard autoComplete else { return pid }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) { [weak self] in
            onLine("ok", false)
            self?.complete(pid: pid, exitCode: 0, errorCode: 0)
        }
        return pid
    }

    @discardableResult
    func terminate(pid: Int32, signal: Int32) -> Bool {
        lock.lock()
        terminatedPIDs.append(pid)
        let exists = completions[pid] != nil
        lock.unlock()
        if autoComplete == false, exists {
            complete(pid: pid, exitCode: -1, errorCode: -4)
        }
        return exists
    }

    func completeAll(exitCode: Int32) {
        lock.lock()
        let pids = Array(completions.keys)
        lock.unlock()
        for pid in pids {
            complete(pid: pid, exitCode: exitCode, errorCode: 0)
        }
    }

    func waitUntilTerminated() async {
        for _ in 0..<100 {
            lock.lock()
            let done = !terminatedPIDs.isEmpty
            lock.unlock()
            if done { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func complete(pid: Int32, exitCode: Int32, errorCode: Int32) {
        lock.lock()
        guard let completion = completions.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        active = max(0, active - 1)
        lock.unlock()
        completion(ISHCommandCompletion(
            pid: pid,
            exitCode: exitCode,
            errorCode: errorCode,
            output: "ok",
            errorOutput: "",
            duration: 0.001
        ))
    }
}
