import Foundation
import SwiftUI
import SwiftData

extension ChatViewModel {
    // MARK: - Persistence

    func bind(context: ModelContext) {
        self.modelContext = context
    }

    /// Continue the latest non-terminal project run after a process restart.
    /// This is intentionally gated to an empty surface: selecting an existing
    /// conversation remains a user-controlled action and cannot be hijacked by
    /// an unrelated stale run in the file-backed AgentRun store.
    func resumeLatestInterruptedProjectRunIfNeeded() async {
        // Resuming re-sends the interrupted request to the model on launch,
        // without a tap — never in limited mode. Checked before the one-shot
        // flag so the run can still resume on a later mount after consent.
        guard AIDataSharingConsent.isAccepted else { return }
        guard !didAttemptInterruptedProjectRecovery else { return }
        didAttemptInterruptedProjectRecovery = true
        guard !isStreaming, messages.isEmpty, modelContext != nil else { return }

        var restoringAssistantID: String?
        do {
            guard let candidate = try await OgentProductionAgentRuntime.latestInterruptedProjectRun(),
                  let context = candidate.context else { return }
            let request = (candidate.request ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { return }

            activeMode = .project
            currentModel = context.model
            if let storedEffort = context.effort,
               let restoredEffort = Models.Effort(rawValue: storedEffort) {
                effort = restoredEffort
            }

            let restoredConversation = ConversationModel(mode: .project, modelId: context.model)
            restoredConversation.title = String(request.prefix(30))
            guard let modelContext else { return }
            modelContext.insert(restoredConversation)
            setConversation(restoredConversation)

            let userMessage = ChatUIMessage.user(request)
            messages.append(userMessage)
            let savedUser = MessageModel(role: "user", content: request)
            if let uuid = UUID(uuidString: userMessage.id) { savedUser.id = uuid }
            savedUser.conversation = restoredConversation
            modelContext.insert(savedUser)
            restoredConversation.messages.append(savedUser)
            restoredConversation.updatedAt = .now
            saveContext(modelContext, "restored project turn")

            let assistantID = makeAssistantPlaceholder(content: String(localized: "正在恢复工程任务…"))
            restoringAssistantID = assistantID
            let plan = ProjectAgentPlanner.plan(for: request, iteration: 1, executedToolCalls: 0)
            let completionContract = AgentCompletionContract(
                requiresArtifact: plan.completionContract.requiresArtifact
            )
            let chatService = service
            let restored = try await OgentProductionAgentRuntime.resumePersistedRun(
                runID: candidate.id,
                service: chatService,
                completionContract: completionContract,
                progress: { [weak self] request, line in
                    Task { @MainActor [weak self] in
                        self?.appendToolCallOutput(
                            assistantId: assistantID,
                            id: request.callID,
                            chunk: line
                        )
                    }
                }
            )
            NSLog("[ProjectAgent] cold_launch_resume run=%@ state=%@", candidate.id.uuidString, candidate.state.rawValue)
            // Stopped (or the user moved on) while the run was being restored.
            guard ownsStream(assistantID) else {
                await restored.runtime.cancel(runID: restored.handle.runID)
                return
            }
            currentTask = AIRequestGate.startRun { [weak self] in
                guard let self else { return }
                await self.runProjectAgent(
                    runtime: restored.runtime,
                    initialHandle: restored.handle,
                    assistantId: assistantID,
                    routingPrompt: request,
                    model: context.model,
                    plan: plan,
                    projectSessionID: context.projectSessionID,
                    projectID: context.projectID
                )
            }
        } catch {
            NSLog("[ProjectAgent] cold_launch_resume_failed %@", error.localizedDescription)
            // Don't leave the "restoring" placeholder holding `isStreaming`.
            if let restoringAssistantID {
                replacePlaceholder(restoringAssistantID, with: "", append: false)
                failStreaming(assistantId: restoringAssistantID, error: error)
            }
        }
    }

    func load(conversation: ConversationModel) {
        setConversation(conversation)
        self.activeMode = conversation.mode
        // [Stage 2.3] A persisted `entry:<id>` selection points at a provider
        // instance that may since have been deleted or lost its credential.
        // Fall back to the mode default so the request doesn't ship a synthetic
        // id to the built-in Oases endpoint.
        // [P1] Checked via `isSelectionUsable`, not `route(for:)` — the latter
        // only covers OpenAI-compatible instances, so it would wrongly discard
        // a valid Anthropic / Gemini selection (those go through
        // AgentProviderChatBridge).
        let raw = conversation.modelId
        let resolved: String
        if ProviderChatRouting.isEntryId(raw) {
            resolved = ProviderChatRouting.isSelectionUsable(raw)
                ? raw
                : conversation.mode.preferredModel
        } else {
            resolved = Models.sanitizedId(raw, category: conversation.mode.category)
        }
        self.currentModel = resolved
        if resolved != raw {
            conversation.modelId = resolved
        }
        self.messages = conversation.sortedMessages.map { msg in
            let role = ChatUIMessage.Role(rawValue: msg.roleRaw) ?? .user
            let attachments = msg.decodedAttachments.isEmpty ? nil : msg.decodedAttachments
            return ChatUIMessage(
                id: msg.id.uuidString,
                role: role,
                // A user row stores its documents' text after the prompt; the bubble shows the
                // prompt, as it did when it was sent (the text still goes out through `api`).
                content: role == .user
                    ? ChatUIMessage.displayText(persisted: msg.content, attachments: attachments)
                    : msg.content,
                thinking: msg.thinking,
                createdAt: msg.createdAt,
                imageUrl: msg.imageUrl,
                audioUrl: msg.audioUrl,
                audioMimeType: msg.audioMimeType,
                attachments: attachments,
                toolCalls: msg.decodedToolCalls
            )
        }
    }

    func reset() {
        // Session switch / new chat: end the stream generation so the old
        // task's late cleanup can't clear or overwrite the next turn.
        abandonActiveStream()
        messages = []
        input = ""
        activeMode = .chat
        currentModel = Models.preferredChatModel()
        effort = Models.preferredEffort()
        setConversation(nil)
        errorMessage = nil
    }

    /// Reset for a new conversation of the given mode — switches the active
    /// model to the mode's preferred default (mirrors Web `handleCategorySelect`).
    func resetFor(mode: AppMode) {
        reset()
        activeMode = mode
        currentModel = mode.preferredModel
    }


}
