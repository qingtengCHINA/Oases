import Foundation
import XCTest
@testable import Oases_Chat

/// Output ordering and scoped cancellation for `ISHRuntimeService`.
final class ISHRuntimeServiceOrderingTests: XCTestCase {
    /// Lines must reach the result in the order the executor emitted them,
    /// and none may be lost when the completion fires right after the last
    /// line (it used to be a separate `Task` per callback).
    func testLinesArriveInOrderBeforeCompletion() async {
        let lineCount = 2_000
        let executor = BurstExecutor(lines: (0..<lineCount).map { "line-\($0)" })
        let service = ISHRuntimeService(bootstrap: { true }, executor: executor)

        for _ in 0..<5 {
            let result = await service.execute(ISHCommand(command: "burst", timeout: 10, sessionId: "order"))
            XCTAssertTrue(result.succeeded)
            let lines = result.stdout.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, lineCount)
            XCTAssertEqual(lines, (0..<lineCount).map { "line-\($0)" })
        }
    }

    func testCancelUnscopedLeavesSessionCommandsRunning() async {
        let executor = ManualExecutor()
        let service = ISHRuntimeService(bootstrap: { true }, executor: executor)
        let unscoped = Task { await service.execute(ISHCommand(command: "sleep 1", timeout: 30, sessionId: nil)) }
        let scoped = Task { await service.execute(ISHCommand(command: "sleep 2", timeout: 30, sessionId: "other-session")) }
        // Launches hop through ISHRuntimeQueue, which the host app may still
        // be using for its own bootstrap; allow a generous window.
        var polls = 0
        while executor.startedCount < 2, polls < 1_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertEqual(executor.startedCount, 2)

        let cancelled = await service.cancelUnscoped()
        XCTAssertEqual(cancelled, 1)
        let unscopedResult = await unscoped.value
        XCTAssertEqual(unscopedResult.termination, .cancelled)
        let scopedPIDs = await service.activePIDs(sessionId: "other-session")
        XCTAssertEqual(scopedPIDs.count, 1, "another session's command must keep running")

        executor.completeAll()
        let scopedResult = await scoped.value
        XCTAssertTrue(scopedResult.succeeded)
    }
}

/// Emits all lines and then the completion back-to-back from one thread.
private final class BurstExecutor: @unchecked Sendable, ISHCommandExecuting {
    private let lines: [String]
    private let lock = NSLock()
    private var nextPID: Int32 = 500

    init(lines: [String]) { self.lines = lines }

    func start(
        command: String,
        environment: [String: String],
        fsContext: UInt64,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        completion: @escaping @Sendable (ISHCommandCompletion) -> Void
    ) -> Int32 {
        lock.lock()
        let pid = nextPID
        nextPID += 1
        lock.unlock()
        let lines = self.lines
        DispatchQueue.global().async {
            for line in lines { onLine(line, false) }
            completion(ISHCommandCompletion(
                pid: pid, exitCode: 0, errorCode: 0, output: "", errorOutput: "", duration: 0.01
            ))
        }
        return pid
    }

    func terminate(pid: Int32, signal: Int32) -> Bool { true }
}

/// Commands run until `completeAll()` or `terminate`.
private final class ManualExecutor: @unchecked Sendable, ISHCommandExecuting {
    private let lock = NSLock()
    private var nextPID: Int32 = 700
    private var completions: [Int32: @Sendable (ISHCommandCompletion) -> Void] = [:]
    private var started = 0

    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func start(
        command: String,
        environment: [String: String],
        fsContext: UInt64,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        completion: @escaping @Sendable (ISHCommandCompletion) -> Void
    ) -> Int32 {
        lock.lock()
        let pid = nextPID
        nextPID += 1
        started += 1
        completions[pid] = completion
        lock.unlock()
        return pid
    }

    func terminate(pid: Int32, signal: Int32) -> Bool {
        finish(pid: pid, exitCode: -1, errorCode: -4)
        return true
    }

    func completeAll() {
        lock.lock()
        let pids = Array(completions.keys)
        lock.unlock()
        for pid in pids { finish(pid: pid, exitCode: 0, errorCode: 0) }
    }

    private func finish(pid: Int32, exitCode: Int32, errorCode: Int32) {
        lock.lock()
        let completion = completions.removeValue(forKey: pid)
        lock.unlock()
        completion?(ISHCommandCompletion(
            pid: pid, exitCode: exitCode, errorCode: errorCode, output: "", errorOutput: "", duration: 0.01
        ))
    }
}
