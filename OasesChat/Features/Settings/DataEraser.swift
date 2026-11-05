import Foundation
import SwiftData
import WebKit

/// Settings → 清除全部对话. One place that removes every conversation *and*
/// the data that hangs off them, awaited end to end so the caller can report
/// completion instead of firing an untracked Task:
///
/// - text/voice/image conversations (SwiftData) and Ogent sessions (ChatStore)
/// - per-session files `Library/MinisChat/minis/<id>` (workspace, browser
///   screenshots, attachments) and cached view models / browser pools
/// - built-in browser state: history, persisted tabs, website data (cookies,
///   storage) plus the cookie backup that would otherwise re-inject them,
///   get_cookies env files and tmp screenshots
@MainActor
enum DataEraser {
    struct Report: Equatable {
        var conversations = 0
        var sessions = 0
    }

    static func eraseAllConversations(modelContext: ModelContext) async -> Report {
        var report = Report()

        let conversations = (try? modelContext.fetch(FetchDescriptor<ConversationModel>())) ?? []
        for conversation in conversations {
            modelContext.delete(conversation)
        }
        try? modelContext.save()
        report.conversations = conversations.count

        let sessions = await ChatStore.shared.listSessions()
        for session in sessions {
            ViewModelCache.shared.remove(sessionId: session.id)
            BrowserUseOffloadBridge.releasePool(forSession: session.id)
            await ChatStore.shared.deleteSession(session.id)
            try? FileManager.default.removeItem(at: ChatStorePaths.sessionDirectory(sessionId: session.id))
            BrowserTabPool.deletePersistedData(for: session.id)
        }
        report.sessions = sessions.count

        await eraseBrowserData()
        return report
    }

    private static func eraseBrowserData() async {
        BrowserHistoryStore.shared.clearAll()
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Tab URLs of sessions that no longer exist (or never had a row).
            try? FileManager.default.removeItem(
                at: support.appendingPathComponent("MinisChat/browser_tabs", isDirectory: true)
            )
        }
        CookieBackupStore.shared.forgetAll()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        BrowserUseManager.purgeCookieEnvFiles(olderThan: 0)
        BrowserUseManager.pruneScreenshots(olderThan: 0, keepingAtMost: 0)
    }
}
