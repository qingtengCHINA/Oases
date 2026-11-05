import SwiftUI

/// Metallic streaming-shimmer modifier driven by `StreamShimmer.metal`.
/// Wraps SwiftUI's iOS 17+ Shader API into a single drop-in modifier so
/// any View can opt-in via `.streamShimmer(active: vm.isStreaming)`.
///
/// The shader runs ONLY while `active` is true — when the flag flips off
/// (stream finished, error, user-stopped) the TimelineView freezes and
/// `colorEffect`'s `isEnabled: false` short-circuits the GPU work.
struct StreamShimmerModifier: ViewModifier {
    var active: Bool
    var tint: Color

    func body(content: Content) -> some View {
        // TimelineView re-evaluates every animation frame, so the
        // shader's `time` argument advances smoothly without us having
        // to manage a phase variable. When `active` is false the
        // colorEffect short-circuits and the timeline still ticks but
        // the GPU work is skipped (`isEnabled: false`).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000)
            let rgb = Self.rgb(of: tint)
            content
                .colorEffect(
                    ShaderLibrary.streamShimmer(
                        .float(Float(t)),
                        .float2(0, 0),
                        .float3(rgb.x, rgb.y, rgb.z)
                    ),
                    isEnabled: active
                )
        }
    }

    /// Pulls the RGB components out of a SwiftUI Color via UIColor — used
    /// so the shader knows the brand tint without us having to keep two
    /// copies of the palette.
    private static func rgb(of color: Color) -> SIMD3<Float> {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }
}

extension View {
    /// Apply the metallic streaming shimmer while `active` is true. Tint
    /// defaults to the brand primary; pass a per-mode colour to make the
    /// sheen match (pink for chat, red for audio, etc.).
    func streamShimmer(active: Bool, tint: Color = OasesColor.primary) -> some View {
        modifier(StreamShimmerModifier(active: active, tint: tint))
    }
}
