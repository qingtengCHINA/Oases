import ActivityKit
import AVFoundation
import Combine
import CoreLocation
import Foundation
import SwiftUI
import UserNotifications
import os.log

private let logger = AppLogger(category: "BackgroundKeepAlive")

// MARK: - Background Keep Alive Manager

@MainActor
final class BackgroundKeepAliveManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAliveManager()

    /// True when there are active sessions and enhanced background is enabled.
    /// Used by `waitIfBackgroundSuspended()` to skip suspension.
    @Published private(set) var isActive = false

    /// App Review 2.5.4: keeping the process alive with a silent audio track
    /// is a developer tool only. Release builds never start it, so every
    /// "keep-alive is active" decision (`enhancedBackgroundEffective`,
    /// `survivalTier`) is false there and agent loops take the normal
    /// suspend/resume path when iOS expires the finite background task.
    /// (The location heartbeat keep-alive was removed outright.)
    #if DEBUG
    static let silentAudioKeepAliveAvailable = true
    #else
    static let silentAudioKeepAliveAvailable = false
    #endif

    /// [T-keepalive-survival-tier] Background-survival capability shown in
    /// Settings → Background → Status. Independent of whether a task is
    /// running right now — it answers "if the app backgrounds at this moment,
    /// how long can it keep working": every iOS app gets only the standard
    /// ~30s grace window unless one of the long-lived legs is enabled.
    enum BackgroundSurvivalTier: Equatable {
        /// Only the standard iOS background grace window (~30 seconds).
        case short
        /// Long-lived, via whichever legs are currently enabled. `location`
        /// is always false now that the location keep-alive is gone; `audio`
        /// is the DEBUG-only silent-audio keep-alive.
        case extended(location: Bool, audio: Bool)
    }

    /// Reactive: all inputs are @Published on this ObservableObject, so the
    /// Settings row re-renders on toggle/permission changes automatically.
    var survivalTier: BackgroundSurvivalTier {
        let audioLeg = Self.silentAudioKeepAliveAvailable && backgroundSpeakEnabled
        return audioLeg ? .extended(location: false, audio: true) : .short
    }

    @Published var enhancedBackgroundEnabled: Bool = UserDefaults.standard.bool(forKey: "enhancedBackgroundExecution") {
        didSet {
            UserDefaults.standard.set(enhancedBackgroundEnabled, forKey: "enhancedBackgroundExecution")
            // Turning on the master switch also opts the user into
            // Background Speak — without it, TTS narration cuts off the
            // instant the app backgrounds, which defeats the typical
            // "enable enhanced background so my long task can keep
            // narrating" intent users have when flipping this from the
            // interruption banner. Off → on only; flipping the master
            // back off leaves Background Speak alone so the user's
            // own choice isn't clobbered (T-enhanced-bg-auto-speak).
            if enhancedBackgroundEnabled && !backgroundSpeakEnabled {
                backgroundSpeakEnabled = true
            }
        }
    }

    /// No longer drives anything: the background-location keep-alive was
    /// removed (App Review 2.5.4). Kept so the persisted setting and the
    /// Settings / config-registry bindings that reference it still compile.
    @Published var locationTrackingEnabled: Bool = UserDefaults.standard.bool(forKey: "locationTrackingEnabled") {
        didSet { UserDefaults.standard.set(locationTrackingEnabled, forKey: "locationTrackingEnabled") }
    }

    /// [T-live-activity-toggle] User switch for the agent-progress Live
    /// Activity (Lock Screen / Dynamic Island). Defaults to ON — the key is
    /// absent until the user first flips it, so read via object(forKey:).
    /// AgentLiveActivityManager gates its start/update entry points on this;
    /// flipping OFF also tears down any currently-displayed activity so the
    /// Lock Screen doesn't keep a stale card.
    @Published var liveActivityEnabled: Bool = (UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool) ?? true {
        didSet {
            guard liveActivityEnabled != oldValue else { return }
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if liveActivityEnabled {
                // Re-enabled mid-task: restore the activity for any running sessions.
                updateLiveActivityIfNeeded(source: "liveActivityToggleOn")
            } else {
                AgentLiveActivityManager.shared.endActivity()
            }
        }
    }

    @Published var backgroundSpeakEnabled: Bool = UserDefaults.standard.bool(forKey: "backgroundSpeakEnabled") {
        didSet { UserDefaults.standard.set(backgroundSpeakEnabled, forKey: "backgroundSpeakEnabled") }
    }

    /// True only when the configuration can actually keep the app alive in the
    /// background. The master switch alone is not enough: silent-audio
    /// keep-alive (the mechanism that prevents background-task expiry) only
    /// plays when Background Speak is also on (see `evaluateSilentAudio`).
    /// So "master on but Background Speak off" still gets interrupted — and
    /// must be treated as "enhanced background NOT effective" everywhere we
    /// decide whether to count interruptions / surface the reminder banner.
    /// Always false in Release, where the silent-audio leg doesn't exist.
    var enhancedBackgroundEffective: Bool {
        Self.silentAudioKeepAliveAvailable && enhancedBackgroundEnabled && backgroundSpeakEnabled
    }

    /// When enabled, posts local notifications when agent tasks start and complete.
    @Published var backgroundNotificationsEnabled: Bool = {
        // Default to true if key hasn't been set
        UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "backgroundNotificationsEnabled")
    }() {
        didSet { UserDefaults.standard.set(backgroundNotificationsEnabled, forKey: "backgroundNotificationsEnabled") }
    }

    /// [T-ios-live-activity-privacy-mode] When enabled, the Live Activity, the
    /// Dynamic Island and background task notifications stop surfacing session
    /// content — no session title, tool status/icon or reply summary. They
    /// degrade to a neutral progress report: completed/total task count plus the
    /// elapsed timer.
    ///
    /// Deliberately NOT related to the pre-existing `envvars.privacyMode`
    /// (ConfigRegistry / EnvVarPrivacyStore), which masks environment-variable
    /// values in the config UI — different concept, hence the distinct
    /// `liveActivityPrivacyMode` key to avoid conflation.
    ///
    /// Defaults to OFF so existing installs keep their current behavior.
    @Published var liveActivityPrivacyMode: Bool =
        UserDefaults.standard.bool(forKey: "liveActivityPrivacyMode") {
        didSet { UserDefaults.standard.set(liveActivityPrivacyMode, forKey: "liveActivityPrivacyMode") }
    }

    // MARK: - Speech Settings

    /// Speech rate (0.0–1.0). Default is AVSpeechUtteranceDefaultSpeechRate (0.5).
    // NSNumber: oases-config stores the rate as a Double, and `as? Float` fails for most of those.
    @Published var speechRate: Float = (UserDefaults.standard.object(forKey: "speechRate") as? NSNumber)?.floatValue ?? AVSpeechUtteranceDefaultSpeechRate {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }

    /// Pitch multiplier (0.5–2.0). Default is 1.0.
    @Published var speechPitch: Float = UserDefaults.standard.object(forKey: "speechPitch") as? Float ?? 1.0 {
        didSet { UserDefaults.standard.set(speechPitch, forKey: "speechPitch") }
    }

    /// Volume (0.0–1.0). Default is 1.0.
    @Published var speechVolume: Float = UserDefaults.standard.object(forKey: "speechVolume") as? Float ?? 1.0 {
        didSet { UserDefaults.standard.set(speechVolume, forKey: "speechVolume") }
    }

    /// Voice identifier for Chinese TTS. nil = system default.
    @Published var speechVoiceZh: String = UserDefaults.standard.string(forKey: "speechVoiceZh") ?? "" {
        didSet { UserDefaults.standard.set(speechVoiceZh, forKey: "speechVoiceZh") }
    }

    /// Voice identifier for English TTS. nil = system default.
    @Published var speechVoiceEn: String = UserDefaults.standard.string(forKey: "speechVoiceEn") ?? "" {
        didSet { UserDefaults.standard.set(speechVoiceEn, forKey: "speechVoiceEn") }
    }

    /// Reset all speech settings to defaults.
    func resetSpeechSettings() {
        speechRate = AVSpeechUtteranceDefaultSpeechRate
        speechPitch = 1.0
        speechVolume = 1.0
        speechVoiceZh = ""
        speechVoiceEn = ""
    }

    /// Build a voice for the given language, respecting user's voice selection.
    func voiceForLanguage(_ lang: String) -> AVSpeechSynthesisVoice? {
        let identifier = lang.hasPrefix("zh") ? speechVoiceZh : speechVoiceEn
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: lang)
    }

    /// Read-only mirror of the location permission for the Settings status row.
    /// This manager never requests location updates.
    @Published private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined

    /// Timer for periodic Live Activity updates.
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let locationManager = CLLocationManager()
    private var appIsInBackground = false

    /// [T-ios-scenephase-active-sigkill] True between a `willEnterForeground`
    /// notification and its deferred (yielded) handler running. Replaces the
    /// `applicationState != .background` guard, which was unreliable because
    /// `.inactive` is ambiguous — it can mean "entering foreground" OR "entering
    /// background". A synchronous `didEnterBackground` clears this flag, so a
    /// rapid bg→fg→bg blip cancels the in-flight foreground work cleanly. Also
    /// gates `reevaluate`'s @Published writes off the transition tick.
    private var pendingForegroundTransition = false

    // MARK: - Silent Audio Keep-Alive
    private var audioEngine: AVAudioEngine?
    private var silentPlayerNode: AVAudioPlayerNode?
    private var silentAudioActive = false

    /// [T-bg-keepalive-debounce] Pending debounced stop of silent audio. When
    /// the app receives a transient `foreground` signal (e.g. a call ending →
    /// Oases Chat briefly foregrounds → immediately backgrounds again), stopping the
    /// keep-alive audio synchronously releases the audio session right before
    /// we go back to background, and iOS then kills the process. While sessions
    /// are active we instead DELAY the stop; if a `background` signal arrives
    /// within the window we cancel it and keep the audio running. nil when no
    /// stop is pending.
    private var pendingSilentAudioStop: DispatchWorkItem?
    /// Debounce window for a foreground-triggered stop while sessions are active.
    private static let silentAudioStopDebounce: TimeInterval = 1.5

    /// [T-bg-keepalive-debounce] How many consecutive `setActive(true)` failures
    /// we've retried for the current start attempt. Reset on success / when the
    /// budget is exhausted.
    private var silentAudioActivationRetries = 0
    private static let maxActivationRetries = 3
    private static let activationRetryDelay: TimeInterval = 0.5

    /// Wall-clock when the current debounced stop was scheduled, for logging the
    /// remaining window. nil when no stop is pending.
    private var pendingStopScheduledAt: Date?

    // MARK: - [BKA] Diagnostic snapshot state (read by CrashReporter)

    /// Last `[BKA][...]` action recorded, e.g. "Stop(reason=foreground,debounce=pending)".
    private(set) var lastBKAEvent: String?
    private(set) var lastBKAEventAt: Date?
    /// Last lifecycle transition, e.g. "Background" / "Foreground".
    private(set) var lastLifecycle: String?
    private(set) var lastLifecycleAt: Date?
    /// Audio-interruption state: "none" / "began" / "ended", with timestamp.
    private(set) var lastAudioInterruption: String = "none"
    private(set) var lastAudioInterruptionAt: Date?

    /// True if the keep-alive engine is genuinely running right now.
    var silentAudioIsPlaying: Bool { audioEngine?.isRunning ?? false }
    /// True if the shared audio session currently holds an active route.
    var audioSessionIsActive: Bool { silentAudioActive }
    /// True if a debounced stop is queued.
    var stopDebouncePending: Bool { pendingSilentAudioStop != nil }

    /// Record the most recent BKA action for the crash snapshot + log it.
    private func recordBKAEvent(_ event: String) {
        lastBKAEvent = event
        lastBKAEventAt = Date()
    }

    /// Human-readable debounce-timer state for the lifecycle snapshot line.
    private func debounceTimerDescription() -> String {
        guard pendingSilentAudioStop != nil else { return "nil" }
        guard let scheduledAt = pendingStopScheduledAt else { return "pending" }
        let left = Self.silentAudioStopDebounce - Date().timeIntervalSince(scheduledAt)
        return left > 0 ? "pending(\(String(format: "%.1f", left))s left)" : "pending(firing)"
    }

    /// One structured snapshot line covering every signal that decides whether
    /// the process survives in the background. Emitted on every lifecycle change.
    /// [BKA][Lifecycle]
    private func logLifecycleSnapshot(_ transition: String) {
        lastLifecycle = transition
        lastLifecycleAt = Date()
        let sessions = SessionActivityTracker.shared.activeSessions.count
        // `ShellCommandRingBuffer` isn't ported; this line is diagnostics only.
        let shellRunning = false
        let bgTask = isActive
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.0fs", remaining)
        logger.info("[BKA][Lifecycle] → \(transition) | isActive=\(self.isActive) bg=\(self.appIsInBackground) sessions=\(sessions) shellRunning=\(shellRunning) bgTask=\(bgTask) bgTaskRemaining=\(remainingStr) silentAudioPlaying=\(self.silentAudioIsPlaying) suspendCount=\(self.silentAudioSuspendCount) bgSpeak=\(self.backgroundSpeakEnabled) stopDebounceTimer=\(self.debounceTimerDescription())")
    }

    /// When > 0, silent audio is suspended so media playback gets full volume.
    /// Multiple callers can nest suspend/resume via this counter. Readable
    /// from outside for diagnostic logging at suspend/resume call sites.
    private(set) var silentAudioSuspendCount = 0

    /// Temporarily suspend silent audio for media playback (full volume).
    /// Each call must be balanced by a matching `resumeSilentAudioForMedia()`.
    func suspendSilentAudioForMedia(caller: String = #function) {
        let before = silentAudioSuspendCount
        silentAudioSuspendCount += 1
        logger.info("[BackgroundKeepAlive] suspendSilentAudioForMedia: count \(before) → \(self.silentAudioSuspendCount) caller=\(caller)")
        if silentAudioSuspendCount == 1 && silentAudioActive {
            stopSilentAudio()
        }
    }

    /// Resume silent audio after media playback ends. Only restarts if all
    /// suspenders have called resume and keep-alive conditions are still met.
    func resumeSilentAudioForMedia(caller: String = #function) {
        let before = silentAudioSuspendCount
        silentAudioSuspendCount = max(0, silentAudioSuspendCount - 1)
        logger.info("[BackgroundKeepAlive] resumeSilentAudioForMedia: count \(before) → \(self.silentAudioSuspendCount) caller=\(caller)")
        if silentAudioSuspendCount == 0 {
            evaluateSilentAudio(caller: "resumeMedia")
        }
    }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationAuthStatus = locationManager.authorizationStatus
    }

    private var didSetup = false

    func setup() {
        guard !didSetup else { return }
        didSetup = true
        logger.info("[BackgroundKeepAlive] Setup: enabled=\(self.enhancedBackgroundEnabled) silentAudioAvailable=\(Self.silentAudioKeepAliveAvailable)")

        // Clear a stale Live Activity left behind by a previous process that
        // died mid-task, so a dead card doesn't linger on the Lock Screen.
        AgentLiveActivityManager.shared.cleanupStaleActivities(source: "BKA.setup")

        // Observe app lifecycle
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // [T-ios-scenephase-active-sigkill] Cancel any in-flight
                // foreground transition: a bg→fg→bg blip must not let the
                // deferred willEnterForeground handler flip appIsInBackground.
                self.pendingForegroundTransition = false
                self.appIsInBackground = true
                // OpenMinis throttles the iSH CPU to 80% duty cycle in the
                // background via `ish_set_timer_tick_hook`. That hook is a patch
                // in OpenMinis' iSH fork — it is NOT in the prebuilt `libish.a`
                // OasesChat vendors (verified with nm), so there is nothing to
                // call. Enabling it needs an iSH rebuild, not a port.
                logger.info("[BKA] background — iSH CPU throttle unavailable (hook not in vendored libish)")
                self.logLifecycleSnapshot("Background")
                self.evaluateSilentAudio(caller: "didEnterBackground")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pendingForegroundTransition = true
                // [T-ios-scenephase-active-sigkill] Defer @Published mutations
                // off the synchronous foreground-notification delivery. Flipping
                // appIsInBackground + evaluateSilentAudio triggers objectWillChange
                // on BackgroundKeepAliveManager, which invalidates any SwiftUI view
                // observing it — during the same tick as the foreground view-graph
                // transition. Yielding first avoids the overlap.
                Task { @MainActor in
                    await Task.yield()
                    // Guard against rapid bg→fg→bg cycling: if didEnterBackground
                    // fired between the notification and this yield it cleared the
                    // flag, so don't flip appIsInBackground. Uses a self-maintained
                    // flag rather than applicationState because `.inactive` is
                    // ambiguous (can mean "entering foreground" OR "entering
                    // background") and would let a backgrounding blip slip through.
                    guard self.pendingForegroundTransition else { return }
                    self.pendingForegroundTransition = false
                    self.appIsInBackground = false
                    logger.info("[BKA] foreground — iSH CPU throttle unavailable (see background branch)")
                    self.logLifecycleSnapshot("Foreground")
                    // Keep the Live Activity consistent with the live session set.
                    self.updateLiveActivityIfNeeded(source: "foregroundCleanup")
                    self.evaluateSilentAudio(caller: "willEnterForeground")
                }
            }
            .store(in: &cancellables)

        // [BKA] willResignActive / didBecomeActive don't change appIsInBackground
        // (that's driven by did-enter-background / will-enter-foreground), but
        // they bracket the transient blip that the debounce defends against, so
        // we snapshot them too for the crash-time timeline.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.logLifecycleSnapshot("Inactive") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.logLifecycleSnapshot("Active") }
            .store(in: &cancellables)

        // Re-evaluate keep-alive whenever sessions or toggle change
        Publishers.CombineLatest(
            SessionActivityTracker.shared.$activeSessions,
            $enhancedBackgroundEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sessions, enabled in
            guard let self else { return }
            self.reevaluate(sessions: sessions, enabled: enabled)
        }
        .store(in: &cancellables)

        // App-icon badge: tracks the running-task count while the app is
        // backgrounded, gated by `backgroundNotificationsEnabled` (the
        // same toggle that controls task-completion banners). Foreground
        // entry clears the badge in `Oases ChatApp.handleScenePhaseChange`.
        Publishers.CombineLatest(
            SessionActivityTracker.shared.$activeSessions,
            $backgroundNotificationsEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sessions, enabled in
            self?.refreshActiveTaskBadge(sessions: sessions, enabled: enabled)
        }
        .store(in: &cancellables)

        // Re-evaluate silent audio when background speak toggle changes
        $backgroundSpeakEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateSilentAudio(caller: "bgSpeakToggle")
            }
            .store(in: &cancellables)

        // [T-ios-live-activity-audio-toggle] Drive the Live Activity from the
        // read-aloud (TTS) engine state, NOT the chat audio-attachment player.
        // `VoiceOutputState.shared` mirrors both TTS engines: isReadingAloud ==
        // a reply is being read (starts/attaches the Live Activity, shows the
        // toggle), speechPaused flips the control icon, and reading-ends tears an
        // audio-only activity down. `removeDuplicates` avoids redundant pushes.
        // (Root-cause fix for b0f3f884: GlobalAudioPlayer.isPlaying/isLoaded
        // never change during read-aloud, so the toggle never appeared.)
        Publishers.CombineLatest(
            VoiceOutputState.shared.$isReadingAloud,
            VoiceOutputState.shared.$speechPaused
        )
        .removeDuplicates { $0 == $1 }
        .dropFirst() // skip the initial replay on subscribe
        .receive(on: DispatchQueue.main)
        .sink { [weak self] reading, paused in
            self?.audioPlaybackStateChanged(source: "voiceOut(reading=\(reading),paused=\(paused))")
        }
        .store(in: &cancellables)

        // Restart silent audio when an external app's audio interruption ends.
        // External media (Spotify, Apple Music, etc.) starting playback will
        // pause our AVAudioEngine via .interruptionTypeBegan; iOS sends
        // .ended once the foreign session relinquishes. Without re-evaluating
        // here, `silentAudioActive` stays true (engine is silently dead) and
        // the process becomes eligible for suspension/termination.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.lastAudioInterruption = "began"
                    self.lastAudioInterruptionAt = Date()
                    let wasSuspended = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                        == AVAudioSession.InterruptionReason.appWasSuspended.rawValue
                    logger.info("[BKA][Interrupt] began — appWasSuspended=\(wasSuspended) wasPlaying=\(self.silentAudioIsPlaying)")
                    self.recordBKAEvent("Interrupt began")
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                        AVAudioSession.InterruptionOptions(rawValue: $0)
                    }
                    let shouldResume = opts?.contains(.shouldResume) ?? false
                    self.lastAudioInterruption = "ended"
                    self.lastAudioInterruptionAt = Date()
                    logger.info("[BKA][Interrupt] ended — shouldResume=\(shouldResume) sessions=\(SessionActivityTracker.shared.activeSessions.count) bg=\(self.appIsInBackground)")
                    // 0.5s grace so the foreign session fully releases before we
                    // re-acquire .playback.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.handleAudioInterruptionEnded()
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        // [T-bg-keepalive-debounce] Route changes (e.g. another app's session
        // taking over, headphones unplugged) can leave our engine running into
        // a dead session, or signal the system reclaimed audio focus. When that
        // happens while a background task is active, re-acquire the session.
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleAudioSessionPossiblyReclaimed(source: "routeChange", note: note)
            }
            .store(in: &cancellables)

        // [T-bg-keepalive-debounce] The secondary-audio hint fires when the
        // system asks us to silence secondary audio (`.begin`) and again when
        // it's safe to resume (`.end`). An `.end` while we're backgrounded with
        // active sessions is another cue to make sure our keep-alive audio is
        // actually live.
        NotificationCenter.default.publisher(for: AVAudioSession.silenceSecondaryAudioHintNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleAudioSessionPossiblyReclaimed(source: "silenceSecondaryAudioHint", note: note)
            }
            .store(in: &cancellables)
    }

    /// [T-bg-keepalive-debounce] Common handler for route-change /
    /// secondary-audio-hint notifications: if we're backgrounded with active
    /// sessions and our silent audio is supposed to be playing, verify the
    /// engine is genuinely alive and re-acquire the session if not. This catches
    /// the case where iOS quietly tore down our session (so `silentAudioActive`
    /// is a lie) and the process becomes eligible for termination.
    private func handleAudioSessionPossiblyReclaimed(source: String, note: Notification) {
        // [BKA][RouteChange] log the route transition (only routeChange carries
        // route info; secondary-hint just signals begin/end).
        if source == "routeChange",
           let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: raw) {
            let outs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { $0.portType.rawValue }.joined(separator: "+")
            logger.info("[BKA][RouteChange] reason=\(reason) newRoute=\(outs.isEmpty ? "none" : outs) sessions=\(SessionActivityTracker.shared.activeSessions.count) bg=\(self.appIsInBackground)")
        }

        let sessionCount = SessionActivityTracker.shared.activeSessions.count
        let wantsKeepAlive = Self.silentAudioKeepAliveAvailable
            && isActive && backgroundSpeakEnabled
            && appIsInBackground && silentAudioSuspendCount == 0 && sessionCount > 0
        guard wantsKeepAlive else { return }

        // If we think audio is active but the engine isn't actually running, iOS
        // pulled the session out from under us — tear down and restart.
        let engineRunning = audioEngine?.isRunning ?? false
        if silentAudioActive && !engineRunning {
            logger.warning("[BKA][\(source)] silentAudioActive but engine NOT running — session reclaimed, restarting")
            recordBKAEvent("Session reclaimed (\(source))")
            silentPlayerNode?.stop()
            audioEngine?.stop()
            silentPlayerNode = nil
            audioEngine = nil
            silentAudioActive = false
            cancelPendingSilentAudioStop(reason: "\(source) reclaim")
            startSilentAudio(reason: "\(source)Reclaim")
        } else if !silentAudioActive {
            // Should be playing but isn't — re-evaluate (also covers a stale
            // pending stop from a prior foreground blip).
            logger.info("[BKA][\(source)] keep-alive wanted but not playing — re-evaluating")
            cancelPendingSilentAudioStop(reason: "\(source) not playing")
            evaluateSilentAudio(caller: source)
        }
    }

    /// Force-reset silent audio state after an AVAudioSession interruption
    /// ends. The engine may have been stopped silently by iOS while we still
    /// believe `silentAudioActive == true`, which prevents `evaluateSilentAudio`
    /// from restarting it.
    private func handleAudioInterruptionEnded() {
        let sessionCount = SessionActivityTracker.shared.activeSessions.count
        logger.info("[BackgroundKeepAlive] Audio session interruption ended — bg=\(self.appIsInBackground) sessions=\(sessionCount) playing=\(self.silentAudioActive)")
        // The engine may have been stopped silently by iOS while we still
        // believe `silentAudioActive == true`, which would block
        // `evaluateSilentAudio` from restarting it. Tear down the stale engine
        // unconditionally so evaluate can cleanly re-start.
        if silentAudioActive {
            silentPlayerNode?.stop()
            audioEngine?.stop()
            silentPlayerNode = nil
            audioEngine = nil
            silentAudioActive = false
        }
        // [T-bg-keepalive-debounce] An interruption ending mid-task (e.g. a
        // WeChat/phone call finishing while a background agent task is still
        // running) is exactly when we must re-acquire the session. If we're in
        // background with active sessions, force a fresh start with retry rather
        // than relying solely on evaluate (which is correct, but be explicit).
        if appIsInBackground && sessionCount > 0 {
            cancelPendingSilentAudioStop(reason: "interruption ended, sessions active")
        }
        evaluateSilentAudio(caller: "interruptionEnded")
    }

    // MARK: - Location Permission

    /// Deliberately a no-op. The background-location keep-alive was removed
    /// (App Review 2.5.4), so nothing here needs location access and the app
    /// no longer declares Always authorization. Features that do use location
    /// (`apple-location`, weather) request When-In-Use themselves.
    func requestLocationPermission() {
        logger.info("[BackgroundKeepAlive] requestLocationPermission ignored — location keep-alive removed")
    }

    // MARK: - Termination

    /// Tears the Live Activity down on a clean exit.
    func prepareForTermination() {
        logger.info("[BackgroundKeepAlive] prepareForTermination — ending Live Activity")
        AgentLiveActivityManager.shared.endActivity()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthStatus = status
            logger.info("[BackgroundKeepAlive] Authorization changed: \(status.rawValue)")
        }
    }

    // MARK: - Evaluate State

    private func reevaluate(sessions: Set<String>, enabled: Bool) {
        // [T-ios-scenephase-active-sigkill] If we're mid foreground transition
        // (between willEnterForeground and its deferred yield), defer this
        // reevaluation. It writes @Published isActive; doing so on the
        // transition tick overlaps the SwiftUI view-graph rebuild → potential
        // SIGKILL (same family as the 2026-06-19 mid-request crash).
        if pendingForegroundTransition {
            Task { @MainActor in
                await Task.yield()
                self.reevaluate(sessions: sessions, enabled: enabled)
            }
            return
        }

        let shouldBeActive = !sessions.isEmpty && enabled
        let sessionList = sessions.prefix(5).joined(separator: ",")
        // [T-ios-log-noise-reduction] INFO→DEBUG: reevaluate runs on every
        // session-set / toggle change and was ~482 lines/day even when nothing
        // transitioned. The actual state CHANGES (Activating / Deactivating
        // below) keep their INFO level, so production logs still show the
        // transitions without the per-call no-op chatter.
        logger.debug("[BackgroundKeepAlive] Reevaluate: sessions=\(sessions.count) enabled=\(enabled) isActive=\(self.isActive) shouldBeActive=\(shouldBeActive) ids=[\(sessionList)]")

        if shouldBeActive && !isActive {
            logger.info("[BackgroundKeepAlive] Activating keep-alive (sessions=\(sessions.count))")
            isActive = true
            AgentLiveActivityManager.shared.startActivity(sessions: buildSessionSnapshots())
            startUpdateTimer()
            evaluateSilentAudio(caller: "reevaluate-activate")
        } else if !shouldBeActive && isActive {
            logger.info("[BackgroundKeepAlive] Deactivating keep-alive")
            stopUpdateTimer()
            isActive = false
            evaluateSilentAudio(caller: "reevaluate-deactivate")
            // Soft-finish the Live Activity: flip to a completed state
            // (checkmark + last message) and leave it on screen; it's dismissed
            // when the user taps it and Oases Chat foregrounds.
            Task { await AgentLiveActivityManager.shared.finishActivity() }
        }
    }

    // MARK: - App Icon Badge

    /// Update the app-icon badge so it reflects the live count of
    /// running agent sessions while the app is in the background. When
    /// the user has turned the task-notifications toggle off, the badge
    /// is forced to 0 — Apple HIG treats badge as a notification
    /// affordance, so it inherits that gate. Foreground transitions
    /// clear the badge separately in `Oases ChatApp.handleScenePhaseChange`.
    func refreshActiveTaskBadge() {
        refreshActiveTaskBadge(
            sessions: SessionActivityTracker.shared.activeSessions,
            enabled: backgroundNotificationsEnabled
        )
    }

    /// Notification permission is asked for on demand — the first time the
    /// user starts a task that can end in a completion notification — rather
    /// than with a cold prompt at launch.
    private var didAskNotificationPermission = false

    private func refreshActiveTaskBadge(sessions: Set<String>, enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        if enabled, !sessions.isEmpty, !didAskNotificationPermission,
           UIApplication.shared.applicationState == .active {
            didAskNotificationPermission = true
            OasesAppDelegate.requestNotificationAuthorizationAndRegister()
        }
        guard enabled else {
            center.setBadgeCount(0) { _ in }
            return
        }
        center.setBadgeCount(sessions.count) { err in
            if let err {
                logger.error("[Badge] setBadgeCount failed: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Background Task Notifications

    /// Notification category for background task completion.
    private static let bgTaskCategoryId = "BACKGROUND_TASK"

    /// Post a local notification when a background task completes.
    /// - Parameters:
    ///   - sessionTitle: Session/conversation title (shown as notification title)
    ///   - responseSummary: Truncated assistant response text (shown as notification body)
    ///   - sessionId: The session ID for tap-to-open navigation
    ///   - isError: Whether the task ended with an error
    /// [T-ios-live-activity-privacy-mode] Content-free notification body:
    /// "1 task completed · 2m 15s". The duration is appended only when a start
    /// time is available (a Live Activity run was in flight); otherwise the body
    /// degrades to just the count, per spec — no extra time tracking is added.
    private static func privacyNotificationBody(isError: Bool, startedAt: Date?) -> String {
        let base = isError
            ? String(localized: "1 task failed")
            : String(localized: "1 task completed")
        guard let startedAt else { return base }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        guard elapsed > 0 else { return base }
        let formatted: String
        if elapsed >= 3600 {
            formatted = String(format: "%dh %dm", elapsed / 3600, (elapsed % 3600) / 60)
        } else if elapsed >= 60 {
            formatted = String(format: "%dm %ds", elapsed / 60, elapsed % 60)
        } else {
            formatted = String(format: "%ds", elapsed)
        }
        return "\(base) · \(formatted)"
    }

    func postBackgroundTaskNotification(sessionTitle: String, responseSummary: String, sessionId: String, isError: Bool = false, wasBackground: Bool? = nil) {
        guard backgroundNotificationsEnabled else { return }
        // Use the caller-captured snapshot when available (the async Task in
        // endBackgroundProcessing may not run until the app is already active).
        // Fall back to the live check for other call sites.
        let isBackground = wasBackground ?? (UIApplication.shared.applicationState != .active)
        guard isBackground else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let category = UNNotificationCategory(
            identifier: Self.bgTaskCategoryId,
            actions: [],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        let content = UNMutableNotificationContent()
        if liveActivityPrivacyMode {
            // [T-ios-live-activity-privacy-mode] Neutral report only: no session
            // title, no reply summary. sessionId stays in userInfo below so the
            // tap-to-open jump keeps working, and the badge logic is untouched.
            content.title = isError
                ? String(localized: "❌ Task failed")
                : String(localized: "✅ Task completed")
            content.body = Self.privacyNotificationBody(
                isError: isError,
                startedAt: AgentLiveActivityManager.shared.taskStartTime
            )
        } else {
            content.title = "\(isError ? "❌" : "✅") \(sessionTitle)"
            content.body = responseSummary
        }
        content.sound = .default
        content.categoryIdentifier = Self.bgTaskCategoryId
        content.userInfo = ["sessionId": sessionId]
        logger.info("[BackgroundNotification] posting notification title=\(content.title.debugDescription) bodyLength=\(content.body.count) sessionId=\(sessionId)")

        // Increment app badge count
        let current = UIApplication.shared.applicationIconBadgeNumber
        content.badge = NSNumber(value: current + 1)
        UIApplication.shared.applicationIconBadgeNumber = current + 1

        let request = UNNotificationRequest(
            identifier: "bg-task-\(sessionId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request) { error in
            if let error {
                logger.error("[BackgroundNotification] Failed to post: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Silent Audio Keep-Alive

    private func evaluateSilentAudio(caller: String = #function) {
        // Self-heal a leaked suspendCount. suspend/resume should pair, but
        // task cancellation, network timeouts mid-playback, etc. occasionally
        // skip the resume call. If keepalive should be active and silent
        // audio is NOT running yet the count is stuck > 2, treat it as leaked
        // and reset so we can re-engage keepalive.
        if isActive && appIsInBackground && backgroundSpeakEnabled
            && !silentAudioActive && silentAudioSuspendCount > 2 {
            logger.warning("[BackgroundKeepAlive] silentAudioSuspendCount=\(self.silentAudioSuspendCount) looks leaked — resetting to 0")
            silentAudioSuspendCount = 0
        }

        let shouldPlay = Self.silentAudioKeepAliveAvailable
            && isActive && backgroundSpeakEnabled && appIsInBackground && silentAudioSuspendCount == 0
        let sessions = SessionActivityTracker.shared.activeSessions.count
        let reason: String = {
            if !Self.silentAudioKeepAliveAvailable { return "releaseBuild" }
            if !isActive { return "isActive=false" }
            if !backgroundSpeakEnabled { return "bgSpeak=false" }
            if !appIsInBackground { return "bg=false" }
            if silentAudioSuspendCount > 0 { return "suspended=\(silentAudioSuspendCount)" }
            return "ok"
        }()
        // [BKA][Evaluate] decision chain — caller, all inputs, and the resolved
        // PLAY / STOP / NOOP decision so the crash-time timeline shows exactly
        // who triggered each evaluation and why it stopped or started audio.
        let decision: String = {
            if shouldPlay { return silentAudioActive ? "NOOP(already playing)" : "PLAY" }
            return silentAudioActive ? "STOP" : "NOOP(already stopped)"
        }()
        logger.info("[BKA][Evaluate] caller=\(caller) isActive=\(self.isActive) bgSpeak=\(self.backgroundSpeakEnabled) bg=\(self.appIsInBackground) sessions=\(sessions) suspended=\(self.silentAudioSuspendCount) playing=\(self.silentAudioActive) stopDebounce=\(self.stopDebouncePending ? "pending" : "nil") → decision=\(decision) reason=\(reason)")

        if shouldPlay && !silentAudioActive {
            // A fresh background signal (or any condition that re-enables play)
            // cancels any debounced stop in flight — the transient foreground
            // blip is over and we want to keep the audio running.
            cancelPendingSilentAudioStop(reason: "shouldPlay=true")
            startSilentAudio()
        } else if shouldPlay && silentAudioActive {
            // Already playing AND should keep playing — a transient foreground
            // blip that flipped back before its debounce fired. Make sure no
            // stale stop is still queued.
            cancelPendingSilentAudioStop(reason: "still shouldPlay")
        } else if !shouldPlay && silentAudioActive {
            requestStopSilentAudio(transientForeground: !appIsInBackground)
        }
    }

    /// [T-bg-keepalive-debounce] Decide whether to stop silent audio now or
    /// after a debounce window. A stop caused purely by a `foreground` signal
    /// (`transientForeground == true`) while sessions are still active is the
    /// dangerous case: it may be the brief blip of an app switch (call ending,
    /// app-switcher peek, Dynamic Island tap, Siri/Control Center) that is about
    /// to background again. We delay it so a `background` signal arriving within
    /// the window can cancel it. Every other reason (no active sessions, media
    /// suspend, Background Speak turned off) is a genuine intent to stop, so we
    /// stop immediately.
    private func requestStopSilentAudio(transientForeground: Bool) {
        let sessionCount = SessionActivityTracker.shared.activeSessions.count
        let shouldDebounce = transientForeground && sessionCount > 0
        guard shouldDebounce else {
            cancelPendingSilentAudioStop(reason: "immediate stop")
            recordBKAEvent("Stop(reason=\(transientForeground ? "foreground,sessions=0" : "non-foreground"))")
            stopSilentAudio(reason: transientForeground ? "foreground_sessions0" : "evaluate")
            return
        }
        // Already have a pending stop — let it ride (don't reset the timer, so a
        // burst of foreground passes can't indefinitely postpone the real stop).
        if pendingSilentAudioStop != nil {
            logger.info("[BKA][Debounce] already scheduled — keeping existing timer (sessions=\(sessionCount))")
            return
        }
        logger.info("[BKA][Debounce] scheduled stop in \(Self.silentAudioStopDebounce)s — sessions=\(sessionCount) caller=foregroundSignal")
        recordBKAEvent("Stop(reason=foreground,debounce=pending)")
        let scheduledAt = Date()
        pendingStopScheduledAt = scheduledAt
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSilentAudioStop = nil
            self.pendingStopScheduledAt = nil
            let nowSessions = SessionActivityTracker.shared.activeSessions.count
            // Re-check the world at fire time: if we went back to background (or
            // any other reason now keeps it playing), do NOT stop.
            let stillForeground = !self.appIsInBackground
            let stillActive = self.isActive && self.backgroundSpeakEnabled
                && self.silentAudioSuspendCount == 0
            if stillForeground || !stillActive {
                logger.info("[BKA][Debounce] fired — proceeding to stop (sessions=\(nowSessions), foreground=\(stillForeground))")
                self.stopSilentAudio(reason: "debounce_expired(\(Self.silentAudioStopDebounce)s)")
            } else {
                logger.info("[BKA][Debounce] fired — skipping stop, app re-backgrounded (sessions=\(nowSessions)) — KEEPING silent audio")
                self.recordBKAEvent("Stop skipped (re-backgrounded)")
            }
        }
        pendingSilentAudioStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silentAudioStopDebounce, execute: work)
    }

    /// Cancel any in-flight debounced stop of silent audio.
    private func cancelPendingSilentAudioStop(reason: String) {
        guard let pending = pendingSilentAudioStop else { return }
        pending.cancel()
        pendingSilentAudioStop = nil
        let elapsed = pendingStopScheduledAt.map { Date().timeIntervalSince($0) }
        pendingStopScheduledAt = nil
        let elapsedStr = elapsed.map { String(format: "elapsed=%.1fs", $0) } ?? ""
        logger.info("[BKA][Debounce] cancelled — \(reason) \(elapsedStr)")
        recordBKAEvent("Debounce cancelled (\(reason))")
    }

    private func startSilentAudio(reason: String = "evaluate") {
        #if DEBUG
        guard !silentAudioActive else { return }
        // Starting up means we definitely don't want any queued stop to fire.
        cancelPendingSilentAudioStop(reason: "startSilentAudio")
        let attempt = silentAudioActivationRetries + 1
        let sessions = SessionActivityTracker.shared.activeSessions.count
        logger.info("[BKA][Start] reason=\(reason) sessions=\(sessions) attempt=\(attempt)/\(Self.maxActivationRetries)")
        recordBKAEvent("Start(reason=\(reason),attempt=\(attempt))")

        // [T-bg-keepalive-debounce] Activate the session, retrying on failure.
        // After a stopSilentAudio() the session was deactivated with
        // notifyOthersOnDeactivation; the system may briefly reject a
        // re-activation while another app is still re-acquiring focus, or while
        // a call/media session is releasing. A single sync attempt here closes
        // the common case; on failure we schedule an async retry (0.5s apart,
        // up to 3 total attempts) by re-invoking startSilentAudio, so we never
        // block the main thread yet still recover from the transient rejection.
        // The session category/active is owned by AudioSessionCoordinator. Declare
        // the keep-alive intent (lowest priority) — the coordinator applies the
        // .mixWithOthers profile ONLY when nothing higher (reply TTS / media /
        // capture) is active, so the silent track no longer clobbers TTS's profile.
        // The silent AVAudioEngine below plays regardless to keep the process alive.
        MainActor.assumeIsolated {
            AudioSessionCoordinator.shared.begin(.backgroundKeepAlive)
        }
        logger.info("[BKA][Start] begin(.backgroundKeepAlive) — acquiring engine")
        silentAudioActivationRetries = 0

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Create a silent audio buffer (1 second of silence, looping)
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate) // 1 second
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.error("[BackgroundKeepAlive] Failed to create silent audio buffer")
            return
        }
        buffer.frameLength = frameCount
        // Buffer is already zero-filled (silent)

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.001

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioEngine = engine
            silentPlayerNode = player
            silentAudioActive = true
            startAudioUpdateTimer()
            logger.info("[BKA][Start] engine running — silent audio keep-alive ACTIVE")
        } catch {
            logger.error("[BKA][Start] engine.start() FAILED: \(error.localizedDescription)")
        }
        #else
        // App Review 2.5.4: Release never plays a silent track to stay alive.
        logger.info("[BKA][Start] skipped (reason=\(reason)) — silent-audio keep-alive is DEBUG-only")
        #endif
    }

    /// [T-bg-keepalive-debounce] Schedule a delayed re-attempt of
    /// `startSilentAudio` after a `setActive(true)` rejection, up to
    /// `maxActivationRetries` total attempts. At fire time we re-check that
    /// keep-alive is still wanted (background + active + not suspended) so we
    /// don't fight a state that has since changed.
    private func scheduleSilentAudioActivationRetry() {
        silentAudioActivationRetries += 1
        guard silentAudioActivationRetries < Self.maxActivationRetries else {
            logger.error("[BKA][Start] exhausted \(Self.maxActivationRetries) activation attempts — giving up")
            recordBKAEvent("Start FAILED (exhausted retries)")
            silentAudioActivationRetries = 0
            return
        }
        let attempt = silentAudioActivationRetries
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationRetryDelay) { [weak self] in
            guard let self else { return }
            let stillWanted = self.isActive && self.backgroundSpeakEnabled
                && self.appIsInBackground && self.silentAudioSuspendCount == 0
                && !self.silentAudioActive
            guard stillWanted else {
                logger.info("[BKA][Start] activation retry #\(attempt) skipped — keep-alive no longer wanted")
                self.silentAudioActivationRetries = 0
                return
            }
            logger.info("[BKA][Start] activation retry #\(attempt) — re-attempting")
            self.startSilentAudio(reason: "activationRetry#\(attempt)")
        }
    }

    /// Called by SpeechFinishedDelegate when TTS completes, to restart silent audio if needed.
    func evaluateSilentAudioFromDelegate() {
        evaluateSilentAudio(caller: "ttsFinished")
    }

    /// [T-shortcuts-eager-keepalive] Eager keep-alive hook for AppIntent entry
    /// points (Shortcuts automations). Call this synchronously at the top of an
    /// Intent's `perform()` BEFORE any `await` that would let iOS suspend the
    /// AppIntent-woken process. It:
    ///   1) records the (already-known) session id in the tracker so the
    ///      Combine publisher fires and `reevaluate` flips `isActive` to true,
    ///   2) immediately re-evaluates silent audio so the AVAudioEngine
    ///      spins up while the process still has wall-clock time.
    ///
    /// STRICTLY gated on `enhancedBackgroundEffective` (the user's
    /// enhancedBackgroundEnabled AND backgroundSpeakEnabled toggles both being
    /// on). If the user hasn't opted into background keep-alive, this is a
    /// no-op — we do NOT silently start background audio playback behind their
    /// back. Returns `(armed, skipReason)` — a non-nil `skipReason` accompanies
    /// `armed=false` so callers can log/persist WHY we skipped without having
    /// to reconstruct the gating logic.
    @MainActor
    @discardableResult
    func armEagerlyForShortcut(sessionId: String, caller: String) -> (armed: Bool, skipReason: String?) {
        guard Self.silentAudioKeepAliveAvailable else {
            logger.info("[ShortcutDiag] eagerKeepAlive caller=\(caller) decision=SKIPPED reason=silentAudioKeepAliveUnavailable")
            return (false, "silentAudioKeepAliveUnavailable")
        }
        let enhancedOn = enhancedBackgroundEnabled
        let bgSpeakOn = backgroundSpeakEnabled
        if !enhancedOn || !bgSpeakOn {
            let reason: String
            if !enhancedOn && !bgSpeakOn {
                reason = "enhancedBackgroundEnabled=false;backgroundSpeakEnabled=false"
            } else if !enhancedOn {
                reason = "enhancedBackgroundEnabled=false"
            } else {
                reason = "backgroundSpeakEnabled=false"
            }
            logger.info("[ShortcutDiag] eagerKeepAlive caller=\(caller) decision=SKIPPED reason=\(reason)")
            return (false, reason)
        }
        logger.info("[ShortcutDiag] eagerKeepAlive caller=\(caller) decision=STARTED session=\(sessionId.prefix(8))")
        SessionActivityTracker.shared.setActive(sessionId, source: "\(caller).eager")
        evaluateSilentAudio(caller: "\(caller).eager")
        return (true, nil)
    }

    func stopSilentAudio(reason: String = "direct") {
        // A direct stop supersedes any debounced one and aborts pending retries.
        cancelPendingSilentAudioStop(reason: "stopSilentAudio called")
        silentAudioActivationRetries = 0
        guard silentAudioActive else { return }
        let sessions = SessionActivityTracker.shared.activeSessions.count
        logger.info("[BKA][Stop] reason=\(reason) sessions=\(sessions)")
        recordBKAEvent("Stop(reason=\(reason))")
        stopAudioUpdateTimer()
        silentPlayerNode?.stop()
        audioEngine?.stop()
        silentPlayerNode = nil
        audioEngine = nil
        silentAudioActive = false
        // End the keep-alive intent — the coordinator re-applies the next-highest
        // intent's profile (reply TTS / capture) or deactivates the session,
        // letting other apps resume. (No direct setActive here anymore.)
        MainActor.assumeIsolated {
            AudioSessionCoordinator.shared.end(.backgroundKeepAlive)
        }
        logger.info("[BKA][Stop] engine.stop() + end(.backgroundKeepAlive)")
    }

    // MARK: - Live Activity Updates

    /// Shared method to push a Live Activity update. Called from:
    /// - updateTimer (foreground, every 2-10s)
    /// - audioUpdateTimer (background with the DEBUG-only silent audio)
    /// [T-ios-live-activity-audio-toggle] Entry point for audio-driven Live
    /// Activity changes. Unlike `updateLiveActivityIfNeeded` (gated on `isActive`,
    /// which is only true while an Agent task runs), this always forwards to the
    /// manager so a pure-audio playback — with zero Agent sessions — can start,
    /// refresh, or end its own Live Activity. When an Agent task is also running,
    /// the manager updates that single existing activity in place (never a 2nd one).
    func audioPlaybackStateChanged(source: String) {
        let v = VoiceOutputState.shared
        logger.info("[LiveActivity][audio] BKA forward src=\(source) reading=\(v.isReadingAloud) paused=\(v.speechPaused) isActive=\(self.isActive)")
        AgentLiveActivityManager.shared.audioStateChanged(source: source)
    }

    func updateLiveActivityIfNeeded(source: String = "?") {
        guard isActive else {
            let cnt = SessionActivityTracker.shared.activeSessions.count
            if cnt > 0 {
                logger.info("[LiveActivity][update] SKIP src=\(source) isActive=false tracker=\(cnt) session(s)")
            }
            return
        }
        let sessions = SessionActivityTracker.shared.activeSessions
        let count = sessions.count
        let idList = sessions.map { $0.prefix(8) }.joined(separator: ",")
        let appState: String = {
            switch UIApplication.shared.applicationState {
            case .active: return "fg"
            case .inactive: return "inactive"
            case .background: return "bg"
            @unknown default: return "?"
            }
        }()
        let silentAudio = silentAudioIsPlaying
        let bgRemaining = UIApplication.shared.backgroundTimeRemaining
        let remainStr = bgRemaining > 99999 ? "unlimited" : String(format: "%.0fs", bgRemaining)
        logger.info("[LiveActivity][update] src=\(source) sessions=\(count) ids=[\(idList)] appState=\(appState) silentAudio=\(silentAudio) bgRemaining=\(remainStr)")
        AgentLiveActivityManager.shared.updateActivity(sessions: buildSessionSnapshots())
    }

    /// [T-ios-live-activity-audio-toggle] Public accessor so the Live Activity
    /// manager's audio-only start/update path can rebuild the current session
    /// snapshots (empty when only audio is active).
    func buildLiveSessionSnapshots() -> [LiveSessionSnapshot] {
        buildSessionSnapshots()
    }

    private func buildSessionSnapshots() -> [LiveSessionSnapshot] {
        guard #available(iOS 16.2, *) else { return [] }
        let tracker = SessionActivityTracker.shared
        return tracker.activeSessions.sorted().map { sid in
            let info = tracker.sessionToolInfo[sid]
            let title = info?.title ?? ""
            let toolName = info?.toolName ?? ""
            let toolStatus = info?.toolStatus ?? ""
            let icon = AgentLiveActivityManager.sfSymbol(forTool: toolName)
            let displayName = AgentLiveActivityManager.displayName(forTool: toolName)
            let statusText: String
            if toolName.isEmpty {
                statusText = String(localized: "Working...")
            } else if toolStatus.isEmpty {
                statusText = displayName
            } else {
                statusText = "\(displayName) · \(toolStatus)"
            }
            logger.info("[LiveActivity][snapshot] sid=\(sid.prefix(8)) toolName=\(toolName) icon=\(icon) status=\(statusText) title=\(title.prefix(20))")
            return LiveSessionSnapshot(
                sessionId: sid,
                title: title.isEmpty ? String(localized: "Agent Task") : title,
                toolIcon: icon,
                toolStatus: statusText,
                loopIteration: info?.loopIteration ?? 0
            )
        }
    }

    private var updateInterval: TimeInterval {
        return 10.0
    }

    /// Foreground RunLoop timer — works while app is active.
    private func startUpdateTimer() {
        stopUpdateTimer()
        let interval = updateInterval
        logger.info("[BackgroundKeepAlive] Starting update timer (interval=\(interval)s)")
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLiveActivityIfNeeded(source: "fgTimer")
            }
        }
        RunLoop.current.add(updateTimer!, forMode: .common)
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Background Audio Update Timer

    /// A GCD timer that fires even when the main RunLoop is suspended,
    /// as long as the process stays alive (DEBUG silent-audio keep-alive).
    private var audioUpdateTimer: DispatchSourceTimer?

    private func startAudioUpdateTimer() {
        stopAudioUpdateTimer()
        stopUpdateTimer()
        let interval = updateInterval
        logger.info("[BackgroundKeepAlive] Starting audio update timer (interval=\(interval)s) — fgTimer suspended")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateLiveActivityIfNeeded(source: "bgAudioTimer")
            }
        }
        timer.resume()
        audioUpdateTimer = timer
    }

    private func stopAudioUpdateTimer() {
        guard audioUpdateTimer != nil else { return }
        audioUpdateTimer?.cancel()
        audioUpdateTimer = nil
        if isActive {
            startUpdateTimer()
            logger.info("[BackgroundKeepAlive] audioUpdateTimer stopped — fgTimer resumed")
        }
    }
}

