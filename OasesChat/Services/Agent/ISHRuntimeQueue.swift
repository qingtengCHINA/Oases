import Foundation

/// Dedicated long-lived thread that owns every interaction with the
/// iSH kernel — `ish_runtime_initialize`, every
/// `ISHShellExecutor.execute…` call, every `become_new_init_child`,
/// etc. All run on the same pthread.
///
/// Why: iSH's emulated Linux state lives in thread-local storage
/// (the kernel's `current` task pointer is pthread-specific). If
/// init runs on one pthread and a later shell invocation runs on
/// another, that second thread's `current` is NULL and the executor
/// can fail process creation or dereference an invalid task. A GCD
/// serial queue is not enough here because it preserves ordering, not
/// thread identity.
enum ISHRuntimeQueue {
    private static let worker = ISHRuntimeThread()

    /// Run `work` on the iSH thread and wait for its result. Used by
    /// async-bridges that need to call into the kernel without
    /// hopping back to the caller's executor mid-flight.
    static func sync<T>(_ work: @escaping @Sendable () -> T) -> T {
        worker.sync(work)
    }

    /// Same shape, async, when the caller has nothing useful to do
    /// with the return value (e.g. fire-and-forget init).
    static func async(_ work: @escaping @Sendable () -> Void) {
        worker.async(work)
    }
}

private final class ISHRuntimeThread: @unchecked Sendable {
    private static let threadName = "dev.oases.ish.runtime"
    private static let threadKey = "dev.oases.ish.runtime.thread"

    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var didStart = false
    private var thread: Thread?

    init() {
        let runtimeThread = Thread { [weak self] in
            self?.runLoop()
        }
        runtimeThread.name = Self.threadName
        runtimeThread.qualityOfService = .userInitiated
        thread = runtimeThread
        runtimeThread.start()

        condition.lock()
        while !didStart {
            condition.wait()
        }
        condition.unlock()
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(work)
        condition.signal()
        condition.unlock()
    }

    func sync<T>(_ work: @escaping @Sendable () -> T) -> T {
        if isOnRuntimeThread {
            return work()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ISHRuntimeResultBox<T>()
        async {
            box.result = .value(work())
            semaphore.signal()
        }
        semaphore.wait()

        guard let result = box.result else {
            fatalError("ISHRuntimeThread sync returned without a result")
        }
        switch result {
        case .value(let value):
            return value
        }
    }

    private var isOnRuntimeThread: Bool {
        Thread.current.threadDictionary[Self.threadKey] as? Bool == true
    }

    private func runLoop() {
        Thread.current.name = Self.threadName
        Thread.current.threadDictionary[Self.threadKey] = true

        condition.lock()
        didStart = true
        condition.broadcast()
        condition.unlock()

        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()

            autoreleasepool {
                job()
            }
        }
    }
}

private enum ISHRuntimeResult<T> {
    case value(T)
}

private final class ISHRuntimeResultBox<T>: @unchecked Sendable {
    var result: ISHRuntimeResult<T>?
}
