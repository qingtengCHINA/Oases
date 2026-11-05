import Foundation

/// Shared ordering contract for concurrent tool fan-out.
/// AgentExecutor and tests both call this so order is not re-implemented.
enum AgentConcurrentToolOrdering {
    /// Reassemble parallel tool results so index 0…n-1 matches original tool_use order.
    static func resultsInOriginalOrder<T>(_ map: [Int: T], count: Int) -> [T] {
        (0..<count).compactMap { map[$0] }
    }
}