// MARK: - Background Interruption Tracker

@MainActor
final class BackgroundInterruptionTracker: ObservableObject {
    static let shared = BackgroundInterruptionTracker()

    @Published var showBanner = false

    /// How many interruptions must accumulate before the banner is shown again.
    /// Starts at 1 (remind on every interruption). Each "Remind me later" tap
    /// doubles it, clamped to [minInterval, maxInterval] — true exponential
    /// back-off: 1 → 2 → 4 → 8 → 10 (capped).
    private static let minInterval = 1
    private static let maxInterval = 10
    private static let intervalKey = "enhancedBackgroundRemindInterval"
    private static let countKey = "enhancedBackgroundInterruptionCount"

    /// Current reminder frequency (show the banner once every `remindInterval`
    /// interruptions). Defaults to 1 when unset.
    var remindInterval: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
            return stored <= 0 ? 1 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.intervalKey) }
    }

    /// Accumulated interruptions since the last time the banner was shown or
    /// the user tapped "Remind me later".
    private var interruptionCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.countKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.countKey) }
    }

    private var wasInterrupted = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Auto-dismiss the banner once enhanced background is turned on, so
        // the user isn't left wondering what else they need to enable after
        // tapping "Enable" and flipping the switch.
        BackgroundKeepAliveManager.shared.$enhancedBackgroundEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, enabled, self.showBanner else { return }
                self.showBanner = false
            }
            .store(in: &cancellables)
    }

    func recordInterruption() {
        wasInterrupted = true
    }

    /// Called when app returns to foreground. Counts the interruption and only
    /// surfaces the banner once the running count reaches `remindInterval`.
    func checkOnForeground() {
        guard wasInterrupted,
              !BackgroundKeepAliveManager.shared.enhancedBackgroundEffective else {
            wasInterrupted = false
            return
        }
        wasInterrupted = false

        interruptionCount += 1
        guard interruptionCount >= remindInterval else { return }
        // Threshold reached — reset the counter and show the banner.
        interruptionCount = 0
        showBanner = true
    }

    func dismiss() {
        showBanner = false
    }

    /// "Remind me later" — back off the reminder frequency (double it, clamped
    /// to [minInterval, maxInterval]), clear the accumulated count, and dismiss.
    func remindLaterAndDismiss() {
        let doubled = remindInterval * 2
        remindInterval = min(max(doubled, Self.minInterval), Self.maxInterval)
        interruptionCount = 0
        showBanner = false
    }
}

// OpenMinis ends this file with `BackgroundInterruptionBanner`, a SwiftUI
// banner that opens `EnhancedBackgroundSettingsView` and routes through
// `DeepLinkCoordinator`. Neither is ported, and the banner is presentation —
// the manager and `BackgroundInterruptionTracker` above carry all the
// behaviour the headless-send intents need. Omitted.
