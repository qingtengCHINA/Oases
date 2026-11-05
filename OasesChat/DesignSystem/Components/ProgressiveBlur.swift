import SwiftUI
import UIKit

/// Height of the chrome (status bar excluded) a chat list scrolls under: the list adds it to
/// its top content inset so the first message starts below the chrome, while the chrome's
/// progressive blur sits over the content that scrolls up beneath it.
private struct OasesTopChromeInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var oasesTopChromeInset: CGFloat {
        get { self[OasesTopChromeInsetKey.self] }
        set { self[OasesTopChromeInsetKey.self] = newValue }
    }
}

/// A progressive blur at the edge of a scrolling area: content melts into the chrome instead of
/// being clipped by a hard line. Built the way expo-backdrop builds its `ProgressiveBlurView`,
/// from public API only:
///
/// * one `UIVisualEffectView` held at a partial strength (a paused `UIViewPropertyAnimator`),
///   masked by a smoothstep gradient that is fully on at the edge and gone at 60 % of the
///   view's height, so the blur ramps instead of stepping;
/// * a wash of the page colour over the whole height (strongest at the edge), which carries
///   the fade the blur alone can't;
/// * coverage: the view finds the scroll view behind it and fades the whole effect in over the
///   first 24 pt of content that scrolls under the edge, so it is invisible when nothing is
///   under it. `progress` overrides coverage when there is no scroll view to watch;
/// * during a fast fling the blur gives way to a plain gradient: a material lags a frame
///   behind the content and smears, and the eye can't tell blur from fade at that speed.
///
/// Height is the effect's whole reach: give it the chrome's height plus ~48 pt of ramp.
/// Reduce Transparency keeps only the wash.
struct ProgressiveBlur: View {
    enum Edge {
        case top, bottom
    }

