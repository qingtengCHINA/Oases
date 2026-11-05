#if DEBUG
import Foundation
import WebKit
import UIKit
import CloudKit
import AVFoundation
import SQLite3

/// In-memory ring buffer of screenshots for time-correlated debugging.
/// Captures are tagged with timestamp and optional label. Max 20 entries (~2MB at 0.5x scale).
final class DebugScreenshotBuffer: @unchecked Sendable {
    static let shared = DebugScreenshotBuffer()

    struct Entry {
        let id: Int
        let label: String
        let date: Date
        let pngData: Data

        var iso: String {
            Self.formatter.string(from: date)
        }
        private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
    }

    private var entries: [Entry] = []
    private var nextId = 1
    private let maxEntries = 20
    private let lock = NSLock()

    @MainActor
    func capture(label: String = "", scale: Double = 0.5) throws -> Entry {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first, let window = scene.windows.first else {
            throw NSError(domain: "DebugScreenshotBuffer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No window"])
        }

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = CGFloat(scale)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: fmt)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else {
            throw NSError(domain: "DebugScreenshotBuffer", code: -2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }

        lock.lock()
        let entry = Entry(id: nextId, label: label, date: Date(), pngData: data)
        nextId += 1
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        return entry
    }

    func captureAsync(label: String = "", scale: Double = 0.5) {
        Task { @MainActor in
            _ = try? capture(label: label, scale: scale)
        }
    }

    func list() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func get(id: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first(where: { $0.id == id })
    }

    func latest() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last
    }

    func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = entries.count
        entries.removeAll()
        return count
    }
}

@MainActor
final class DebugJSONRPC: @unchecked Sendable {

    private let inspector: DebugViewInspector

