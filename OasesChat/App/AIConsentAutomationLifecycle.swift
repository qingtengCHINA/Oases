import Foundation

/// Keeps background automation in step with the AI data-sharing consent.
///
/// Automations (Ogent run-due, background app refresh, silent-push wakeups)
/// send data to models, so they only run with consent — unlike the rest of
/// the launch work, which is local and runs in limited mode too.
/// `AppLaunchCoordinator` schedules them once per launch; this observer
/// covers changes during the session: agreeing later (Settings or the
/// consent sheet) schedules them, declining or withdrawing cancels the
/// pending background refresh.
///
/// Withdrawing also voids every AI request under way (`AIRequestGate`): chat
/// and agent runs stop, and requests in flight are cancelled at the transport.
///
/// A run already executing inside iSH can't be interrupted from here:
/// `OgentAutomationScheduler` drives it through the synchronous
/// `ISHShellExecutor.executeCommandSync`, which exposes no pid. Its model
/// calls still go through `LLMProviderFactory` / `SessionsOffloadBridge` and
/// are refused there from the moment consent is withdrawn, and a run that
/// was scheduled but hasn't started re-checks consent before it begins.
@MainActor
enum AIConsentAutomationLifecycle {
    private static var observer: NSObjectProtocol?

    /// Idempotent; installed from `didFinishLaunching`.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AIDataSharingConsent.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { consentDidChange() }
        }
    }

    /// The parameters exist for tests; production uses the defaults.
    static func consentDidChange(
        isAccepted: Bool = AIDataSharingConsent.isAccepted,
        resume: () -> Void = { AppLaunchCoordinator.resumeAutomationsAfterConsent() },
        cancelPending: () -> Void = { OgentBackgroundAutomation.cancelAppRefresh() },
        voidRequests: () -> Void = { AIRequestGate.voidRequests() }
    ) {
        if isAccepted {
            resume()
        } else {
            cancelPending()
            voidRequests()
            NSLog("[OgentAutomation] consent_withdrawn pending_refresh_cancelled=1 in_flight_run_interruptible=0")
        }
    }
}
