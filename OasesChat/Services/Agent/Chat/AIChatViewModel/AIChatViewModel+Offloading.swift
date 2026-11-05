import Foundation
import ImageIO
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Context Window Offloading

extension AIChatViewModel {
    // MARK: - Offload placeholders (T-offload-placeholder-write-guard, OpenMinis #374)

    /// Opens every offload stub of the old, plain-text form (still in older sessions).
    nonisolated static let offloadedStubPrefix = "[CONTEXT OFFLOADED]"
    /// The tag inside the current form, which wraps the notice in a system-reminder envelope
    /// so the model reads it as a note about a removed argument, not as content to copy.
    nonisolated static let offloadedStubNoticeTag = "[Ogent System Notice]"
    nonisolated static let offloadedStubEnvelope = "<system-reminder>"

    /// True when `value` is an offload placeholder in either form (including OpenMinis's
    /// "[Minis System Notice]" tag in sessions imported from it).
    nonisolated static func isOffloadedStub(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(offloadedStubPrefix) { return true }
        return trimmed.hasPrefix(offloadedStubEnvelope)
            && (trimmed.contains(offloadedStubNoticeTag) || trimmed.contains("[Minis System Notice]"))
    }

    /// What replaces a `file_write` / `file_edit` payload moved out of context.
    nonisolated static func offloadedStubNotice(tokens: Int, bytes: Int, linuxPath: String) -> String {
        """
        \(offloadedStubEnvelope)
        \(offloadedStubNoticeTag) The original content (~\(tokens) tokens, \(bytes) bytes) \
        of this tool argument has been pruned to save context and offloaded to: \(linuxPath)

        CRITICAL: This is a placeholder notice, NOT actual file content. NEVER pass this \
        placeholder or reuse it in subsequent file_write or file_edit calls. If you need the \
        original content, call file_read on the offloaded path first.
        </system-reminder>
        """
    }

    /// The refusal returned when a write's payload is a placeholder: nothing is written.
    nonisolated static func offloadedWriteRefusal(field: String, path: String) -> String {
        """
        Error: This call was NOT executed. Its `\(field)` is an offload placeholder, not real \
        content: the original text was moved out of context to free tokens, and only a reference \
        notice survived in the conversation. Writing it would have replaced the file\(path.isEmpty ? "" : " at \(path)") \
        with that notice. Nothing was written; the file is unchanged.

        Use file_read on the path named inside the placeholder to recover the real content, then \
        re-issue this write with it. Do not resend the placeholder.
        """
    }


    // MARK: - Context Window Offloading

    /// Save context content to disk for later retrieval via file_read.
    /// Returns the Linux-visible path where the file was saved.
    /// Derive a short unique suffix from a tool ID for use in file names.
    /// Anthropic IDs are `toolu_01XXXX...` (prefix is always `toolu_01`),
    /// so we take the last 12 characters to guarantee uniqueness.
    private nonisolated static func shortToolId(_ toolId: String) -> String {
        String(toolId.suffix(12))
    }

