import Foundation
import SwiftUI
import SwiftData

extension ChatViewModel {
    // MARK: - Sending

    func send(attachments: [Attachment] = []) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), !isStreaming else { return }
        // Defense in depth for limited mode: the composer asks for consent
        // before calling this, so getting here without it means a caller
        // skipped the sheet. Return before anything is consumed — `input`,
        // the attachments and the transcript stay exactly as they were.
        guard AIDataSharingConsent.isAccepted else {
            NSLog("[ChatViewModel] send_blocked consent_required=1")
            return
        }

        let category = activeMode.category
        if category == .audio, trimmed.isEmpty { return }
        if category == .image,
           trimmed.isEmpty,
           !attachments.contains(where: { $0.kind == .image }) {
            return
        }

        sanitizeCurrentModelIfNeeded()
        if let denial = MembershipCenter.shared.authorize(category: category, modelId: currentModel) {
            MembershipCenter.shared.present(denial)
            return
        }
        // Charged when the turn finishes successfully (`finishStreaming`),
        // so a failed or cancelled request doesn't use up a daily send.
        let quotaCharge = (category: category, modelId: currentModel)
        SoundEffects.shared.play(.send)

        // Image / audio modes ignore attachments on the wire (mirrors Web —
        // only text/project inline them), but we still surface them on the
        // user bubble for context. For text/project we build a wire content
        // that is either a plain string or a multipart array (image_url parts)
        // when the model is vision-capable — so attached images are actually
        // seen by the model, not just noted in text.
        //
        // Use the category-aware lookup: `gpt-5.4` exists in both the
        // chat and project lists with DIFFERENT vision support, so the
        // global `option(for:)` reads the wrong row in project mode.
        // [Stage 2.3] A user-configured provider entry carries its own modality
        // metadata; fall back to the built-in catalog for Oases models.
        let supportsVision = ProviderChatRouting.selectedOption(for: currentModel)?.supportsImageInput
            ?? (Models.option(for: currentModel, category: category)?.supportsImageInput ?? false)
        let composedContent = (category == .text || category == .project)
            ? Self.composeWireContent(prompt: trimmed, attachments: attachments, supportsVision: supportsVision)
            : (MessageContent.text(trimmed.isEmpty ? String(localized: "（附件）") : trimmed),
               trimmed.isEmpty ? String(localized: "（附件）") : trimmed)
        let wireContent = composedContent.0
        let persistText = composedContent.1.isEmpty ? String(localized: "（附件）") : composedContent.1

        // Create conversation on first send if needed
        if conversation == nil, let ctx = modelContext {
            let mode = activeMode
            let conv = ConversationModel(mode: mode, modelId: currentModel)
            ctx.insert(conv)
            setConversation(conv)
        }
        if let conv = conversation { conv.modelId = currentModel }

        let userMessage = ChatUIMessage.user(
            trimmed.isEmpty ? persistText : trimmed,
            attachments: attachments.isEmpty ? nil : attachments
        )
        messages.append(userMessage)
        input = ""
        Haptics.tap()

        // Persist user message — SwiftData stores a plain string, so the
        // image parts are flattened to the text portion only.
        if let conv = conversation, let ctx = modelContext {
            let saved = MessageModel(role: "user", content: persistText, attachments: attachments)
            // Share the UI id so retry can find this row by id.
            if let uuid = UUID(uuidString: userMessage.id) { saved.id = uuid }
            saved.conversation = conv
            ctx.insert(saved)
            if conv.title == "新对话" { // i18n-ignore: persisted default-title sentinel
                conv.title = trimmed.isEmpty
                    ? String(localized: "附件", comment: "Conversation title when the first message only has attachments")
                    : String(trimmed.prefix(30))
            }
            conv.messages.append(saved)
            conv.updatedAt = .now
            saveContext(ctx, "user message")
        }

        if category == .project {
            // Placeholder first: it flips `isStreaming` (so a second send is
            // rejected) and shows the loader while the preflight below runs —
            // profile installs can take minutes. The preflight runs inside
            // `currentTask`, so Stop cancels it before the agent run starts.
            let assistantId = makeAssistantPlaceholder(quotaCharge: quotaCharge)
            let preflightWireContent = wireContent
            currentTask = AIRequestGate.startRun { [weak self] in
                await self?.prepareAndSendProjectTurn(
                    trimmed: trimmed,
                    persistText: persistText,
                    wireContent: preflightWireContent,
                    assistantId: assistantId
                )
            }
            return
        }

        switch category {
        case .image:
            // Image-mode forwards image attachments as reference images so the
            // proxy can run image-to-image when supported. Text/file
            // attachments are surfaced in the prompt for context.
            let refImages = attachments.compactMap { $0.kind == .image ? $0.dataUrl : nil }
            let imagePrompt = trimmed.isEmpty ? "请根据参考图生成" : trimmed // i18n-ignore: model-facing image prompt
            await sendImage(prompt: imagePrompt,
                            referenceImages: refImages,
                            assistantId: makeAssistantPlaceholder(content: "正在生成图片…", quotaCharge: quotaCharge)) // i18n-ignore: placeholder sentinel matched by AssistantPendingView
        case .audio:
            await sendAudio(prompt: trimmed, assistantId: makeAssistantPlaceholder(content: "正在合成语音…", quotaCharge: quotaCharge)) // i18n-ignore: placeholder sentinel matched by AssistantPendingView
        case .text, .project:
            await sendChat(userWireContent: wireContent, assistantId: makeAssistantPlaceholder(quotaCharge: quotaCharge), routingPrompt: trimmed)
        }
    }

    /// Engineering-mode preflight (routing note, iSH profile preparation,
    /// memory context, host session record) followed by the agent run. Runs
    /// as `currentTask` behind the placeholder created by `send`.
    func prepareAndSendProjectTurn(
        trimmed: String,
        persistText: String,
        wireContent initialWireContent: MessageContent,
        assistantId: String
    ) async {
        var wireContent = initialWireContent
        var projectHandle: OgentProjectTurnHandle?
        let projectPlan = ProjectAgentPlanner.plan(for: trimmed, iteration: 1, executedToolCalls: 0)
        wireContent = await projectWireContentWithLocalContextIfNeeded(
            prompt: trimmed,
            wireContent: wireContent,
            routePlan: projectPlan
        )
        let title = conversation?.title ?? "工程模式" // i18n-ignore: Ogent session record (agent-facing)
        let conversationID = conversation?.id.uuidString ?? "unsaved"
        if projectPlan.exposesTools, !Task.isCancelled {
            projectHandle = await OgentProjectSessionRecorder.recordTurnStart(
                conversationTitle: title,
                conversationID: conversationID,
                model: currentModel,
                userPrompt: persistText,
                plan: projectPlan
            )
            if projectHandle == nil {
                NSLog("[OgentSession] failed to record project turn preflight")
            }
        }
        // Stopped (or replaced by a newer turn / session) during the
        // preflight: don't start the agent run.
        guard !Task.isCancelled, ownsStream(assistantId) else {
            setStreamingFlag(assistantId, false)
            finishStreaming(assistantId: assistantId, success: false)
            return
        }
        if let projectHandle {
            wireContent = Self.prependingText(
                // i18n-ignore: model-facing prompt
                """
                [Ogent host session]
                session_id=\(projectHandle.sessionID)
                project_id=\(projectHandle.projectID ?? "none")
                本轮工程任务的 tool trace、lifecycle、artifact/交付记录都绑定到这个本机 iSH/Ogent session 与 project manifest。需要读取或补写会话时，优先使用 `ogent_agent session_read/session_note` 并传入 sessionID；需要记录阶段、产物或恢复状态时，使用 `ogent_agent project_manifest_update/read` 并传入 projectID。
                [/Ogent host session]
                """,
                to: wireContent
            )
        }
        await sendProjectOrChat(
            category: .project,
            wireContent: wireContent,
            trimmed: trimmed,
            assistantId: assistantId,
            projectSessionID: projectHandle?.sessionID,
            projectID: projectHandle?.projectID
        )
    }

    func sendProjectOrChat(
        category: Models.Category,
        wireContent: MessageContent,
        trimmed: String,
        assistantId: String,
        projectSessionID: String?,
        projectID: String?
    ) async {
        switch category {
        case .text, .project:
            await sendChat(
                userWireContent: wireContent,
                assistantId: assistantId,
                routingPrompt: trimmed,
                projectSessionID: projectSessionID,
                projectID: projectID
            )
        case .image, .audio:
            return
        }
    }

    func stop() {
        // The turn being stopped: what it already streamed is kept (below).
        let stoppedAssistantId = activeStreamID
        // Ends the stream generation too, so the cancelled task's late
        // cleanup can't touch a turn started right after this.
        abandonActiveStream()

        // Tear down production agent + guest shells so stop actually kills work.
        let runtime = activeProjectRuntime
        let runID = activeProjectRunID
        let sessionID = activeProjectSessionID
        activeProjectRuntime = nil
        activeProjectRunID = nil
        Task {
            if let runtime, let runID {
                await runtime.cancel(runID: runID)
            }
            if let sessionID {
                _ = await ISHRuntimeService.shared.cancelAll(sessionId: sessionID)
            }
            // Only commands without a session scope — a global cancel would
            // also kill other sessions' shells (engineering mode, other chats).
            _ = await ISHRuntimeService.shared.cancelUnscoped()
        }

        // Drop a trailing assistant placeholder that never produced any
        // content (or only carries an "正在生成…" pending marker). Otherwise
        // the UI is stuck rendering MatrixLoader forever after a manual stop.
        if let last = messages.last,
           last.role == .assistant,
           last.imageUrl == nil,
           last.audioUrl == nil,
           AssistantPendingView.isPending(last.content) {
            messages.removeLast()
        } else if let stoppedAssistantId {
            // A reply that already has text: the user saw it and may build on it, so it is
            // saved like a finished one (it used to live only in memory and vanish on the next
            // session switch, and later turns' history went without it).
            keepPartialReply(assistantId: stoppedAssistantId)
        }
    }

    /// Saves the part of a stopped or failed reply that was already streamed. Nothing is saved
    /// when the turn produced no text (or only the pending marker).
    func keepPartialReply(assistantId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantId }),
              messages[idx].role == .assistant else { return }
        messages[idx].isStreaming = false
        let text = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !AssistantPendingView.isPending(text) else { return }
        persistAssistantMessage(id: assistantId)
    }


}
