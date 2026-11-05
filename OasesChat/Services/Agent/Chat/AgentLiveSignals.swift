import Foundation
import os
import QuartzCore

/// What an agent run is doing right now, for the effects that react to it (the Ogent ASCII
/// ocean, the dithered "mind" in the activity rail, the thinking Live Activity).
///
/// The stream handler (`processStreamEvents`) runs off the main actor and must not hop to it
/// per token, so writes are O(1) under an unfair lock. Readers take a copy (`snapshot()`) once
/// per frame. Counters only ever grow, so any number of readers can each keep their own "last
/// seen" value instead of draining shared state.
final class AgentLiveSignals: Sendable {
    enum Phase: UInt8, Sendable {
        /// No run.
        case idle
        /// Sent; nothing has come back yet.
        case awaiting
        /// The model is streaming its reasoning.
        case thinking
        /// The model is writing or running a tool call.
        case tool
        /// The model is writing the answer.
        case text
        /// The run ended normally.
        case done
        /// The run ended with an error or was stopped.
        case failed

        var isLive: Bool { self == .awaiting || self == .thinking || self == .tool || self == .text }
    }

    struct Snapshot: Sendable, Equatable {
        var phase: Phase = .idle
        /// `CACurrentMediaTime()` of the last phase change.
        var phaseChangedAt: CFTimeInterval = 0
        /// Characters received so far (text, a share of thinking, tool input), ever growing.
        var streamedCharacters: Int = 0
        /// Bumped on every send.
        var sendCount: Int = 0
        /// Bumped when a run fails or is stopped, or a send is refused.
        var failureCount: Int = 0
        /// Bumped when a tool call finishes.
        var toolCompletionCount: Int = 0
        /// `CACurrentMediaTime()` of the last keystroke in the composer.
        var typedAt: CFTimeInterval = 0
        /// The tool being called (latest), if any.
        var toolName: String?
        /// The prompt of the latest send, trimmed.
        var prompt: String = ""
        /// The last few hundred characters of reasoning, for picking a shape that fits it.
        var reasoningTail: String = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    static let reasoningTailLimit = 240

    func snapshot() -> Snapshot { state.withLock { $0 } }

    // MARK: - Writers

    /// The composer's text at send time; the run itself starts with `didStartRun()`.
    func notePrompt(_ prompt: String) {
        let trimmed = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        state.withLock { $0.prompt = trimmed }
    }

    /// A run began (a send, a retry, a resumed or scheduled run).
    func didStartRun() {
        state.withLock { s in
            s.sendCount &+= 1
            s.reasoningTail = ""
            s.toolName = nil
            Self.set(.awaiting, in: &s)
        }
    }

    func didStartText() {
        state.withLock { Self.set(.text, in: &$0) }
    }

    func didStartTool(named name: String) {
        state.withLock { s in
            s.toolName = name
            s.streamedCharacters &+= 8
            Self.set(.tool, in: &s)
        }
    }

    func didReceiveText(count: Int) {
        state.withLock { s in
            s.streamedCharacters &+= count
            if s.phase != .text { Self.set(.text, in: &s) }
        }
    }

    func didReceiveReasoning(_ text: String) {
        state.withLock { s in
            s.streamedCharacters &+= max(1, text.count / 2)
            s.reasoningTail += text
            if s.reasoningTail.count > Self.reasoningTailLimit * 2 {
                s.reasoningTail = String(s.reasoningTail.suffix(Self.reasoningTailLimit))
            }
            if s.phase != .thinking { Self.set(.thinking, in: &s) }
        }
    }

    func didReceiveToolInput() {
        state.withLock { $0.streamedCharacters &+= 2 }
    }

    func didCompleteTool() {
        state.withLock { $0.toolCompletionCount &+= 1 }
    }

    /// The model asked for more tools: the run goes on.
    func didFinishStep() {
        state.withLock { s in
            if s.phase == .text { Self.set(.awaiting, in: &s) }
        }
    }

    func didFinishRun(failed: Bool) {
        state.withLock { s in
            guard s.phase != .idle else { return }
            if failed { s.failureCount &+= 1 }
            Self.set(failed ? .failed : .done, in: &s)
        }
    }

    func didType() {
        state.withLock { $0.typedAt = CACurrentMediaTime() }
    }

    func didRefuse() {
        state.withLock { $0.failureCount &+= 1 }
    }

    private static func set(_ phase: Phase, in s: inout Snapshot) {
        guard s.phase != phase else { return }
        s.phase = phase
        s.phaseChangedAt = CACurrentMediaTime()
    }
}

/// Every live `AgentLiveSignals` in the app (Ogent sessions and regular chat), so the Live
/// Activity can show what the model is doing after the app goes to the background.
@MainActor
final class ThinkingLiveState {
    static let shared = ThinkingLiveState()

    private struct Entry { weak var signals: AgentLiveSignals? }
    private var entries: [Entry] = []

    func register(_ signals: AgentLiveSignals) {
        entries.removeAll { $0.signals == nil || $0.signals === signals }
        entries.append(Entry(signals: signals))
    }

    /// The most recently changed run that is still live, if any.
    func current() -> AgentLiveSignals.Snapshot? {
        entries.removeAll { $0.signals == nil }
        return entries
            .compactMap { $0.signals?.snapshot() }
            .filter { $0.phase.isLive }
            .max { $0.phaseChangedAt < $1.phaseChangedAt }
    }

    var isLive: Bool { current() != nil }
}
