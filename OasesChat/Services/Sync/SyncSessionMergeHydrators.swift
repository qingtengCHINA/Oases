import Foundation

private let hydratorLogger = AppLogger(category: "SyncHydrators")

/// Registers the Session/Message hydrators with `SyncCoreHydrators`, closing
/// the inbound loop: `SyncCore` → hydrator → `SyncSessionMerge` → SwiftData.
///
/// This is OasesChat's counterpart to OpenMinis `ChatStoreSyncHydrators`(1595L).
/// That file registers 14 record types; only `SessionV2` and `MessageV2` have a
/// local counterpart here. The rest — `CompactMarkerV2`, `SkillV2`,
/// `MCPServerItem`, `SoulV2`, `MemoryDaily`, … — describe OpenMinis subsystems
/// OasesChat either stores differently or doesn't have, so registering them
/// would mean inventing a local shape for records nothing can consume. They're
/// left unregistered: `SyncCoreHydrators.buildPortable` returns nil for an
/// unregistered type and `SyncCore` treats that as "no builder yet", which is
/// the correct, already-handled state.
///
/// The wire format is unchanged, so a peer running OpenMinis and one running
/// OasesChat still agree on Session/Message records.
///
/// NOT registered by the app. `SyncV2Bootstrap.startIfEnabled()` registers
/// `ChatStoreSyncHydrators`, which owns `SessionV2`/`MessageV2`; registering
/// this set as well overwrote those entries (the dirty rows come from
/// ChatStore, so this builder found no SwiftData row and dropped them).
/// Kept only for its unit tests until the SwiftData sync chain is removed.
enum SyncSessionMergeHydrators {

    @MainActor
    static func registerAll() async {
        let hydrators = SyncCoreHydrators.shared

        hydrators.register(
            recordType: "SessionV2",
            builder: { id in await buildSession(id: id) },
            merger: { record in await mergeSession(record: record) },
            deletionApplier: { id in await deleteSession(id: id) }
        )

        hydrators.register(
            recordType: "MessageV2",
            builder: { id in await buildMessage(id: id) },
            merger: { record in await mergeMessage(record: record) },
            deletionApplier: { id in await deleteMessage(id: id) }
        )

        hydratorLogger.info("registered SessionV2 + MessageV2 hydrators")
    }

    // MARK: - Session

    private static func buildSession(id: String) async -> PortableRecord? {
        guard let conversation = await SyncSessionMerge.shared.getSession(id) else { return nil }
        let synced = await MainActor.run {
            SyncedSession(
                id: conversation.id.uuidString,
                title: conversation.title,
                category: conversation.mode.rawValue,
                modelId: conversation.modelId,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                // OasesChat has no per-session memory toggle or model binding;
                // emit upstream's defaults so a peer decoding the record sees
                // well-formed fields rather than absent ones.
                memoryEnabled: 1,
                modelBinding: nil,
                pinnedAt: nil
            )
        }
        return SyncableTypeRegistry.shared.metadata(for: "SessionV2")?.buildPortable(synced)
    }

    private static func mergeSession(record: PortableRecord) async {
        guard let id = stringField(record, "sessionId") else { return }
        let title = optionalStringField(record, "title") ?? "新对话" // i18n-ignore: persisted default-title sentinel, compared as `title == "新对话"` in ChatViewModel/ShareCardView
        let modelId = stringField(record, "modelId") ?? Models.defaultChat
        let createdAt = dateField(record, "createdAt") ?? Date()
        let updatedAt = dateField(record, "updatedAt") ?? record.updatedAt

        await SyncSessionMerge.shared.mergeRemoteSession(
            id: id, title: title, modelId: modelId,
            createdAt: createdAt, updatedAt: updatedAt,
            lastMessage: nil,
            // v2 PortableRecord doesn't carry per-device origin; upstream
            // passes an empty sentinel here too.
            fromDeviceId: ""
        )
    }

    private static func deleteSession(id: String) async {
        _ = await TombstoneManager.shared.applyRemoteSessionDeletion(sessionId: id)
    }

    // MARK: - Message

    private static func buildMessage(id: String) async -> PortableRecord? {
        guard let message = await SyncSessionMerge.shared.loadSingleMessage(id: id) else {
            return nil
        }
        let synced = await MainActor.run {
            SyncedMessage(
                id: message.id.uuidString,
                sessionId: message.conversation?.id.uuidString ?? "",
                role: message.roleRaw,
                // OpenMinis stores a parts array; OasesChat's message body is a
                // plain string, so it ships as a single text part — the field
                // stays JSON so the wire format is unchanged.
                partsJson: encodeTextPart(message.content),
                tokenUsageJson: nil,
                reasoningContent: message.thinking,
                streamInterruptCount: 0,
                sortOrder: message.sortOrder,
                createdAt: message.createdAt,
                updatedAt: message.updatedAt ?? message.createdAt
            )
        }
        return SyncableTypeRegistry.shared.metadata(for: "MessageV2")?.buildPortable(synced)
    }

    private static func mergeMessage(record: PortableRecord) async {
        guard let id = stringField(record, "messageId"),
              let sessionId = stringField(record, "sessionId"),
              let role = stringField(record, "role"),
              let createdAt = dateField(record, "createdAt") else { return }
        let partsJson = stringField(record, "partsJson") ?? "[]"
        let sortOrder = intField(record, "sortOrder") ?? 0
        let updatedAt = dateField(record, "updatedAt") ?? record.updatedAt

        await SyncSessionMerge.shared.mergeRemoteMessage(
            id: id, sessionId: sessionId, role: role,
            content: decodeTextParts(partsJson),
            createdAt: createdAt, updatedAt: updatedAt, sortOrder: sortOrder
        )
    }

    private static func deleteMessage(id: String) async {
        await SyncSessionMerge.shared.deleteLocalMessage(id: id)
        hydratorLogger.debug("applied MessageV2 deletion: id=\(id.prefix(8))")
    }

    // MARK: - Parts JSON

    /// `[{"type":"text","text":"…"}]` — the shape OpenMinis' text parts use, so
    /// a peer on either build reads the other's messages.
    private static func encodeTextPart(_ text: String) -> String {
        let payload = [["type": "text", "text": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Concatenate every text part; non-text parts (images, tool calls) have no
    /// representation in `MessageModel.content` and are dropped rather than
    /// rendered as placeholder junk.
    private static func decodeTextParts(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return "" }
        return parts.compactMap { part in
            guard (part["type"] as? String) == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }

    // MARK: - Field accessors

    private static func stringField(_ r: PortableRecord, _ key: String) -> String? {
        if case .string(let s) = r.fields[key] ?? .null { return s }
        return nil
    }

    private static func optionalStringField(_ r: PortableRecord, _ key: String) -> String? {
        if case .string(let s) = r.fields[key] { return s }
        return nil
    }

    private static func intField(_ r: PortableRecord, _ key: String) -> Int? {
        if case .int(let i) = r.fields[key] ?? .null { return i }
        return nil
    }

    private static func dateField(_ r: PortableRecord, _ key: String) -> Date? {
        if case .date(let d) = r.fields[key] ?? .null { return d }
        return nil
    }
}
