import Foundation
import os.log

private let logger = AppLogger(category: "SessionFork")

/// Handles forking remote sessions (deep copy) and copying remote skills/memories to local device.
@MainActor
final class SessionForkManager {
    static let shared = SessionForkManager()
    private init() {}

    // MARK: - Fork Remote Session

    /// Fork a remote session into a new local session with deep-copied messages.
    func forkSession(remoteSessionId: String, remoteDeviceId: String) async -> ChatSession? {
        let store = ChatStore.shared

        // Load remote session
        let remoteSessions = await store.listRemoteSessions(deviceId: remoteDeviceId)
        guard let remoteSession = remoteSessions.first(where: { $0.id == remoteSessionId }) else {
            logger.error("[Fork] Remote session not found: \(remoteSessionId)")
            return nil
        }

        // Create new local session
        let sourceTitle = remoteSession.title ?? String(localized: "Untitled", comment: "Fallback title for a session without one")
        let forkTitle = String(localized: "\(sourceTitle) (Fork)", comment: "Title of a session forked from another device; argument is the original title")
        let newSession = await store.createSession(modelId: remoteSession.modelId, title: forkTitle)

        // Update category if present
        if let category = remoteSession.category {
            await store.updateSessionTitle(newSession.id, title: forkTitle, category: category)
        }

        // Load and deep-copy messages. Media files present on this device are
        // copied too, and the refs re-pointed at the copies. (Remote compact
        // markers have no local mirror to copy from.)
        let remoteMessages = await store.loadRemoteMessages(sessionId: remoteSessionId, deviceId: remoteDeviceId)
        let copiedMedia = await copySessionMedia(from: remoteSessionId, to: newSession.id, store: store)
        for msg in remoteMessages {
            let newMsg = RawMessage(
                id: UUID().uuidString,
                sessionId: newSession.id,
                role: msg.role,
                parts: Self.rebasedParts(msg.parts, from: remoteSessionId, to: newSession.id, copied: copiedMedia),
                createdAt: msg.createdAt,
                tokenUsage: msg.tokenUsage,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount
            )
            await store.appendMessage(newMsg)
        }

        logger.info("[Fork] Forked remote session \(remoteSessionId) → \(newSession.id) (\(remoteMessages.count) messages)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: newSession.id)

        return newSession
    }

    // MARK: - Duplicate Local Session

    /// Duplicate a local session (same as fork but reads from main tables).
    func duplicateSession(sessionId: String) async -> ChatSession? {
        let store = ChatStore.shared

        guard let session = await store.getSession(sessionId) else {
            logger.error("[Fork] Local session not found: \(sessionId)")
            return nil
        }

        let sourceTitle = session.title ?? String(localized: "Untitled", comment: "Fallback title for a session without one")
        let dupTitle = String(localized: "\(sourceTitle) (Copy)", comment: "Title of a duplicated session; argument is the original title")
        let newSession = await store.createSession(modelId: session.modelId, title: dupTitle)

        if let category = session.category {
            await store.updateSessionTitle(newSession.id, title: dupTitle, category: category)
        }

        let messages = await store.loadMessages(sessionId: sessionId)
        // Copy the media the messages reference into the new session and point
        // the refs at the copies; otherwise the duplicate's images live in the
        // original's directory and vanish when the original is deleted.
        let copiedMedia = await copySessionMedia(from: sessionId, to: newSession.id, store: store)
        // [T-session-duplicate-compact-marker-ios] Track old→new message id so
        // copied compact markers (which reference DB message ids) can be
        // remapped onto the freshly-minted duplicate messages. Without this the
        // markers dangle and the compact divider/shadow is lost on the copy.
        var oldToNewMessageId: [String: String] = [:]
        for msg in messages {
            let newId = UUID().uuidString
            oldToNewMessageId[msg.id] = newId
            let newMsg = RawMessage(
                id: newId,
                sessionId: newSession.id,
                role: msg.role,
                parts: Self.rebasedParts(msg.parts, from: sessionId, to: newSession.id, copied: copiedMedia),
                createdAt: msg.createdAt,
                tokenUsage: msg.tokenUsage,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount
            )
            await store.appendMessage(newMsg)
        }

        // [T-session-duplicate-compact-marker-ios] Copy compact markers AFTER
        // all messages are appended (so the new messages' sort_orders exist).
        // Zero-marker sessions make this a no-op — the normal duplicate path is
        // untouched. Each marker is remapped independently so multi-compact
        // sessions copy all dividers, in createdAt order (compactMarkers ORDERs
        // by created_at ASC; insertCompactMarker preserves each createdAt).
        let markers = await store.compactMarkers(sessionId: sessionId)
        if !markers.isEmpty {
            // Authoritative new sort_orders, keyed by the new message id.
            let newMessages = await store.loadMessages(sessionId: newSession.id)
            let newSortOrderById = Dictionary(
                uniqueKeysWithValues: newMessages.map { ($0.id, $0.sortOrder) }
            )
            // Remap a referenced message id through the copy map. nil → nil.
            func remapId(_ id: String?) -> String? {
                guard let id else { return nil }
                return oldToNewMessageId[id]
            }
            // Resolve a legacy sort_order fallback to the NEW message's
            // sort_order via the remapped id; keep the original if the id
            // can't be resolved (legacy markers whose id field is nil).
            func remapSortOrder(messageId: String?, original: Int) -> Int {
                guard let newId = remapId(messageId),
                      let so = newSortOrderById[newId] else { return original }
                return so
            }
            var copied = 0
            for marker in markers {
                // All source messages are copied, so every non-nil id field
                // MUST resolve. If one doesn't, the marker is corrupt/dangling
                // already — skip it rather than write a dangling copy.
                let firstKeptNew = remapId(marker.firstKeptMessageId)
                let lastCompactedNew = remapId(marker.lastCompactedMessageId)
                let boundaryNew = remapId(marker.boundaryMessageId)
                if (marker.firstKeptMessageId != nil && firstKeptNew == nil)
                    || (marker.lastCompactedMessageId != nil && lastCompactedNew == nil)
                    || (marker.boundaryMessageId != nil && boundaryNew == nil) {
                    logger.error("[Fork] Skipping compact marker \(marker.id): a referenced message id is not in the copy map (dangling source marker)")
                    continue
                }
                let copy = CompactMarker(
                    id: UUID().uuidString,
                    sessionId: newSession.id,
                    summary: marker.summary,
                    firstKeptSortOrder: remapSortOrder(
                        messageId: marker.firstKeptMessageId,
                        original: marker.firstKeptSortOrder
                    ),
                    compactedCount: marker.compactedCount,
                    createdAt: marker.createdAt,
                    uiBoundarySortOrder: marker.uiBoundarySortOrder.map { _ in
                        remapSortOrder(
                            messageId: marker.boundaryMessageId,
                            original: marker.uiBoundarySortOrder ?? 0
                        )
                    },
                    boundaryMessageId: boundaryNew,
                    firstKeptMessageId: firstKeptNew,
                    lastCompactedMessageId: lastCompactedNew,
                    version: marker.version
                )
                await store.insertCompactMarker(copy)
                copied += 1
            }
            logger.info("[Fork] Copied \(copied)/\(markers.count) compact marker(s) to \(newSession.id)")
        }

        logger.info("[Fork] Duplicated session \(sessionId) → \(newSession.id) (\(messages.count) messages)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: newSession.id)

        return newSession
    }

    // MARK: - Session Media

    /// Session subdirectories that hold the files `MediaRef`s point at — the
    /// set `ChatStore.deleteSessionMedia` treats as a session's media.
    nonisolated static let mediaSubdirectories = ["attachments", "browser", "images"]

    /// Copy `sourceId`'s media into `targetId` off the main thread and queue
    /// the copies for iCloud (same SessionFile record ids `saveMedia` uses).
    /// Returns the copied files' session-relative paths.
    private func copySessionMedia(from sourceId: String, to targetId: String, store: ChatStore) async -> Set<String> {
        let baseURL = store.minisBaseURL
        let copied = await Task.detached(priority: .utility) {
            Self.copySessionMediaFiles(from: sourceId, to: targetId, baseURL: baseURL)
        }.value
        for relativePath in copied.sorted() {
            await store.markDirty(recordType: "SessionFile", recordId: "\(targetId):\(relativePath)")
        }
        if !copied.isEmpty {
            logger.info("[Fork] Copied \(copied.count) media file(s) \(sourceId) → \(targetId)")
        }
        return copied
    }

    /// Copies every regular file under `<base>/<sourceId>/<mediaSubdirectory>`
    /// to the same place under `targetId` (APFS clones, so no extra space until
    /// either side changes). Returns session-relative paths like
    /// `attachments/<file>`.
    nonisolated static func copySessionMediaFiles(from sourceId: String, to targetId: String, baseURL: URL) -> Set<String> {
        let fm = FileManager.default
        var copied = Set<String>()
        for subdirectory in mediaSubdirectories {
            let sourceDir = baseURL.appendingPathComponent(sourceId, isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
            let targetDir = baseURL.appendingPathComponent(targetId, isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
            guard let subpaths = try? fm.subpathsOfDirectory(atPath: sourceDir.path) else { continue }
            for subpath in subpaths {
                var isDirectory: ObjCBool = false
                let source = sourceDir.appendingPathComponent(subpath)
                guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let target = targetDir.appendingPathComponent(subpath)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: target)
                    copied.insert("\(subdirectory)/\(subpath)")
                } catch {
                    logger.error("[Fork] Media copy failed for \(subdirectory)/\(subpath): \(error.localizedDescription)")
                }
            }
        }
        return copied
    }

    /// Re-point `MediaRef`s (message, tool result and snapshot) from
    /// `<sourceId>/…` to `<targetId>/…` for the files in `copied`. Refs to files
    /// that weren't copied keep pointing at the original.
    nonisolated static func rebasedParts(
        _ parts: [ContentPart], from sourceId: String, to targetId: String, copied: Set<String>
    ) -> [ContentPart] {
        let prefix = sourceId + "/"
        func rebase(_ ref: MediaRef?) -> MediaRef? {
            guard let ref, ref.relativePath.hasPrefix(prefix) else { return ref }
            let sessionRelative = String(ref.relativePath.dropFirst(prefix.count))
            guard copied.contains(sessionRelative) else { return ref }
            return MediaRef(
                id: ref.id,
                relativePath: targetId + "/" + sessionRelative,
                mimeType: ref.mimeType,
                originalFileName: ref.originalFileName,
                linuxPath: ref.linuxPath
            )
        }
        return parts.map { part in
            switch part {
            case .mediaRef(let ref):
                return .mediaRef(rebase(ref) ?? ref)
            case .toolResult(let result):
                return .toolResult(ChatMessageToolResult(
                    toolUseId: result.toolUseId,
                    output: result.output,
                    success: result.success,
                    mediaRef: rebase(result.mediaRef),
                    snapshot: result.snapshot.map {
                        ToolSnapshot(type: $0.type, text: $0.text, mediaRef: rebase($0.mediaRef), duration: $0.duration)
                    },
                    pageURL: result.pageURL,
                    status: result.status
                ))
            case .text, .toolUse:
                return part
            }
        }
    }

    // MARK: - Copy Remote Skill

    /// Copy a remote skill to the local device.
    func copyRemoteSkill(skillId: String, deviceId: String) async -> Bool {
        let remoteSkills = await ChatStore.shared.listRemoteSkills(deviceId: deviceId)
        guard let skill = remoteSkills.first(where: { $0.id == skillId }) else {
            logger.error("[Fork] Remote skill not found: \(skillId)")
            return false
        }

        // Build SKILL.md content from body
        let content = skill.body.isEmpty ? "---\nname: \(skill.name)\ndescription: \(skill.description)\nversion: \(skill.version)\n---\n" : skill.body

        do {
            try SkillStore.shared.importSkill(content: content, source: .file)
            logger.info("[Fork] Copied remote skill: \(skill.name)")
            return true
        } catch {
            logger.error("[Fork] Failed to copy skill: \(error)")
            return false
        }
    }

    // MARK: - Copy Remote Memory

    /// Copy a remote memory file to the local memory directory.
    func copyRemoteMemory(memoryId: String, deviceId: String) async -> Bool {
        let remoteMemories = await ChatStore.shared.listRemoteMemories(deviceId: deviceId)
        guard let memory = remoteMemories.first(where: { $0.id == memoryId }) else {
            logger.error("[Fork] Remote memory not found: \(memoryId)")
            return false
        }

        let memoryDir = AIChatViewModel.minisMemoryPersistentDir
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        let destURL = memoryDir.appendingPathComponent(memory.fileName)
        do {
            try memory.content.write(to: destURL, atomically: true, encoding: String.Encoding.utf8)
            logger.info("[Fork] Copied remote memory: \(memory.fileName)")
            return true
        } catch {
            logger.error("[Fork] Failed to copy memory: \(error)")
            return false
        }
    }
}

