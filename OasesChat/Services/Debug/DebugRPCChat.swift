#if DEBUG
import Foundation
import SwiftData

/// [T-debug-chat-rpc] Debug JSON-RPC surface for OasesChat's chat/sessions
/// subsystem.
///
/// Differs from OpenMinis' `DebugRPCProviderChat`:
/// - Provider CRUD (`provider.types/instancesList/.../groupsList/...`) lives
///   behind a different `ProviderConfigStore` architecture in OasesChat —
///   those methods are intentionally NOT exposed here. A future iteration can
///   port the provider-side RPC after the Providers stack lands.
/// - Session/message read paths go through the read-only dual-store facade;
///   engineering-session mutations are explicitly unsupported here so their
///   ids cannot fall through to legacy SwiftData/native paths.
/// - `chat.prompt` still drives native sessions through `ChatViewModelCache`
///   exactly like `SendPromptIntent` does — fire-and-forget by default,
///   `await` if `waitForResult: true`. Engineering-session prompt requests
///   are rejected before that cache is touched.
@MainActor
enum DebugRPCChat {

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - Sessions

    /// `chat.sessions.list` → metadata for every session, newest first.
    /// Params: { limit?: int (default 100), keywords?: [string] }
    static func sessionsList(params: [String: Any]) async -> [String: Any] {
        let limit = (params["limit"] as? Int) ?? 100
        let keywords = (params["keywords"] as? [String]) ?? []
        let metas = await SessionReadFacade.shared.listSessions(
            sessionIds: nil, keywords: keywords, limit: limit
        )
        let dicts = metas.map { sessionDict($0) }
        return ["count": dicts.count, "sessions": dicts]
    }

    /// `chat.sessions.get` → metadata for one session.
    /// Params: { sessionId: string }
    static func sessionsGet(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        guard let meta = await SessionReadFacade.shared.getSession(id: sid) else {
            throw DebugRPCErr(-32004, "Session '\(sid)' not found.")
        }
        return sessionDict(meta)
    }

    /// `chat.session.delete` → delete a session and cascade its messages.
    /// Params: { sessionId: string }
    static func sessionDelete(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        // ChatStore rows are engineering-mode sessions and are read-only from
        // this legacy SwiftData mutation surface.
        if let meta = await SessionReadFacade.shared.getSession(id: sid),
           meta.owner == .engineering {
            throw DebugRPCErr(
                -32010,
                "unsupported_engineering_session_mutation: session '\(sid)' is owned by ChatStore; session delete is unsupported."
            )
        }
        guard let uuid = UUID(uuidString: sid) else {
            throw DebugRPCErr(-32602, "Malformed sessionId: \(sid)")
        }
        let existed = (await SessionsQueryEngine.shared.getSession(id: sid)) != nil
        try await MainActor.run {
            let context = ModelContext(ConversationContainer.shared)
            if let conv = try context.fetch(FetchDescriptor<ConversationModel>(
                predicate: #Predicate { $0.id == uuid }
            )).first {
                context.delete(conv)
                try context.save()
            }
        }
        // Drop the cached vm so subsequent calls don't resurrect it.
        ChatViewModelCache.shared.remove(conversationId: sid)
        return ["ok": true, "deleted": existed, "sessionId": sid]
    }

    // MARK: - Messages

    /// `chat.messages.list` → paginated message rows.
    /// Params: { sessionId: string, offset?: int (default 0),
    ///           limit?: int (default 20), maxChars?: int (default 1000) }
    static func messagesList(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        let offset = (params["offset"] as? Int) ?? 0
        let limit = (params["limit"] as? Int) ?? 20
        let maxChars = (params["maxChars"] as? Int) ?? 1000
        let rows = await SessionReadFacade.shared.loadMessagePage(
            sessionId: sid, offset: offset, limit: limit, maxChars: maxChars
        )
        let dicts = rows.map { row -> [String: Any] in
            [
                "messageId": row.messageId,
                "role": row.role,
                "createdAt": iso8601(row.createdAt),
                "text": row.text,
                "truncated": row.truncated,
            ]
        }
        let total = await SessionReadFacade.shared.messageCount(sessionId: sid)
        return [
            "count": dicts.count,
            "messages": dicts,
            "offset": offset,
            "limit": limit,
            "totalInSession": total,
        ]
    }

