import SwiftUI
import UIKit

private let intakeLog = AppLogger(category: "Intake")

/// Routes the app's external entry points into the mounted RootView:
/// Home Screen quick actions (`QuickActionRouter`), Share Extension
/// hand-offs (`ShareCoordinator`), and deep-link / notification targets
/// (`DeepLinkCoordinator`, `DeepLinkRouter` notifications).
///
/// These producers used to be observed only by `EngineeringAgentShell`,
/// which the app no longer mounts, so every one of them was dropped. Each
/// producer keeps its request pending until it is consumed here, and
/// `onAppear` drains anything that arrived before the view existed (cold
/// launch from a shortcut, share, or notification tap).
@MainActor
struct AppIntakeCoordinator: ViewModifier {
    struct Handlers {
        /// Open a fresh chat, then run the optional follow-up.
        var newChat: @MainActor (ChatLaunchAction?) -> Void
        /// Put shared content into a composer.
        var share: @MainActor (PendingShare) -> Void
        /// Present Settings; `SettingsView` consumes the pending target itself.
        var openSettings: @MainActor () -> Void
        /// Open a conversation (Oases chat or Ogent session) by id.
        var openSession: @MainActor (String) -> Void
        var showSessionList: @MainActor () -> Void
    }

    let handlers: Handlers

    @ObservedObject private var quickActions = QuickActionRouter.shared
    @ObservedObject private var shares = ShareCoordinator.shared
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var storeRecoveryNotice: String?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: drainPending)
            .onChange(of: quickActions.newChatTrigger) { _, _ in routeNewChat() }
            .onChange(of: shares.hasPendingShare) { _, pending in
                if pending { routeShare() }
            }
            .onChange(of: deepLink.pendingSettingsTarget) { _, target in
                if target != nil { handlers.openSettings() }
            }
            .onChange(of: deepLink.pendingSessionId) { _, _ in routeSession() }
            .onChange(of: scenePhase) { _, phase in
                // The Share Extension's `oases://share` open can be lost
                // (e.g. the host was suspended mid-hand-off). The App Group
                // record survives, so look for it whenever we come back.
                if phase == .active { ShareCoordinator.shared.checkForPendingShare() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .oasesShowSessionList)) { _ in
                handlers.showSessionList()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWebAppDeepLink)) { note in
                guard let shortcut = note.userInfo?["shortcut"] as? WebAppShortcut else { return }
                presentWebApp(shortcut)
            }
            .alert(
                SettingsCopy.t("对话记录已重置", "Chat history was reset"),
                isPresented: Binding(
                    get: { storeRecoveryNotice != nil },
                    set: { if !$0 { storeRecoveryNotice = nil } }
                )
            ) {
                Button(SettingsCopy.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(storeRecoveryNotice ?? "")
            }
    }

    private func drainPending() {
        routeNewChat()
        if shares.hasPendingShare { routeShare() }
        if deepLink.pendingSettingsTarget != nil { handlers.openSettings() }
        routeSession()
        if let notice = ConversationContainer.takeRecoveryNotice() {
            storeRecoveryNotice = notice
        }
    }

    private func routeNewChat() {
        guard let request = quickActions.consumeNewChatRequest() else { return }
        intakeLog.info("new chat from quick action, action=\(String(describing: request.action))")
        handlers.newChat(request.action)
    }

    private func routeShare() {
        guard let pending = SharedContainerStore.loadPendingShare() else {
            intakeLog.info("pending-share flag raised but the App Group record is gone")
            shares.hasPendingShare = false
            return
        }
        SharedContainerStore.clearPendingShare()
        shares.hasPendingShare = false
        intakeLog.info("routing share with \(pending.items.count) item(s)")
        handlers.share(pending)
    }

    private func routeSession() {
        guard let id = deepLink.pendingSessionId, !id.isEmpty else { return }
        deepLink.pendingSessionId = nil
        handlers.openSession(id)
    }

    /// `WebAppWebViewController` dismisses itself (menu → Close, edge swipe),
    /// so present it with UIKit rather than a SwiftUI cover whose binding
    /// would not learn about that dismissal.
    private func presentWebApp(_ shortcut: WebAppShortcut) {
        let resolved: WebAppPathResolver.Resolved
        do {
            resolved = try WebAppPathResolver.resolve(shortcut)
        } catch {
            intakeLog.warning("pinned WebApp failed to resolve: \(String(describing: error))")
            ShareFeedbackToast.show(SettingsCopy.t("无法打开这个网页应用，文件可能已被移动或删除。",
                                                  "Couldn't open this web app. The file may have been moved or deleted."))
            return
        }
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = WebAppWebViewController(shortcut: shortcut, resolved: resolved)
        controller.modalPresentationStyle = .fullScreen
        top.present(controller, animated: true)
    }
}

extension View {
    func appIntake(_ handlers: AppIntakeCoordinator.Handlers) -> some View {
        modifier(AppIntakeCoordinator(handlers: handlers))
    }
}
