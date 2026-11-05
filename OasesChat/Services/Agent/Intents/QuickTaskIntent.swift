import AppIntents
import Foundation
import SwiftData
import UserNotifications
import UniformTypeIdentifiers

private let logger = AppLogger(category: "QuickTaskIntent")

/// Predefined tasks that Siri can invoke by name in a single utterance.
/// e.g. "Oases check weather" (or the same phrase pattern in the user's locale).
enum QuickTask: String, AppEnum {
    case checkWeather
    case morningBriefing
    case checkCalendar
    case takePhoto
    case setAlarm

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quick Task")

    static let caseDisplayRepresentations: [QuickTask: DisplayRepresentation] = [
        .checkWeather:   DisplayRepresentation(title: "Check Weather", subtitle: LocalizedStringResource("查看天气", comment: "Quick task subtitle")),
        .morningBriefing: DisplayRepresentation(title: "Morning Briefing", subtitle: LocalizedStringResource("早间简报", comment: "Quick task subtitle")),
        .checkCalendar:  DisplayRepresentation(title: "Check Calendar", subtitle: LocalizedStringResource("查看日程", comment: "Quick task subtitle")),
        .takePhoto:      DisplayRepresentation(title: "Take Photo", subtitle: LocalizedStringResource("拍照", comment: "Quick task subtitle")),
        .setAlarm:       DisplayRepresentation(title: "Set Alarm", subtitle: LocalizedStringResource("设置闹钟", comment: "Quick task subtitle")),
    ]

    /// Sent to the model as the task prompt — stays in English.
    var prompt: String {
        switch self {
        case .checkWeather:
            return "Check today's weather (apple-weather) and give clothing and travel suggestions"
        case .morningBriefing:
            return "Give me a morning briefing for today: first check the weather (apple-weather), then check today's calendar events (apple-calendar), finally search for important news today using the browser, and summarize into a briefing"
        case .checkCalendar:
            return "Check my schedule for today and tomorrow (apple-calendar)"
        case .takePhoto:
            return "Take a photo using the device camera (apple-media camera) and describe what was captured"
        case .setAlarm:
            return "Set an alarm to remind me in 5 minutes"
        }
    }
}

/// Runs a predefined quick task.
///
/// Ported from OpenMinis `Agent/Intents/QuickTaskIntent.swift`. Real driver:
/// allocates a fresh session, fills `vm.input` with the task prompt, and
/// awaits `vm.send()` exactly like `SendPromptIntent`. Optional `files` are
/// converted to `[Attachment]` and passed through.
struct QuickTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Task"
    static let description = IntentDescription("Runs a predefined Oases Chat task like a weather check, calendar check, or morning briefing.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: QuickTask

    @Parameter(title: "Attachments", description: "Images, videos, or files to attach to the task. Accepts output from previous Shortcuts actions (e.g. filtered photos or documents).",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]?

    @Parameter(title: "Model", description: "Specify a model or model group to use. Leave empty to use the app default.")
    var model: ModelSelectionEntity?

    @Parameter(title: "Wait for Result", description: "When enabled, waits for the AI to finish and returns the full response for use in subsequent actions.", default: false)
    var waitForResult: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog {
        try await SessionIntentError.requireDataSharingConsent()
        BackgroundKeepAliveManager.shared.setup()

        let taskNameRep = QuickTask.caseDisplayRepresentations[task]?.title
        let taskName = taskNameRep.map { String(localized: $0) } ?? "\(task.rawValue)"
        let promptText = task.prompt
        logger.info("[QuickTaskIntent] task=\(task.rawValue) (\(taskName))")

        let context = ModelContext(ConversationContainer.shared)
        let conversation = ConversationModel()
        conversation.title = taskName
        context.insert(conversation)
        try? context.save()

        let sid = conversation.id.uuidString
        let (vm, _) = ChatViewModelCache.shared.getOrCreate(for: sid)

        // Optional model selection. `model.id` is the user-facing label
        // (ModelSelectionEntity wraps a ModelEntry label); if provided,
        // swap the conversation's modelId before sending.
        if let modelEntity = model, !modelEntity.id.isEmpty {
            conversation.modelId = modelEntity.id
            try? context.save()
        }
        let modelName = ProviderChatRouting.label(for: conversation.modelId)
            ?? Models.option(for: conversation.modelId)?.label
            ?? conversation.modelId

        let attachments = SendPromptIntent.attachments(from: files)

        SessionActivityTracker.shared.setActive(sid)
        SessionActivityTracker.shared.updateSessionTitle(sid, title: conversation.title)
        let pendingId = ShortcutRunTracker.beginIntentRun(intent: "QuickTaskIntent", sessionId: sid)
        ShortcutNotification.post(
            id: "shortcut-quicktask-\(sid)",
            title: String(localized: "Oases Chat: \(taskName)", comment: "Notification title when a Siri quick task starts; argument is the task name"),
            body: "\(modelName): \(promptText.prefix(50))\(promptText.count > 50 ? "…" : "")",
            sessionId: sid,
            phase: .started
        )

        vm.input = promptText

        if waitForResult {
            await vm.send(attachments: attachments)
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "waitForResult.done")
            let responseText = SendPromptIntent.extractResponseText(from: vm)
            ShortcutNotification.post(
                id: "shortcut-quicktask-done-\(sid)",
                title: String(localized: "Oases Chat: \(taskName) Done", comment: "Notification title when a Siri quick task finishes; argument is the task name"),
                body: "\(modelName): \(responseText.prefix(200))",
                sessionId: sid,
                phase: .completed
            )
            let result = SendPromptResult(
                sessionId: sid, modelName: modelName, status: "Completed",
                isNewSession: true, prompt: promptText, responseText: responseText
            )
            return .result(value: result, dialog: "\(responseText.prefix(500))")
        }

        // Fire-and-forget.
        Task { @MainActor in
            await vm.send(attachments: attachments)
            SessionActivityTracker.shared.setInactive(sid)
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "async.done")
            ShortcutNotification.post(
                id: "shortcut-quicktask-done-\(sid)",
                title: String(localized: "Oases Chat: \(taskName) Done", comment: "Notification title when a Siri quick task finishes; argument is the task name"),
                body: "\(modelName): \(SendPromptIntent.extractResponseText(from: vm).prefix(200))",
                sessionId: sid,
                phase: .completed
            )
        }

        let result = SendPromptResult(
            sessionId: sid, modelName: modelName, status: "Running",
            isNewSession: true, prompt: promptText
        )
        return .result(value: result, dialog: "On \(taskName) — I'll notify you when it's done.")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$task)")
    }
}