    /// `chat.messages.count` → integer count.
    /// Params: { sessionId: string }
    static func messagesCount(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        let total = await SessionReadFacade.shared.messageCount(sessionId: sid)
        return ["sessionId": sid, "count": total]
    }

    // MARK: - Session state

    /// `chat.session.status` → in-memory liveness for the resolved owner.
    /// Params: { sessionId: string }
    static func sessionStatus(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        let meta = await SessionReadFacade.shared.getSession(id: sid)
        let resolvedId = meta?.id ?? sid
        let status: (running: Bool, hasViewModel: Bool, messageCount: Int) = {
            switch meta?.owner {
            case .engineering:
                return (
                    ViewModelCache.shared.isProcessing(sessionId: resolvedId),
                    ViewModelCache.shared.hasCached(sessionId: resolvedId),
                    meta?.messageCount ?? 0
                )
            case .native:
                return (
                    ChatViewModelCache.shared.isStreaming(conversationId: resolvedId),
                    ChatViewModelCache.shared.hasCached(conversationId: resolvedId),
                    meta?.messageCount ?? 0
                )
            case nil:
                return (false, false, 0)
            }
        }()
        return [
            "sessionId": sid,
            "isStreaming": status.running,
            "isProcessing": status.running,
            "hasViewModel": status.hasViewModel,
            "messageCount": status.messageCount,
        ]
    }

    /// `chat.session.cancel` → cancel an in-flight VM from the owning store.
    /// Params: { sessionId: string }
    static func sessionCancel(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        let meta = await SessionReadFacade.shared.getSession(id: sid)
        let resolvedId = meta?.id ?? sid
        let wasProcessing: Bool
        switch meta?.owner {
        case .engineering:
            let vm = ViewModelCache.shared.get(for: resolvedId)
            wasProcessing = vm?.isProcessing ?? false
            vm?.cancel()
        case .native:
            let vm = ChatViewModelCache.shared.get(for: resolvedId)
            wasProcessing = vm?.isStreaming ?? false
            vm?.stop()
        case nil:
            wasProcessing = false
        }
        return [
            "ok": true,
            "sessionId": sid,
            "wasStreaming": wasProcessing,
            "wasProcessing": wasProcessing,
        ]
    }

    // MARK: - Prompt

    /// `chat.prompt` → send a prompt to a session (existing or new).
    /// Params: { prompt: string, sessionId?: string (omit/empty for new),
    ///           waitForResult?: bool (default false) }
    static func prompt(params: [String: Any]) async throws -> [String: Any] {
        guard let prompt = params["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'prompt' (non-empty string).")
        }
        let waitForResult = (params["waitForResult"] as? Bool) ?? false

