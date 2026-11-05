import CoreGraphics
import Foundation

/// The geometry of the Oases mark, "Twin Pools": two circles on an exact 45° axis joined by a
/// smooth neck of two concave arcs (`qingtengstudio/logos/oases/a-twin-pools-mark.svg`).
///
/// Everything is in a unit square with the y axis pointing down (the SVG's 1024 viewBox divided
/// by 1024). The app icon PNGs, the metallic welcome glyph's mask and the animated launch mark
/// are all drawn from this one path, so they can never drift apart.
///
/// Only CoreGraphics is used, so `scripts/brand/render_icons.swift` compiles this same file on
/// the Mac to regenerate the icon assets.
enum TwinPoolsGeometry {
    /// Upper-right pool.
    static let bigCenter = CGPoint(x: 643.5744355 / 1024, y: 368.4255645 / 1024)
    static let bigRadius: CGFloat = 206 / 1024
    /// Lower-left pool.
    static let smallCenter = CGPoint(x: 332.4821304 / 1024, y: 679.5178696 / 1024)
    static let smallRadius: CGFloat = 158 / 1024
    /// The two concave arcs of the neck.
    static let neckRadius: CGFloat = 126 / 1024

    /// The mark's tight bounds in the unit square (both pools touch it).
    static var bounds: CGRect {
        let minX = smallCenter.x - smallRadius
        let maxX = bigCenter.x + bigRadius
        let minY = bigCenter.y - bigRadius
        let maxY = smallCenter.y + smallRadius
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The outline for any pair of pool sizes on the fixed centres. `upperRadius` belongs to the
    /// upper-right pool and `lowerRadius` to the lower-left one; the defaults give the logo.
    /// Swapping them (the launch animation) keeps a smooth neck, because the neck only depends on
    /// the sum of the two radii, which the animation keeps nearly constant.
    static func path(
        upperRadius: CGFloat = bigRadius,
        lowerRadius: CGFloat = smallRadius,
        neckRadius: CGFloat = neckRadius,
        transform: CGAffineTransform = .identity
    ) -> CGPath {
        let c1 = bigCenter, c2 = smallCenter
        let r1 = upperRadius, r2 = lowerRadius, rn = neckRadius
        let dx = c2.x - c1.x, dy = c2.y - c1.y
        let d = (dx * dx + dy * dy).squareRoot()
        let u = CGPoint(x: dx / d, y: dy / d)
        let n = CGPoint(x: -u.y, y: u.x)
        let a = r1 + rn, b = r2 + rn
        let along = (a * a - b * b + d * d) / (2 * d)
        let h = max(a * a - along * along, 0).squareRoot()
        let base = CGPoint(x: c1.x + u.x * along, y: c1.y + u.y * along)
        let neckPlus = CGPoint(x: base.x + n.x * h, y: base.y + n.y * h)
        let neckMinus = CGPoint(x: base.x - n.x * h, y: base.y - n.y * h)

        func angle(_ from: CGPoint, _ to: CGPoint) -> CGFloat { atan2(to.y - from.y, to.x - from.x) }
        func positive(_ x: CGFloat) -> CGFloat {
            var v = x.truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v
        }
        /// The signed sweep from `start` to `end` that does (or does not) pass `through`.
        func sweep(from start: CGFloat, to end: CGFloat, avoiding avoid: CGFloat) -> CGFloat {
            let forward = positive(end - start)
            return positive(avoid - start) < forward ? forward - 2 * .pi : forward
        }
        func shortSweep(from start: CGFloat, to end: CGFloat) -> CGFloat {
            let forward = positive(end - start)
            return forward > .pi ? forward - 2 * .pi : forward
        }

        let path = CGMutablePath()
        // Outer arc of the upper pool: from the tangent with the + neck to the tangent with the
        // − neck, the long way round (away from the lower pool).
        let t1Plus = angle(c1, neckPlus), t1Minus = angle(c1, neckMinus)
        let towardLower = angle(c1, c2)
        path.addRelativeArc(center: c1, radius: r1, startAngle: t1Plus,
                            delta: sweep(from: t1Plus, to: t1Minus, avoiding: towardLower), transform: transform)
        // − neck: concave, from the upper pool's tangent to the lower pool's.
        let nMinusStart = angle(neckMinus, c1), nMinusEnd = angle(neckMinus, c2)
        path.addRelativeArc(center: neckMinus, radius: rn, startAngle: nMinusStart,
                            delta: shortSweep(from: nMinusStart, to: nMinusEnd), transform: transform)
        // Outer arc of the lower pool, the long way round (away from the upper pool).
        let t2Minus = angle(c2, neckMinus), t2Plus = angle(c2, neckPlus)
        let towardUpper = angle(c2, c1)
        path.addRelativeArc(center: c2, radius: r2, startAngle: t2Minus,
                            delta: sweep(from: t2Minus, to: t2Plus, avoiding: towardUpper), transform: transform)
        // + neck back to the start.
        let nPlusStart = angle(neckPlus, c2), nPlusEnd = angle(neckPlus, c1)
        path.addRelativeArc(center: neckPlus, radius: rn, startAngle: nPlusStart,
                            delta: shortSweep(from: nPlusStart, to: nPlusEnd), transform: transform)
        path.closeSubpath()
        return path
    }

    /// Maps the unit square onto `rect` (square-fitted and centred), optionally scaling the mark
    /// about the centre so its bounds fill `fill` of the side (nil keeps the logo's own 66 %).
    static func transform(fitting rect: CGRect, fill: CGFloat? = nil) -> CGAffineTransform {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var t = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: side, y: side)
        if let fill {
            let b = bounds
            let k = fill / max(b.width, b.height)
            // Centre the mark's bounds in the square, then scale it about the centre.
            t = t.translatedBy(x: 0.5, y: 0.5)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -b.midX, y: -b.midY)
        }
        return t
    }
}
