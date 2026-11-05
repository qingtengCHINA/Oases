import SwiftUI

/// 品牌标「双池」（Twin Pools）的动态版。
///
/// 形状和 App 图标是同一条几何（`TwinPoolsGeometry`）：两个圆沿 45° 轴，由两段凹弧
/// 平滑相连。这里让它活起来——右上的大池不断把水"倒"给左下的小池，两池周期性互换
/// 大小，颈部始终平滑相连。边缘是清晰的矢量，不再靠模糊阈值做融合。
///
/// 开屏动画和首次引导的欢迎页共用这一个标：开屏结束时，标从屏幕中央移到欢迎页标题
/// 上方（`OnboardingFlowView`）。`isAnimating` 变为 false 后，会把当前这一轮倒完，
/// 停在图标的静止形态，而不是中途定格。
struct OasesDropletsMark: View {
    var isAnimating: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 停住时使用的时间点（整周期 → 静止形态）；nil 表示正在流动。
    @State private var frozenTime: Double?
    /// 每次重新开始流动都加一，作废之前排好的「停住」。
    @State private var settleGeneration = 0

    /// 大小互换一个来回的周期（秒）。
    static let period: Double = 2.4

    init(isAnimating: Bool = true) {
        self.isAnimating = isAnimating
        // 一出现就是静止的标直接画静止形态（t = 0 → 大池在右上）。
        _frozenTime = State(initialValue: isAnimating ? nil : 0)
    }

    /// 深色模式白色、浅色模式黑色。
    private var ink: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        // 「减少动态效果」打开时只画静止的标。
        let paused = frozenTime != nil || reduceMotion
        TimelineView(.animation(minimumInterval: nil, paused: paused)) { ctx in
            let t = reduceMotion ? 0 : (frozenTime ?? ctx.date.timeIntervalSinceReferenceDate)
            // cos 振荡：两端自带缓入缓出
            let f = 0.5 - 0.5 * cos(t * .pi * 2 / Self.period)
            // 呼吸级的微抖动，让水面更像液体（静止形态时为 0）
            let wob = sin(t * 5.1) * 0.0035 * sin(t * .pi * 2 / Self.period)
            let big = TwinPoolsGeometry.bigRadius
            let small = TwinPoolsGeometry.smallRadius
            TwinPoolsShape(
                upperRadius: big + (small - big) * f + wob,
                lowerRadius: small + (big - small) * f - wob
            )
            .fill(ink)
        }
        .onChange(of: isAnimating) { _, animating in
            settleGeneration += 1
            if animating {
                frozenTime = nil
            } else {
                settleAtNextRest()
            }
        }
        .accessibilityHidden(true)
    }

    /// 让当前这一轮倒完：在下一个整周期（静止形态）那一刻停住。
    private func settleAtNextRest() {
        guard frozenTime == nil else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let rest = (floor(now / Self.period) + 1) * Self.period
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (rest - now)) {
            guard generation == settleGeneration else { return }
            frozenTime = rest
        }
    }
}

/// 开屏动画每次冷启动只播一次：首次启动时由引导页播放（水滴随后落到
/// 欢迎页上），引导完成后挂载的 `RootView` 就不再重播。只在主线程读写。
@MainActor
enum LaunchSplashPlayback {
    static var hasPlayed = false
}

/// The page colour with the droplets centred on screen. Bridges onboarding
/// and the app: onboarding fades into it, and `RootView` (whose first mount
/// can take a moment on a cold launch) starts under it and fades it away,
/// so the hand-over never shows a blank or frozen page.
struct LaunchHandoffCover: View {
    static let markSize: CGFloat = 88

    var body: some View {
        ZStack {
            OasesColor.background
            OasesDropletsMark()
                .frame(width: Self.markSize, height: Self.markSize)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct LaunchSplashView: View {
    var onComplete: () -> Void

    @State private var appear = false
    @State private var rootOpacity: CGFloat = 1.0

    /// 开屏水滴的尺寸；引导页的交接动画从这个尺寸开始。
    static let markSize: CGFloat = 210

    var body: some View {
        ZStack {
            OasesColor.background
                .ignoresSafeArea()

            OasesDropletsMark()
                .frame(width: Self.markSize, height: Self.markSize)
                .scaleEffect(appear ? 1 : 0.86)
                .opacity(appear ? 1 : 0)
                .animation(.spring(duration: 0.55, bounce: 0.25), value: appear)
        }
        .opacity(rootOpacity)
        .onAppear { runSequence() }
        .accessibilityHidden(true)
    }

    /// 开屏至少播放这么久（弹入后水滴完成约 3/4 个互换周期）。
    static let minimumDuration: TimeInterval = 1.8
    /// 等欢迎页图标就绪最多等到这里，之后无论如何都进入 App。
    static let maximumDuration: TimeInterval = 4.0

    /// 开屏播放的同时，欢迎页的液态金属图标在后台准备（`MetallicPaintPrewarm`，从
    /// didFinishLaunching 开始）。播满最短时长后，若图标还没准备好就继续播，直到它就绪
    /// （最多 `maximumDuration`），这样淡出后图标已经能直接显示，不会再等一下才出现。
    private func runSequence() {
        LaunchSplashPlayback.hasPlayed = true
        appear = true
        Task { @MainActor in
            let start = Date()
            try? await Task.sleep(for: .seconds(Self.minimumDuration))
            while !MetallicPaintImage.isReady(imageName: "OasesIcon"),
                  Date().timeIntervalSince(start) < Self.maximumDuration {
                try? await Task.sleep(for: .milliseconds(60))
            }
            withAnimation(.easeIn(duration: 0.28)) {
                rootOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(300))
            onComplete()
        }
    }
}

#Preview {
    LaunchSplashView(onComplete: {})
        .preferredColorScheme(.dark)
}
