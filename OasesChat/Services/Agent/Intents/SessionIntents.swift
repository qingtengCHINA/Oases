import AppIntents
import Foundation

/// [P2] Session-facing App Intents, ported from OpenMinis `Agent/Intents/`.
///
/// The headless-send counterparts (`SendPromptIntent` / `AskOasesIntent`) live
/// in `SendPromptIntent.swift`, on top of the now-ported background stack
/// (`ChatViewModelCache` / `SessionActivityTracker` / `BackgroundKeepAliveManager`).

extension Notification.Name {
    /// Posted when an intent wants the app to navigate to a session. Consumed by
    /// `RootView`, which selects the matching conversation.
    static let openSessionFromIntent = Notification.Name("openSessionFromIntent")
}

/// Lists sessions — gives automations a session id to feed other intents.
struct ListSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Sessions"
    static let description = IntentDescription("Lists your Oases Chat sessions with their titles and IDs.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let conversations = ConversationContainer.recentConversations()
        guard !conversations.isEmpty else {
            return .result(value: String(localized: "No sessions found.", comment: "Shortcuts List Sessions result when there are no sessions"))
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        let lines = conversations.map { conversation -> String in
            let age = formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
            return "\(conversation.title) (\(age)) — \(conversation.id.uuidString)"
        }
        return .result(value: lines.joined(separator: "\n"))
    }
}

/// Opens a session in the app.
struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Session"
    static let description = IntentDescription("Opens an Oases Chat session in the app.")
    static let openAppWhenRun = true

    @Parameter(title: "Session")
    var session: SessionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationNavigationStore.shared.setPending(session.id)
        NotificationCenter.default.post(
            name: .openSessionFromIntent,
            object: nil,
            userInfo: ["sessionId": session.id]
        )
        return .result()
    }
}

/// Structured session status, usable in Shortcuts conditionals and text blocks.
struct SessionStatus: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Session Status")
    static let defaultQuery = SessionStatusQuery()

    var id: String

    @Property(title: "Session ID")
    var sessionId: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Model")
    var modelName: String

    @Property(title: "Message Count")
    var messageCount: Int

    @Property(title: "Last Message")
    var lastMessage: String

    @Property(title: "Updated At")
    var updatedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(modelName)")
    }

    init(sessionId: String, title: String, modelName: String,
         messageCount: Int, lastMessage: String, updatedAt: Date) {
        self.id = sessionId
        self.sessionId = sessionId
        self.title = title
        self.modelName = modelName
        self.messageCount = messageCount
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
    }
}

struct SessionStatusQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SessionStatus] { [] }
}

/// Reads a session's latest state — title, model, last message.
struct GetSessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Session Status"
    static let description = IntentDescription("Gets an Oases Chat session's title, model, and latest message.")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionStatus> {
        guard let uuid = UUID(uuidString: session.id),
              let conversation = ConversationContainer.conversation(id: uuid) else {
            throw SessionIntentError.sessionNotFound
        }

        let messages = conversation.sortedMessages
        let label = ProviderChatRouting.label(for: conversation.modelId)
            ?? Models.option(for: conversation.modelId)?.label
            ?? conversation.modelId

        return .result(value: SessionStatus(
            sessionId: session.id,
            title: conversation.title,
            modelName: label,
            messageCount: messages.count,
            lastMessage: messages.last?.content ?? "",
            updatedAt: conversation.updatedAt
        ))
    }
}

enum SessionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case sessionNotFound
    case emptyPrompt
    /// Limited mode: the user hasn't agreed to share data with AI services.
    /// Intents can't show the consent sheet, so they stop before doing
    /// anything and tell the user where to agree.
    case dataSharingConsentRequired

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sessionNotFound: return "That session no longer exists."
        case .emptyPrompt: return "The prompt was empty."
        case .dataSharingConsentRequired:
            return LocalizedStringResource(
                "请先打开 Oases，同意 AI 数据共享后再试。",
                comment: "Siri / Shortcuts error: sending to AI is off until the user agrees to AI data sharing in the app"
            )
        }
    }

    /// First statement of every intent that sends to a model (SendPrompt,
    /// AskOases, QuickTask, FollowUpSession, RetryRun): runs before a session
    /// is created, the keep-alive is armed or the composer is touched.
    static func requireDataSharingConsent() async throws {
        guard AIDataSharingConsent.isAccepted else {
            throw SessionIntentError.dataSharingConsentRequired
        }
    }
}

/// Exposes the intents to Siri with spoken phrases.
/// Renamed from OpenMinis `MinisShortcutsProvider`.
struct OasesShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListSessionsIntent(),
            phrases: [
                "List \(.applicationName) sessions",
                "Show my \(.applicationName) sessions",
            ],
            shortTitle: "List Sessions",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: AskOasesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) to do something",
            ],
            shortTitle: "Ask Oases",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenSessionIntent(),
            phrases: [
                "Open a session in \(.applicationName)",
                "Open \(.applicationName) session",
            ],
            shortTitle: "Open Session",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
