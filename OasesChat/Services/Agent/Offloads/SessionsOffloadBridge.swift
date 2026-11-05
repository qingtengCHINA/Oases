//
//  SessionsOffloadBridge.swift
//  OasesChat
//
//  Swift bridge for the sessions CLI offload. Provides synchronous
//  @objc entry points that the `.m` handler calls.
//
//  Read paths (query / search / loadMessages / getSessionStatus) route through
//  the read-only dual-store facade. `getSessionStatus` additionally probes the
//  cache belonging to the resolved session owner without touching its LRU.
//
//  Writes/retry/open remain legacy SwiftData/native `ChatViewModel` paths for
//  native sessions. If an id belongs to engineering-mode `ChatStore`, those
//  mutating entry points return an explicit unsupported error before touching
//  the legacy engine. `SessionsQueryEngine` continues to provide existence
//  checks for the untouched native flows. `ViewModelCache` supplies the
//  engineering UI's `AIChatViewModel` for the status probe only.
//
//    - `sendPrompt`   — resolves/creates the conversation, applies a model
//                       override, materialises `attachmentPaths` into
//                       `Attachment` values, then fires `send(attachments:)`.
//    - `retryMessage` — real truncate-then-retry via
//                       `ChatViewModel.retryFromMessage(_:)`.
//    - `openSession`  — posts `.openSessionFromIntent` and buffers the id in
//                       `NotificationNavigationStore` for the cold-launch path,
//                       i.e. the same route the App Intents use.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

private let logger = AppLogger(category: "SessionsOffload")

@objc public class SessionsOffloadBridge: NSObject {

    // MARK: - List / Search Sessions

    @objc public static func querySessions(
        sessionIds sessionIdFilter: [String]?,
        keywords: [String]?,
        startDate: Date?,
        endDate: Date?,
        limit: Int
    ) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var output: [String: Any] = [:]

        Task.detached {
            let metas = await SessionReadFacade.shared.listSessions(
                sessionIds: sessionIdFilter,
                keywords: keywords,
                limit: limit,
                startDate: startDate,
                endDate: endDate
            )
            let dicts = metas.map { m -> [String: Any] in
                [
                    "session_id": m.id,
                    "title": m.title ?? "",
                    "started_at": ISO8601DateFormatter().string(from: m.startedAt),
                    "last_active": ISO8601DateFormatter().string(from: m.lastActive),
                    "message_count": m.messageCount,
                    "model_id": m.modelId ?? "",
                    "pinned": m.pinnedAt != nil,
                ]
            }
            output = [
                "ok": true,
                "action": "query",
                "count": dicts.count,
                "sessions": dicts,
            ]
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }

    @objc public static func searchMessages(
        sessionIds sessionIdFilter: [String]?,
        keywords: [String],
        startDate: Date?,
        endDate: Date?,
        limit: Int
    ) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var output: [String: Any] = [:]

        Task.detached {
            let hits = await SessionReadFacade.shared.searchMessages(
                sessionIds: sessionIdFilter,
                keywords: keywords,
                limit: limit,
                startDate: startDate,
                endDate: endDate
            )
            let dicts = hits.map { h -> [String: Any] in
                [
                    "session_id": h.sessionId,
                    "session_title": h.sessionTitle ?? "",
                    "message_id": h.messageId,
                    "role": h.role,
                    "created_at": ISO8601DateFormatter().string(from: h.createdAt),
                    "snippet": h.snippet,
                ]
            }
            output = [
                "ok": true,
                "action": "search",
                "count": dicts.count,
                "matches": dicts,
            ]
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }

    @objc public static func loadMessages(
        sessionId: String,
        offset: Int,
        limit: Int,
        full: Bool
    ) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var output: [String: Any] = [:]
        let maxChars = full ? Int.max : 1000

        Task.detached {
            let total = await SessionReadFacade.shared.messageCount(sessionId: sessionId)
            let page = await SessionReadFacade.shared.loadMessagePage(
                sessionId: sessionId,
                offset: offset,
                limit: limit,
                maxChars: maxChars
            )
            let dicts = page.map { row -> [String: Any] in
                [
                    "message_id": row.messageId,
                    "role": row.role,
                    "created_at": ISO8601DateFormatter().string(from: row.createdAt),
                    "text": row.text,
                    "truncated": row.truncated,
                ]
            }
            output = [
                "ok": true,
                "action": "load_messages",
                "session_id": sessionId,
                "offset": offset,
                "limit": limit,
                "total": total,
                "count": dicts.count,
                "messages": dicts,
            ]
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }

