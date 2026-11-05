import Foundation

struct ISHCommandCompletion: Sendable {
    let pid: Int32
    let exitCode: Int32
    let errorCode: Int32
    let output: String
    let errorOutput: String
    let duration: TimeInterval
}

protocol ISHCommandExecuting: Sendable {
    /// Called on `ISHRuntimeQueue`'s owner thread.
    func start(
        command: String,
        environment: [String: String],
        fsContext: UInt64,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        completion: @escaping @Sendable (ISHCommandCompletion) -> Void
    ) -> Int32

    @discardableResult
    func terminate(pid: Int32, signal: Int32) -> Bool
}

private struct ProductionISHCommandExecutor: ISHCommandExecuting {
    func start(
        command: String,
        environment: [String: String],
        fsContext: UInt64,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        completion: @escaping @Sendable (ISHCommandCompletion) -> Void
    ) -> Int32 {
        return Int32(ISHShellExecutor.executeExecutable(
            "/bin/sh",
            arguments: ["-c", command],
            environment: environment.isEmpty ? nil : environment,
            fsContext: fsContext,
            lineCallback: { line, isStderr in
                onLine(line, isStderr)
            },
            completion: { result in
                completion(ISHCommandCompletion(
                    pid: Int32(result.pid),
                    exitCode: Int32(result.exitCode),
                    errorCode: Int32(result.error.rawValue),
                    output: result.output,
                    errorOutput: result.errorOutput,
                    duration: result.duration
                ))
            }
        ))
    }

    /// Kills the command's whole process group (SIGTERM, then SIGKILL
    /// ~200ms later) rather than only `pid`: children that inherited the
    /// output pipes would otherwise keep running and keep the pipes open, so
    /// the readers never see EOF. `signal` is superseded by that escalation.
    ///
    /// Every caller has already delivered the command's result (cancelled or
    /// timed out), so the executor context is then finalised straight away
    /// ([T-ish-shell-timeout-leak]): without that, a task that never exits
    /// would leave the context registered and its two reader threads polling
    /// forever, and this service's `pending` entry waiting for a completion
    /// that never comes.
    func terminate(pid: Int32, signal: Int32) -> Bool {
        guard pid > 1 else { return false }
        ISHShellExecutor.killProcessGroup(pid)
        ISHShellExecutor.finalizeTimedOutPid(pid)
        return true
    }
}