    var edge: Edge
    /// Fades the whole effect (0 … 1). Used when no scroll view sits behind the view; with one,
    /// coverage is read from the scroll offset instead.
    var progress: CGFloat = 1
    /// How opaque the page-colour wash is at the very edge (1 for bars over the status bar,
    /// lower for the edge of a list inside the page).
    var wash: CGFloat = 1
    var tint: Color = OasesColor.background
    /// Blur strength 0 … 1 (0.3 reads as the system's own progressive edges).
    var intensity: CGFloat = 0.3

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        EdgeBlurRepresentable(
            edge: edge,
            progress: max(0, min(1, progress)),
            wash: max(0, min(1, wash)),
            tint: UIColor(tint),
            intensity: reduceTransparency ? 0 : max(0, min(1, intensity)),
            scheme: colorScheme
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EdgeBlurRepresentable: UIViewRepresentable {
    let edge: ProgressiveBlur.Edge
    let progress: CGFloat
    let wash: CGFloat
    let tint: UIColor
    let intensity: CGFloat
    let scheme: ColorScheme

    func makeUIView(context: Context) -> ProgressiveBlurView {
        let view = ProgressiveBlurView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: ProgressiveBlurView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ProgressiveBlurView) {
        view.edge = edge
        view.progress = progress
        view.washOpacity = wash
        view.tint = tint
        view.intensity = intensity
    }
}

/// The UIKit view behind `ProgressiveBlur`.
final class ProgressiveBlurView: UIView {
    /// Gradient samples per ramp (smoothstep needs a few).
    private static let fadeSamples = 6
    /// The blur ramps over this share of the height; the wash over all of it.
    private static let blurRampShare: CGFloat = 0.6
    /// Content hidden under the edge before the effect is fully on.
    private static let coverageFadeDistance: CGFloat = 24
    /// The system's ultra-thin material at `intensity`; 1.25 lifts the default 0.3 to a
    /// visible blur without the frosted look of a full material.
    private static let blurScale: CGFloat = 1.25

    var edge: ProgressiveBlur.Edge = .top {
        didSet { if edge != oldValue { updateGradients() } }
    }
    var progress: CGFloat = 1 {
        didSet { if abs(progress - oldValue) > 0.001 { updateVisibility() } }
    }
    var washOpacity: CGFloat = 1 {
        didSet { if abs(washOpacity - oldValue) > 0.001 { updateGradients() } }
    }
    var tint: UIColor = .systemBackground {
        didSet { if tint != oldValue { updateGradients() } }
    }
    var intensity: CGFloat = 0.3 {
        didSet {
            if abs(intensity - oldValue) > 0.001 {
                applyStrength()
                updateGradients()
                updateVisibility()
            }
        }
    }

    private let blurContainer = UIView()
    private let maskedBlur = UIView()
    private let effectView = UIVisualEffectView(effect: nil)
    private let blurMask = GradientView()
    private let washGradient = GradientView()
    /// Replaces the blur while the content flies past.
    private let fallbackGradient = GradientView()
    private let scrollMonitor = ScrollBlurMonitor()

    private var animator: UIViewPropertyAnimator?
    private var liveBlurAmount: CGFloat = 1
    private var foregroundObserver: NSObjectProtocol?
    private var scrollViewCheck: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Group opacity would flatten the blur into a bitmap when the container fades.
        blurContainer.layer.allowsGroupOpacity = false
        blurContainer.isUserInteractionEnabled = false
        effectView.isUserInteractionEnabled = false
        maskedBlur.addSubview(effectView)
        maskedBlur.layer.mask = blurMask.layer
        blurContainer.addSubview(maskedBlur)
        blurContainer.addSubview(washGradient)
        addSubview(blurContainer)
        fallbackGradient.isHidden = true
        addSubview(fallbackGradient)

        scrollMonitor.onScroll = { [weak self] in self?.updateVisibility() }
        scrollMonitor.onBlurAmountChange = { [weak self] amount in
            self?.liveBlurAmount = amount
            self?.updateVisibility()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressiveBlurView, _: UITraitCollection) in
            // The material is re-made for the new appearance; the wash resolves the tint again.
            if view.window != nil {
                view.applyStrength()
                view.updateGradients()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // A UIView dies on the main thread; the timer and the paused animator must be
        // stopped before they are released.
        MainActor.assumeIsolated {
            scrollViewCheck?.invalidate()
            animator?.stopAnimation(true)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scrollViewCheck?.invalidate()
        scrollViewCheck = nil
        if window != nil {
            applyStrength()
            attachScrollMonitor()
            // The list behind may be swapped (a session change); look again now and then.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattachIfScrollViewLeft() }
            }
            RunLoop.main.add(timer, forMode: .common)
            scrollViewCheck = timer
            if foregroundObserver == nil {
                foregroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    // A paused animator can lose its fraction across a background trip.
                    MainActor.assumeIsolated { self?.applyStrength() }
                }
            }
        } else {
            scrollMonitor.stop()
            animator?.stopAnimation(true)
            animator = nil
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
            foregroundObserver = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurContainer.frame = bounds
        maskedBlur.frame = bounds
        effectView.frame = bounds
        blurMask.frame = bounds
        washGradient.frame = bounds
        fallbackGradient.frame = bounds
        CATransaction.commit()
        updateGradients()
        if scrollMonitor.scrollView == nil { attachScrollMonitor() }
        updateVisibility()
    }

    // MARK: Strength

    private var blurStrength: CGFloat { min(1, intensity * Self.blurScale) }

    /// A partial `UIVisualEffect` the documented way: an animator towards the full material,
    /// paused at the wanted fraction. It must be stopped before it is released.
    private func applyStrength() {
        guard window != nil else { return }
        animator?.stopAnimation(true)
        animator = nil
        effectView.effect = nil
        guard blurStrength > 0.01 else { return }
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [effectView] in
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = blurStrength
        self.animator = animator
    }

    // MARK: Gradients

    private func updateGradients() {
        let blurStops = Self.ramp(to: Self.blurRampShare) + [(1, 0)]
        blurMask.update(edge: edge, color: .black, stops: blurStops)

        let washStops = Self.ramp(to: 1)
        let resolvedTint = tint.resolvedColor(with: traitCollection)
        washGradient.update(edge: edge, color: resolvedTint.withAlphaComponent(washOpacity * 0.85), stops: washStops)
        washGradient.isHidden = washOpacity <= 0.001

        // Without the blur, the fallback carries what the blur would have hidden.
        let fallback = washStops.map { ($0.location, $0.alpha) }
        fallbackGradient.update(edge: edge, color: resolvedTint.withAlphaComponent(max(washOpacity, 0.6) * 0.95), stops: fallback)
    }

    /// Alpha 1 at the edge (location 0) easing to 0 at `end`, as smoothstep samples.
    private static func ramp(to end: CGFloat) -> [GradientStop] {
        (0...fadeSamples).map { sample in
            let t = CGFloat(sample) / CGFloat(fadeSamples)
            return (end * t, 1 - smoothstep(0, 1, t))
        }
    }

    // MARK: Visibility

    private func updateVisibility() {
        let coverage = scrollMonitor.scrollView == nil ? progress : contentCoverage()
        let blurAmount = liveBlurAmount
        let blurAlpha = (blurStrength > 0.01 ? blurAmount : 0) * coverage
        if abs(blurContainer.alpha - blurAlpha) > 0.001 { blurContainer.alpha = blurAlpha }
        let blurHidden = blurAlpha <= 0.001
        if blurContainer.isHidden != blurHidden { blurContainer.isHidden = blurHidden }

        // Reduce Transparency (strength 0) shows the wash through the fallback path.
        let fallbackAlpha = (blurStrength > 0.01 ? 1 - blurAmount : 1) * coverage
        if abs(fallbackGradient.alpha - fallbackAlpha) > 0.001 { fallbackGradient.alpha = fallbackAlpha }
        let fallbackHidden = fallbackAlpha <= 0.001
        if fallbackGradient.isHidden != fallbackHidden { fallbackGradient.isHidden = fallbackHidden }
    }

    /// How much content is hidden under this edge, 0 … 1 over the first 24 pt.
    private func contentCoverage() -> CGFloat {
        guard let scrollView = scrollMonitor.scrollView else { return progress }
        let inset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset
        let hidden: CGFloat
        switch edge {
        case .top:
            hidden = offset.y + inset.top
        case .bottom:
            hidden = scrollView.contentSize.height + inset.bottom - (offset.y + scrollView.bounds.height)
        }
        return smoothstep(0, Self.coverageFadeDistance, hidden)
    }

    // MARK: The scroll view behind

    private func attachScrollMonitor() {
        guard window != nil else {
            scrollMonitor.stop()
            return
        }
        scrollMonitor.observe(findScrollViewBehind())
        updateVisibility()
    }

    private func reattachIfScrollViewLeft() {
        if let scrollView = scrollMonitor.scrollView {
            guard scrollView.window == nil else { return }
            scrollMonitor.stop()
        }
        attachScrollMonitor()
    }

    /// The scroll view drawn under this view: among the siblings behind it (and their
    /// subviews), walking up the hierarchy, the first one whose frame overlaps ours.
    private func findScrollViewBehind() -> UIScrollView? {
        let frameInWindow = convert(bounds, to: nil)
        var child: UIView = self
        while let container = child.superview {
            let index = container.subviews.firstIndex(of: child) ?? 0
            for sibling in container.subviews[..<index].reversed() {
                if let scrollView = Self.scrollView(in: sibling, overlapping: frameInWindow) { return scrollView }
            }
            child = container
        }
        return nil
    }

    private static func scrollView(in view: UIView, overlapping frame: CGRect) -> UIScrollView? {
        guard !view.isHidden, view.convert(view.bounds, to: nil).intersects(frame) else { return nil }
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews.reversed() {
            if let scrollView = scrollView(in: subview, overlapping: frame) { return scrollView }
        }
        return nil
    }
}

private typealias GradientStop = (location: CGFloat, alpha: CGFloat)

private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    func update(edge: ProgressiveBlur.Edge, color: UIColor, stops: [GradientStop]) {
        let baseAlpha = color.cgColor.alpha
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = stops.map { color.withAlphaComponent(baseAlpha * $0.alpha).cgColor }
        gradient.locations = stops.map { NSNumber(value: Double($0.location)) }
        switch edge {
        case .top:
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        case .bottom:
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        CATransaction.commit()
    }
}

/// Watches the scroll view behind a progressive blur: offset changes drive coverage, and the
/// scroll speed drives how much of the effect is blur (slow) or plain gradient (fast).
@MainActor
private final class ScrollBlurMonitor: NSObject {
    private static let slowSpeed: CGFloat = 500
    private static let fastSpeed: CGFloat = 1500
    private static let speedSmoothing: CGFloat = 0.1
    private static let fadeOutDuration: CGFloat = 0.08
    private static let fadeInDuration: CGFloat = 0.2

    private(set) weak var scrollView: UIScrollView?
    private(set) var blurAmount: CGFloat = 1
    var onScroll: (() -> Void)?
    var onBlurAmountChange: ((CGFloat) -> Void)?

    private var offsetObservation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?
    private var lastOffset = CGPoint.zero
    private var lastTimestamp: CFTimeInterval = 0
    private var speed: CGFloat = 0

    func observe(_ scrollView: UIScrollView?) {
        guard scrollView !== self.scrollView else { return }
        stop()
        self.scrollView = scrollView
        offsetObservation = scrollView?.observe(\.contentOffset, options: [.old]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onScroll?()
                self.scrollViewDidScroll(from: change.oldValue)
            }
        }
    }

    func stop() {
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView = nil
        displayLink?.invalidate()
        displayLink = nil
        speed = 0
        setBlurAmount(1)
    }

    private func scrollViewDidScroll(from oldOffset: CGPoint?) {
        guard displayLink == nil, let scrollView else { return }
        lastOffset = oldOffset ?? scrollView.contentOffset
        lastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else {
            stop()
            return
        }
        let elapsed = CGFloat(max(link.timestamp - lastTimestamp, 1.0 / 240))
        let offset = scrollView.contentOffset
        let instant = hypot(offset.x - lastOffset.x, offset.y - lastOffset.y) / elapsed
        lastOffset = offset
        lastTimestamp = link.timestamp
        speed += (instant - speed) * min(1, elapsed / Self.speedSmoothing)

        let target = 1 - smoothstep(Self.slowSpeed, Self.fastSpeed, speed)
        let duration = target < blurAmount ? Self.fadeOutDuration : Self.fadeInDuration
        var next = blurAmount + (target - blurAmount) * min(1, elapsed / duration)
        if abs(target - next) < 0.01 { next = target }
        setBlurAmount(next)

        if speed < 5, blurAmount == 1 {
            speed = 0
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func setBlurAmount(_ amount: CGFloat) {
        guard amount != blurAmount else { return }
        blurAmount = amount
        onBlurAmountChange?(amount)
    }
}

private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}