    /// Returns nil when the file could not be written: callers must then keep
    /// the content in context instead of replacing it with a stub that points
    /// at a file that does not exist.
    private func offloadContextContent(_ content: String, toolId: String, toolName: String, ext: String = "txt") -> String? {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"
        let persistDir = Self.minisOffloadsPersistentDir(for: sid)
            .appendingPathComponent("tools", isDirectory: true)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let sanitizedName = toolName.isEmpty ? "tool" : toolName.replacingOccurrences(of: "/", with: "_")
        let shortId = Self.shortToolId(toolId)
        let fileName = "\(sanitizedName)_\(shortId).\(ext)"
        let persistPath = persistDir.appendingPathComponent(fileName)
        do {
            try content.write(to: persistPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Context offload: failed to write \(fileName): \(error.localizedDescription)")
            return nil
        }

        return "\(Self.minisOffloadsLinuxDir)/tools/\(fileName)"
    }

    /// Save context image data to disk for later retrieval.
    /// Returns the Linux-visible path where the file was saved, or nil when
    /// the write failed (see `offloadContextContent`).
    private func offloadContextImage(_ data: Data, toolId: String, mimeType: String) -> String? {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"
        let persistDir = Self.minisOffloadsPersistentDir(for: sid)
            .appendingPathComponent("tools", isDirectory: true)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let ext: String
        switch mimeType {
        case "image/png": ext = "png"
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "bin"
        }

        let shortId = Self.shortToolId(toolId)
        let fileName = "image_\(shortId).\(ext)"
        let persistPath = persistDir.appendingPathComponent(fileName)
        do {
            try data.write(to: persistPath)
        } catch {
            logger.error("Context offload: failed to write \(fileName): \(error.localizedDescription)")
            return nil
        }

        return "\(Self.minisOffloadsLinuxDir)/tools/\(fileName)"
    }

    /// Decode the pixel dimensions of an image blob without fully decoding it.
    /// Returns (width, height) or nil on failure.
    private static func imagePixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    /// Build the text placeholder that replaces an image omitted from the
    /// sent context. Dimensions + byte size give the model enough semantic
    /// context to recognize the image from memory, and the path hints let
    /// it re-fetch the bytes via `read_image` when needed.
    ///
    /// Two forms:
    /// - Stable original (no snapshot needed): `originalPath` set,
    ///   `snapshotPath` nil.
    /// - Volatile original (snapshot written as fallback): both set.
    static func imagePlaceholderText(
        data: Data,
        originalPath: String?,
        snapshotPath: String?
    ) -> String {
        let size = byteFormatter.string(fromByteCount: Int64(data.count))
        let dims: String
        if let (w, h) = imagePixelSize(data) { dims = "\(w)×\(h), \(size)" }
        else { dims = size }

        switch (originalPath, snapshotPath) {
        case let (orig?, snap?):
            return "[image omitted to save context — \(dims) — original: \(orig); snapshot: \(snap), use read_image on snapshot if original is unavailable]"
        case let (orig?, nil):
            return "[image omitted to save context — \(dims) — original: \(orig), use read_image to view again]"
        case let (nil, snap?):
            return "[image omitted to save context — \(dims) — saved to \(snap), use read_image to view again]"
        case (nil, nil):
            return "[image omitted to save context — \(dims)]"
        }
    }

    /// Decide whether a file path (Linux view) or minis:// URL is backed by
    /// persistent session storage under `/var/minis/*`. Paths in those
    /// locations survive shell restarts, session reloads, and cross-day
    /// reopens, so we don't need to write a snapshot copy of the bytes.
    ///
    /// Anything else (`/tmp/*`, absent, unknown prefix) is considered
    /// volatile and must be snapshotted before the original is dropped from
    /// context.
    private static func isPersistentMinisPath(_ path: String) -> Bool {
        // Linux view: bind-mounted persistent directories under /var/minis
        if path.hasPrefix("/var/minis/workspace/") { return true }
        if path.hasPrefix("/var/minis/browser/") { return true }
        if path.hasPrefix("/var/minis/attachments/") { return true }
        if path.hasPrefix("/var/minis/offloads/") { return true }
        // minis:// URL view maps 1:1 to the directories above
        if path.hasPrefix("minis://workspace/") { return true }
        if path.hasPrefix("minis://browser/") { return true }
        if path.hasPrefix("minis://attachments/") { return true }
        if path.hasPrefix("minis://offloads/") { return true }
        return false
    }

    /// Extract the original accessible path of an image produced by a known
    /// tool, so the placeholder can reference it as a semantic hint (and,
    /// when the path is persistent, skip writing a snapshot copy).
    ///
    /// Returns nil when no path is recoverable — the caller must write a
    /// snapshot in that case.
    ///
    /// - `toolName`: the tool that produced the result. May be empty when
    ///   the message was rehydrated from persistence (ChatStore drops the
    ///   name on reload); callers pass the tool_use name they recovered
    ///   from the matching `tool_use` block.
    /// - `input`: the `tool_use` input JSON for this call.
    /// - `content`: the textual `tool_result` body. Used to recover paths
    ///   that only the tool knows at runtime (e.g. browser screenshot URLs
    ///   emitted as `minis_url: minis://...`).
    private static func originalImagePath(
        toolName: String,
        input: [String: Any]?,
        content: String
    ) -> String? {
        // read_image: absolute path is the first positional argument.
        if toolName == "read_image", let path = input?["path"] as? String, !path.isEmpty {
            return path
        }
        // browser_use (any action) appends `minis_url: minis://...` to the
        // result content when it persists a screenshot or fetched file to
        // /var/minis/browser/. Extract that URL.
        if toolName == "browser_use" || toolName.isEmpty {
            if let urlRange = content.range(of: #"minis://\S+"#, options: .regularExpression) {
                return String(content[urlRange])
            }
        }
        return nil
    }

    /// Trim old images from `agentHistory` so at most `kImageContextKeepCount`
    /// images remain in the context sent to the model. Older images are
    /// replaced with a text placeholder.
    ///
    /// Snapshot policy: an image is **not** copied to offloads when its
    /// original path lives under `/var/minis/*` (workspace, browser,
    /// attachments, offloads) — those directories are persistent and the
    /// placeholder's path hint is enough for the model to re-fetch via
    /// `read_image`. Any other origin — volatile (`/tmp/*`), unknown, or a
    /// standalone user attachment with no path at all — is snapshotted
    /// via `offloadContextImage` so inference can continue even if the
    /// original is lost. When a snapshot is taken alongside a volatile
    /// original path, both are surfaced in the placeholder so the model
    /// prefers the semantic original and falls back to the snapshot.
    ///
    /// This is a destructive in-place rewrite of `agentHistory` (same
    /// contract as `offloadContextIfNeeded`). It runs *before* token-based
    /// offloading so image bytes are removed first, reducing the pressure on
    /// the subsequent token-window offload decision.
    func trimOldImagesFromHistory() {
        let keep = Self.kImageContextKeepCount

        // First pass: index tool_use calls by id (for name + input lookup)
        // and count total images across the history. Rehydrated messages
        // lose the name on `.toolResult`, so the index is the canonical
        // source of truth for tool metadata.
        var toolCallById: [String: (name: String, input: [String: Any])] = [:]
        var totalImages = 0
        for msg in agentHistory {
            for part in msg.parts {
                switch part {
                case .toolUse(let id, let name, let input):
                    toolCallById[id] = (name: name, input: input)
                case .toolResult(_, _, _, _, let imgData, _, _, _):
                    if imgData != nil { totalImages += 1 }
                case .imageData:
                    totalImages += 1
                default:
                    break
                }
            }
        }
        guard totalImages > keep else { return }

        // Evict the oldest `totalImages - keep` images so the most recent
        // `keep` remain as real bytes.
        let evictCount = totalImages - keep
        var evicted = 0
        var snapshotsWritten = 0

        for mi in agentHistory.indices {
            if evicted >= evictCount { break }
            let parts = agentHistory[mi].parts
            var newParts = parts
            var mutated = false

            for pi in parts.indices {
                if evicted >= evictCount { break }
                switch parts[pi] {
                case .toolResult(let id, let name, let content, let isError, let imgData, let mime, let pageURL, _):
                    guard let data = imgData else { continue }

                    let call = toolCallById[id]
                    let effectiveName = !name.isEmpty ? name : (call?.name ?? "")
                    let originalPath = Self.originalImagePath(
                        toolName: effectiveName,
                        input: call?.input,
                        content: content
                    )

                    // Decide whether to snapshot: only skip the copy when the
                    // original path is under /var/minis/* (persistent).
                    let snapshotPath: String?
                    if let op = originalPath, Self.isPersistentMinisPath(op) {
                        snapshotPath = nil
                    } else {
                        // A failed write leaves snapshotPath nil, so the
                        // placeholder doesn't point at a file that isn't there.
                        snapshotPath = offloadContextImage(data, toolId: id, mimeType: mime ?? "image/jpeg")
                        if snapshotPath != nil { snapshotsWritten += 1 }
                    }

                    let placeholder = Self.imagePlaceholderText(
                        data: data,
                        originalPath: originalPath,
                        snapshotPath: snapshotPath
                    )
                    let newContent = content.isEmpty ? placeholder : "\(content)\n\n\(placeholder)"
                    newParts[pi] = .toolResult(
                        id: id, name: name, content: newContent,
                        isError: isError, imageData: nil, imageMimeType: nil, pageURL: pageURL
                    )
                    mutated = true
                    evicted += 1

                case .imageData(let data, let mime, _):
                    // Standalone image (user attachment) — no tool id, no
                    // recoverable original path. Always snapshot.
                    let synthId = "img-\(sessionId ?? "s")-\(mi)-\(pi)"
                    let snap = offloadContextImage(data, toolId: synthId, mimeType: mime)
                    if snap != nil { snapshotsWritten += 1 }
                    let placeholder = Self.imagePlaceholderText(
                        data: data, originalPath: nil, snapshotPath: snap
                    )
                    newParts[pi] = .text(placeholder)
                    mutated = true
                    evicted += 1

                default:
                    break
                }
            }

            if mutated {
                // In place: a rebuilt AgentMessage would drop `dbMessageId` (the compact
                // marker's anchor — without it the summary is lost and the full history goes
                // out again) and `reasoningEcho`.
                agentHistory[mi].parts = newParts
            }
        }

        if evicted > 0 {
            logger.info("🖼️ Context image trim: evicted \(evicted) old image(s) (snapshots: \(snapshotsWritten)), kept last \(keep) (total was \(totalImages))")
        }
    }

    /// Check if context is approaching the model's window limit and offload old tool content.
    ///
    /// Uses a **subtraction method**: starts from the real `lastContextTokens` reported by the API,
    /// and subtracts each offloaded part's token count (computed via BPETokenizer) until the
    /// context drops to the policy's offload target. This avoids unreliable full-history estimation.
    /// Estimate total agentHistory token count using character-based heuristic.
    /// Uses ~3.5 chars/token for mixed English/CJK/code content (conservative).
    /// Also accounts for image data tokens (~85 tokens per 1KB of base64).
    ///
    /// Estimates against `effectiveAgentHistory()` — the slice that actually
    /// reaches the model — not the raw `agentHistory`. After compact-v2
    /// (90ac63e8), the raw history is preserved while marker overlay trims
    /// what's sent; estimating against the raw log made post-compact usage
    /// look unchanged and fired the "near capacity" prompt before every send.
    ///
    /// Cached per `contextRevision`: the loop asks several times per
    /// iteration (offload check, in-loop compact check, logging) and the
    /// answer only changes when the history or the compact marker does.
    func estimateContextTokens(_ caller: String = #function) -> Int {
        if let cache = contextTokenEstimateCache, cache.revision == contextRevision {
            return cache.tokens
        }
        var totalChars = 0
        var imageTokens = 0
        let slice = effectiveAgentHistoryUncounted()
        // DIAG: per-message breakdown so we can see EXACTLY what occupies the
        // post-compact context. Logs every message's role + part summary +
        // token estimate; lets us tell whether bloat comes from the injected
        // summary, pre-anchor warm-up turns, or post-anchor tool results.
        var perMsg: [String] = []
        var biggest: [(kind: String, chars: Int, msgIdx: Int)] = []
        for (idx, msg) in slice.enumerated() {
            var msgChars = 0
            var msgImgTok = 0
            var partTags: [String] = []
            for part in msg.parts {
                var partChars = 0
                var partKind = ""
                switch part {
                case .text(let t):
                    partChars = t.count
                    let isSummary = t.contains("<context-summary>")
                    partKind = isSummary ? "SUMMARY" : "text"
                case .toolUse(_, let name, let input):
                    if let data = try? JSONSerialization.data(withJSONObject: input) {
                        partChars = data.count
                    }
                    partKind = "tu:\(name)"
                case .toolResult(_, _, let content, _, let imgData, _, _, _):
                    partChars = content.count
                    if let imgData = imgData {
                        let it = BPETokenizer.shared.countImageTokens(imgData)
                        imageTokens += it
                        msgImgTok += it
                    }
                    partKind = "tr"
                case .imageData(let data, _, _):
                    let it = BPETokenizer.shared.countImageTokens(data)
                    imageTokens += it
                    msgImgTok += it
                    partKind = "img"
                }
                msgChars += partChars
                totalChars += partChars
                partTags.append("\(partKind)=\(partChars)c")
                if partChars >= 2000 {
                    biggest.append((partKind, partChars, idx))
                }
            }
            let msgTok = Int(Double(msgChars) / 3.5) + msgImgTok
            let dbId = msg.dbMessageId?.prefix(8) ?? "----"
            perMsg.append("[\(idx) \(msg.role.rawValue) db=\(dbId) ~\(msgTok)tok | \(partTags.joined(separator: ","))]")
        }
        let totalTokens = Int(Double(totalChars) / 3.5) + imageTokens
        biggest.sort { $0.chars > $1.chars }
        let top = biggest.prefix(5).map { "[\($0.msgIdx)\($0.kind)=\($0.chars)c]" }.joined(separator: " ")
        logger.debug("[CompactDiag] estimate caller=\(caller) slice=\(slice.count) total=\(totalTokens)tok (\(totalChars)chars+\(imageTokens)imgTok) bigParts(≥2kc): \(top)")
        logger.debug("[CompactDiag] estimate perMsg: \(perMsg.joined(separator: " "))")
        contextTokenEstimateCache = (revision: contextRevision, tokens: totalTokens)
        return totalTokens
    }

    /// - `force`: When true, skip the threshold check and offload all eligible candidates
    ///   regardless of current context usage. Used after compaction to unconditionally slim down
    ///   the kept messages.
    func offloadContextIfNeeded(model: LLMModel, lastContextTokens: Int, force: Bool = false) {
        let contextWindow = effectiveContextWindow(for: model)
        let policy = ContextPolicy(contextWindow: contextWindow)

        // Policy disables offloading for this context window tier
        if !force && policy.offloadThreshold == 0 {
            logger.debug("Context offload: disabled for window \(contextWindow) tokens")
            return
        }

        // When no API baseline exists (first iteration of a new message),
        // use a fast char-based estimate to avoid sending an oversized prompt.
        var effectiveTokens = lastContextTokens
        if lastContextTokens == 0 {
            effectiveTokens = estimateContextTokens()
            if !force {
                if effectiveTokens < policy.offloadThreshold {
                    let remaining = contextWindow - effectiveTokens
                    logger.debug("Context offload: skipped (estimate \(effectiveTokens)/\(contextWindow), remaining ~\(remaining) tokens)")
                    return
                }
            }
            logger.info("Context offload: no API baseline — using char estimate: ~\(effectiveTokens) tokens")
        }

        let pct = Int(Double(effectiveTokens) / Double(contextWindow) * 100)

        if !force {
            guard effectiveTokens >= policy.offloadThreshold else {
                let remaining = contextWindow - effectiveTokens
                logger.debug("Context offload: below threshold — \(effectiveTokens)/\(contextWindow) (\(pct)%), remaining ~\(remaining) tokens")
                return
            }
        }

        // When forced (post-compact), offload everything eligible — no early stop target.
        let targetTokens = force ? 0 : policy.offloadTarget
        let beforeTokens = effectiveTokens
        var currentTokens = effectiveTokens

        let source = force ? "post-compact" : (lastContextTokens > 0 ? "API" : "estimate")
        let remaining = contextWindow - beforeTokens
        logger.info("━━━ Context Offload Triggered ━━━")
        logger.info("  Model: \(model.id) (window: \(contextWindow) tokens)")
        logger.info("  Before: \(beforeTokens) tokens (\(pct)% of window, ~\(remaining) remaining) [source: \(source)]")
        if force {
            logger.info("  Mode: FORCE (post-compact) — offloading all eligible candidates")
        } else {
            logger.info("  Threshold: \(policy.offloadThreshold) — Target: \(targetTokens)")
            logger.info("  Need to free: ~\(beforeTokens - targetTokens) tokens")
        }
        logger.info("  Agent history: \(self.agentHistory.count) messages")

        // Protect the last 4 messages from offloading
        let protectedCount = min(4, agentHistory.count)
        let candidateRange = 0..<(agentHistory.count - protectedCount)
        logger.info("  Scanning messages 0..<\(candidateRange.upperBound) (last \(protectedCount) protected)")

        // Collect offload candidates: (messageIndex, partIndex, tokenCount, byteCount)
        struct OffloadCandidate {
            let msgIdx: Int
            let partIdx: Int
            let tokens: Int
            let bytes: Int
            let toolId: String
            let toolName: String
        }

        var candidates: [OffloadCandidate] = []
        var skippedAlreadyOffloaded = 0
        var skippedTooSmall = 0
        // [T-offload-toolinput-guards] Only a tool call that already has its result may lose
        // its arguments: a pending or resumed call would otherwise run with the placeholder.
        var answeredToolIds = Set<String>()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _, _, _) = part { answeredToolIds.insert(id) }
            }
        }

        for msgIdx in candidateRange {
            let msg = agentHistory[msgIdx]
            for (partIdx, part) in msg.parts.enumerated() {
                switch part {
                case .toolResult(let id, let name, let content, _, let imgData, _, _, _):
                    // Skip already-offloaded parts
                    if Self.isOffloadedStub(content) {
                        skippedAlreadyOffloaded += 1
                        continue
                    }
                    // Only offload substantial content (>500 chars) or large images (>1KB)
                    let hasLargeContent = content.count > 500
                    let hasLargeImage = (imgData?.count ?? 0) > 1024
                    guard hasLargeContent || hasLargeImage else {
                        skippedTooSmall += 1
                        continue
                    }

                    let tokens = BPETokenizer.shared.countPartTokens(part)
                    let bytes = content.utf8.count + (imgData?.count ?? 0)
                    candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: bytes, toolId: id, toolName: name))

                case .toolUse(let id, let name, let input):
                    // Offload large file_write/file_edit tool inputs
                    guard name == "file_write" || name == "file_edit", answeredToolIds.contains(id) else { continue }
                    if let content = input["content"] as? String, content.count > 500, !Self.isOffloadedStub(content) {
                        let tokens = BPETokenizer.shared.countPartTokens(part)
                        let bytes = content.utf8.count
                        candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: bytes, toolId: id, toolName: name))
                    }

                case .imageData(let data, _, _):
                    guard data.count > 1024 else {
                        skippedTooSmall += 1
                        continue
                    }
                    let tokens = BPETokenizer.shared.countPartTokens(part)
                    candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: data.count, toolId: "img\(msgIdx)_\(partIdx)", toolName: "image"))

                case .text:
                    continue
                }
            }
        }

        // Sort by token count descending (offload largest first)
        candidates.sort { $0.tokens > $1.tokens }

        let totalCandidateTokens = candidates.reduce(0) { $0 + $1.tokens }
        logger.info("  Candidates: \(candidates.count) parts (~\(totalCandidateTokens) tokens total)")
        logger.info("  Skipped: \(skippedAlreadyOffloaded) already offloaded, \(skippedTooSmall) too small")
        if !candidates.isEmpty {
            let top = candidates.prefix(5)
            for (i, c) in top.enumerated() {
                logger.info("  Candidate #\(i + 1): [\(c.toolName)] id:\(c.toolId.prefix(8)) msg[\(c.msgIdx)] ~\(c.tokens) tokens (\(c.bytes) bytes)")
            }
            if candidates.count > 5 {
                logger.info("  ... and \(candidates.count - 5) more candidates")
            }
        }

        var offloadedCount = 0
        var freedTokens = 0

        for candidate in candidates {
            guard currentTokens > targetTokens else { break }

            let part = agentHistory[candidate.msgIdx].parts[candidate.partIdx]
            var linuxPath = ""

            // Every write a stub refers to must have succeeded; otherwise the
            // part stays in context untouched (the stub would point the model
            // at a missing file and the content would be gone for good).
            switch part {
            case .toolResult(let id, let name, let content, let isError, let imgData, let imgMime, _, _):
                // Offload text content
                if content.count > 500 {
                    guard let textPath = offloadContextContent(content, toolId: id, toolName: name) else { continue }
                    linuxPath = textPath
                }
                // Offload image data
                if let imgData = imgData, imgData.count > 1024 {
                    guard let imgPath = offloadContextImage(imgData, toolId: id, mimeType: imgMime ?? "image/png") else { continue }
                    if linuxPath.isEmpty { linuxPath = imgPath }
                }

                let stub = "[CONTEXT OFFLOADED] Content (~\(candidate.tokens) tokens, \(candidate.bytes) bytes) saved to: \(linuxPath)\nUse file_read tool to retrieve if needed."
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .toolResult(
                    id: id, name: name, content: stub, isError: isError
                )

            case .toolUse(let id, let name, let input):
                if let content = input["content"] as? String {
                    guard let textPath = offloadContextContent(content, toolId: id, toolName: name) else { continue }
                    linuxPath = textPath
                }
                var newInput = input
                newInput["content"] = Self.offloadedStubNotice(tokens: candidate.tokens, bytes: candidate.bytes, linuxPath: linuxPath)
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .toolUse(
                    id: id, name: name, input: newInput
                )

            case .imageData(let data, let mime, _):
                guard let imgPath = offloadContextImage(data, toolId: candidate.toolId, mimeType: mime) else { continue }
                linuxPath = imgPath
                let stub = "[CONTEXT OFFLOADED] Image (~\(candidate.tokens) tokens, \(candidate.bytes) bytes) saved to: \(linuxPath)\nUse file_read tool to retrieve if needed."
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .text(stub)

            case .text:
                continue
            }

            currentTokens -= candidate.tokens
            freedTokens += candidate.tokens
            offloadedCount += 1
            let afterPct = Int(Double(currentTokens) / Double(contextWindow) * 100)
            logger.info("  ✂ Offloaded #\(offloadedCount): [\(candidate.toolName)] id:\(candidate.toolId.prefix(8)) ~\(candidate.tokens) tokens (\(candidate.bytes) bytes) → \(linuxPath) [now \(currentTokens) (\(afterPct)%)]")
        }

        if offloadedCount > 0 {
            let afterPct = Int(Double(currentTokens) / Double(contextWindow) * 100)
            logger.info("━━━ Context Offload Complete ━━━")
            logger.info("  Parts offloaded: \(offloadedCount)")
            logger.info("  Tokens freed: ~\(freedTokens)")
            logger.info("  Before: \(beforeTokens)/\(contextWindow) (\(pct)%)")
            logger.info("  After:  \(currentTokens)/\(contextWindow) (\(afterPct)%)")
            logger.info("  Delta:  -\(beforeTokens - currentTokens) tokens (-\(pct - afterPct)pp)")

            // List files in offloads/tools directory (top 20 by recency)
            let sid = sessionId ?? "unknown"
            let toolsDir = Self.minisOffloadsPersistentDir(for: sid)
                .appendingPathComponent("tools", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: toolsDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                let sorted = files.sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
                let top20 = sorted.prefix(20)
                var totalSize: Int64 = 0
                logger.info("  /var/minis/offloads/tools/ — \(files.count) files (showing top \(top20.count)):")
                for file in top20 {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    totalSize += Int64(size)
                    let sizeStr: String
                    if size >= 1_048_576 {
                        sizeStr = String(format: "%.1fMB", Double(size) / 1_048_576)
                    } else if size >= 1024 {
                        sizeStr = String(format: "%.1fKB", Double(size) / 1024)
                    } else {
                        sizeStr = "\(size)B"
                    }
                    logger.info("    \(file.lastPathComponent) (\(sizeStr))")
                }
                let totalStr: String
                if totalSize >= 1_048_576 {
                    totalStr = String(format: "%.1fMB", Double(totalSize) / 1_048_576)
                } else {
                    totalStr = String(format: "%.1fKB", Double(totalSize) / 1024)
                }
                logger.info("  Total offload size: \(totalStr) across \(files.count) files")
            }
            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
    }

    /// Remove persistent minis data for a given session.
    private func cleanupMinis(for sid: String) {
        let fm = FileManager.default
        let persistDir = Self.minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
        try? fm.removeItem(at: persistDir)
    }

    /// Sync a single minis subdirectory bidirectionally between persistent storage and iSH-visible path.
    /// One-time migration: moves old `Library/MinisChat/offloads/<sid>/` to
    /// `Library/MinisChat/minis/<sid>/offloads/`.
    func migrateOffloadsIfNeeded(for sid: String) {
        let fm = FileManager.default
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let oldDir = lib.appendingPathComponent("MinisChat/offloads/\(sid)", isDirectory: true)
        guard fm.fileExists(atPath: oldDir.path) else { return }

        let newDir = Self.minisOffloadsPersistentDir(for: sid)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // Move each file from old location to new
        if let files = try? fm.contentsOfDirectory(atPath: oldDir.path) {
            for file in files {
                let src = oldDir.appendingPathComponent(file)
                let dst = newDir.appendingPathComponent(file)
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Remove old directory
        try? fm.removeItem(at: oldDir)
        logger.info("Migrated offloads for session \(sid) to new minis path")
    }

    /// Bind-mount a session's minis directories into iSH-visible /var/minis/.
    /// Delegates to ISHExecutionCoordinator for serialized mount management.
    func mountMinis(for sid: String) {
        // Always ensure symlinks exist in data/ for the file browser,
        // even when the iSH kernel isn't booted yet.
        ensureMinisSymlinks(for: sid)
        Task { await ISHExecutionCoordinator.shared.mountForSession(sid) }
    }

    /// Keeps the Ogent file browser's `/var/minis` view pointing at this
    /// session's trees; also refreshes the mounted-folder links.
    private func ensureMinisSymlinks(for sid: String) {
        Self.prepareFileBrowserRoot(for: sid)
        Self.refreshMountedFolderSymlinks()
    }

    /// Directory the Ogent file browser opens as `/var/minis`: one symlink per
    /// bucket to this session's trees and to the global ones, i.e. the same
    /// host directories the shell, the file tools and `minis://` use.
    ///
    /// It lives outside the rootfs. Guest `/var/minis` is a symlink to
    /// `/var/oases`, which fakefs stores as a regular file at
    /// `data/var/minis`, so links can't be created under it (every session
    /// load logged nine `createSymbolicLink FAILED`) and the browser opened
    /// on a file.
    nonisolated static func fileBrowserRoot(for sid: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OgentFiles", isDirectory: true)
            .appendingPathComponent(sid, isDirectory: true)
    }

    @discardableResult
    nonisolated static func prepareFileBrowserRoot(for sid: String) -> URL {
        let fm = FileManager.default
        let root = fileBrowserRoot(for: sid)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var links: [(name: String, target: URL)] = [
            ("workspace", minisWorkspacePersistentDir(for: sid)),
            ("attachments", minisAttachmentsPersistentDir(for: sid)),
            ("offloads", minisOffloadsPersistentDir(for: sid)),
            ("browser", minisBrowserPersistentDir(for: sid)),
            ("shared", minisSharedPersistentDir),
            ("skills", minisSkillsPersistentDir),
            ("memory", minisMemoryPersistentDir),
        ]
        for target in links.map(\.target) {
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        if let mounts = OasesPathResolver.hostURLInRootfs(forGuest: OasesExternalMountsManager.mountsLinuxDir),
           fm.fileExists(atPath: mounts.path) {
            links.append(("mounts", mounts))
        }
        for (name, target) in links {
            let link = root.appendingPathComponent(name)
            var info = stat()
            if lstat(link.path, &info) == 0 {
                // Only ever replace a symlink this function made.
                guard (info.st_mode & S_IFMT) == S_IFLNK else { continue }
                if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
                unlink(link.path)
            }
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                logger.error("[FileBrowserRoot] \(name): \(error.localizedDescription)")
            }
        }
        return root
    }

    /// Create/refresh `/var/minis/mounts/<name>` symlinks for every entry in
    /// `MountedFoldersManager`. Removes stale symlinks whose mounts were deleted.
    ///
    /// Called from:
    ///   - `ensureMinisSymlinks` on each session mount
    ///   - `MountedFoldersManager` after add/rename/remove
    ///   - App launch after `activateAll`
    ///
    /// Safe to call before the iSH kernel is booted — writes only into `data/`.
    nonisolated static func refreshMountedFolderSymlinks() {
        // Must run on main actor to access MountedFoldersManager.shared.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                performMountedFolderSymlinkRefresh()
            }
        } else {
            DispatchQueue.main.async {
                performMountedFolderSymlinkRefresh()
            }
        }
    }

    @MainActor
    private static func performMountedFolderSymlinkRefresh() {
        let fm = FileManager.default
        let dataPath = RootfsManager.shared.dataPath
        let mountsDir = dataPath.appendingPathComponent("var/minis/mounts", isDirectory: true)
        try? fm.createDirectory(at: mountsDir, withIntermediateDirectories: true)

        let manager = MountedFoldersManager.shared
        let desiredNames = Set(manager.entries.map(\.name))

        // 1. Remove symlinks for mounts that no longer exist.
        if let existing = try? fm.contentsOfDirectory(atPath: mountsDir.path) {
            for entry in existing where !desiredNames.contains(entry) {
                let stalePath = mountsDir.appendingPathComponent(entry)
                var buf = stat()
                if lstat(stalePath.path, &buf) == 0,
                   (buf.st_mode & S_IFMT) == S_IFLNK {
                    unlink(stalePath.path)
                }
            }
        }

        // 2. Create or fix symlinks for active mounts.
        for entry in manager.entries {
            guard let target = manager.resolvedURL(for: entry.id) else {
                // Inactive (stale/denied) — remove any leftover symlink so the
                // user doesn't see a broken entry in FileBrowserView.
                let link = mountsDir.appendingPathComponent(entry.name)
                var buf = stat()
                if lstat(link.path, &buf) == 0 { unlink(link.path) }
                continue
            }

            let link = mountsDir.appendingPathComponent(entry.name)
            var buf = stat()
            let exists = lstat(link.path, &buf) == 0
            if exists && (buf.st_mode & S_IFMT) == S_IFLNK {
                let resolved = link.resolvingSymlinksInPath().standardized.path
                let expected = target.resolvingSymlinksInPath().standardized.path
                if resolved == expected { continue }
                unlink(link.path)
            } else if exists {
                // Non-symlink in the way — unexpected, remove.
                unlink(link.path)
            }
            try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }

    /// Save an attachment (image, media) to the session's persistent attachments directory.
    /// With bind mounts, writing to persistent storage is automatically visible to iSH.
    /// Returns a `minis://attachments/<filename>` URL string, or nil on failure.
    func saveAttachment(_ data: Data, filename: String) -> String? {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"

        // Write to persistent storage (bind-mounted, so iSH sees it automatically)
        let persistDir = Self.minisAttachmentsPersistentDir(for: sid)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let persistPath = persistDir.appendingPathComponent(filename)
        guard (try? data.write(to: persistPath)) != nil else { return nil }

        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return "minis://attachments/\(encoded)"
    }

}
