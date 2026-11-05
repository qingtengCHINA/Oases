import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatUIMessage] = []
    var input: String = ""
    var isStreaming: Bool = false
    var currentModel: String = Models.preferredChatModel()
    var activeMode: AppMode = .chat
    var errorMessage: String?
    /// Reasoning effort plumbed through to the request (Web sends both
    /// `effort` and `reasoning_effort`). Defaults to the user's model preference.
    var effort: Models.Effort = Models.preferredEffort()

    // private(set) preserved so external views cannot mutate; extensions can write.
    private(set) var conversation: ConversationModel?
    // Demoted from private → internal so extension files in this module can access.
    var modelContext: ModelContext?
    var currentTask: Task<Void, Never>?
    /// Stream generation token: the id of the assistant placeholder whose
    /// turn currently owns `isStreaming` / `currentTask`. Set when a turn
    /// starts (`makeAssistantPlaceholder`), cleared when it ends or is
    /// abandoned (`stop()` / `reset()`). A cancelled task that finishes late
    /// no longer matches, so its cleanup can't end a newer stream.
    var activeStreamID: String?
    /// What the current turn is doing, for the thinking Live Activity.
    let liveSignals = AgentLiveSignals()
    /// When the active turn started, for the "reply finished" sound (long replies only).
    var streamStartedAt: Date?
    /// Daily-quota charge for the active turn. Applied only when that turn
    /// finishes successfully — failed or cancelled requests are not counted.
    var pendingQuotaCharge: (category: Models.Category, modelId: String)?
    /// Active production engineering run — used by `stop()` to cancel the
    /// executor and kill in-flight shell PIDs (not just the UI consumer Task).
    var activeProjectRuntime: OgentProductionAgentRuntime?
    var activeProjectRunID: UUID?
    var activeProjectSessionID: String?
    /// Session key this view model registered with `SessionActivityTracker`
    /// for the Live Activity. Held so the finish/cancel paths clear the same
    /// entry they created.
    var activeLiveSessionId: String?
    var dismissTask: Task<Void, Never>?
    let service: ChatService
    var didAttemptInterruptedProjectRecovery = false

    init(service: ChatService = ChatService()) {
        self.service = service
        ThinkingLiveState.shared.register(liveSignals)
        // The consent taken back (Settings › 撤回同意) stops the
        // turn under way at once: its requests are cancelled in flight (`AIRequestGate`).
        AIRequestGate.registerStopper(for: self) { viewModel in
            if viewModel.isStreaming { viewModel.stop() }
        }
    }

    // Internal setter for conversation — needed by extension files.
    func setConversation(_ c: ConversationModel?) { conversation = c }
}
