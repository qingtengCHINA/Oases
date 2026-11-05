import SwiftData
import Foundation

// MARK: - SwiftData Models

@Model
final class ConversationModel {
    @Attribute(.unique) var id: UUID
    var title: String
    var modeRaw: String
    var modelId: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MessageModel.conversation)
    var messages: [MessageModel]

    // MARK: - Sync V2 fields
    //
    // Added for the inbound hydration layer. All are optional or defaulted so
    // an existing store migrates in place without a schema version bump.

    /// Device id this conversation arrived from, nil when it originated here.
    /// Mirrors `ChatSession.remoteDeviceId`.
    var remoteDeviceId: String?
    var remoteDeviceName: String?
    /// Last successful push to iCloud; nil means never synced.
    var lastSyncedAt: Date?
    /// Soft-delete tombstone. A remote record whose `updatedAt` predates this
    /// (within the 5s skew window) is a stale resurrection and must be ignored.
    var remoteTombstonedAt: Date?
    /// Preview text for the session list, kept in sync on merge so the list
    /// doesn't have to fault in every message.
    var lastMessagePreview: String?

    init(mode: AppMode = .chat, modelId: String = Models.defaultChat) {
        self.id = UUID()
        // i18n-ignore: persisted default-title sentinel, compared as `title == "新对话"` in ChatViewModel/ShareCardView
        self.title = "新对话"
        self.modeRaw = mode.rawValue
        self.modelId = modelId
        self.createdAt = .now
        self.updatedAt = .now
        self.messages = []
    }

    /// Init for a conversation arriving from a peer, preserving its identity
    /// and timestamps rather than minting new ones.
    init(remoteId: UUID, title: String, modelId: String,
         createdAt: Date, updatedAt: Date, deviceId: String?) {
        self.id = remoteId
        self.title = title
        self.modeRaw = AppMode.chat.rawValue
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = []
        self.remoteDeviceId = deviceId
    }

    var mode: AppMode {
        get { AppMode(rawValue: modeRaw) ?? .chat }
        set { modeRaw = newValue.rawValue }
    }

    var sortedMessages: [MessageModel] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
final class MessageModel {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var thinking: String?
    /// Image-mode assistant messages carry a generated image URL/data URL.
    var imageUrl: String?
    /// Audio-mode assistant messages carry a synthesized audio URL/data URL.
    var audioUrl: String?
    var audioMimeType: String?
    /// JSON-encoded tool invocations attached to an assistant turn.
    /// Optional for lightweight migration from older local stores.
    var toolCallsJSON: String?
    /// JSON-encoded user attachments so chips survive reload. Optional so
    /// existing stores migrate in place.
    var attachmentsJSON: String?
    var createdAt: Date
    var conversation: ConversationModel?

    // MARK: - Sync V2 fields

    /// Last-writer-wins clock for inbound merges. Defaults to `createdAt` for
    /// rows written before sync existed.
    var updatedAt: Date?
    /// Stable ordering within a conversation. Sync peers must agree on order
    /// independently of wall-clock `createdAt`, which can collide.
    var sortOrder: Int = 0

    init(role: String, content: String, thinking: String? = nil,
         imageUrl: String? = nil, audioUrl: String? = nil, audioMimeType: String? = nil,
         toolCalls: [ToolCall] = [], attachments: [Attachment] = []) {
        self.id = UUID()
        self.roleRaw = role
        self.content = content
        self.thinking = thinking
        self.imageUrl = imageUrl
        self.audioUrl = audioUrl
        self.audioMimeType = audioMimeType
        self.toolCallsJSON = Self.encodeToolCalls(toolCalls)
        self.attachmentsJSON = Self.encodeAttachments(attachments)
        self.createdAt = .now
    }

    var decodedToolCalls: [ToolCall] {
        guard let toolCallsJSON,
              let data = toolCallsJSON.data(using: .utf8),
              let calls = try? JSONDecoder().decode([ToolCall].self, from: data) else {
            return []
        }
        return calls
    }

    var decodedAttachments: [Attachment] {
        guard let attachmentsJSON,
              let data = attachmentsJSON.data(using: .utf8),
              let items = try? JSONDecoder().decode([Attachment].self, from: data) else {
            return []
        }
        return items
    }