    // MARK: - Mutating paths

    /// Materialise host file paths handed over by the guest CLI into
    /// `Attachment` values.
    ///
    /// The `.m` handler already resolved each `--attach` argument through
    /// `noff_resolve_guest_path_strict` (guest-visible session buckets and the
    /// rootfs only) and rejects the command otherwise. Whatever reaches this
    /// point is sent to the model, so paths are checked again against
    /// `OffloadPathGuard.isAllowedAttachmentHostPath` before reading. Text-ish
    /// files become `.text` attachments carrying their decoded contents;
    /// everything else becomes a base64 `data:` URL so the provider layer can
    /// ship it without a second filesystem hop.
    ///
    /// Unreadable or oversized entries are skipped and logged rather than
    /// failing the whole send — a CLI caller that mistyped one path still gets
    /// its prompt through.
    nonisolated static func attachments(
        fromHostPaths paths: [String],
        isAllowed: (String) -> Bool = { OffloadPathGuard.isAllowedAttachmentHostPath($0) }
    ) -> [Attachment] {
        /// Matches the composer's own ceiling; base64 inflates by ~4/3 and the
        /// request budget rejects anything larger anyway.
        let maxBytes = 8 * 1024 * 1024
        var built: [Attachment] = []

        for path in paths {
            guard isAllowed(path) else {
                logger.warning("[attachments] outside the guest sandbox, skipped: \(path)")
                continue
            }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                logger.warning("[attachments] unreadable, skipped: \(path)")
                continue
            }
            guard data.count <= maxBytes else {
                logger.warning("[attachments] \(name) is \(data.count)B > \(maxBytes)B limit, skipped")
                continue
            }

            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            let mime = type?.preferredMIMEType ?? "application/octet-stream"

            if type?.conforms(to: .image) == true {
                built.append(Attachment(
                    name: name,
                    mimeType: mime,
                    kind: .image,
                    dataUrl: "data:\(mime);base64,\(data.base64EncodedString())"
                ))
            } else if type?.conforms(to: .text) == true,
                      let text = String(data: data, encoding: .utf8) {
                built.append(Attachment(
                    name: name,
                    mimeType: mime,
                    kind: .text,
                    textContent: text
                ))
            } else {
                built.append(Attachment(
                    name: name,
                    mimeType: mime,
                    kind: .file,
                    dataUrl: "data:\(mime);base64,\(data.base64EncodedString())"
                ))
            }
        }

