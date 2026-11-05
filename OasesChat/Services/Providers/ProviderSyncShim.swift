import Foundation
import SwiftData

/// ChatStore actor is now ported at Services/Agent/Chat/ChatStore.swift.
/// This file only keeps DTO helpers + ProviderV3Bootstrap used by ProviderConfigStore.

/// Lightweight session/message DTOs for non-sync callers (App Intents,
/// shortcut providers). Field set is the minimum App Intents currently
/// needs; extend on demand.
struct ChatStoreSessionDTO {
    let id: String
    var title: String?
    let updatedAt: Date?

    init(id: String, title: String?, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
    init(from conv: SessionsQueryEngine.SessionMeta) {
        self.id = conv.sessionId
        self.title = conv.title
        self.updatedAt = conv.lastActive
    }
}

struct ChatStoreMessageDTO {
    /// "user" / "assistant" / "system" / "tool".
    let roleRaw: String
    let content: String

    var isUser: Bool { roleRaw == "user" }
    var isAssistant: Bool { roleRaw == "assistant" }
}


// ProviderV3Bootstrap lives in Services/Sync/V2/ChatStoreSyncHydrators.swift
