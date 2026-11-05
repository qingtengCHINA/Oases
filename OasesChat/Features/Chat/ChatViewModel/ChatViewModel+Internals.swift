import Foundation
import SwiftUI
import SwiftData

extension ChatViewModel {
    // MARK: - Internals

    func replacePlaceholder(_ id: String, with chunk: String, append: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if append {
            messages[idx].content += chunk
        } else {
            messages[idx].content = chunk
        }
        if id == activeStreamID, !chunk.isEmpty, !AssistantPendingView.isPending(messages[idx].content) {
            liveSignals.didReceiveText(count: chunk.count)
        }
    }

    func setImageMessage(id: String, url: String, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = text
        messages[idx].imageUrl = url
    }

    func setAudioMessage(id: String, url: String, mime: String, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = text
        messages[idx].audioUrl = url
        messages[idx].audioMimeType = mime
    }

    /// True while `assistantId`'s turn still owns the streaming state.
    func ownsStream(_ assistantId: String) -> Bool {
        activeStreamID == assistantId
    }

    /// Ends `assistantId`'s turn. Returns false (and changes nothing) when a
    /// newer turn — or a Stop / session switch — has already taken over, so
    /// a stale task's late cleanup can't clear the new stream's state.
    @discardableResult
    func finishStreaming(assistantId: String, success: Bool) -> Bool {
        guard ownsStream(assistantId) else { return false }
        let charge = pendingQuotaCharge
        activeStreamID = nil
        pendingQuotaCharge = nil
        isStreaming = false
        currentTask = nil
        if success {
            if let charge {
                MembershipCenter.shared.commit(category: charge.category, modelId: charge.modelId)
            }
            Haptics.success()
            // Only a reply worth waiting for gets a sound.
            if let started = streamStartedAt, Date().timeIntervalSince(started) >= 5 {
                SoundEffects.shared.play(.replyDone)
            }
        }
        streamStartedAt = nil
        liveSignals.didFinishRun(failed: !success)
        return true
    }

    /// Abandons whatever turn is active without completing it (Stop, reset).
    func abandonActiveStream() {
        liveSignals.didFinishRun(failed: true)
        activeStreamID = nil
        pendingQuotaCharge = nil
        isStreaming = false
        currentTask?.cancel()
        currentTask = nil
    }

    /// Saves the context, logging and surfacing a failure instead of
    /// silently dropping the write.
    func saveContext(_ ctx: ModelContext, _ reason: String) {
        do {
            try ctx.save()
        } catch {
            NSLog("[ChatViewModel] save failed (\(reason)): \(error.localizedDescription)")
            errorMessage = String(localized: "聊天记录保存失败：\(error.localizedDescription)")
            scheduleBannerDismiss()
        }
    }

    func persistAssistantMessage(id: String) {
        guard let conv = conversation,
              let ctx = modelContext,
              let msg = messages.first(where: { $0.id == id }) else { return }
        let saved = MessageModel(
            role: "assistant",
            content: msg.content,
            thinking: msg.thinking,
            imageUrl: msg.imageUrl,
            audioUrl: msg.audioUrl,
            audioMimeType: msg.audioMimeType,
            toolCalls: msg.toolCalls
        )
        // Share the UI id so retry can find this row by id.
        if let uuid = UUID(uuidString: msg.id) { saved.id = uuid }
        saved.conversation = conv
        ctx.insert(saved)
        conv.messages.append(saved)
        conv.updatedAt = .now
        saveContext(ctx, "assistant message")
    }