/// Concurrent multi-PID iSH command dispatcher (OpenMinis coordinator style).
/// Commands fan out in parallel; per-session PIDs are tracked for stop/cancel.
actor ISHRuntimeService {
    static let shared = ISHRuntimeService()

    private enum State {
        case queued
        case launching
        case running
    }

    /// An executor callback, delivered to the actor in the order it fired.
    private enum ExecutorEvent: Sendable {
        case line(String, isStderr: Bool)
        case completion(ISHCommandCompletion)
    }

    private final class PendingCommand: @unchecked Sendable {
        let command: ISHCommand
        let continuation: CheckedContinuation<ISHCommandResult, Never>
        var state: State = .queued
        var pid: Int32?
        var startedAt: Date?
        var stdout = ""
        var stderr = ""
        var delivered = false
        var deliveredTermination: ISHCommandTermination?
        var completionReceived = false
        var cancellationRequested = false
        var timeoutTask: Task<Void, Never>?

        init(command: ISHCommand, continuation: CheckedContinuation<ISHCommandResult, Never>) {
            self.command = command
            self.continuation = continuation
        }
    }

    private let bootstrap: @Sendable () -> Bool
    private let executor: any ISHCommandExecuting
    private let now: @Sendable () -> Date
    private var pending: [UUID: PendingCommand] = [:]
    private var cancelledBeforeEnqueue: Set<UUID> = []
    /// All currently launching/running command IDs (concurrent).
    private var activeIDs: Set<UUID> = []
    private var diagnosticsState = ISHRuntimeDiagnostics()

    init(
        bootstrap: @escaping @Sendable () -> Bool = { ISHRuntimeBootstrap.bootstrap() },
        executor: any ISHCommandExecuting = ProductionISHCommandExecutor(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bootstrap = bootstrap
        self.executor = executor
        self.now = now
    }

    func execute(_ command: ISHCommand) async -> ISHCommandResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ISHCommandResult, Never>) in
                self.enqueue(command, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(commandID: command.id) }
        }
    }

    /// Cancel every in-flight command for a session (Stop button).
    @discardableResult
    func cancelAll(sessionId: String) async -> Int {
        let ids = pending.values
            .filter { $0.command.sessionId == sessionId && !$0.delivered }
            .map(\.command.id)
        var count = 0
        for id in ids {
            if await cancel(commandID: id) { count += 1 }
        }
        return count
    }

    /// Cancel every in-flight command launched without a session scope.
    @discardableResult
    func cancelUnscoped() async -> Int {
        let ids = pending.values
            .filter { $0.command.sessionId == nil && !$0.delivered }
            .map(\.command.id)
        var count = 0
        for id in ids {
            if await cancel(commandID: id) { count += 1 }
        }
        return count
    }

    /// Cancel every currently tracked command (any session / nil session).
    @discardableResult
    func cancelAllInFlight() async -> Int {
        let ids = pending.values.filter { !$0.delivered }.map(\.command.id)
        var count = 0
        for id in ids {
            if await cancel(commandID: id) { count += 1 }
        }
        return count
    }

    /// PIDs currently tracked for a session (for tests / stop UI).
    func activePIDs(sessionId: String) -> [Int32] {
        pending.values.compactMap { item in
            guard item.command.sessionId == sessionId, !item.delivered else { return nil }
            return item.pid
        }
    }

    @discardableResult
    func cancel(commandID: UUID) async -> Bool {
        guard let command = pending[commandID] else {
            cancelledBeforeEnqueue.insert(commandID)
            return true
        }
        guard !command.delivered else { return false }
        command.cancellationRequested = true

        switch command.state {
        case .queued:
            deliver(command, termination: .cancelled, exitCode: nil)
            removeIfFinished(commandID)
        case .launching, .running:
            if let pid = command.pid {
                terminateOnRuntimeThread(pid: pid)
            }
            deliver(command, termination: .cancelled, exitCode: nil)
            finishWhenCompletionArrives(commandID)
        }
        return true
    }

    @discardableResult
    func terminate(commandID: UUID) async -> Bool {
        await cancel(commandID: commandID)
    }

    func diagnostics() -> ISHRuntimeDiagnostics {
        diagnosticsState
    }

    func runStressSelfTest(commandCount: Int = 16) async -> ISHRuntimeStressSelfTestReport {
        let count = max(0, commandCount)
        let commands = (0..<count).map { index in
            ISHCommand(command: "printf 'ish-stress-\\n' # \(index)", timeout: 10)
        }
        let results = await withTaskGroup(of: ISHCommandResult.self, returning: [ISHCommandResult].self) { group in
            for command in commands {
                group.addTask { await self.execute(command) }
            }
            var collected: [ISHCommandResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        let snapshot = diagnosticsState
        let successful = results.filter(\.succeeded).count
        let uniqueIDs = Set(results.map(\.commandID)).count
        // Concurrent contract: allow maxConcurrent > 1; still require all complete uniquely.
        return ISHRuntimeStressSelfTestReport(
            requested: count,
            completed: successful,
            uniqueCommandIDs: uniqueIDs,
            maxConcurrent: snapshot.maxConcurrent,
            serializedViolations: snapshot.serializedViolations,
            passed: successful == count
                && uniqueIDs == count
                && snapshot.serializedViolations == 0
        )
    }

    private func enqueue(
        _ command: ISHCommand,
        continuation: CheckedContinuation<ISHCommandResult, Never>
    ) {
        if cancelledBeforeEnqueue.remove(command.id) != nil {
            continuation.resume(returning: ISHCommandResult(
                commandID: command.id,
                command: command.command,
                pid: nil,
                exitCode: nil,
                termination: .cancelled,
                stdout: "",
                stderr: "",
                startedAt: nil,
                endedAt: now()
            ))
            return
        }
        guard pending[command.id] == nil else {
            continuation.resume(returning: ISHCommandResult(
                commandID: command.id,
                command: command.command,
                pid: nil,
                exitCode: nil,
                termination: .failed,
                stdout: "",
                stderr: "duplicate command id",
                startedAt: nil,
                endedAt: now()
            ))
            return
        }

        let item = PendingCommand(command: command, continuation: continuation)
        pending[command.id] = item
        diagnosticsState.recordSubmission()
        // Concurrent: launch immediately (no global FIFO wait).
        launch(id: command.id)
    }

    private func launch(id: UUID) {
        guard let command = pending[id] else { return }
        command.state = .launching
        activeIDs.insert(id)

        let bootstrap = self.bootstrap
        let executor = self.executor
        let commandValue = command.command.command
        let environment = command.command.environment
        let sessionId = command.command.sessionId
        let fsContext: UInt64 = {
            guard let sessionId else { return 0 }
            return OasesFsRouter.shared.context(for: sessionId)
        }()
        if sessionId != nil {
            OasesFsRouter.shared.installHookIfNeeded()
        }

        // One ordered channel per command: the executor's line and completion
        // callbacks are yielded in the order they fire and drained by a single
        // task. (A `Task` per callback gave no ordering guarantee — lines
        // could land out of order, or after the completion and be dropped.)
        let (events, sink) = AsyncStream<ExecutorEvent>.makeStream()
        Task { [weak self] in
            for await event in events {
                await self?.receive(event, commandID: id)
            }
        }

        let launch = ISHRuntimeQueue.sync { () -> (bootstrapSucceeded: Bool, pid: Int32) in
            guard bootstrap() else { return (false, -1) }
            let pid = executor.start(
                command: commandValue,
                environment: environment,
                fsContext: fsContext,
                onLine: { line, isStderr in
                    sink.yield(.line(line, isStderr: isStderr))
                },
                completion: { completion in
                    sink.yield(.completion(completion))
                    sink.finish()
                }
            )
            return (true, pid)
        }

        if !launch.bootstrapSucceeded || launch.pid < 0 {
            // No callbacks will follow; release the drain task.
            sink.finish()
        }

        if !launch.bootstrapSucceeded {
            didFailToStart(id: id, termination: .runtimeNotReady)
        } else {
            didStart(id: id, pid: launch.pid)
        }
    }

    private func didStart(id: UUID, pid: Int32) {
        guard let command = pending[id] else { return }
        guard pid >= 0 else {
            didFailToStart(id: id, termination: startFailure(for: pid))
            return
        }

        command.pid = pid
        command.startedAt = now()
        command.state = .running
        diagnosticsState.recordStart()

        if command.delivered {
            if command.cancellationRequested {
                terminateOnRuntimeThread(pid: pid)
            }
            diagnosticsState.recordTerminal(command.deliveredTermination ?? .failed)
        } else if command.cancellationRequested {
            terminateOnRuntimeThread(pid: pid)
            deliver(command, termination: .cancelled, exitCode: nil)
        } else if command.command.timeout > 0 {
            let timeout = command.command.timeout
            command.timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.timeout(commandID: id)
                } catch {}
            }
        }

        if command.completionReceived {
            clearFinishedCommand(id)
        }
    }

    private func didFailToStart(id: UUID, termination: ISHCommandTermination) {
        guard let command = pending[id] else { return }
        diagnosticsState.recordStartFailure(termination)
        deliver(command, termination: termination, exitCode: nil)
        activeIDs.remove(id)
        pending.removeValue(forKey: id)
    }

    private func receive(_ event: ExecutorEvent, commandID: UUID) {
        switch event {
        case .line(let line, let isStderr):
            receiveLine(commandID: commandID, line: line, isStderr: isStderr)
        case .completion(let completion):
            receiveCompletion(commandID: commandID, completion: completion)
        }
    }

    private func receiveLine(commandID: UUID, line: String, isStderr: Bool) {
        guard let command = pending[commandID], !command.delivered else { return }
        if isStderr {
            CommandOutputCap.append(line + "\n", to: &command.stderr)
        } else {
            CommandOutputCap.append(line + "\n", to: &command.stdout)
        }
    }

    private func receiveCompletion(commandID: UUID, completion: ISHCommandCompletion) {
        guard let command = pending[commandID] else { return }
        command.completionReceived = true
        if command.stdout.isEmpty { command.stdout = completion.output }
        if command.stderr.isEmpty { command.stderr = completion.errorOutput }

        if !command.delivered {
            let termination = command.cancellationRequested
                ? ISHCommandTermination.cancelled
                : termination(forErrorCode: completion.errorCode)
            deliver(command, termination: termination, exitCode: completion.exitCode)
        }
        clearFinishedCommand(commandID)
    }

    private func timeout(commandID: UUID) {
        guard let command = pending[commandID], !command.delivered else { return }
        command.cancellationRequested = true
        if let pid = command.pid {
            terminateOnRuntimeThread(pid: pid)
        }
        deliver(command, termination: .timedOut, exitCode: nil)
    }

    private func deliver(_ command: PendingCommand, termination: ISHCommandTermination, exitCode: Int32?) {
        guard !command.delivered else { return }
        command.delivered = true
        command.deliveredTermination = termination
        command.timeoutTask?.cancel()
        if command.state == .running {
            diagnosticsState.recordTerminal(termination)
        }
        let result = ISHCommandResult(
            commandID: command.command.id,
            command: command.command.command,
            pid: command.pid,
            exitCode: exitCode,
            termination: termination,
            stdout: command.stdout,
            stderr: command.stderr,
            startedAt: command.startedAt,
            endedAt: now()
        )
        command.continuation.resume(returning: result)
    }

    private func finishWhenCompletionArrives(_ id: UUID) {
        if pending[id]?.completionReceived == true {
            clearFinishedCommand(id)
        }
    }

    private func removeIfFinished(_ id: UUID) {
        guard pending[id]?.delivered == true else { return }
        pending.removeValue(forKey: id)
        activeIDs.remove(id)
    }

    private func clearFinishedCommand(_ id: UUID) {
        guard let command = pending[id], command.delivered, command.completionReceived else { return }
        pending.removeValue(forKey: id)
        activeIDs.remove(id)
    }

    /// [T-ish-killpg-main-thread-watchdog] On the shared kill queue, no longer
    /// the iSH runtime thread: killProcessGroup can block on the kernel's
    /// pids_lock, and every shell launch (and any caller waiting on
    /// `ISHRuntimeQueue.sync`, the main thread included) queued behind it.
    private func terminateOnRuntimeThread(pid: Int32) {
        let executor = self.executor
        ISHExecutionCoordinator.killQueue.async {
            _ = executor.terminate(pid: pid, signal: 9)
        }
    }

    private func startFailure(for code: Int32) -> ISHCommandTermination {
        switch code {
        case -1: return .processCreationFailed
        case -2: return .execFailed
        case -3: return .timedOut
        case -4: return .cancelled
        default: return .failed
        }
    }

    private func termination(forErrorCode code: Int32) -> ISHCommandTermination {
        switch code {
        case 0: return .exited
        case -3: return .timedOut
        case -4: return .cancelled
        case -1: return .processCreationFailed
        case -2: return .execFailed
        default: return .failed
        }
    }
}