        let sid: String
        let isNewSession: Bool
        if let provided = params["sessionId"] as? String, !provided.isEmpty {
            sid = provided
            isNewSession = false
            // Engineering-mode ChatStore sessions are read-only through this
            // native prompt surface; reject before touching SwiftData/cache.
            if let meta = await SessionReadFacade.shared.getSession(id: sid),
               meta.owner == .engineering {
                throw DebugRPCErr(
                    -32010,
                    "unsupported_engineering_session_mutation: session '\(sid)' is owned by ChatStore; prompt is unsupported."
                )
            }
            // Confirm a legacy/native session exists.
            guard await SessionsQueryEngine.shared.getSession(id: sid) != nil else {
                throw DebugRPCErr(-32004, "Session '\(sid)' not found.")
            }
        } else {
            let context = ModelContext(ConversationContainer.shared)
            let conv = ConversationModel()
            conv.title = String(prompt.prefix(30))
            context.insert(conv)
            try? context.save()
            sid = conv.id.uuidString
            isNewSession = true
        }

        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)
        vm.input = prompt

        if waitForResult {
            await vm.send()
            let responseText = (vm.messages.last(where: { $0.role == .assistant })?.content)
                ?? "No response."
            return [
                "ok": true,
                "sessionId": sid,
                "isNewSession": isNewSession,
                "status": "Completed",
                "responseText": responseText,
            ]
        }

        // Fire-and-forget.
        Task { @MainActor in
            await vm.send()
        }
        return [
            "ok": true,
            "sessionId": sid,
            "isNewSession": isNewSession,
            "status": "Running",
        ]
    }

    // MARK: - Session replay (SessionDataSimulator)

    /// `chat.simulate.load` → parse "Copy Session Data" JSON into the
    /// simulator's in-memory buffer.
    /// Params: { json: string }
    static func simulateLoad(params: [String: Any]) throws -> [String: Any] {
        guard let json = params["json"] as? String, !json.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'json' (string).")
        }
        let count = SessionDataSimulator.shared.loadSessionData(json)
        guard let n = count else {
            throw DebugRPCErr(-32700, "Failed to parse 'json' as [[String: Any]].")
        }
        return ["ok": true, "loaded": n, "state": "\(SessionDataSimulator.shared.state)"]
    }

    /// `chat.simulate.replay` → replay the loaded entries into the target
    /// session, streaming assistant turns char-by-char.
    /// Params: { sessionId: string,
    ///           charsPerTick?: int (default 20),
    ///           tickIntervalMs?: int (default 30) }
    static func simulateReplay(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = params["sessionId"] as? String, !sid.isEmpty else {
            throw DebugRPCErr(-32602, "Missing required 'sessionId' (string).")
        }
        if let cpt = params["charsPerTick"] as? Int, cpt > 0 {
            SessionDataSimulator.shared.charsPerTick = cpt
        }
        if let ms = params["tickIntervalMs"] as? Int, ms > 0 {
            SessionDataSimulator.shared.tickInterval = TimeInterval(ms) / 1000.0
        }
        let inserted = await SessionDataSimulator.shared.replay(into: sid)
        return [
            "ok": true,
            "sessionId": sid,
            "inserted": inserted,
            "state": "\(SessionDataSimulator.shared.state)",
            "progress": SessionDataSimulator.shared.progress,
        ]
    }

    /// `chat.simulate.status` → current state + buffer size.
    static func simulateStatus() -> [String: Any] {
        return [
            "state": "\(SessionDataSimulator.shared.state)",
            "progress": SessionDataSimulator.shared.progress,
            "parsedEntries": SessionDataSimulator.shared.parsedEntriesCount,
            "charsPerTick": SessionDataSimulator.shared.charsPerTick,
            "tickIntervalMs": Int(SessionDataSimulator.shared.tickInterval * 1000),
        ]
    }

    /// `chat.simulate.pause` → pause an in-flight replay.
    static func simulatePause() -> [String: Any] {
        SessionDataSimulator.shared.pause()
        return ["ok": true, "state": "\(SessionDataSimulator.shared.state)"]
    }

    /// `chat.simulate.resume` → resume a paused replay.
    static func simulateResume() -> [String: Any] {
        SessionDataSimulator.shared.resume()
        return ["ok": true, "state": "\(SessionDataSimulator.shared.state)"]
    }

    /// `chat.simulate.cancel` → cancel + drop buffer.
    static func simulateCancel() -> [String: Any] {
        SessionDataSimulator.shared.reset()
        return ["ok": true, "state": "\(SessionDataSimulator.shared.state)"]
    }

    // MARK: - Helpers

    private static func sessionDict(_ m: SessionReadFacade.SessionMeta) -> [String: Any] {
        var d: [String: Any] = [
            "sessionId": m.id,
            "title": m.title ?? "",
            "startedAt": iso8601(m.startedAt),
            "lastActive": iso8601(m.lastActive),
            "messageCount": m.messageCount,
            "modelId": m.modelId ?? "",
        ]
        if let pinnedAt = m.pinnedAt {
            d["pinnedAt"] = iso8601(pinnedAt)
        }
        return d
    }
}
#endif
