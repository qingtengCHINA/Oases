import Foundation

/// App-wide Notification.Name constants (ported from OpenMinis MinisApp.swift
/// + attachment-size invalidation used by media/markdown modules).
extension Notification.Name {
    static let newChatRequested = Notification.Name("newChatRequested")
    /// Posted when a new session is persisted. `object` is the session ID (`String`).
    static let sessionDidCreate = Notification.Name("sessionDidCreate")
    /// Posted when a session's title or messages are updated.
    static let sessionDidUpdate = Notification.Name("sessionDidUpdate")
    static let sessionDidDelete = Notification.Name("sessionDidDelete")
    /// Posted when an agent loop ends on a non-displayed VM. `object` = session ID.
    static let sessionAgentLoopDidEnd = Notification.Name("sessionAgentLoopDidEnd")
    /// userInfo: ["targetId": String]
    static let moveInputToSession = Notification.Name("moveInputToSession")
    /// userInfo: ["sessionId": String] and optionally ["groupId": String].
    static let sessionModelBindingChanged = Notification.Name("sessionModelBindingChanged")
    /// Oases chrome asks the embedded Ogent chat to present its model picker.
    static let ogentRequestModelPicker = Notification.Name("ogentRequestModelPicker")
    /// Home-screen widget. `userInfo["action"]` is `ask`, `camera`, or `voice`.
    static let oasesWidgetOpen = Notification.Name("oasesWidgetOpen")
    /// Posted when a send hits a membership limit. RootView presents the paywall.
    static let membershipPaywall = Notification.Name("membershipPaywall")
    /// Dismiss fullScreenCover hosts so shares / deep-links can surface.
    static let dismissAllImmersivePresentations = Notification.Name("dismissAllImmersivePresentations")

    static let cloudSyncDidFetchChanges = Notification.Name("cloudSyncDidFetchChanges")
    static let cloudSyncDidPushChanges = Notification.Name("cloudSyncDidPushChanges")
    static let providerConfigDidChange = Notification.Name("providerConfigDidChange")
    static let mcpServersDidChange = Notification.Name("mcpServersDidChange")
    static let skillsDidChange = Notification.Name("skillsDidChange")

    /// Media/markdown attachment layout grew — message list should invalidate size.
    static let minisAttachmentSizeChanged = Notification.Name("minisAttachmentSizeChanged")
    /// Posted to leave AppMode.project and return to Oases chat modes.
    static let oasesExitEngineeringMode = Notification.Name("oasesExitEngineeringMode")
    /// Posted after APNs device token registration succeeds.
    /// `userInfo["token"]` is the hex device token string.
    static let oasesDidRegisterPushToken = Notification.Name("oasesDidRegisterPushToken")
}

struct OasesWidgetLaunch: Equatable {
    var id = UUID()
    var action: String
}
