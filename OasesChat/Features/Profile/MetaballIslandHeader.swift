import SwiftUI

/// The Profile page's avatar, drawn over the whole screen so it can travel into the Dynamic
/// Island as the page scrolls: it rises and shrinks, a liquid bridge reaches up from it, the
/// photo darkens to black and the whole drop melts into the island. Pulled down, it swells a
/// little. On iPhones without an island it shrinks into a small dot that then disappears; on
/// iPad and in landscape it simply shrinks and fades. Reduce Motion keeps only the rise and
/// shrink.
///
/// The bridge is a metaball (shapes blurred together, then alpha-thresholded) drawn in black:
/// the island target, the avatar's disc and a tapering chain of drops between them.
/// Motion curves after rit3zh/expo-scroll-metaball (MIT).
struct MetaballIslandHeader<Avatar: View>: View {
    /// Scroll distance divided by the collapse distance: 0 at rest, 1 merged, negative when
    /// pulled down.
    let progress: CGFloat
    /// Avatar centre at rest (window coordinates).
    let rest: CGPoint
    let radius: CGFloat
    let island: IslandGeometry
    @ViewBuilder var avatar: () -> Avatar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let m = Motion(progress: progress, rest: rest, radius: radius, island: island, reduceMotion: reduceMotion)
        ZStack(alignment: .topLeading) {
            if m.drawsLiquid {
                Canvas { context, _ in
                    context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    if m.goo > 0.05 { context.addFilter(.blur(radius: m.goo)) }
                    context.drawLayer { layer in
                        if let target = m.target {
                            layer.fill(Path(roundedRect: target, cornerRadius: target.height / 2), with: .color(.black))
                        }
                        if m.radius > 0.5 {
                            layer.fill(Path(ellipseIn: CGRect(x: m.center.x - m.radius * 0.97, y: m.center.y - m.radius * 0.97,
                                                              width: m.radius * 1.94, height: m.radius * 1.94)),
                                       with: .color(.black))
                        }
                        for drop in m.bridge {
                            layer.fill(Path(ellipseIn: CGRect(x: drop.x - drop.r, y: drop.y - drop.r, width: drop.r * 2, height: drop.r * 2)),
                                       with: .color(.black))
                        }
                    }
                }
                .transition(.opacity)
            }
            if m.radius > 0.5 {
                avatar()
                    .frame(width: m.radius * 2, height: m.radius * 2)
                    .blur(radius: m.blur)
                    .opacity(m.photoOpacity)
                    .position(m.center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Everything the header draws for one scroll position.
    struct Motion {
        var center: CGPoint
        var radius: CGFloat
        var blur: CGFloat
        var photoOpacity: CGFloat
        var goo: CGFloat
        var target: CGRect?
        var bridge: [(x: CGFloat, y: CGFloat, r: CGFloat)] = []
        var drawsLiquid: Bool

        init(progress: CGFloat, rest: CGPoint, radius r: CGFloat, island: IslandGeometry, reduceMotion: Bool) {
            let p = progress
            let pc = max(0, min(1, p))
            // Pulled down: swell a little.
            let swell = p < 0 ? 1 + min(0.22, -p * 0.45) : 1
            let rad = r * swell * Self.ramp(pc, [0, 0.5, 1], [1, 0.62, 0])
            var targetRect: CGRect?
            var targetCenter: CGPoint?
            switch island {
            case .island(_, let target):
                targetRect = pc > 0.02 ? target : nil
                targetCenter = CGPoint(x: target.midX, y: target.midY)
            case .dot(let rect):
                let presence = Self.ramp(pc, [0, 0.4, 0.9, 1.1], [0, 1, 1, 0])
                if presence > 0.02 {
                    let side = rect.width * presence
                    targetRect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
                }
                targetCenter = CGPoint(x: rect.midX, y: rect.midY)
            case .none:
                break
            }
            if let tc = targetCenter {
                center = CGPoint(x: rest.x, y: rest.y + (tc.y - rest.y) * pc)
            } else {
                // No island: drift up with the content and fade.
                center = CGPoint(x: rest.x, y: rest.y - rest.y * 0.5 * pc)
            }
            radius = max(0, rad)
            let liquid = targetCenter != nil && !reduceMotion
            blur = liquid ? Self.ramp(pc, [0.08, 0.5], [0, 6]) : 0
            let darkness = liquid ? Self.ramp(pc, [0.6, 0.95], [0, 1]) : Self.ramp(pc, [0.4, 0.9], [0, 1])
            photoOpacity = 1 - darkness
            goo = liquid ? Self.ramp(pc, [0, 0.3, 0.78, 1], [2, 9, 9, 0]) : 0
            target = liquid ? targetRect : nil
            drawsLiquid = liquid && pc > 0.02
            if liquid, let tc = targetCenter {
                let stretch = Self.ramp(pc, [0.22, 0.4], [0, 1])
                if stretch > 0, radius > 1 {
                    // A tapering chain from the avatar's top toward the island.
                    let from = CGPoint(x: center.x, y: center.y - radius * 0.55)
                    let reach = (from.y - tc.y) * stretch
                    let steps = 7
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        bridge.append((x: from.x, y: from.y - reach * t, r: radius * (0.5 - 0.28 * t)))
                    }
                }
            }
        }

        /// Piecewise-linear map of `x` through `xs` → `ys` (clamped at both ends).
        static func ramp(_ x: CGFloat, _ xs: [CGFloat], _ ys: [CGFloat]) -> CGFloat {
            guard let first = xs.first, let last = xs.last else { return 0 }
            if x <= first { return ys[0] }
            if x >= last { return ys[ys.count - 1] }
            for i in 1..<xs.count where x <= xs[i] {
                let t = (x - xs[i - 1]) / max(xs[i] - xs[i - 1], 0.0001)
                return ys[i - 1] + (ys[i] - ys[i - 1]) * t
            }
            return ys[ys.count - 1]
        }
    }
}
