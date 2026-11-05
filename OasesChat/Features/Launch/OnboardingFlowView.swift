import SwiftUI

/// First-run onboarding, shown until the user answers the current one-page
/// consent (`AIDataSharingConsent.hasDecision`).
///
///     launch splash ─(droplets settle)→ ① Welcome ─继续→ ② 开始使用前
///                                                        ├ 同意并继续 → app
///                                                        └ 不同意     → app, limited mode
///
/// Finishing is a one-way door: the decision is stored and the app root
/// swaps to `RootView`, so nothing can navigate back here. Declining is a
/// valid answer — the app opens without AI until the user agrees.
///
/// Motion: on first launch the splash mark moves and shrinks into the
/// welcome hero (Reduce Motion: cross-fade). Steps push horizontally with a
/// strong ease-out under 300 ms, driven by one continuous `progress` value so
/// the interactive edge-swipe back and the button-driven transition can't
/// disagree. Reduce Motion turns the push into a cross-fade.
struct OnboardingFlowView: View {
    private enum Stage {
        case splash, welcome, privacy
    }

    /// Settings › About › Replay the welcome page: the splash and the welcome page play again,
    /// the button says Done and `onReplayDone` closes it. The consent page is not part of it
    /// and the stored decision is untouched.
    var replay = false
    var onReplayDone: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: Stage
    /// Pager position: 0 = ①, 1 = ②.
    @State private var progress: CGFloat = 0
    @State private var splashAppeared = false
    /// The splash mark is flying from the centre to the welcome hero.
    @State private var markInFlight = false
    /// The mark has arrived and now lives in the hero slot.
    @State private var markLanded: Bool
    /// Welcome copy and actions; hidden while the splash plays.
    @State private var welcomeRevealed: Bool
    /// The hero droplets finish their current cycle and come to rest.
    @State private var markSettled: Bool
    @State private var isFinishing = false

    private static let heroMarkSize: CGFloat = 132

    init(replay: Bool = false, onReplayDone: @escaping () -> Void = {}) {
        self.replay = replay
        self.onReplayDone = onReplayDone
        let playsSplash = replay || !LaunchSplashPlayback.hasPlayed
        _stage = State(initialValue: playsSplash ? .splash : .welcome)
        _markLanded = State(initialValue: !playsSplash)
        _welcomeRevealed = State(initialValue: !playsSplash)
        _markSettled = State(initialValue: !playsSplash)
    }

