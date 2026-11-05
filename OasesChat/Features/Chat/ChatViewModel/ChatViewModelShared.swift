import Foundation
import Observation
import SwiftData

/// Holds a reference to the currently-armed watchdog task so the
/// per-chunk reset can cancel the previous one before scheduling a new
/// one. A class (not a struct) so the inner Task closures share the same
/// reference cell without copying.
@MainActor
final class WatchdogBox {
    var task: Task<Void, Never>?

    /// Length of one budget tick. A tick that took longer than
    /// `maxTickCharge` spanned a suspension (app in the background), so
    /// only `maxTickCharge` of it is charged.
    static let tick: TimeInterval = 1
    static let maxTickCharge: TimeInterval = 2

    /// (Re)arms the watchdog to call `onFire` after `timeout` seconds of time
    /// the app actually spent running. A single long `Task.sleep` fired the
    /// moment the app came back from >30 s in the background, failing a
    /// stream that was still healthy; draining the budget in short ticks
    /// and capping each tick keeps background time from counting.
    func arm(timeout: TimeInterval, onFire: @escaping @MainActor @Sendable () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            var remaining = timeout
            var last = ContinuousClock.now
            while remaining > 0 {
                let step = min(remaining, Self.tick)
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                if Task.isCancelled { return }
                let now = ContinuousClock.now
                let elapsed = last.duration(to: now)
                last = now
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                remaining -= min(max(seconds, step), Self.maxTickCharge)
            }
            onFire()
        }
    }
}

/// Accumulator for an in-flight tool call. OpenAI's streaming API
/// breaks tool calls across many SSE chunks — the first carries `id`
/// and `function.name`, subsequent chunks just append to
/// `function.arguments`. We aggregate by `index` then materialize a
/// `ToolCall` once the turn finishes.
struct WorkingToolCall {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""

    func materialize() -> ToolCall {
        ToolCall(
            id: id.isEmpty ? UUID().uuidString : id,
            name: name,
            displayName: ToolRegistry.shared.tool(named: name)?.descriptor.displayName,
            description: ToolRegistry.shared.tool(named: name)?.descriptor.summary,
            status: .pending,
            inputJSON: arguments
        )
    }
}