    private static func encodeToolCalls(_ calls: [ToolCall]) -> String? {
        guard !calls.isEmpty,
              let data = try? JSONEncoder().encode(calls) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeAttachments(_ items: [Attachment]) -> String? {
        guard !items.isEmpty,
              let data = try? JSONEncoder().encode(items) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}


// MARK: - Shared container (App Intents)

/// [P2] Single `ModelContainer` shared by the SwiftUI scene and App Intents.
///
/// `.modelContainer(for:)` builds its own container scoped to the scene, which
/// Siri / Shortcuts can't reach — an intent runs before (or without) any scene.
/// Both now go through this one instance so an intent reads the same store the
/// UI writes.
enum ConversationContainer {
    /// How the store was opened this launch.
    enum Recovery: Equatable, Sendable {
        /// Opened normally.
        case none
        /// The store would not open; it was moved aside to `backup` and a
        /// fresh, empty store was created.
        case resetStore(backup: URL)
        /// Not even a fresh store would open. History lives in memory only
        /// for this launch.
        case inMemory
    }

    private static let loaded = load(storeURL: nil)

    static var shared: ModelContainer { loaded.container }
    static var recovery: Recovery { loaded.recovery }

    /// A failed open used to `fatalError` — on every launch, since nothing
    /// ever repaired the store. Instead: back the broken store up, retry with
    /// a fresh one, and as a last resort fall back to an in-memory container
    /// so the app still starts. RootView tells the user what happened.
    ///
    /// `storeURL` is nil for the app's default store location; tests pass a
    /// temporary one.
    static func load(storeURL: URL?) -> (container: ModelContainer, recovery: Recovery) {
        let configuration = makeConfiguration(storeURL: storeURL)
        do {
            return (try makeContainer(configuration), .none)
        } catch {
            NSLog("[ConversationStore] ModelContainer init failed: %@", String(describing: error))
        }

        let backup = moveStoreAside(at: configuration.url)
        do {
            let container = try makeContainer(makeConfiguration(storeURL: storeURL))
            NSLog("[ConversationStore] recovered with a fresh store; old store kept at %@", backup?.path ?? "(not moved)")
            if let backup { return (container, .resetStore(backup: backup)) }
            return (container, .none)
        } catch {
            NSLog("[ConversationStore] fresh store also failed: %@ — using in-memory store", String(describing: error))
        }

        do {
            let memory = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return (try makeContainer(memory), .inMemory)
        } catch {
            // An in-memory SQLite store failing means the schema itself is
            // broken — not recoverable at runtime.
            fatalError("In-memory ModelContainer init failed: \(error)")
        }
    }

    private static func makeConfiguration(storeURL: URL?) -> ModelConfiguration {
        // `cloudKitDatabase: .none` is load-bearing. Once the app declares
        // the CloudKit entitlement (for Sync V2's CKSyncEngine transport),
        // SwiftData auto-enables its *own* CloudKit mirroring — which then
        // rejects this schema at init ("relationships must be optional",
        // "unique constraints unsupported") and crashes on launch.
        //
        // Sync V2 does its own record-level sync through
        // `ICloudSharedZoneTransport`; SwiftData mirroring would be a
        // second, conflicting sync path even if the schema allowed it.
        if let storeURL {
            return ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        }
        return ModelConfiguration(cloudKitDatabase: .none)
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: ConversationModel.self, MessageModel.self, configurations: configuration)
    }

    /// Moves the SQLite store and its `-wal` / `-shm` sidecars into a
    /// timestamped `…-corrupt-<date>` folder next to it. Returns that folder,
    /// or nil when there was nothing to move.
    private static func moveStoreAside(at storeURL: URL) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupDir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.lastPathComponent)-corrupt-\(stamp)", isDirectory: true)
        var moved = false
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: backupDir.appendingPathComponent(file.lastPathComponent))
                moved = true
            } catch {
                NSLog("[ConversationStore] could not move %@ aside: %@", file.lastPathComponent, error.localizedDescription)
            }
        }
        return moved ? backupDir : nil
    }

    /// One-shot, user-facing description of a recovery, for RootView's alert.
    /// nil when the store opened normally or the notice was already taken.
    @MainActor
    static func takeRecoveryNotice() -> String? {
        guard !recoveryNoticeTaken else { return nil }
        recoveryNoticeTaken = true
        switch recovery {
        case .none:
            return nil
        case .resetStore:
            return SettingsCopy.t(
                "聊天记录数据库无法打开，已备份原文件并新建了一个空数据库。Ogent 会话不受影响。",
                "The chat history database couldn't be opened. It was backed up and replaced with an empty one. Ogent sessions are not affected."
            )
        case .inMemory:
            return SettingsCopy.t(
                "聊天记录数据库无法打开。本次新的对话只保存在内存中，退出 App 后会丢失。",
                "The chat history database couldn't be opened. New chats are kept in memory only and will be lost when the app quits."
            )
        }
    }

    @MainActor private static var recoveryNoticeTaken = false

    /// Conversations newest-first. Intents run off the main actor, so this
    /// builds its own context rather than borrowing the view's.
    static func recentConversations(limit: Int = 100) -> [ConversationModel] {
        let context = ModelContext(shared)
        var descriptor = FetchDescriptor<ConversationModel>(
            sortBy: [SortDescriptor(\ConversationModel.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    static func conversation(id: UUID) -> ConversationModel? {
        let context = ModelContext(shared)
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }
}