    /// Static meta included in every JSON-RPC response.
    private nonisolated(unsafe) static let responseMeta: [String: Any] = {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "app": "OasesChat",
            "version": info["CFBundleShortVersionString"] as? String ?? "?",
            "build": info["CFBundleVersion"] as? String ?? "?",
            "device": DeviceIdentity.deviceName,
        ]
    }()

    init(inspector: DebugViewInspector) {
        self.inspector = inspector
    }

    // MARK: - Public

    func handle(json: String) async -> String {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorResponse(code: -32700, message: "Parse error", id: nil)
        }

        let id = parsed["id"]
        let jsonrpc = parsed["jsonrpc"] as? String

        guard jsonrpc == "2.0" else {
            return errorResponse(code: -32600, message: "Invalid Request: missing jsonrpc 2.0", id: id)
        }

        guard let method = parsed["method"] as? String else {
            return errorResponse(code: -32600, message: "Invalid Request: missing method", id: id)
        }

        let params = parsed["params"] as? [String: Any] ?? [:]

        do {
            let result = try await dispatch(method: method, params: params)
            return successResponse(result: result, id: id)
        } catch let error as RPCError {
            return errorResponse(code: error.code, message: error.message, id: id)
        } catch {
            return errorResponse(code: -32000, message: error.localizedDescription, id: id)
        }
    }

    // MARK: - Dispatch

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "rpc.discover":
            return DebugMethodRegistry.discover()
        case "debug.viewTree":
            return try await handleViewTree(params: params)
        case "debug.search":
            return try await handleSearch(params: params)
        case "debug.inspect":
            return try await handleInspect(params: params)
        case "debug.highlight":
            return try await handleHighlight(params: params)
        case "debug.agentTrace":
            return handleAgentTrace(params: params)
        case "debug.ls":
            return try handleLS(params: params)
        case "debug.readFile":
            return try handleReadFile(params: params)
        case "debug.shellExecute":
            return try await handleShellExecute(params: params)
        case "debug.appInfo":
            return handleAppInfo(params: params)
        case "debug.llmRequests":
            return handleLLMRequests(params: params)
        case "debug.voiceInputs":
            return handleVoiceInputs(params: params)
        case "debug.logs.list":
            return handleLogsList()
        case "debug.logs.read":
            return try handleLogsRead(params: params)
        case "debug.logs.flush":
            return handleLogsFlush()
        case "debug.logs.setEnabled":
            return try await handleLogsSetEnabled(params: params)
        case "debug.screenshot":
            return try await handleScreenshot(params: params)
        case "debug.screenshot.capture":
            return try await handleScreenshotCapture(params: params)
        case "debug.screenshot.list":
            return handleScreenshotList()
        case "debug.screenshot.get":
            return try handleScreenshotGet(params: params)
        case "debug.screenshot.clear":
            return handleScreenshotClear()
        case _ where !CloudSyncFeature.isEnabled
            && ["debug.sync.ckQuery", "debug.sync.allZones", "debug.sync.zoneStats"].contains(method):
            // The CloudKit entitlement was removed with iCloud sync;
            // `CKContainer(identifier:)` would raise instead of failing.
            return ["ok": false, "error": "iCloud sync is not part of this build"] as [String: Any]
        case "debug.sync.ckQuery":
            return await handleSyncCKQuery(params: params)
        case "debug.sync.allZones":
            return await handleSyncAllZones()
        case "debug.sync.deviceId":
            return await handleSyncDeviceId()
        case "debug.sync.zoneStats":
            return await handleSyncZoneStats(params: params)
        case "debug.envvar.list":
            return await handleEnvVarList(params: params)
        case "debug.envvar.set":
            return await handleEnvVarSet(params: params)
        case "debug.envvar.delete":
            return await handleEnvVarDelete(params: params)
        case "debug.tap":
            return try await handleTap(params: params)
        case "debug.inputText":
            return try await handleInputText(params: params)
        case "debug.scroll":
            return try await handleScroll(params: params)
        // MARK: Hang detector
        case "debug.markdownSnapshot.setEnabled":
            return try handleMarkdownSnapshotSetEnabled(params: params)
        case "debug.markdownSnapshot.list":
            return handleMarkdownSnapshotList()
        case "debug.markdownSnapshot.get":
            return try handleMarkdownSnapshotGet(params: params)
        case "debug.markdownSnapshot.clear":
            return handleMarkdownSnapshotClear()
        case "debug.messageListSnapshot.setEnabled":
            return try handleMessageListSnapshotSetEnabled(params: params)
        case "debug.messageListSnapshot.list":
            return handleMessageListSnapshotList()
        case "debug.messageListSnapshot.get":
            return try handleMessageListSnapshotGet(params: params)
        case "debug.messageListSnapshot.clear":
            return handleMessageListSnapshotClear()
        case "debug.messageListSnapshot.captureNow":
            return try await handleMessageListSnapshotCaptureNow()
        case "debug.debugOverlay.setEnabled":
            return try await handleDebugOverlaySetEnabled(params: params)
        case "debug.debugOverlay.setMode":
            return try await handleDebugOverlaySetMode(params: params)
        // MARK: Chat / sessions (DebugRPCChat)
        case "chat.sessions.list":
            return await DebugRPCChat.sessionsList(params: params)
        case "chat.sessions.get":
            return try await DebugRPCChat.sessionsGet(params: params)
        case "chat.session.delete":
            return try await DebugRPCChat.sessionDelete(params: params)
        case "chat.messages.list":
            return try await DebugRPCChat.messagesList(params: params)
        case "chat.messages.count":
            return try await DebugRPCChat.messagesCount(params: params)
        case "chat.session.status":
            return try await DebugRPCChat.sessionStatus(params: params)
        case "chat.session.cancel":
            return try await DebugRPCChat.sessionCancel(params: params)
        case "chat.prompt":
            return try await DebugRPCChat.prompt(params: params)
        // MARK: Session replay (SessionDataSimulator)
        case "chat.simulate.load":
            return try await MainActor.run { try DebugRPCChat.simulateLoad(params: params) }
        case "chat.simulate.replay":
            return try await DebugRPCChat.simulateReplay(params: params)
        case "chat.simulate.status":
            return await MainActor.run { DebugRPCChat.simulateStatus() }
        case "chat.simulate.pause":
            return await MainActor.run { DebugRPCChat.simulatePause() }
        case "chat.simulate.resume":
            return await MainActor.run { DebugRPCChat.simulateResume() }
        case "chat.simulate.cancel":
            return await MainActor.run { DebugRPCChat.simulateCancel() }
        // MARK: MCP server config (DebugRPCMCP)
        case "mcp.list":
            return await MainActor.run { DebugRPCMCP.list() }
        case "mcp.import":
            return try await MainActor.run { try DebugRPCMCP.importJSON(params: params) }
        case "mcp.delete":
            return try await MainActor.run { try DebugRPCMCP.delete(params: params) }
        // MARK: Providers stack (DebugRPCProviderChat)
        case "provider.types":
            return await MainActor.run { DebugRPCProviderChat.types() }
        case "provider.instances.list":
            return await MainActor.run { DebugRPCProviderChat.instancesList(params: params) }
        case "provider.instances.create":
            return try await MainActor.run { try DebugRPCProviderChat.instancesCreate(params: params) }
        case "provider.instances.update":
            return try await MainActor.run { try DebugRPCProviderChat.instancesUpdate(params: params) }
        case "provider.instances.delete":
            return try await MainActor.run { try DebugRPCProviderChat.instancesDelete(params: params) }
        case "provider.models.list":
            return await MainActor.run { DebugRPCProviderChat.modelsList(params: params) }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method). Call 'rpc.discover' to list available methods.")
        }
    }

    #if DEBUG
    // MARK: - Markdown Snapshot handlers (DEBUG only)

    private func handleMarkdownSnapshotSetEnabled(params: [String: Any]) throws -> Any {
        guard let enabled = params["enabled"] as? Bool else {
            throw RPCError(code: -32602, message: "Missing required 'enabled' (bool).")
        }
        MarkdownSnapshotCollector.isEnabled = enabled
        return ["enabled": enabled]
    }

    private func handleMarkdownSnapshotList() -> Any {
        let brief = MarkdownSnapshotCollector.shared.listBrief()
        return ["count": brief.count, "snapshots": brief]
    }

    private func handleMarkdownSnapshotGet(params: [String: Any]) throws -> Any {
        guard let id = params["id"] as? String else {
            throw RPCError(code: -32602, message: "Missing required 'id' (string).")
        }
        guard let snapshot = MarkdownSnapshotCollector.shared.getFull(id: id) else {
            throw RPCError(code: -32004, message: "Snapshot '\(id)' not found (may have been evicted from ring buffer).")
        }
        return snapshot
    }

    private func handleMarkdownSnapshotClear() -> Any {
        MarkdownSnapshotCollector.shared.clear()
        return ["cleared": true]
    }

    // MARK: - Message-list snapshot handlers (DEBUG only)

    private func handleMessageListSnapshotSetEnabled(params: [String: Any]) throws -> Any {
        guard let enabled = params["enabled"] as? Bool else {
            throw RPCError(code: -32602, message: "Missing required 'enabled' (bool).")
        }
        MessageListSnapshotCollector.isEnabled = enabled
        return ["enabled": enabled]
    }

    private func handleMessageListSnapshotList() -> Any {
        let brief = MessageListSnapshotCollector.shared.listBrief()
        return ["count": brief.count, "snapshots": brief]
    }

    private func handleMessageListSnapshotGet(params: [String: Any]) throws -> Any {
        guard let id = params["id"] as? String else {
            throw RPCError(code: -32602, message: "Missing required 'id' (string).")
        }
        guard let snapshot = MessageListSnapshotCollector.shared.getFull(id: id) else {
            throw RPCError(code: -32004, message: "Snapshot '\(id)' not found.")
        }
        return snapshot
    }

    private func handleMessageListSnapshotClear() -> Any {
        MessageListSnapshotCollector.shared.clear()
        return ["cleared": true]
    }

    // MARK: - Debug View Overlay handlers (DEBUG only)

    private func handleDebugOverlaySetEnabled(params: [String: Any]) async throws -> Any {
        guard let enabled = params["enabled"] as? Bool else {
            throw RPCError(code: -32602, message: "Missing required 'enabled' (bool).")
        }
        await MainActor.run { DebugViewOverlay.shared.setEnabled(enabled) }
        return ["enabled": enabled]
    }

    private func handleDebugOverlaySetMode(params: [String: Any]) async throws -> Any {
        // mode = "all" | "byType" | "byTypePrefix" | "byAddress"
        guard let modeStr = params["mode"] as? String else {
            throw RPCError(code: -32602, message: "Missing required 'mode' (string: 'all'|'byType'|'byTypePrefix'|'byAddress').")
        }
        let mode: DebugViewOverlay.Mode
        switch modeStr {
        case "all":
            mode = .all
        case "byType":
            guard let t = params["type"] as? String else {
                throw RPCError(code: -32602, message: "'byType' requires 'type' (string class name).")
            }
            mode = .byType(t)
        case "byTypePrefix":
            guard let t = params["type"] as? String else {
                throw RPCError(code: -32602, message: "'byTypePrefix' requires 'type' (string class-name prefix).")
            }
            mode = .byTypePrefix(t)
        case "byAddress":
            guard let a = params["address"] as? String else {
                throw RPCError(code: -32602, message: "'byAddress' requires 'address' (string '0x...').")
            }
            mode = .byAddress(a)
        default:
            throw RPCError(code: -32602, message: "Unknown mode '\(modeStr)'. Expected 'all'|'byType'|'byTypePrefix'|'byAddress'.")
        }
        await MainActor.run { DebugViewOverlay.shared.setMode(mode) }
        return ["mode": modeStr]
    }

    /// Force one manual capture of the currently visible message list. Useful
    /// to grab a snapshot AFTER a layout has settled / after a bug repro,
    /// independently of the in-code capture sites.
    private func handleMessageListSnapshotCaptureNow() async throws -> Any {
        await MainActor.run {
            // Walk every window to find a NoAnimationCollectionView.
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows {
                    var found: UICollectionView?
                    func dfs(_ v: UIView) {
                        if found != nil { return }
                        if let cv = v as? UICollectionView,
                           String(describing: type(of: cv)) == "NoAnimationCollectionView" {
                            found = cv; return
                        }
                        for s in v.subviews { dfs(s); if found != nil { return } }
                    }
                    dfs(w)
                    if let cv = found {
                        MessageListSnapshotCollector.captureManually(collectionView: cv)
                        return
                    }
                }
            }
        }
        return ["ok": true]
    }
    #endif

    // MARK: - Handlers

    private func handleViewTree(params: [String: Any]) async throws -> Any {
        let maxDepth = params["maxDepth"] as? Int ?? 50
        return await MainActor.run {
            let trees = inspector.buildTree(maxDepth: maxDepth)
            if trees.count == 1 { return trees[0] }
            return trees
        }
    }

    private func handleSearch(params: [String: Any]) async throws -> Any {
        guard let keyword = params["keyword"] as? String, !keyword.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'keyword' is required")
        }
        let scope = params["scope"] as? String ?? "all"
        return await MainActor.run {
            inspector.search(keyword: keyword, scope: scope)
        }
    }

    private func handleInspect(params: [String: Any]) async throws -> Any {
        guard let address = params["address"] as? String, !address.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'address' is required")
        }
        return await MainActor.run {
            guard let result = inspector.inspect(address: address) else {
                return ["error": "View not found at address \(address)"] as [String: Any]
            }
            return result
        }
    }

    private func handleHighlight(params: [String: Any]) async throws -> Any {
        guard let address = params["address"] as? String, !address.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'address' is required")
        }
        let color = params["color"] as? String ?? "red"
        let duration = params["duration"] as? Double ?? 2.0
        return await MainActor.run {
            let ok = inspector.highlight(address: address, color: color, duration: duration)
            return ["ok": ok]
        }
    }

    private func handleAgentTrace(params: [String: Any]) -> Any {
        let last = params["last"] as? Bool ?? false
        if last {
            return AgentRequestTrace.shared.getLast() ?? ["traces": []]
        }
        return ["traces": AgentRequestTrace.shared.getAll()]
    }

    private func handleLLMRequests(params: [String: Any]) -> Any {
        let requests = LastAPIRequestBody.shared.getAll()
        let last = params["last"] as? Int
        let formatted = params["formatted"] as? Bool ?? false

        let selected: [CapturedAPIRequest]
        if let last, last > 0 {
            selected = Array(requests.suffix(last))
        } else {
            selected = requests
        }

        // Captures hold live credentials (Authorization / API-key headers,
        // key query params, OAuth token bodies). Everything leaving the debug
        // server is redacted here.
        if formatted {
            let text = selected.enumerated().map { idx, req in
                DebugSecretRedactor.text(req.formatted(index: idx + 1))
            }.joined(separator: "\n\n")
            return ["count": selected.count, "text": text]
        }

        let tf = ISO8601DateFormatter()
        tf.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items: [[String: Any]] = selected.map { req in
            var dict: [String: Any] = [
                "provider": req.provider,
                "timestamp": tf.string(from: req.timestamp),
                "requestBody": DebugSecretRedactor.text(req.requestBody),
            ]
            if let url = req.requestURL { dict["requestURL"] = DebugSecretRedactor.url(url) }
            if let method = req.requestMethod { dict["requestMethod"] = method }
            if let rh = req.requestHeaders { dict["requestHeaders"] = DebugSecretRedactor.headers(rh) }
            if let d = req.durationMs { dict["durationMs"] = d }
            if let u = req.usage {
                dict["usage"] = [
                    "inputTokens": u.inputTokens,
                    "outputTokens": u.outputTokens,
                    "cacheCreationTokens": u.cacheCreationTokens,
                    "cacheReadTokens": u.cacheReadTokens,
                ] as [String: Any]
            }
            if let sc = req.responseStatusCode { dict["responseStatusCode"] = sc }
            if let rh = req.responseHeaders { dict["responseHeaders"] = DebugSecretRedactor.headers(rh) }
            if let rb = req.responseBody { dict["responseBody"] = DebugSecretRedactor.text(rb) }
            if let tag = req.tag { dict["tag"] = tag }
            return dict
        }
        return ["count": items.count, "requests": items]
    }

    // MARK: - Voice Input Capture Handler

    /// [T-debug-voice-input-capture] Return the last ≤5 audio payloads that were
    /// actually sent to the ASR model, for diagnosing VAD trimming/drops.
    ///   params:
    ///     last          Int?   — return only the most recent N (default: all)
    ///     includeAudio  Bool?  — include base64 WAV per entry (default true)
    private func handleVoiceInputs(params: [String: Any]) -> Any {
        let includeAudio = params["includeAudio"] as? Bool ?? true
        var items = VoiceInputCapture.shared.getAll(includeAudio: includeAudio)
        if let last = params["last"] as? Int, last > 0 {
            items = Array(items.suffix(last))
        }
        return ["count": items.count, "voiceInputs": items]
    }



    // MARK: - Log Handlers

    private func handleLogsList() -> Any {
        let mgr = LoggingManager.shared
        let iso = ISO8601DateFormatter()
        let files = mgr.logFiles().map { file -> [String: Any] in
            [
                "name": file.name,
                "size": file.size,
                "modified": iso.string(from: file.date),
                "type": file.type,
            ]
        }
        return [
            "enabled": mgr.isEnabled,
            "logDirectory": mgr.logDirectory.path,
            "totalSize": mgr.totalLogSize(),
            "files": files,
        ] as [String: Any]
    }

    /// Synchronously flush the in-memory log buffer to disk so a subsequent
    /// `debug.logs.read` sees the very latest lines (the writer batches +
    /// fsyncs lazily, so without this the freshest entries can lag on disk).
    /// Returns today's log name + post-flush size for an immediate tail read.
    private func handleLogsFlush() -> Any {
        let mgr = LoggingManager.shared
        mgr.flushSync()
        // Surface the current (post-flush) file so the caller can read its tail
        // immediately: read from offset = max(0, size - N).
        let iso = ISO8601DateFormatter()
        let newest = mgr.logFiles().max(by: { $0.date < $1.date })
        return [
            "ok": true,
            "enabled": mgr.isEnabled,
            "name": newest?.name as Any,
            "size": newest?.size as Any,
            "modified": newest.map { iso.string(from: $0.date) } as Any,
        ] as [String: Any]
    }

    private func handleLogsRead(params: [String: Any]) throws -> Any {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'name' is required")
        }
        // Sanitize: only allow filenames, no path separators
        guard !name.contains("/"), !name.contains("..") else {
            throw RPCError(code: -32602, message: "Invalid params: 'name' must be a filename, not a path")
        }

        let mgr = LoggingManager.shared
        let fileURL = mgr.logDirectory.appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RPCError(code: -32602, message: "Log file not found: \(name)")
        }

        // Cap response size hard so a multi-MB log never floods the
        // single-shot HTTP response and stalls the connection.
        let requestedLimit = params["limit"] as? Int ?? 262_144 // 256KB default
        let limit = min(max(requestedLimit, 0), 1_048_576)      // 1MB ceiling
        let offset = params["offset"] as? Int

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int ?? 0

        let startOffset = offset.map { max(0, $0) } ?? 0
        if startOffset > 0 {
            handle.seek(toFileOffset: UInt64(startOffset))
        }

        let data = handle.readData(ofLength: limit)
        let content = String(data: data, encoding: .utf8) ?? data.base64EncodedString()

        var result: [String: Any] = [
            "name": name,
            "size": fileSize,
            "offset": startOffset,
            "bytesRead": data.count,
            "content": content,
        ]
        let endOffset = startOffset + data.count
        if endOffset < fileSize {
            result["truncated"] = true
            result["nextOffset"] = endOffset
        }
        return result
    }

    private func handleLogsSetEnabled(params: [String: Any]) async throws -> Any {
        guard let enabled = params["enabled"] as? Bool else {
            throw RPCError(code: -32602, message: "Invalid params: 'enabled' (bool) is required")
        }
        await MainActor.run {
            LoggingManager.shared.isEnabled = enabled
        }
        return ["enabled": enabled]
    }

    // MARK: - Screenshot Handler

    private func handleScreenshot(params: [String: Any]) async throws -> Any {
        let scale = params["scale"] as? Double ?? 1.0
        let windowIndex = params["window"] as? Int ?? 0

        let pngData: Data = try await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .sorted { ($0.windows.first?.windowLevel.rawValue ?? 0) < ($1.windows.first?.windowLevel.rawValue ?? 0) }

            guard let scene = scenes.first,
                  windowIndex < scene.windows.count else {
                throw RPCError(code: -32000, message: "No window available (index: \(windowIndex))")
            }

            let window = scene.windows[windowIndex]
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = CGFloat(scale)
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: fmt)
            let image = renderer.image { ctx in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            guard let data = image.pngData() else {
                throw RPCError(code: -32000, message: "Failed to encode screenshot")
            }
            return data
        }

        return [
            "base64": pngData.base64EncodedString(),
            "size": pngData.count,
            "encoding": "png",
        ] as [String: Any]
    }

    // MARK: - Screenshot Buffer Handlers

    private func handleScreenshotCapture(params: [String: Any]) async throws -> Any {
        let label = params["label"] as? String ?? ""
        let scale = params["scale"] as? Double ?? 0.5
        let entry = try await MainActor.run {
            try DebugScreenshotBuffer.shared.capture(label: label, scale: scale)
        }
        return [
            "id": entry.id,
            "label": entry.label,
            "timestamp": entry.iso,
            "size": entry.pngData.count,
        ] as [String: Any]
    }

    private func handleScreenshotList() -> Any {
        let entries = DebugScreenshotBuffer.shared.list()
        return [
            "count": entries.count,
            "entries": entries.map { [
                "id": $0.id,
                "label": $0.label,
                "timestamp": $0.iso,
                "size": $0.pngData.count,
            ] as [String: Any] },
        ] as [String: Any]
    }

    private func handleScreenshotGet(params: [String: Any]) throws -> Any {
        if let id = params["id"] as? Int {
            guard let entry = DebugScreenshotBuffer.shared.get(id: id) else {
                throw RPCError(code: -32602, message: "Screenshot not found: \(id)")
            }
            return [
                "id": entry.id,
                "label": entry.label,
                "timestamp": entry.iso,
                "base64": entry.pngData.base64EncodedString(),
                "size": entry.pngData.count,
                "encoding": "png",
            ] as [String: Any]
        }
        // Return the latest
        guard let entry = DebugScreenshotBuffer.shared.latest() else {
            throw RPCError(code: -32000, message: "No screenshots captured")
        }
        return [
            "id": entry.id,
            "label": entry.label,
            "timestamp": entry.iso,
            "base64": entry.pngData.base64EncodedString(),
            "size": entry.pngData.count,
            "encoding": "png",
        ] as [String: Any]
    }

    private func handleScreenshotClear() -> Any {
        let count = DebugScreenshotBuffer.shared.clear()
        return ["cleared": count]
    }

    // MARK: - Sync v2 Diagnostics






    /// Run an ad-hoc CKQuery against the iCloud private database for
    /// experimentation. Lets us probe which predicates / sorts the
    /// container's current schema actually accepts without needing to
    /// rebuild the app for each variant.
    ///
    /// Params:
    ///   recordType  (string, default "MessageV2")
    ///   zone        (string, default "oases-shared")
    ///   predicate   (string, default "TRUEPREDICATE")
    ///   predicateArgs (array of strings, optional — passed positionally
    ///                  via NSPredicate(format:argumentArray:); each
    ///                  string parsed as ISO8601 date if it looks like one,
    ///                  otherwise as raw string)
    ///   sortKey     (string, optional — e.g. "modificationDate",
    ///                "creationDate", "___modTime", "title")
    ///   sortAscending (bool, default false)
    ///   limit       (int, default 5)
    ///   desiredKeys (array of strings, optional — narrow the fetched
    ///                fields to keep response small; pass [] for ALL)
    ///
    /// Returns one of:
    ///   { "ok": true, "count": N, "records": [{ "name": ..., "type": ...,
    ///     "modificationDate": "...", "creationDate": "...", "fields": {...} }, ...] }
    ///   { "ok": false, "errorCode": Int, "ckCode": Int, "description": "..." }
    private func handleSyncCKQuery(params: [String: Any]) async -> Any {
        let recordType = (params["recordType"] as? String) ?? "MessageV2"
        let zoneName = (params["zone"] as? String) ?? "oases-shared"
        let predicateString = (params["predicate"] as? String) ?? "TRUEPREDICATE"
        let predicateArgs = params["predicateArgs"] as? [String] ?? []
        let sortKey = params["sortKey"] as? String
        let sortAscending = (params["sortAscending"] as? Bool) ?? false
        let limit = (params["limit"] as? Int) ?? 5
        let desiredKeysParam = params["desiredKeys"] as? [String]

        let predicate: NSPredicate
        if predicateArgs.isEmpty {
            predicate = NSPredicate(format: predicateString)
        } else {
            // Parse ISO date-like strings into Date so the predicate
            // can compare date fields properly.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parsed: [Any] = predicateArgs.map { s in
                if let d = iso.date(from: s) { return d as NSDate }
                if let d = ISO8601DateFormatter().date(from: s) { return d as NSDate }
                return s as NSString
            }
            predicate = NSPredicate(format: predicateString, argumentArray: parsed)
        }
        let query = CKQuery(recordType: recordType, predicate: predicate)
        if let key = sortKey {
            query.sortDescriptors = [NSSortDescriptor(key: key, ascending: sortAscending)]
        }
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        let container = CKContainer(identifier: "iCloud.dev.oases.chat.ios")
        do {
            let result = try await container.privateCloudDatabase.records(
                matching: query,
                inZoneWith: zoneID,
                desiredKeys: desiredKeysParam,
                resultsLimit: limit
            )
            var out: [[String: Any]] = []
            for (_, recResult) in result.matchResults {
                if case .success(let rec) = recResult {
                    var entry: [String: Any] = [
                        "name": rec.recordID.recordName,
                        "type": rec.recordType,
                    ]
                    if let mod = rec.modificationDate {
                        entry["modificationDate"] = ISO8601DateFormatter().string(from: mod)
                    }
                    if let created = rec.creationDate {
                        entry["creationDate"] = ISO8601DateFormatter().string(from: created)
                    }
                    if desiredKeysParam == nil || !(desiredKeysParam?.isEmpty ?? true) {
                        var fields: [String: String] = [:]
                        for key in rec.allKeys() {
                            let val = rec[key]
                            fields[key] = String(describing: val).prefix(120).description
                        }
                        entry["fields"] = fields
                    }
                    out.append(entry)
                }
            }
            return [
                "ok": true,
                "count": out.count,
                "records": out,
            ] as [String: Any]
        } catch {
            let nse = error as NSError
            let ck = error as? CKError
            return [
                "ok": false,
                "errorCode": nse.code,
                "ckCode": ck?.code.rawValue ?? -1,
                "description": error.localizedDescription,
            ] as [String: Any]
        }
    }

    /// List all CKRecordZone IDs in the user's private database. Used to
    /// diagnose v1 zone presence (device-<id>) and confirm v2 zones
    /// (oases-shared / oases-devices / oases-secrets) when migration
    /// counters look suspect.
    private func handleSyncAllZones() async -> Any {
        let container = CKContainer(identifier: "iCloud.dev.oases.chat.ios")
        do {
            let zones = try await container.privateCloudDatabase.allRecordZones()
            return [
                "ok": true,
                "count": zones.count,
                "zones": zones.map { ["zoneName": $0.zoneID.zoneName, "ownerName": $0.zoneID.ownerName] },
            ] as [String: Any]
        } catch {
            let nse = error as NSError
            let ck = error as? CKError
            return [
                "ok": false,
                "errorCode": nse.code,
                "ckCode": ck?.code.rawValue ?? -1,
                "description": error.localizedDescription,
            ] as [String: Any]
        }
    }

    /// Return this device's stable identifier — used as the zone-name
    /// suffix for v1 ("device-<id>") and the device record key for
    /// SyncDevice records.
    private func handleSyncDeviceId() async -> Any {
        return [
            "ok": true,
            "deviceId": DeviceIdentity.deviceId,
        ] as [String: Any]
    }

    /// Per-zone record + asset-byte rollup. Walks the user's private
    /// database zones, counts each known record type via paginated
    /// `desiredKeys=["fileSize"]` queries, and reports the totals.
    ///
    /// CloudKit does NOT expose a per-zone "used storage" API, so this
    /// is the closest we can get to "how much space does X zone hold".
    /// Each recordType run is one CKQuery + cursor pagination capped at
    /// 200 pages × 400 results = 80k records per type. Body bytes
    /// (record fields other than the asset) are NOT included — we only
    /// sum `fileSize` because that's the dominant cost for media-heavy
    /// types like SessionFile/SessionFileV2.
    ///
    /// Params:
    ///   zone (optional): single zone name. Defaults to all v2 zones
    ///     + the caller's own v1 zone.
    ///   recordTypes (optional): override the default per-zone type
    ///     list. Useful for ad-hoc probes.
    private func handleSyncZoneStats(params: [String: Any]) async -> Any {
        let containerId = "iCloud.dev.oases.chat.ios"
        let container = CKContainer(identifier: containerId)
        let db = container.privateCloudDatabase

        // Resolve zone list.
        let requestedZone = params["zone"] as? String
        var zonesToScan: [(name: String, types: [String])] = []
        if let z = requestedZone {
            // Caller supplied a zone — let them also pass recordTypes
            // explicitly, otherwise we guess by zone name.
            let userTypes = params["recordTypes"] as? [String]
            zonesToScan.append((z, userTypes ?? Self.guessRecordTypes(forZone: z)))
        } else {
            // Default: all v2 zones + own v1 zone.
            let myDeviceId = DeviceIdentity.deviceId
            zonesToScan = [
                ("oases-shared", ["SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2", "SkillV2"]),
                ("oases-devices", ["SyncDeviceV2"]),
                ("oases-secrets", ["ProviderConfigV2", "EnvVarV2", "EnvVarItem"]),
                ("device-\(myDeviceId)", ["Session", "Message", "CompactMarker", "SessionFile"]),
            ]
        }

        struct TypeStat {
            var count: Int = 0
            var assetBytes: Int64 = 0
        }
        var zoneResults: [[String: Any]] = []
        var totalRecords = 0
        var totalAssetBytes: Int64 = 0

        for (zoneName, recordTypes) in zonesToScan {
            let zoneID = CKRecordZone.ID(zoneName: zoneName)
            var perType: [String: TypeStat] = [:]
            var zoneCount = 0
            var zoneBytes: Int64 = 0
            var zoneMissing = false
            for type in recordTypes {
                do {
                    let stat = try await Self.scanZoneTypeStats(
                        type: type, zoneID: zoneID, db: db)
                    perType[type] = TypeStat(count: stat.count, assetBytes: stat.assetBytes)
                    zoneCount += stat.count
                    zoneBytes += stat.assetBytes
                } catch let error as CKError where error.code == .zoneNotFound {
                    zoneMissing = true
                    break
                } catch let error as CKError where error.code == .unknownItem
                                                || error.code == .invalidArguments {
                    // Schema doesn't have this type in this zone — skip.
                    continue
                } catch {
                    perType[type] = TypeStat(count: -1, assetBytes: -1)
                }
            }
            totalRecords += zoneCount
            totalAssetBytes += zoneBytes
            var entry: [String: Any] = [
                "zone": zoneName,
                "exists": !zoneMissing,
                "recordCount": zoneCount,
                "assetBytes": zoneBytes,
                "assetSizeFormatted": ByteCountFormatter.string(
                    fromByteCount: zoneBytes, countStyle: .file),
            ]
            entry["byType"] = perType.mapValues { stat -> [String: Any] in
                [
                    "count": stat.count,
                    "assetBytes": stat.assetBytes,
                    "assetSizeFormatted": ByteCountFormatter.string(
                        fromByteCount: stat.assetBytes, countStyle: .file),
                ]
            }
            zoneResults.append(entry)
        }
        return [
            "ok": true,
            "zones": zoneResults,
            "totalRecords": totalRecords,
            "totalAssetBytes": totalAssetBytes,
            "totalAssetSizeFormatted": ByteCountFormatter.string(
                fromByteCount: totalAssetBytes, countStyle: .file),
        ] as [String: Any]
    }

    /// Fallback recordType list when a caller asks for a single zone
    /// without specifying types. Matches the v2 zone layout (see
    /// ICloudSharedZoneTransport.zoneByRecordType) and treats anything
    /// matching `device-*` as a v1 zone.
    private static func guessRecordTypes(forZone zone: String) -> [String] {
        switch zone {
        case "oases-shared":
            return ["SessionV2", "MessageV2", "CompactMarkerV2", "SessionFileV2", "SkillV2"]
        case "oases-devices":
            return ["SyncDeviceV2"]
        case "oases-secrets":
            return ["ProviderConfigV2", "EnvVarV2", "EnvVarItem"]
        default:
            if zone.hasPrefix("device-") {
                return ["Session", "Message", "CompactMarker", "SessionFile"]
            }
            return []
        }
    }

    /// Paginated scan of one (recordType, zone) tuple. Predicate uses a
    /// queryable field appropriate to each known type so CK doesn't
    /// reject the query with "field not queryable" (recordName is the
    /// default but isn't marked queryable on these schemas).
    private static func scanZoneTypeStats(
        type: String, zoneID: CKRecordZone.ID, db: CKDatabase
    ) async throws -> (count: Int, assetBytes: Int64) {
        let epoch = Date(timeIntervalSince1970: 946_684_800) as NSDate
        let predicate: NSPredicate
        let assetField: String?
        switch type {
        case "SessionFile":
            // No createdAt/updatedAt — use sessionId.
            predicate = NSPredicate(format: "sessionId != %@", "__none__" as NSString)
            assetField = "fileSize"
        case "SessionFileV2":
            predicate = NSPredicate(format: "sessionId != %@", "__none__" as NSString)
            assetField = "asset_size"
        case "SkillV2":
            predicate = NSPredicate(format: "updatedAt > %@", epoch)
            assetField = "assetSize"
        case "ProviderConfigV2", "EnvVarV2", "EnvVarItem", "SyncDeviceV2":
            // Singletons / device records carry only updatedAt — there
            // is no createdAt to anchor on.
            predicate = NSPredicate(format: "updatedAt > %@", epoch)
            assetField = nil
        default:
            predicate = NSPredicate(format: "createdAt > %@", epoch)
            assetField = nil
        }
        var desired: [String] = []
        if let f = assetField { desired.append(f) }

        let query = CKQuery(recordType: type, predicate: predicate)
        var cursor: CKQueryOperation.Cursor? = nil
        var count = 0
        var bytes: Int64 = 0
        for _ in 0..<200 {
            let resp: (matchResults: [(CKRecord.ID, Swift.Result<CKRecord, Error>)],
                       queryCursor: CKQueryOperation.Cursor?)
            if let cur = cursor {
                resp = try await db.records(continuingMatchFrom: cur,
                                            desiredKeys: desired,
                                            resultsLimit: CKQueryOperation.maximumResults)
            } else {
                resp = try await db.records(matching: query,
                                            inZoneWith: zoneID,
                                            desiredKeys: desired,
                                            resultsLimit: CKQueryOperation.maximumResults)
            }
            count += resp.matchResults.count
            if let field = assetField {
                for (_, r) in resp.matchResults {
                    if case .success(let rec) = r,
                       let n = rec[field] as? Int64 {
                        bytes += n
                    } else if case .success(let rec) = r,
                              let n = rec[field] as? Int {
                        bytes += Int64(n)
                    }
                }
            }
            if let next = resp.queryCursor { cursor = next } else { break }
        }
        return (count, bytes)
    }

    // OpenMinis' `debug.browser.*` handlers (listTabs / pageInfo / executeJS /
    // getReadable / getText / screenshot / agentNav / concurrentTest) are
    // omitted together with their dispatch cases: they drive `BrowserTabPool`,
    // a WKWebView pool that isn't ported. Those method names now return a real
    // method-not-found error instead of a stub that pretends to succeed.

    // MARK: - File System Handlers

    private func resolveHostPath(_ path: String) -> URL {
        let stripped = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if stripped.isEmpty {
            return ISHRootfsManager.dataURL
        }
        // Support Library/ prefix to access app Library directory
        if stripped.hasPrefix("Library/") {
            let fm = FileManager.default
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let relative = String(stripped.dropFirst("Library/".count))
            return relative.isEmpty ? library : library.appendingPathComponent(relative)
        }
        // Support Documents/ prefix to access app Documents directory
        if stripped.hasPrefix("Documents/") {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let relative = String(stripped.dropFirst("Documents/".count))
            return relative.isEmpty ? docs : docs.appendingPathComponent(relative)
        }
        // Support AppGroup/ prefix to access the shared App Group container,
        // where the FileProvider extension writes its diagnostic log.
        if stripped.hasPrefix("AppGroup/") {
            let fm = FileManager.default
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.oases.chat.ios") {
                let relative = String(stripped.dropFirst("AppGroup/".count))
                return relative.isEmpty ? container : container.appendingPathComponent(relative)
            }
        }
        return ISHRootfsManager.dataURL.appendingPathComponent(stripped)
    }

    private func guardPathTraversal(_ path: String) throws {
        let components = (path as NSString).pathComponents
        if components.contains("..") {
            throw RPCError(code: -32602, message: "Invalid path: '..' components not allowed")
        }
    }

    private func handleLS(params: [String: Any]) throws -> Any {
        let path = params["path"] as? String ?? "/"
        try guardPathTraversal(path)

        let recursive = params["recursive"] as? Bool ?? false
        let maxDepth = params["maxDepth"] as? Int ?? 3

        let url = resolveHostPath(path)
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw RPCError(code: -32602, message: "Not a directory: \(path)")
        }

        if recursive {
            return try listRecursive(url: url, fm: fm, depth: 0, maxDepth: maxDepth, basePath: path)
        }

        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw RPCError(code: -32000, message: "Cannot read directory: \(path)")
        }

        let iso = ISO8601DateFormatter()
        return contents.map { entry -> [String: Any] in
            entryDict(url: entry, fm: fm, iso: iso)
        }
    }

    private func listRecursive(url: URL, fm: FileManager, depth: Int, maxDepth: Int, basePath: String) throws -> [[String: Any]] {
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            return []
        }
        let iso = ISO8601DateFormatter()
        var result: [[String: Any]] = []
        for entry in contents {
            var dict = entryDict(url: entry, fm: fm, iso: iso)
            if dict["type"] as? String == "directory" && depth < maxDepth {
                let children = try listRecursive(url: entry, fm: fm, depth: depth + 1, maxDepth: maxDepth, basePath: basePath)
                dict["children"] = children
            }
            result.append(dict)
        }
        return result
    }

    private func entryDict(url: URL, fm: FileManager, iso: ISO8601DateFormatter) -> [String: Any] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        let isSymlink = values?.isSymbolicLink ?? false
        let isDirectory = values?.isDirectory ?? false
        let type: String = isSymlink ? "symlink" : (isDirectory ? "directory" : "file")
        var dict: [String: Any] = [
            "name": url.lastPathComponent,
            "type": type,
        ]
        if let size = values?.fileSize {
            dict["size"] = size
        }
        if let mod = values?.contentModificationDate {
            dict["modified"] = iso.string(from: mod)
        }
        return dict
    }

    private func handleReadFile(params: [String: Any]) throws -> Any {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'path' is required")
        }
        try guardPathTraversal(path)

        let forceBase64 = params["base64"] as? Bool ?? false
        let offset = params["offset"] as? Int
        let limit = params["limit"] as? Int
        let maxSize = 524_288_000 // 500MB

        let url = resolveHostPath(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw RPCError(code: -32602, message: "File not found: \(path)")
        }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let fileSize = attrs[.size] as? Int ?? 0

        if offset == nil && limit == nil && fileSize > maxSize {
            throw RPCError(code: -32000, message: "File too large (\(fileSize) bytes). Use offset/limit for partial reads.")
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        // Client-supplied: negative values trap in UInt64(_:) /
        // readData(ofLength:), huge ones would allocate without bound.
        let startOffset = min(max(offset ?? 0, 0), fileSize)
        fileHandle.seek(toFileOffset: UInt64(startOffset))

        let readLimit = min(max(limit ?? min(fileSize, maxSize), 0), maxSize)
        let data = fileHandle.readData(ofLength: readLimit)

        var result: [String: Any] = ["size": fileSize]

        if forceBase64 {
            result["content"] = data.base64EncodedString()
            result["encoding"] = "base64"
        } else if let text = String(data: data, encoding: .utf8), text.utf8.count == data.count {
            result["content"] = text
            result["encoding"] = "utf8"
        } else {
            result["content"] = data.base64EncodedString()
            result["encoding"] = "base64"
        }

        return result
    }

    // MARK: - File write (with fakefs meta.db registration)


    // MARK: - Shell execute (synchronous, returns stdout/stderr)

    /// Run a shell command inside the iSH guest. Blocks until the process
    /// exits or the timeout fires. Returns captured stdout/stderr plus exit
    /// code and duration. Intended for automated debugging / test harnesses
    /// — not for interactive sessions.
    ///
    /// Params:
    ///   - command: shell command string (passed to `/bin/sh -c` in default
    ///     mode, or written to `/bin/sh`'s stdin pipe when `stdinScript=true`
    ///     to mirror the agent's `ISHExecutionCoordinator.runCommand` path).
    ///   - timeout: max wait seconds (default 60, clamped to 600)
    ///   - stdinScript: when true, run `/bin/sh` with no argv and feed the
    ///     command as a script via stdin (the agent tool path). When false
    ///     (default), use `/bin/sh -c <command>` (the debug/test path).
    ///   - env: optional [String:String] of environment overrides to pass
    ///     to the child process (mirrors EnvVarStore injection in agent
    ///     path when `stdinScript=true`).
    private func handleShellExecute(params: [String: Any]) async throws -> Any {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'command' is required")
        }
        let rawTimeout = (params["timeout"] as? NSNumber)?.doubleValue ?? 60
        let timeout = max(1, min(600, rawTimeout))
        let stdinScript = params["stdinScript"] as? Bool ?? false
        let env = params["env"] as? [String: String]
        // Optional sessionId to stamp the shell's task group with the matching
        // fs_context, so /var/oases/{offloads,attachments,workspace,browser}
        // route to that session's bucket. Omit (or pass nil) for the default
        // global view (fs_context = 0).
        let sessionId = params["sessionId"] as? String
        let fsContext: UInt64 = sessionId.map { OasesFsRouter.shared.context(for: $0) } ?? 0

        // Run off the main thread (blocks on semaphore).
        let (result, didTimeout): (ISHShellExecutionResult?, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // OpenMinis branches here on `stdinScript` to feed the script
                // through stdin via `executeExecutable(stdinData:)`. OasesChat's
                // ISHShellExecutor has no stdinData variant, so both paths run
                // `executeCommandSync` (which is itself `/bin/sh -c`). The
                // `stdinScript` param stays accepted so existing callers don't
                // break; it simply has no effect.
                _ = stdinScript
                guard fsContext != 0 else {
                    _ = env
                    let res = ISHShellExecutor.executeCommandSync(
                        command,
                        timeout: timeout,
                        lineCallback: nil
                    )
                    continuation.resume(returning: (res, res.error == .timeout))
                    return
                }
                // With a sessionId, run the way the agent's shell tool does
                // (fs_context stamped on the task group) so session buckets
                // resolve exactly as they do for Ogent.
                let done = DispatchSemaphore(value: 0)
                var captured: ISHShellExecutionResult?
                let pid = ISHShellExecutor.executeExecutable(
                    "/bin/sh",
                    arguments: ["-c", command],
                    environment: env,
                    fsContext: fsContext,
                    lineCallback: nil,
                    completion: { result in
                        captured = result
                        done.signal()
                    }
                )
                guard pid > 0 else {
                    continuation.resume(returning: (nil, false))
                    return
                }
                if done.wait(timeout: .now() + timeout) == .timedOut {
                    // Already off the main thread (global queue).
                    ISHShellExecutor.killProcessGroup(pid)
                    // [T-ish-shell-timeout-leak] Same self-heal as the agent
                    // path: don't leave teardown to an exit notification a
                    // task that never exits does not send. This also delivers
                    // the completion, so the wait below returns the output
                    // captured before the deadline.
                    ISHShellExecutor.finalizeTimedOutPid(pid)
                    _ = done.wait(timeout: .now() + 2)
                    continuation.resume(returning: (captured, true))
                    return
                }
                continuation.resume(returning: (captured, captured?.error == .timeout))
            }
        }

        guard let result else {
            return [
                "exitCode": -1,
                "pid": 0,
                "error": "processCreationFailed",
                "stdout": "",
                "stderr": "",
                "duration": 0,
                "timedOut": false,
            ] as [String: Any]
        }

        let errorName: String
        if didTimeout {
            errorName = "timeout"
        } else {
            switch result.error {
            case .none: errorName = "none"
            case .processCreationFailed: errorName = "processCreationFailed"
            case .execFailed: errorName = "execFailed"
            case .timeout: errorName = "timeout"
            case .cancelled: errorName = "cancelled"
            @unknown default: errorName = "unknown"
            }
        }

        // [T-ios-debugrpc-json-nsexception-abort] Cap stdout/stderr at the
        // SOURCE. Unbounded shell output flowed straight into the JSON writer;
        // a large-enough payload failed CFString reallocation inside
        // _convertJSONString (NSException → abort). 4 MB per stream is far
        // beyond any diagnostic need; callers get the tail truncated with an
        // explicit marker + the original byte counts so nothing fails silently.
        let stdoutCapped = Self.capRPCOutput(result.output)
        let stderrCapped = Self.capRPCOutput(result.errorOutput)
        var resp: [String: Any] = [
            "exitCode": Int(result.exitCode),
            "pid": Int(result.pid),
            "error": errorName,
            "stdout": stdoutCapped.text,
            "stderr": stderrCapped.text,
            "duration": result.duration,
            "timedOut": didTimeout || result.error == .timeout,
        ]
        if stdoutCapped.truncated { resp["stdoutTruncatedFrom"] = stdoutCapped.originalCount }
        if stderrCapped.truncated { resp["stderrTruncatedFrom"] = stderrCapped.originalCount }
        return resp
    }

    /// Truncate an RPC output string to a serialization-safe size (UTF-16
    /// unit cap ≈ 4 MB of UTF-8 for ASCII-ish shell output), keeping the HEAD
    /// (build logs / command output lead with the useful part) and appending
    /// an explicit truncation marker. [T-ios-debugrpc-json-nsexception-abort]
    private static func capRPCOutput(_ s: String, limit: Int = 4_000_000) -> (text: String, truncated: Bool, originalCount: Int) {
        let count = s.utf16.count
        guard count > limit else { return (s, false, count) }
        let head = String(s.prefix(limit))
        return (head + "\n…[truncated \(count - limit) of \(count) UTF-16 units by debug server]", true, count)
    }

    /// Holds state for the stdin-script path's async-to-sync bridge.
    private final class ISHShellExecutionContextBox {
        let sem = DispatchSemaphore(value: 0)
        var result: ISHShellExecutionResult?
    }

    private func handleAppInfo(params: [String: Any] = [:]) -> Any {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dataPath = ISHRootfsManager.dataURL
        let bundlePath = Bundle.main.bundlePath
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!

        // Binary modification date as build date
        let executableURL = Bundle.main.executableURL
        let buildDate: String
        if let url = executableURL,
           let attrs = try? fm.attributesOfItem(atPath: url.path),
           let mod = attrs[.modificationDate] as? Date {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            buildDate = fmt.string(from: mod)
        } else {
            buildDate = "unknown"
        }

        var result: [String: Any] = [
            "documentsPath": docs.path,
            "libraryPath": library.path,
            "dataPath": dataPath.path,
            "rootfsPath": ISHRootfsManager.rootURL.path,
            "bundlePath": bundlePath,
            // [T-ish-shell-timeout-leak] Reader-thread accounting. `liveReaders`
            // should sit at 0 between commands; a value that only grows is the
            // shell timeout leak recurring.
            "shellLeakGuard": ISHShellExecutor.leakGuardStatus(),
            "buildDate": buildDate,
        ]

        // Disk usage requires recursive directory walks that can be very slow
        // when alpine-rootfs/data has millions of files. Off by default; pass
        // {"includeDiskUsage": true} to opt in.
        if (params["includeDiskUsage"] as? Bool) == true {
            func dirSize(_ url: URL) -> Int64 {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
                var total: Int64 = 0
                for case let fileURL as URL in enumerator {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(size)
                    }
                }
                return total
            }
            result["diskUsage"] = [
                "documents": dirSize(docs),
                "rootfsData": dirSize(dataPath),
                "bundle": dirSize(URL(fileURLWithPath: bundlePath)),
            ]
        }
        return result
    }

    // MARK: - Touch / Input / Scroll Handlers

    private func handleTap(params: [String: Any]) async throws -> Any {
        // Priority: identifier > label > text (partial) > address > x/y. The
        // accessibility-based paths sidestep the SwiftUI hit-test problem —
        // a synthetic UITouch dispatched at a coordinate often lands on the
        // containing ListCollectionViewCell but never reaches SwiftUI's
        // internal tap gesture. `accessibilityActivate()` DOES reach it,
        // because SwiftUI's Button/onTapGesture wire that up directly.
        //
        // Outer timeout: even though the inspector's walk is budget-bounded
        // internally (1.5s), an already-stuck main thread from prior work
        // could still delay THIS request's MainActor hop indefinitely. We
        // wrap the whole hop in a race against a 3s deadline so the client
        // ALWAYS gets a response within a bounded time.
        //
        // First-line strategy for text/label/identifier: forward to iCTRL's
        // find_and_tap RPC on 127.0.0.1:8200. iCTRL is a UI test bundle so
        // it has XCUIElement.tap(), which drives the OS's real touch
        // pipeline and works on SwiftUI Lists / hosting-view content that
        // OpenMinis' app-embedded synthesis can't reach. iCTRL's isLoopback
        // check bypasses its bearer auth for us. If iCTRL isn't running (or
        // returns "no element found") we fall through to the existing app-
        // embedded escalation ladder — behaviour unchanged when the tool
        // isn't installed.
        // Order of preference for element-lookup taps:
        // 1. App-embedded ladder FIRST. If it engages `accessibilityActivate`
        //    (buttons, .button-trait AX nodes), `didSelectItemAt`, or
        //    UIControl.sendActions, the button's REAL handler runs — this is
        //    what worked for the "Default Models" toolbar chip.
        // 2. Only if the local ladder falls back to synthesized coordinate
        //    tap (`via` starts with "coordinate" or ends with
        //    "→coordinate(...)"), we escalate to iCTRL's XCUIElement.tap.
        //    That's the path for SwiftUI List rows / hosting-view content
        //    whose activation isn't published via the accessibility API.
        // 3. If iCTRL is unreachable or reports no matching element, the
        //    local result (the synthesized-tap envelope) is returned as-is.
        func localResultUsedCoordinateFallback(_ result: [String: Any]) -> Bool {
            guard let via = result["via"] as? String else { return false }
            if via == "coordinate" { return true }
            if via.hasSuffix("→coordinate") { return true }
            // Also matches "collectionCell:1-0→coordinate(207,541)" etc.
            if via.contains("→coordinate(") { return true }
            return false
        }
        func tryICTRLThenReturn(local: [String: Any]) async -> Any {
            if localResultUsedCoordinateFallback(local),
               let forwarded = await Self.forwardTapToICTRL(params: params) {
                return forwarded
            }
            return local
        }

        if let identifier = params["identifier"] as? String, !identifier.isEmpty {
            let local = await Self.withMainActorTimeout(strategy: "identifier=\(identifier)") {
                self.performTargetTap(strategy: "identifier=\(identifier)") {
                    self.inspector.findTarget(identifier: identifier)
                }
            }
            return await tryICTRLThenReturn(local: local)
        }
        if let label = params["label"] as? String, !label.isEmpty {
            let local = await Self.withMainActorTimeout(strategy: "label=\(label)") {
                self.performTargetTap(strategy: "label=\(label)") {
                    self.inspector.findTarget(text: label, partial: false)
                }
            }
            return await tryICTRLThenReturn(local: local)
        }
        if let text = params["text"] as? String, !text.isEmpty {
            let partial = (params["partial"] as? Bool) ?? true
            let local = await Self.withMainActorTimeout(strategy: "text=\(text) partial=\(partial)") {
                self.performTargetTap(strategy: "text=\(text) partial=\(partial)") {
                    self.inspector.findTarget(text: text, partial: partial)
                }
            }
            return await tryICTRLThenReturn(local: local)
        }

        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw RPCError(code: -32602, message: "Invalid params: pass 'identifier', 'label', 'text' (with optional 'partial'), or numeric 'x' + 'y'")
        }
        let point = CGPoint(x: x, y: y)

        // Optional: tap on a specific view by address
        if let address = params["address"] as? String, !address.isEmpty {
            return await MainActor.run {
                guard let view = self.inspector.findView(byAddress: address) else {
                    return ["ok": false, "error": "View not found at address \(address)"] as [String: Any]
                }
                AutoTouch.simulateTap(at: point, in: view)
                return ["ok": true, "point": ["x": x, "y": y], "view": address, "via": "coordinate"] as [String: Any]
            }
        }

        await MainActor.run {
            AutoTouch.simulateTap(at: point, in: nil)
        }
        return ["ok": true, "point": ["x": x, "y": y], "via": "coordinate"] as [String: Any]
    }

    /// URL of iCTRL's JSON-RPC endpoint on this device. iCTRL is a co-
    /// installed XCTest automation service (bundle com.openminis.ictrl,
    /// port 8200). It runs inside a UI test runner so it can drive
    /// XCUIElement.tap() — which we can't from the app process.
    /// Loopback auth exemption on iCTRL side means we don't send a token.
    private static let ictrlRPCURL = URL(string: "http://127.0.0.1:8200/rpc")!

    /// Try iCTRL's find_and_tap. Maps our tap params to iCTRL's schema:
    ///   identifier / label → element_id + match:"exact"
    ///   text[, partial]    → element_id + match:"contains" | "exact"
    /// Returns iCTRL's result envelope when the call succeeded (with a
    /// synthesised via:"ictrl" so callers can see the mechanism). Returns
    /// nil when iCTRL isn't reachable or replied that no element matched
    /// — so the caller falls through to the app-embedded escalation.
    static func forwardTapToICTRL(params: [String: Any]) async -> [String: Any]? {
        // Assemble find_and_tap params from whichever field was supplied.
        var elementId: String = ""
        var matchMode: String = "exact"
        var strategy: String = ""
        if let identifier = params["identifier"] as? String, !identifier.isEmpty {
            elementId = identifier; strategy = "identifier=\(identifier)"
        } else if let label = params["label"] as? String, !label.isEmpty {
            elementId = label; strategy = "label=\(label)"
        } else if let text = params["text"] as? String, !text.isEmpty {
            let partial = (params["partial"] as? Bool) ?? true
            elementId = text
            matchMode = partial ? "contains" : "exact"
            strategy = "text=\(text) partial=\(partial)"
        } else {
            return nil
        }

        // iCTRL defaults to querying whatever app is currently bound (or
        // SpringBoard if none). Since debug.tap is called BY the app asking
        // to tap something in ITSELF, pin the query to our own bundle id
        // unless the caller explicitly overrides via ictrl_bundle_id.
        let bundleId = (params["ictrl_bundle_id"] as? String) ?? Bundle.main.bundleIdentifier ?? "dev.oases.chat.ios"
        let rpcParams: [String: Any] = [
            "element_id": elementId,
            "match": matchMode,
            "bundle_id": bundleId,
        ]
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "find_and_tap",
            "params": rpcParams,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: ictrlRPCURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // find_and_tap can take up to ~4s (locate + native XCUIElement.tap).
        // Give it 8s total headroom; we still return an error envelope on
        // timeout without hanging the client.
        request.timeoutInterval = 8.0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 10.0
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // Success envelope from iCTRL. Return it verbatim with a stamp
            // so debug.tap callers can see the mechanism.
            if http.statusCode == 200, let result = obj["result"] as? [String: Any] {
                var out = result
                out["ok"] = true
                out["via"] = "ictrl"
                out["strategy"] = strategy
                return out
            }
            // iCTRL replied but couldn't tap (bad token, no element, etc.).
            // "No element matching" → nil so we retry with the app-embedded
            // path. Anything else we surface so the caller sees why iCTRL
            // rejected (auth failure, invalid params, method missing).
            if let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                if msg.contains("no element matching") || msg.contains("No element matching") {
                    return nil
                }
                return [
                    "ok": false, "via": "ictrl", "strategy": strategy,
                    "error": "ictrl: \(msg)",
                    "ictrl_status": http.statusCode,
                ]
            }
            return nil
        } catch {
            // Connection refused / timeout / DNS — iCTRL isn't running.
            return nil
        }
    }

    /// Race a MainActor.run against a wall-clock deadline. If the main-actor
    /// work doesn't finish within the timeout, return an "ok:false, timeout"
    /// envelope so the client's RPC returns fast instead of hanging.
    ///
    /// Note: this can't ABORT main-thread work — Swift/Obj-C UI code isn't
    /// cancellable mid-call. What it does is stop THIS RPC's response from
    /// waiting on it. The stuck main thread will eventually finish (or crash
    /// the process); either way the client isn't held hostage.
    static func withMainActorTimeout(strategy: String,
                                     seconds: Double = 3.0,
                                     _ body: @escaping @MainActor () -> [String: Any]) async -> [String: Any] {
        // Kick off the main-actor work and a sleep in parallel; take whichever
        // finishes first. TaskGroup handles cleanup of the loser.
        return await withTaskGroup(of: (kind: String, value: [String: Any]).self) { group in
            group.addTask {
                let result = await MainActor.run { body() }
                return ("done", result)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return ("timeout", [
                    "ok": false,
                    "strategy": strategy,
                    "error": "main thread busy — request timed out after \(seconds)s; try 'identifier' if you know one, or fall back to x/y",
                    "timedOutAfter": seconds,
                ] as [String: Any])
            }
            defer { group.cancelAll() }
            if let first = await group.next() {
                return first.value
            }
            return ["ok": false, "strategy": strategy, "error": "task group returned nothing"] as [String: Any]
        }
    }

    /// Walk a UICollectionViewCell subtree looking for something whose
    /// activation actually fires the SwiftUI row handler. We try, per node:
    ///   1. accessibilityActivate() — public; SwiftUI Buttons implement it.
    ///   2. _accessibilityActivate — private VoiceOver hook; SwiftUI's
    ///      internal cell hosting view implements this even for List rows
    ///      that don't publish `.button` traits.
    ///   3. Any accessibilityCustomActions[0] — Apple-recommended when a row
    ///      has a primary action but isn't a Button (e.g. List rows with
    ///      selection binding).
    /// Returns which mechanism won (or nil if nothing accepted). Capped at
    /// 32 nodes for safety — a SwiftUI row is a handful of views.
    @MainActor
    private static func activateCellOrDescendant(_ root: UIView) -> String? {
        // [T-ios-debugtap-nsexception-abort] Every activation below hands
        // control to arbitrary UIKit/SwiftUI accessibility machinery that can
        // raise NSExceptions (device crash 2026-07-23 20:41, Build 1.11(1):
        // customAction target.perform → Foundation recursion → NSException →
        // abort, taking the whole app down from a debug-server tap RPC fired
        // during launch). Swift can't catch ObjC exceptions — run each
        // invocation under OasesCatchObjCException and treat a raise as
        // "this node didn't activate" instead of terminating the process.
        var stack: [UIView] = [root]
        var visits = 0
        var caughtReason: NSString?
        func attempt(_ label: String, _ body: () -> Bool) -> Bool {
            var accepted = false
            var reason: NSString?
            let ok = OasesCatchObjCException({ accepted = body() }, &reason)
            if !ok {
                caughtReason = reason
                AppLogger(category: "DebugServer").error("[debug.tap] \(label) raised NSException (caught): \(reason ?? "?")")
                return false
            }
            return accepted
        }
        while let v = stack.popLast() {
            visits += 1
            if visits > 32 { break }
            if attempt("accessibilityActivate", { v.accessibilityActivate() }) {
                return "accessibilityActivate"
            }
            // Private VoiceOver hook. On iOS 17+, SwiftUI's cell hosting view
            // implements this; the public `accessibilityActivate` doesn't
            // forward to it for non-button rows.
            let sel = NSSelectorFromString("_accessibilityActivate")
            if v.responds(to: sel) {
                if attempt("_accessibilityActivate", { _ = v.perform(sel); return true }) {
                    return "_accessibilityActivate"
                }
            }
            if let actions = v.accessibilityCustomActions, !actions.isEmpty {
                let action = actions[0]
                if let target = action.target, let selector = action.selector as Selector?,
                   target.responds(to: selector) {
                    if attempt("customAction.perform", { _ = target.perform(selector, with: action); return true }) {
                        return "customAction(\(action.name))"
                    }
                } else if let handler = action.actionHandler {
                    if attempt("customAction.handler", { _ = handler(action); return true }) {
                        return "customAction(\(action.name))"
                    }
                }
            }
            for sub in v.subviews { stack.append(sub) }
        }
        _ = caughtReason
        return nil
    }

    /// Resolve a target via the lookup closure, then escalate to an ancestor
    /// that will actually respond before invoking. This matters because a
    /// SwiftUI `Text` inside a `List` row shows up in the accessibility tree
    /// as a `staticText` leaf — activating IT does nothing. The real handler
    /// lives on the `UICollectionViewCell` above, and the collection view's
    /// delegate dispatches selection. See DebugViewInspector.resolveActionable
    /// for the full escalation ladder.
    @MainActor
    private func performTargetTap(strategy: String, lookup: () -> DebugViewInspector.TapTarget?) -> [String: Any] {
        guard let target = lookup() else {
            return ["ok": false, "strategy": strategy, "error": "no on-screen element matched"]
        }
        let point = target.screenPoint
        let actionable = self.inspector.resolveActionable(target)
        var via = actionable.description
        switch actionable {
        case .control(let control):
            // sendActions is the exact same call the runtime makes when the
            // user taps a UIButton/UISwitch — no synthetic touch required.
            // Guarded: the invoked handler is arbitrary app code that may
            // raise an ObjC exception Swift can't catch.
            // [T-ios-debugtap-nsexception-abort]
            var sendReason: NSString?
            if !OasesCatchObjCException({ control.sendActions(for: .touchUpInside) }, &sendReason) {
                AppLogger(category: "DebugServer").error("[debug.tap] sendActions raised NSException (caught): \(sendReason ?? "?")")
                return ["ok": false, "strategy": strategy,
                        "error": "target action raised NSException: \(sendReason ?? "?")"]
            }
        case .collectionCell(let cv, let indexPath, let cell):
            // SwiftUI-backed cells (List / ForEach rows) frequently:
            //  * Return false from shouldSelectItemAt (the collection view's
            //    built-in selection is off because SwiftUI runs its own state).
            //  * Have NO UITapGestureRecognizer we can find — the tap handler
            //    is buried in a SwiftUI-internal recogniser.
            // In that setup neither delegate.didSelectItemAt nor a synthetic
            // UITouch does anything visible. But `accessibilityActivate()` on
            // the CellHostingView (or the cell itself) IS wired: VoiceOver
            // relies on it to activate SwiftUI List rows, so SwiftUI publishes
            // a working handler there. Try that path first.
            //
            // Order:
            //  1. cell.accessibilityActivate() and every direct descendant's
            //     accessibilityActivate() — one of them (the CellHostingView)
            //     usually returns true for SwiftUI rows.
            //  2. Delegate dispatch (works for classic UICollectionView code
            //     that gates via shouldSelectItemAt).
            //  3. Synthetic tap at the cell centre (last resort).
            let indexTag = "\(indexPath.section)-\(indexPath.item)"
            if let mechanism = Self.activateCellOrDescendant(cell) {
                via = "collectionCell:\(indexTag)→\(mechanism)"
            } else {
                let delegate = cv.delegate
                let allowed = delegate?.collectionView?(cv, shouldSelectItemAt: indexPath) ?? true
                if allowed {
                    cv.selectItem(at: indexPath, animated: true, scrollPosition: [])
                    cell.isSelected = true
                    delegate?.collectionView?(cv, didSelectItemAt: indexPath)
                    via = "collectionCell:\(indexTag)→didSelect"
                } else {
                    let centre = cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
                    AutoTouch.simulateTap(at: centre, in: nil)
                    via = "collectionCell:\(indexTag)→coordinate(\(Int(centre.x)),\(Int(centre.y)))"
                }
            }
        case .tableCell(let tv, let indexPath, _):
            let delegate = tv.delegate
            // willSelectRowAt returns the target IndexPath (possibly a
            // different one, or nil to cancel).
            let target = delegate?.tableView?(tv, willSelectRowAt: indexPath) ?? indexPath
            tv.selectRow(at: target, animated: true, scrollPosition: .none)
            delegate?.tableView?(tv, didSelectRowAt: target)
        case .buttonElement(let element):
            if !element.accessibilityActivate() {
                AutoTouch.simulateTap(at: point, in: nil)
                via = "buttonElement→coordinate"
            }
        case .activatableView(let view):
            if !view.accessibilityActivate() {
                AutoTouch.simulateTap(at: point, in: nil)
                via = "activatableView→coordinate"
            }
        case .coordinate:
            AutoTouch.simulateTap(at: point, in: nil)
        }
        return [
            "ok": true,
            "strategy": strategy,
            "via": via,
            "point": ["x": point.x, "y": point.y],
        ]
    }

    private func handleInputText(params: [String: Any]) async throws -> Any {
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw RPCError(code: -32602, message: "Invalid params: 'text' (string) is required")
        }
        let ok = await MainActor.run {
            AutoTouch.inputText(text)
        }
        return ["ok": ok, "length": text.count] as [String: Any]
    }

    private func handleScroll(params: [String: Any]) async throws -> Any {
        guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
            throw RPCError(code: -32602, message: "Invalid params: 'x' and 'y' (start point) are required")
        }
        let deltaX = params["deltaX"] as? Double ?? 0.0
        let deltaY = params["deltaY"] as? Double ?? 0.0

        if deltaX == 0 && deltaY == 0 {
            throw RPCError(code: -32602, message: "Invalid params: at least one of 'deltaX' or 'deltaY' must be non-zero")
        }

        await MainActor.run {
            AutoTouch.simulateScroll(at: CGPoint(x: x, y: y),
                                     deltaX: CGFloat(deltaX),
                                     deltaY: CGFloat(deltaY),
                                     in: nil)
        }
        return ["ok": true, "start": ["x": x, "y": y], "delta": ["x": deltaX, "y": deltaY]] as [String: Any]
    }

    // MARK: - JSON Response Helpers

    private func successResponse(result: Any, id: Any?) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
            "_meta": Self.responseMeta,
        ]
        return jsonString(response)
    }

    private func errorResponse(code: Int, message: String, id: Any?) -> String {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
            "_meta": Self.responseMeta,
        ]
        return jsonString(response)
    }

    private func jsonString(_ obj: Any) -> String {
        // [T-ios-debugrpc-json-nsexception-abort] `try?` only catches the
        // Swift-error path. NSJSONSerialization ALSO raises ObjC exceptions —
        // NSInvalidArgumentException for non-serializable values (NaN/Inf,
        // arbitrary objects) and NSMallocException when _convertJSONString's
        // CFString reallocation fails on a huge payload (device crash
        // 2026-07-23 20:58, Build 1.11(1): shell RPC stdout large enough that
        // __CFStringHandleOutOfMemory raised → abort on thread "sh-2").
        // Swift can't catch those; run the writer under the @try/@catch
        // bridge and fall back to a fixed error envelope.
        var data: Data?
        var reason: NSString?
        let ok = OasesCatchObjCException({
            data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }, &reason)
        guard ok, let data, let str = String(data: data, encoding: .utf8) else {
            if let reason {
                AppLogger(category: "DebugServer").error("[rpc] response serialization raised NSException (caught): \(reason)")
            }
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Serialization failed\"}}"
        }
        return str
    }

    // MARK: - Env Var Handlers

    /// Serialize an EnvVarEntry for RPC. Includes hasValue (Keychain probe);
    /// optionally includes the decoded plaintext value when includeValues=true.
    @MainActor
    private func encodeEnvVarEntry(_ entry: EnvVarEntry, includeValue: Bool) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let stored = EnvVarStore.loadValueSync(forKey: entry.key)
        let hasValue = (stored?.isEmpty == false)
        var dict: [String: Any] = [
            "id": entry.id,
            "key": entry.key,
            "note": entry.note,
            "createdAt": iso.string(from: entry.createdAt),
            // EnvVarEntry has no per-row updatedAt yet — mirror createdAt so
            // callers can rely on the field being present.
            "updatedAt": iso.string(from: entry.createdAt),
            "hasValue": hasValue,
        ]
        if includeValue {
            dict["value"] = stored ?? ""
        }
        return dict
    }

    /// debug.envvar.list — return all env-var entries. With
    /// `includeValues=true`, also includes the decoded Keychain value.
    private func handleEnvVarList(params: [String: Any]) async -> Any {
        let includeValues = (params["includeValues"] as? Bool) ?? false
        return await MainActor.run { () -> [String: Any] in
            let entries = EnvVarStore.shared.entries
            let items = entries.map { self.encodeEnvVarEntry($0, includeValue: includeValues) }
            return ["count": items.count, "entries": items]
        }
    }

    /// debug.envvar.set — create or update an entry. Update by `id` first,
    /// else by `key`, else create new. Routes through EnvVarStore so the
    /// dirty-marking / sync push behaves identically to user edits.
    private func handleEnvVarSet(params: [String: Any]) async -> Any {
        let key = (params["key"] as? String) ?? ""
        let value = params["value"] as? String
        let note = params["note"] as? String
        let idParam = params["id"] as? String

        return await MainActor.run { () -> [String: Any] in
            let store = EnvVarStore.shared
            // Resolve target entry: explicit id, then matching key, else new.
            let existing: EnvVarEntry?
            if let idParam, !idParam.isEmpty {
                existing = store.entry(id: idParam)
            } else if !key.isEmpty {
                let upper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                existing = store.entries.first(where: { $0.key == upper })
            } else {
                existing = nil
            }

            if let existing {
                let newKey = key.isEmpty ? existing.key : key
                // Use existing value when caller passed nil (note-only update).
                let newValue: String
                if let value {
                    newValue = value
                } else {
                    newValue = EnvVarStore.loadValueSync(forKey: existing.key) ?? ""
                }
                store.update(id: existing.id, key: newKey, value: newValue, note: note)
                if let updated = store.entry(id: existing.id) {
                    return self.encodeEnvVarEntry(updated, includeValue: false)
                }
                return ["error": "update failed"]
            } else {
                guard !key.isEmpty else {
                    return ["error": "missing key"]
                }
                store.add(key: key, value: value ?? "", note: note ?? "")
                let upper = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let created = store.entries.first(where: { $0.key == upper }) {
                    return self.encodeEnvVarEntry(created, includeValue: false)
                }
                return ["error": "add failed (invalid key or duplicate)"]
            }
        }
    }

    /// debug.envvar.delete — delete by `id` or by `key`. Routes through
    /// EnvVarStore so the entry's per-key sync record is queued for delete.
    private func handleEnvVarDelete(params: [String: Any]) async -> Any {
        let idParam = params["id"] as? String
        let keyParam = params["key"] as? String
        return await MainActor.run { () -> [String: Any] in
            let store = EnvVarStore.shared
            let target: EnvVarEntry?
            if let idParam, !idParam.isEmpty {
                target = store.entry(id: idParam)
            } else if let keyParam, !keyParam.isEmpty {
                let upper = keyParam.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                target = store.entries.first(where: { $0.key == upper })
            } else {
                return ["deleted": false, "error": "missing id or key"]
            }
            guard let target else {
                return ["deleted": false]
            }
            store.delete(id: target.id)
            return ["deleted": true, "id": target.id, "key": target.key]
        }
    }

    // MARK: - Error Type

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    // MARK: - Quick Test handler


    // MARK: - DB inspection (read-only SQL over the app's SQLite files)



    /// Open a database strictly read-only. Uses a file: URI with mode=ro so we
    /// can never mutate the live db a running actor also holds open.
    private func openReadOnly(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro&immutable=0"
        let rc = sqlite3_open_v2(uri, &handle,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            handle.map { sqlite3_close($0) }
            throw RPCError(code: -32000, message: "Failed to open db read-only: \(msg)")
        }
        // 5s busy timeout so a concurrent writer's lock doesn't fail us outright.
        sqlite3_busy_timeout(handle, 5000)
        return handle
    }

    /// Reject anything that isn't a single read-only statement. Defence in depth:
    /// the connection is already opened read-only (writes fail at the engine),
    /// but this gives a clear error instead of a cryptic SQLITE_READONLY and
    /// blocks multi-statement smuggling.
    private func assertReadOnlySQL(_ sql: String) throws {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RPCError(code: -32602, message: "Empty sql.")
        }
        // Disallow statement separators that would allow a second statement.
        // A trailing semicolon is fine; an interior one is not.
        let withoutTrailing = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
        if withoutTrailing.contains(";") {
            throw RPCError(code: -32602, message: "Only a single statement is allowed (no ';' inside the query).")
        }
        let head = withoutTrailing.lowercased()
        let allowed = ["select", "pragma", "explain", "with", "values"]
        guard allowed.contains(where: { head.hasPrefix($0) }) else {
            throw RPCError(code: -32602, message: "Only read-only queries allowed (SELECT/WITH/PRAGMA/EXPLAIN/VALUES). Got: \(head.prefix(20))…")
        }
    }

    /// Run a prepared read-only statement and materialise up to `limit` rows as
    /// [[column: value]]. NULL → NSNull, INTEGER/FLOAT → Number, TEXT → String,
    /// BLOB → {"__blob__": byteCount} (never inlined — could be huge/binary).
    private func runQuery(dbURL: URL, sql: String, limit: Int) throws -> [String: Any] {
        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw RPCError(code: -32000, message: "SQL error: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        for i in 0..<colCount {
            columns.append(String(cString: sqlite3_column_name(stmt, Int32(i))))
        }

        var rows: [[String: Any]] = []
        var truncated = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if rows.count >= limit { truncated = true; break }
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let c = Int32(i)
                let value: Any
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_NULL:
                    value = NSNull()
                case SQLITE_INTEGER:
                    value = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT:
                    value = sqlite3_column_double(stmt, c)
                case SQLITE_BLOB:
                    value = ["__blob__": Int(sqlite3_column_bytes(stmt, c))]
                default:
                    if let text = sqlite3_column_text(stmt, c) {
                        value = String(cString: text)
                    } else {
                        value = NSNull()
                    }
                }
                row[columns[i]] = value
            }
            rows.append(row)
        }
        return [
            "columns": columns,
            "rows": rows,
            "rowCount": rows.count,
            "truncated": truncated,
        ]
    }




}
#endif
