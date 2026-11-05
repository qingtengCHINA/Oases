import Foundation

struct AgentRetryPolicy: Sendable, Equatable {
    /// Maximum attempts for one logical tool call, including the first call.
    let maxAttempts: Int
    let initialDelayNanoseconds: UInt64
    let maxDelayNanoseconds: UInt64
    let backoffMultiplier: UInt64
    /// A repeated failure signature across model turns is terminal. This
    /// prevents a model from spinning on the same unavailable capability.
    let maxConsecutiveIdenticalFailures: Int

    static let noRetries = AgentRetryPolicy(maxAttempts: 1, initialDelayNanoseconds: 0)

    init(
        maxAttempts: Int = 3,
        initialDelayNanoseconds: UInt64 = 100_000_000,
        maxDelayNanoseconds: UInt64 = 2_000_000_000,
        backoffMultiplier: UInt64 = 2,
        maxConsecutiveIdenticalFailures: Int = 2
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maxDelayNanoseconds = max(initialDelayNanoseconds, maxDelayNanoseconds)
        self.backoffMultiplier = max(1, backoffMultiplier)
        self.maxConsecutiveIdenticalFailures = max(1, maxConsecutiveIdenticalFailures)
    }

    func shouldRetry(
        record: ToolExecutionRecord,
        attempt: Int,
        identicalFailureCount: Int
    ) -> Bool {
        guard record.outcome == .failed else { return false }
        guard attempt < maxAttempts else { return false }
        return identicalFailureCount < maxConsecutiveIdenticalFailures
    }

    func delayNanoseconds(forRetryNumber retryNumber: Int) -> UInt64 {
        guard retryNumber > 0, initialDelayNanoseconds > 0 else { return 0 }

        var delay = initialDelayNanoseconds
        for _ in 1..<retryNumber {
            if delay >= maxDelayNanoseconds / backoffMultiplier {
                return maxDelayNanoseconds
            }
            delay = min(maxDelayNanoseconds, delay * backoffMultiplier)
        }
        return min(delay, maxDelayNanoseconds)
    }
}