    var body: some View {
        ZStack {
            // Stays put while the pages fade out on completion, so the
            // swap to the app goes through the page colour, not black.
            OasesColor.background
                .ignoresSafeArea()

            NavigationStack {
                pager
                    // The welcome page's atmosphere: a quiet field of rising specks and the
                    // accent glow under the mark. Lives behind the pager so page ② (opaque)
                    // covers it, and fades on the way there.
                    .backgroundPreferenceValue(HeroMarkAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            WelcomeAtmosphere(
                                glowCenter: anchor.map { proxy[$0] }.map { CGPoint(x: $0.midX, y: $0.midY) },
                                glowVisible: markLanded
                            )
                            .opacity(stage == .splash ? 0 : 1 - progress)
                            .animation(.easeOut(duration: 0.6), value: stage == .splash)
                        }
                    }
                    // The splash mark flies to wherever the hero slot was
                    // laid out, then hands over to the slot (`markLanded`).
                    .overlayPreferenceValue(HeroMarkAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            if !markLanded {
                                flyingMark(in: proxy, hero: anchor.map { proxy[$0] })
                            }
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .opacity(isFinishing ? 0 : 1)
            .allowsHitTesting(!isFinishing)

            if isFinishing {
                LaunchHandoffCover()
                    .transition(.opacity)
            }
        }
        .onAppear(perform: playSplashIfNeeded)
        .accessibilityIdentifier("oases.onboarding")
    }

    // MARK: Pager

    private var pager: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                welcomePage
                    .offset(x: reduceMotion ? 0 : -progress * width * 0.3)
                    // Fully covered at progress 1: hide it, so it can't show
                    // through ② while the pages fade out on completion.
                    .opacity(reduceMotion ? 1 - progress : (progress >= 1 ? 0 : 1))
                    .allowsHitTesting(stage == .welcome)
                    .accessibilityHidden(stage != .welcome)

                privacyPage
                    .offset(x: reduceMotion ? 0 : (1 - progress) * width)
                    .opacity(reduceMotion ? progress : 1)
                    .allowsHitTesting(stage == .privacy)
                    .accessibilityHidden(stage != .privacy)

                if stage == .privacy {
                    edgeSwipeArea(width: width)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    /// Leading-edge pan that walks back from ② to ①, following the finger.
    private func edgeSwipeArea(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        let travelled = min(max(value.translation.width, 0), width)
                        progress = 1 - travelled / width
                    }
                    .onEnded { value in
                        let travelled = value.translation.width
                        let projected = value.predictedEndTranslation.width
                        if travelled > width * 0.4 || projected > width * 0.5 {
                            goBack(springing: true)
                        } else {
                            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                                progress = 1
                            }
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: ① Welcome

    private var welcomePage: some View {
        OnboardingPageLayout(reservesTopBar: false, pageColor: .clear) {
            VStack(spacing: OasesSpacing.xxl) {
                VStack(spacing: OasesSpacing.lg) {
                    heroMarkSlot

                    VStack(spacing: OasesSpacing.sm) {
                        Text(SettingsCopy.t("欢迎使用 Oases", "Welcome to Oases"))
                            .font(.oasesDisplay())
                            .foregroundStyle(OasesColor.foreground)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .modifier(reveal(order: 0))

                        Text(SettingsCopy.t(
                            "会聊、会说、会画，还能替你把事做完。",
                            "It chats, speaks and draws — and gets things done for you."
                        ))
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, OasesSpacing.md)
                        .modifier(reveal(order: 1))
                    }
                }
                .frame(maxWidth: .infinity)

                WelcomeCapabilityStrip()
                    .modifier(reveal(order: 2))
                    .accessibilityIdentifier("oases.onboarding.features")
            }
        } actions: {
            VStack(spacing: OasesSpacing.sm) {
                if replay {
                    Button(String(localized: "完成", comment: "Profile editor: save changes"), action: onReplayDone)
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .accessibilityIdentifier("oases.onboarding.replay-done")
                } else {
                    Button(SettingsCopy.t("继续", "Continue"), action: goToPrivacy)
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .accessibilityIdentifier("oases.onboarding.continue")
                    Text(String(localized: "下一步会说明 AI 功能如何使用你的数据。", comment: "Welcome page: what the next onboarding step is"))
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .modifier(reveal(order: 3))
        }
        .accessibilityIdentifier("oases.onboarding.welcome")
    }

    /// Reserves the hero's space from the first frame so the layout never
    /// moves, and reports where it is so the splash mark can land on it.
    private var heroMarkSlot: some View {
        ZStack {
            if markLanded {
                OasesDropletsMark(isAnimating: !markSettled)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.heroMarkSize, height: Self.heroMarkSize)
        .anchorPreference(key: HeroMarkAnchorKey.self, value: .bounds) { $0 }
        .accessibilityHidden(true)
    }

    /// The splash mark: centred at splash size, then (with motion allowed)
    /// moving and shrinking onto the hero slot. Under Reduce Motion it stays
    /// put and cross-fades with the hero instead.
    @ViewBuilder
    private func flyingMark(in proxy: GeometryProxy, hero: CGRect?) -> some View {
        let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        let flies = markInFlight && hero != nil && !reduceMotion
        let size = flies ? Self.heroMarkSize : LaunchSplashView.markSize
        OasesDropletsMark()
            .frame(width: size, height: size)
            .scaleEffect(splashAppeared ? 1 : 0.86)
            .opacity(splashAppeared ? 1 : 0)
            .position(flies ? CGPoint(x: hero!.midX, y: hero!.midY) : center)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The copy starts once the flying mark has cleared the title, then
    /// cascades down the page.
    private func reveal(order: Int) -> OnboardingReveal {
        OnboardingReveal(
            isRevealed: welcomeRevealed,
            delay: (reduceMotion ? 0.1 : 0.4) + Double(order) * 0.05,
            travels: !reduceMotion
        )
    }

    // MARK: ② 开始使用前 (the one-page consent)

    private var privacyPage: some View {
        OnePageConsentView(
            showsBackButton: true,
            onBack: { goBack(springing: false) },
            onAgree: { finish(accepted: true) },
            onDecline: { finish(accepted: false) }
        )
    }

    // MARK: Actions

    private func playSplashIfNeeded() {
        guard stage == .splash else { return }
        if !replay { LaunchSplashPlayback.hasPlayed = true }
        // Timed from the appear animation, not from `onAppear`: on a cold
        // launch the first frames can lag, and the mark should still be
        // seen whole for the same beat as the in-app splash before it moves.
        withAnimation(.spring(duration: 0.55, bounce: 0.25)) {
            splashAppeared = true
        } completion: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { handOffToWelcome() }
        }
    }

    private func handOffToWelcome() {
        guard stage == .splash else { return }
        stage = .welcome
        // Copy and actions follow the mark in (staggered in `reveal`).
        welcomeRevealed = true
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) {
                markLanded = true
            }
            settleMarkSoon()
            return
        }
        withAnimation(.spring(duration: 0.7, bounce: 0)) {
            markInFlight = true
        } completion: {
            // Same frame, same time-based drawing: the swap is invisible.
            var swap = Transaction()
            swap.disablesAnimations = true
            withTransaction(swap) {
                markLanded = true
            }
            settleMarkSoon()
        }
    }

    /// Let the hero mark appear still flowing, then finish its cycle at rest.
    private func settleMarkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            markSettled = true
        }
    }

    private func goToPrivacy() {
        guard stage == .welcome, !replay else { return }
        stage = .privacy
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : OnboardingLayout.pushIn) {
            progress = 1
        }
    }