    func failStreaming(assistantId: String, error: Error) {
        NSLog("[ChatViewModel] streaming failed: \(error.localizedDescription)")
        // A superseded turn (stopped, or replaced by a newer send / session)
        // must not write an error into the transcript or end the new stream.
        guard ownsStream(assistantId) else { return }
        let displayError = userFacingErrorMessage(for: error)
        // Preserve any partial content already streamed before the failure —
        // don't overwrite it with the error (the user may have gotten useful
        // output before a mid-stream timeout). Only fall back to the error
        // message if nothing was produced at all.
        var recoveredLocally = false
        // Text streamed before the failure (a mid-stream timeout, say) is kept and saved.
        var keptPartial = false
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            let existing = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
            if activeMode == .project,
               assistantNeedsFinalDelivery(assistantId) {
                let fallback = localFinalDelivery(assistantId: assistantId, reason: "模型响应中断：\(displayError)") // i18n-ignore: Ogent final-delivery record (fed back to the model, marker-matched)
                if !fallback.isEmpty {
                    messages[idx].content = fallback
                    recoveredLocally = true
                }
            } else if existing.isEmpty || AssistantPendingView.isPending(existing) {
                if activeMode == .project, let fallback = localFinalDeliveryFromPriorWork(error: error, excluding: assistantId) {
                    messages[idx].content = fallback
                    recoveredLocally = true
                } else {
                    messages[idx].content = "⚠️ \(displayError)"
                }
            } else {
                keptPartial = true
            }
        }
        activeStreamID = nil
        pendingQuotaCharge = nil
        if recoveredLocally {
            errorMessage = nil
            Haptics.success()
            persistAssistantMessage(id: assistantId)
            if activeMode == .project {
                recordProjectTurnMemory(assistantId: assistantId, model: currentModel)
            }
        } else {
            if keptPartial { keepPartialReply(assistantId: assistantId) }
            errorMessage = displayError
            scheduleBannerDismiss()
            Haptics.error()
            SoundEffects.shared.play(.error)
        }
        liveSignals.didFinishRun(failed: !recoveredLocally)
        isStreaming = false
        currentTask = nil
    }

    func userFacingErrorMessage(for error: Error) -> String {
        activeMode == .project
            ? ChatErrorCopy.projectMessage(for: error)
            : ChatErrorCopy.message(for: error)
    }

    func dismissBanner() {
        errorMessage = nil
        dismissTask?.cancel()
    }

    func scheduleBannerDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
    }

    // MARK: - Attachment composition (mirrors Web buildAttachmentPromptBlock + image parts)

    /// Builds the wire content for the current user turn.
    ///
    /// - When the model is vision-capable AND there are image attachments,
    ///   returns a multipart array: a `text` part (prompt + text/file notes)
    ///   followed by `image_url` parts (base64 data URLs) — the OpenAI vision
    ///   format, so the model actually sees the images.
    /// - Otherwise returns a plain string with everything inlined as text
    ///   notes (image attachments get a "not supported" note).
    ///
    /// Also returns the plain-text form for SwiftData persistence.
    /// Builds the wire content for the current user turn — strictly native
    /// OpenAI multipart format. No "[附件：name]" wrappers, no descriptive
    /// noise injected into the prompt, no fabricated content for
    /// unsupported attachments. The model receives exactly:
    ///
    ///   • the user's prompt as a `text` part (or as the bare `content`
    ///     string if there are no attachments at all)
    ///   • each text-extracted attachment as its OWN `text` part, prefixed
    ///     only by a single-line filename header so the model can tell
    ///     them apart
    ///   • each image as a native `image_url` part (when vision-capable)
    ///
    /// The previous version stuffed sentences like "[文件附件: x.pdf]\n
    /// MIME: application/pdf。当前尚未解析该二进制文件正文。" into the
    /// prompt for binary files, which is exactly the message the model
    /// then echoed back as "我无法读取" in the user's screenshot.
    /// We now ALWAYS extract text up-front (PDFKit etc.) before reaching
    /// this function, so by the time we're here every parseable attachment
    /// is already kind = .text. Unparseable binaries are simply omitted
    /// from the wire (the user still sees their chip in the UI).
    ///
    /// Also returns the plain-text form for SwiftData persistence.
    static func composeWireContent(prompt: String, attachments: [Attachment], supportsVision: Bool) -> (MessageContent, String) {
        let textAttachments = attachments.filter { $0.kind == .text }
        let imageAttachments = attachments.filter { $0.kind == .image }
        // Binary attachments without extracted text are not sent on the
        // wire at all — silently dropped. There's nothing useful we can
        // tell the model about a blob it can't read.
        let visionImages = supportsVision
            ? imageAttachments.compactMap { $0.dataUrl }
            : []

        // Persisted text form: prompt + each extracted file's text, joined
        // with light separators. This is what gets saved to SwiftData and
        // shown as the user bubble after send.
        var persistBlocks: [String] = []
        if !prompt.isEmpty { persistBlocks.append(prompt) }
        for item in textAttachments {
            let body = (item.textContent ?? "").prefix(80_000) // soft cap
            persistBlocks.append("# \(item.name)\n\n\(body)")
        }
        if !supportsVision && !imageAttachments.isEmpty {
            persistBlocks.append(String(localized: "（已附加 \(imageAttachments.count) 张图片，当前模型不支持图像输入）"))
        }
        let persistText = persistBlocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // No attachments at all → plain text content, cheapest path.
        // Non-vision image chips still count as attachments for persist/wire
        // notes even though they never become `image_url` parts.
        if textAttachments.isEmpty && visionImages.isEmpty {
            if !supportsVision && !imageAttachments.isEmpty {
                let note = persistText.isEmpty
                    ? String(localized: "（已附加 \(imageAttachments.count) 张图片，当前模型不支持图像输入）")
                    : persistText
                return (.text(note), note)
            }
            return (.text(prompt), prompt)
        }

        // Build native parts. Order: prompt → text-extracted files →
        // images. Empty prompt with attachments still needs an anchor part,
        // so we use the first attachment's content as the implicit prompt
        // rather than injecting "请读取这些附件" noise.
        var parts: [APIContentPart] = []
        if !prompt.isEmpty {
            parts.append(.text(prompt))
        } else if !supportsVision && !imageAttachments.isEmpty {
            parts.append(.text("（已附加 \(imageAttachments.count) 张图片，当前模型不支持图像输入）")) // i18n-ignore: wire-only note for the model
        }
        for item in textAttachments {
            let body = (item.textContent ?? "").prefix(80_000)
            // Single-line filename header is the only framing — the model
            // needs SOMETHING to disambiguate when there are multiple
            // attached docs, but no other narration is injected.
            parts.append(.text("# \(item.name)\n\n\(body)"))
        }
        for url in visionImages {
            parts.append(.image(url: url))
        }

        // If every part is text (no vision images), collapse into a single
        // string content — every OpenAI-compatible proxy handles plain
        // string content; some choke on multi-text-part arrays.
        if parts.allSatisfy({ $0.type == "text" }) {
            let combined = parts.compactMap { $0.text }.joined(separator: "\n\n")
            return (.text(combined), persistText)
        }
        return (.parts(parts), persistText)
    }

    /// Remap retired catalog ids and unusable `entry:` selections before a
    /// request leaves the device.
    func sanitizeCurrentModelIfNeeded() {
        let raw = currentModel
        let next: String
        if ProviderChatRouting.isEntryId(raw) {
            next = ProviderChatRouting.isSelectionUsable(raw)
                ? raw
                : activeMode.preferredModel
        } else {
            next = Models.sanitizedId(raw, category: activeMode.category)
        }
        guard next != raw else { return }
        currentModel = next
        conversation?.modelId = next
    }
}