        if built.count != paths.count {
            logger.info("[attachments] materialised \(built.count)/\(paths.count)")
        }
        return built
    }

    /// Result for a send/retry refused in limited mode. Read by the guest
    /// CLI (and the model driving it), so it stays English.
    static func consentRequiredResult(action: String, sessionId: String?) -> [String: Any] {
        [
            "ok": false,
            "action": action,
            "session_id": sessionId ?? "",
            "error": "ai_data_sharing_consent_required",
            "reason": "AI data sharing is off on this device. Agree to it in the Oases app before sending to a model.",
        ]
    }

    @objc public static func sendPrompt(
        sessionId: String?,
        prompt: String,
        attachmentPaths: [String],
        modelEntryId: String?,
        source: String
    ) -> NSDictionary {
        // Limited mode (the terminal works there): refuse before a session is
        // created or the composer is touched. Checked off the main actor —
        // the consent read is a plain UserDefaults lookup.
        if !AIDataSharingConsent.isAccepted {
            return consentRequiredResult(action: "send", sessionId: sessionId) as NSDictionary
        }
        // Same semaphore + Task.detached pattern OpenMinis uses — the .m
        // handler runs on a guest thread and expects a synchronous return.
        let sem = DispatchSemaphore(value: 0)
        var output: [String: Any] = [:]

        Task.detached { @MainActor in
            // Resolve / create the VM.
            let vm: ChatViewModel
            var isNew = false
            var resolvedSid: String

            if let sid = sessionId, !sid.isEmpty {
                // `--session` means an existing native conversation. Resolve
                // ownership before touching the native cache so a cold cache
                // cannot turn an unknown id into a new conversation.
                if let meta = await SessionReadFacade.shared.getSession(id: sid),
                   meta.owner == .engineering {
                    output = [
                        "ok": false,
                        "action": "send",
                        "session_id": sid,
                        "error": "unsupported_engineering_session_mutation",
                        "reason": "Session \(sid) is owned by engineering mode; sendPrompt cannot mutate ChatStore sessions.",
                    ]
                    sem.signal()
                    return
                }
                guard UUID(uuidString: sid) != nil else {
                    output = [
                        "ok": false,
                        "action": "send",
                        "session_id": sid,
                        "error": "invalid_session_id",
                        "reason": "Native session IDs must be existing UUIDs.",
                    ]
                    sem.signal()
                    return
                }
                guard let meta = await SessionReadFacade.shared.getSession(id: sid),
                      meta.owner == .native else {
                    output = [
                        "ok": false,
                        "action": "send",
                        "session_id": sid,
                        "error": "session_not_found",
                        "reason": "Session \(sid) does not exist.",
                    ]
                    sem.signal()
                    return
                }
                let (cached, _) = ChatViewModelCache.shared.getOrCreate(for: meta.id)
                vm = cached
                // A cold cache VM is still an existing native session.
                isNew = false
                resolvedSid = meta.id
            } else {
                // No session id — spin up a new conversation row.
                vm = ChatViewModelCache.shared.createDraft()
                isNew = true
                let context = ModelContext(ConversationContainer.shared)
                let conv = ConversationModel()
                conv.title = prompt.isEmpty ? String(localized: "New Session", comment: "Title of a session created without a prompt") : String(prompt.prefix(40))
                context.insert(conv)
                try? context.save()
                vm.bind(context: context)
                vm.load(conversation: conv)
                resolvedSid = conv.id.uuidString
                ChatViewModelCache.shared.adopt(vm, conversationId: resolvedSid)
            }

            // Apply model override if requested. OasesChat's ChatViewModel
            // exposes `currentModel` as a String model id — set it directly
            // when the caller passed a known entry id.
            if let entryId = modelEntryId, !entryId.isEmpty {
                let store = ProviderConfigStore.shared
                if let entry = store.entry(for: entryId) {
                    vm.currentModel = entry.model.id
                }
            }

            // Materialise the attachment paths the CLI handed over. Done before
            // the send so a partially-unreadable set still produces a coherent
            // count in the response.
            let staged = attachments(fromHostPaths: attachmentPaths)

            // Fire the send. OasesChat's `send()` is async; we don't await
            // completion (the .m handler's 90s timeout would block the
            // semaphore anyway). The CLI caller polls `getSessionStatus`
            // for completion — same pattern as OpenMinis when
            // `waitForResult` is false.
            vm.input = prompt
            Task { @MainActor in
                await vm.send(attachments: staged)
            }

            output = [
                "ok": true,
                "action": "send",
                "session_id": resolvedSid,
                "is_new_session": isNew,
                "model_name": vm.currentModel,
                "status": vm.isStreaming ? "Running" : "Queued",
                "prompt": prompt,
                "attachments_staged": staged.count,
                "attachments_requested": attachmentPaths.count,
                "response_text": "",
            ]
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }

    @objc public static func retryMessage(
        sessionId: String,
        messageId: String?,
        attachmentPaths: [String]
    ) -> NSDictionary {
        // Like SessionsOffloadBridge.sendPrompt, this needs a synchronous
        // return shape but the native ChatViewModel work is async; bounce
        // through a semaphore. Session existence remains a legacy SwiftData
        // check, while the cached native vm supplies the transcript and
        // retryFromMessage(_:replacementAttachments:) performs the retry.
        var output: [String: Any] = [
            "ok": false,
            "action": "retry",
            "session_id": sessionId,
        ]

        // Before the transcript is truncated (see sendPrompt).
        if !AIDataSharingConsent.isAccepted {
            return consentRequiredResult(action: "retry", sessionId: sessionId) as NSDictionary
        }

        guard !sessionId.isEmpty else {
            output["error"] = "missing_session"
            output["reason"] = "retryMessage requires a session_id."
            return output as NSDictionary
        }

        let sem = DispatchSemaphore(value: 0)
        let resolvedMessageId = messageId
        Task { @MainActor in
            // ChatStore owns engineering-mode sessions. Keep them out of this
            // legacy SwiftData/native retry path instead of reporting a
            // misleading session_not_found result.
            if let meta = await SessionReadFacade.shared.getSession(id: sessionId),
               meta.owner == .engineering {
                output["error"] = "unsupported_engineering_session_mutation"
                output["reason"] = "Session \(sessionId) is owned by engineering mode; retryMessage cannot mutate ChatStore sessions."
                sem.signal()
                return
            }

            // Confirm the session exists before touching the vm.
            let exists = await SessionsQueryEngine.shared.getSession(id: sessionId) != nil
            guard exists else {
                output["error"] = "session_not_found"
                output["reason"] = "Session \(sessionId) does not exist."
                sem.signal()
                return
            }

            let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sessionId)

            // Resolve target message. Prefer an exact id match on a user
            // message; fall back to the most recent user message.
            let userMessages = vm.messages.filter { $0.role == .user }
            guard let target = (resolvedMessageId.flatMap { id in
                userMessages.first(where: { $0.id == id })
            }) ?? userMessages.last else {
                output["error"] = "no_user_message"
                output["reason"] = "No user message found to retry (messageId=\(resolvedMessageId ?? "nil"))."
                sem.signal()
                return
            }

            // Truncate-and-retry: removes the target + every newer message
            // (DB + UI), then re-sends the target's content as a fresh turn.
            // A non-empty `attachmentPaths` replaces the original message's
            // attachments; empty keeps whatever the target already carried.
            let staged = attachmentPaths.isEmpty
                ? nil
                : attachments(fromHostPaths: attachmentPaths)
            vm.retryFromMessage(target.id, replacementAttachments: staged)

            output["ok"] = true
            output["message_id"] = target.id
            output["prompt"] = target.content
            output["model_name"] = vm.currentModel
            output["status"] = vm.isStreaming ? "Running" : "Queued"
            output["attachments_staged"] = staged?.count ?? 0
            output["attachments_requested"] = attachmentPaths.count
            output["note"] = "Truncated everything after target and re-ran."
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }

    @objc public static func openSession(sessionId: String) -> NSDictionary {
        // Route through the same path the App Intents use: buffer the id for the
        // cold-launch case (RootView's `.onReceive` isn't mounted yet) and post
        // the notification for the warm case. Previously this only logged and
        // returned ok:true, which reported success for work that never happened.
        var output: [String: Any] = [
            "ok": false,
            "action": "open_session",
            "session_id": sessionId,
        ]
        guard !sessionId.isEmpty, UUID(uuidString: sessionId) != nil else {
            output["error"] = "invalid_session_id"
            output["reason"] = "openSession needs a conversation UUID."
            return output as NSDictionary
        }

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            // Opening an engineering-mode id through the legacy notification
            // path is deliberately unsupported; do not fall through to the
            // native SwiftData existence check.
            if let meta = await SessionReadFacade.shared.getSession(id: sessionId),
               meta.owner == .engineering {
                output["error"] = "unsupported_engineering_session_mutation"
                output["reason"] = "Session \(sessionId) is owned by engineering mode; openSession cannot use the legacy session path."
                sem.signal()
                return
            }

            let exists = await SessionsQueryEngine.shared.getSession(id: sessionId) != nil
            guard exists else {
                output["error"] = "session_not_found"
                output["reason"] = "Session \(sessionId) does not exist."
                sem.signal()
                return
            }
            await MainActor.run {
                NotificationNavigationStore.shared.setPending(sessionId)
                NotificationCenter.default.post(
                    name: .openSessionFromIntent,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
            output["ok"] = true
            output["note"] = "Requested foreground open; the app switches session when it is frontmost."
            sem.signal()
        }
        sem.wait()
        logger.info("[SessionsOffload] openSession: \(sessionId) ok=\(output["ok"] as? Bool ?? false)")
        return output as NSDictionary
    }

    @objc public static func getSessionStatus(sessionId: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var output: [String: Any] = [:]
        Task.detached {
            let meta = await SessionReadFacade.shared.getSession(id: sessionId)
            let total = meta?.messageCount ?? 0
            // Probe the cache that owns this session without touching its LRU.
            // A native send uses ChatViewModel.isStreaming; engineering mode
            // uses AIChatViewModel.isProcessing.
            let running = await MainActor.run {
                guard let owner = meta?.owner else { return false }
                switch owner {
                case .engineering:
                    return ViewModelCache.shared.isProcessing(sessionId: meta?.id ?? sessionId)
                case .native:
                    return ChatViewModelCache.shared.isStreaming(conversationId: meta?.id ?? sessionId)
                }
            }
            output = [
                "ok": true,
                "session_id": sessionId,
                "exists": meta != nil,
                "message_count": total,
                "running": running,
                "title": meta?.title ?? "",
                "last_active": meta.map { ISO8601DateFormatter().string(from: $0.lastActive) } ?? "",
            ]
            sem.signal()
        }
        sem.wait()
        return output as NSDictionary
    }
}