    private func goBack(springing: Bool) {
        guard stage == .privacy else { return }
        stage = .welcome
        let animation: Animation
        if reduceMotion {
            animation = .easeInOut(duration: 0.2)
        } else if springing {
            animation = .spring(duration: 0.3, bounce: 0)
        } else {
            animation = OnboardingLayout.pushOut
        }
        withAnimation(animation) {
            progress = 0
        }
    }

    /// One-way door. The pages fade into the centred mark; storing the
    /// decision then swaps the app root to `RootView`, which starts under
    /// the same cover and fades it away.
    private func finish(accepted: Bool) {
        guard !isFinishing else { return }
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.2)) {
            isFinishing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if accepted {
                AIDataSharingConsent.accept()
            } else {
                AIDataSharingConsent.decline()
            }
        }
    }
}

/// The four things Oases does, as a row of quiet tiles: the welcome page names them without
/// turning into a feature list. Neutral on purpose: the accent is spent on the button.
private struct WelcomeCapabilityStrip: View {
    @ScaledMetric(relativeTo: .title3) private var tile: CGFloat = 52

    private var items: [(symbol: String, label: String)] {
        [
            ("bubble.left.and.bubble.right.fill", SettingsCopy.t("对话", "Conversations")),
            ("waveform", SettingsCopy.t("语音", "Voice")),
            ("photo.fill", SettingsCopy.t("图像", "Image")),
            ("terminal.fill", "Ogent"),
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: OasesSpacing.sm) {
            ForEach(items, id: \.symbol) { item in
                VStack(spacing: OasesSpacing.xs) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(OasesColor.foreground)
                        .frame(width: tile, height: tile)
                        .background(OasesColor.card, in: RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                                .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
                        )
                    Text(item.label)
                        .font(.oasesCaptionBold())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 360)
    }
}

/// Behind the welcome page: specks drifting up like bubbles in still water, and one soft glow
/// of the accent under the mark. Drawn in one Canvas at 24 fps; still under Reduce Motion.
private struct WelcomeAtmosphere: View {
    var glowCenter: CGPoint?
    var glowVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private struct Speck {
        let x: CGFloat
        let phase: CGFloat
        let speed: CGFloat
        let size: CGFloat
        let alpha: CGFloat
    }

    private static let specks: [Speck] = {
        var seed: UInt64 = 0x5EED_0A5E5
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }
        return (0..<70).map { _ in
            Speck(x: next(), phase: next(), speed: 0.35 + next() * 0.65, size: 1 + next() * 1.4, alpha: 0.35 + next() * 0.65)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { context, size in
                if let glowCenter, glowVisible {
                    let radius = min(size.width, size.height) * 0.42
                    let glow = Path(ellipseIn: CGRect(x: glowCenter.x - radius, y: glowCenter.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    context.fill(glow, with: .radialGradient(
                        Gradient(colors: [OasesColor.primary.opacity(colorScheme == .dark ? 0.16 : 0.12), .clear]),
                        center: glowCenter, startRadius: 0, endRadius: radius))
                }
                let ink = colorScheme == .dark ? Color.white : Color.black
                for s in Self.specks {
                    // Each speck climbs the whole height in 60–170 s and wraps; the drift sideways
                    // is a slow sine so the field never looks like rain.
                    let climb = (CGFloat(t) * s.speed / 110 + s.phase).truncatingRemainder(dividingBy: 1)
                    let y = size.height * (1 - climb)
                    let x = size.width * s.x + sin(CGFloat(t) * 0.25 + s.phase * 6.28) * 6
                    // Fade in near the bottom and out near the top.
                    let edge = min(climb, 1 - climb) * 6
                    let a = s.alpha * min(1, edge) * (colorScheme == .dark ? 0.22 : 0.16)
                    let rect = CGRect(x: x - s.size / 2, y: y - s.size / 2, width: s.size, height: s.size)
                    context.fill(Path(ellipseIn: rect), with: .color(ink.opacity(a)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fade (and, with motion allowed, an 8 pt rise) for the welcome copy as the
/// splash mark lands. Instant when the welcome was never hidden.
struct OnboardingReveal: ViewModifier {
    var isRevealed: Bool
    var delay: Double
    var travels: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || !travels ? 0 : 8)
            .animation(.easeOut(duration: 0.45).delay(delay), value: isRevealed)
    }
}

/// Where the welcome hero mark sits, for the splash mark to land on.
private struct HeroMarkAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

#Preview {
    OnboardingFlowView()
        .preferredColorScheme(.dark)
}
