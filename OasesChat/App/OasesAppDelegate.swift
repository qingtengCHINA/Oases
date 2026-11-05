import UIKit
import UserNotifications
import os.log

/// UIKit application delegate for capabilities that SwiftUI `App` cannot own:
/// push registration, remote-notification wakeups, background-task
/// registration, and the scene delegate that receives Home Screen shortcuts.
@MainActor
final class OasesAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OasesChat", category: "Push")
    /// The QingTeng account (Settings › QingTeng 账号). Optional and independent of everything else:
    /// signing out or deleting the account keeps the chats, sessions, providers, API keys,
    /// provider sign-ins and the membership.
    let account = AccountStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First thing: the welcome icon's liquid-metal state (Metal pipeline + the icon's depth
        // field) is built while the launch splash plays, so the icon is ready when it ends.
        MetallicPaintPrewarm.start()

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // BGTaskScheduler requires every launch handler to be registered
        // before the app finishes launching; it used to run 4 s after the
        // first frame, too late for a background launch into the task.
        OgentBackgroundAutomation.register()
        // Agreeing later schedules automations; declining cancels the
        // pending background refresh.
        AIConsentAutomationLifecycle.startObserving()

        // The QingTeng account follows the one-page consent: nothing goes to its server without
        // it, and declining or withdrawing signs out at once (requests to AI providers are voided
        // by `AIConsentAutomationLifecycle`).
        account.followConsent()

        // No permission prompt at launch. `BackgroundKeepAliveManager` asks
        // the first time the user starts a task that can notify them; here we
        // only re-register when permission was already granted. Not
        // consent-gated: the token stays on the device and task-finished
        // notifications are local features that work in limited mode.
        Self.registerForRemoteNotificationsIfAuthorized()
        return true
    }

    /// This is a scene-based app, so Home Screen quick actions never arrive in
    /// `launchOptions` or `application(_:performActionFor:)` — they go to the
    /// scene delegate. SwiftUI still owns the scene and its window.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = OasesSceneDelegate.self
        return configuration
    }

    // MARK: - Push token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "push.deviceToken")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "push.deviceTokenUpdatedAt")
        logger.info("APNs device token registered (\(token.prefix(16), privacy: .public)…)")
        NotificationCenter.default.post(
            name: .oasesDidRegisterPushToken,
            object: nil,
            userInfo: ["token": token]
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Silent / background push wakeups (requires `remote-notification` mode).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        logger.info("remote notification wakeup keys=\(userInfo.keys.map { "\($0)" }, privacy: .public)")
        // The only work a wakeup does is running due automations, which send
        // data to models — so that part stays consent-gated.
        guard AIDataSharingConsent.isAccepted else {
            logger.info("remote notification: automations skipped until AI data sharing consent")
            completionHandler(.noData)
            return
        }
        // Kick lightweight maintenance; heavy work stays on existing keep-alive paths.
        Task { @MainActor in
            guard AIDataSharingConsent.isAccepted else {
                completionHandler(.noData)
                return
            }
            OgentAutomationScheduler.scheduleRunDue(reason: "remote_notification", delay: 0.5)
            completionHandler(.newData)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Navigation only — works in limited mode.
        let userInfo = response.notification.request.content.userInfo
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            // The router drops `qtc-oases://` and anything that isn't
            // `oases://`, and logs only scheme + host — the payload is not
            // trusted to be one of our links.
            DeepLinkRouter.handle(url: url, shareCoordinator: ShareCoordinator.shared)
        } else if let sessionId = userInfo["sessionId"] as? String, !sessionId.isEmpty {
            // Task-finished notifications carry the session to reopen;
            // `AppIntakeCoordinator` consumes it once RootView is mounted.
            DeepLinkCoordinator.shared.pendingSessionId = sessionId
        }
        completionHandler()
    }

    // MARK: - Helpers

    static func registerForRemoteNotificationsIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            default:
                break
            }
        }
    }

    /// Prompts only while permission is undetermined, then registers for
    /// remote notifications once granted.
    static func requestNotificationAuthorizationAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }
}

/// Receives the UIKit scene callbacks SwiftUI doesn't surface. SwiftUI creates
/// the window; this delegate only forwards Home Screen quick actions — in the
/// connection options on a cold launch, via `windowScene(_:performActionFor:)`
/// while running — to `QuickActionRouter`. It deliberately does not implement
/// URL callbacks, which SwiftUI routes to `.onOpenURL`.
@MainActor
final class OasesSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Quick actions only open a chat / voice / camera composer; any send
        // from there goes through the consent-gated send path.
        if let shortcut = connectionOptions.shortcutItem {
            QuickActionRouter.shared.handle(shortcut)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActionRouter.shared.handle(shortcutItem))
    }
}
