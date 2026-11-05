//
//  QuickActionRouter.swift
//  MinisApp
//
//  Home-screen Quick Actions (long-press app icon → "New Chat",
//  "Chat with Voice", "Chat with Camera").
//
//  Two responsibilities:
//   1. Register the three `UIApplicationShortcutItem`s once at app
//      launch (dynamic registration so they can be added / removed
//      without touching Info.plist).
//   2. Receive `UIApplicationShortcutItem` events from the scene delegate
//      (`OasesSceneDelegate`: cold launch via the connection options, warm
//      tap via `windowScene(_:performActionFor:completionHandler:)`) and
//      hand them to the mounted UI:
//        - All three bump `newChatTrigger`; `AppIntakeCoordinator` (attached
//          to RootView) consumes it via `consumeNewChatRequest()` and opens
//          a fresh chat.
//        - Voice + Camera also stash a pending `ChatLaunchAction` that rides
//          along in the request, so the fresh chat starts dictation /
//          presents the camera.
//

import Foundation
import UIKit

private let logger = AppLogger(category: "QuickAction")

/// One-shot action consumed by `AIChatView` when a new chat opens from
/// a Home Screen shortcut.
enum ChatLaunchAction: Equatable {
    case startVoice
    case openCamera
}

@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()

    /// Monotonically incremented whenever a shortcut requests a new
    /// chat. `AppIntakeCoordinator` observes this and also checks it on
    /// appear, so a cold-launch shortcut that fires before RootView mounts
    /// is still routed.
    @Published private(set) var newChatTrigger: Int = 0

    /// Last `newChatTrigger` value a host has routed. Lives here, not in view
    /// state, so a RootView rebuild (the language switch re-creates it with
    /// `.id`) can't replay a shortcut that was already handled.
    private var consumedNewChatTrigger = 0

    /// A new-chat request from a Home Screen quick action, with the optional
    /// follow-up for the fresh chat (dictation / camera).
    struct NewChatRequest: Equatable {
        let action: ChatLaunchAction?
    }

    private init() {}

    // MARK: - Shortcut item types (also referenced from AppDelegate)

    enum ShortcutType {
        static let newChat = "dev.oases.chat.ios.shortcut.newChat"
        static let voiceChat = "dev.oases.chat.ios.shortcut.voiceChat"
        static let cameraChat = "dev.oases.chat.ios.shortcut.cameraChat"
    }

    /// Install the dynamic shortcut items on the running app. Idempotent —
    /// can be called multiple times without growing the list. We always
    /// overwrite so removing / re-ordering only requires editing one
    /// place.
    static func registerShortcutItems() {
        let items: [UIApplicationShortcutItem] = [
            UIApplicationShortcutItem(
                type: ShortcutType.newChat,
                localizedTitle: String(localized: "shortcut.newChat.title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.and.bubble.right"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: ShortcutType.voiceChat,
                localizedTitle: String(localized: "shortcut.voiceChat.title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "mic.fill"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: ShortcutType.cameraChat,
                localizedTitle: String(localized: "shortcut.cameraChat.title"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "camera.fill"),
                userInfo: nil
            ),
        ]
        UIApplication.shared.shortcutItems = items
        logger.info("registerShortcutItems installed=\(items.count)")
    }

    /// Entry point called by `AppDelegate` for both cold-launch
    /// shortcut items (via launchOptions) and warm taps. Returns true
    /// when the shortcut type was recognized, so the system can mark
    /// the request as handled.
    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        logger.info("handle shortcut type=\(shortcutItem.type)")
        switch shortcutItem.type {
        case ShortcutType.newChat:
            // [Stage 0] `QuickActionWorkflow` lives in OpenMinis `Shared/QuickActionWorkflow.swift`
            // and is bound to a ChatView-level launcher cover sheet that OasesChat
            // hasn't ported yet. We surface the event and post a new chat; the
            // follow-up ChatLaunchAction (.startVoice / .openCamera) resumes once
            // Stage 1 brings over the cover-sheet wiring.
            logger.info("newChat shortcut — no follow-up action")
            pendingLaunchAction = nil
            postNewChat()
            return true
        case ShortcutType.voiceChat:
            pendingLaunchAction = .startVoice
            postNewChat()
            return true
        case ShortcutType.cameraChat:
            pendingLaunchAction = .openCamera
            postNewChat()
            return true
        default:
            logger.warning("unknown shortcut type: \(shortcutItem.type)")
            return false
        }
    }

    /// Follow-up for the next new chat; handed out (and cleared) by
    /// `consumeNewChatRequest()`.
    @Published var pendingLaunchAction: ChatLaunchAction?

    /// One-shot hand-off to the mounted host. Returns nil when every trigger
    /// bump has already been routed.
    func consumeNewChatRequest() -> NewChatRequest? {
        guard newChatTrigger != consumedNewChatTrigger else { return nil }
        consumedNewChatTrigger = newChatTrigger
        let action = pendingLaunchAction
        pendingLaunchAction = nil
        logger.info("consumeNewChatRequest trigger=\(newChatTrigger) action=\(String(describing: action))")
        return NewChatRequest(action: action)
    }

    private func postNewChat() {
        // Bump the @Published counter — `AppIntakeCoordinator`'s
        // `.onChange(of: newChatTrigger)` + `.onAppear` belt-and-braces
        // drives the new chat. Do NOT also post `.newChatRequested`:
        // RootView observes that notification separately, so posting both
        // would start two new chats.
        newChatTrigger &+= 1
        logger.info("postNewChat trigger=\(newChatTrigger)")
    }
}
