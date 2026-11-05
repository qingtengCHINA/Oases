import SwiftUI

/// Metal-driven aurora field used as the empty-state / page backdrop. The
/// shader lives in `Aurora.metal` (`[[ stitchable ]] half4 aurora(...)`)
/// and is fed `time` + `size` + brand `tint` via SwiftUI iOS 17+'s
/// `Shader` API on a single `Rectangle()`.
///
/// The previous design used a static `RadialGradient` — pretty but flat.
/// This view keeps the radial composition (bright band leaning toward
/// the top) while adding slow drift so the home screen never feels
/// frozen, especially in the moments before the model responds.
struct AuroraBackground: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // GeometryReader hands the shader the live view bounds so the
        // aurora composition scales with the device. We pass `size` as
        // a float2 uniform; the shader normalises against it.
        //
        // Note: NO `paused` gate here. The previous `active` parameter
        // tore down the TimelineView subtree the moment the host
        // flipped it to false, which made SwiftUI cancel the opacity
        // transition that was supposed to be fading the view out.
        // The shader ticks continuously; opacity = 0 trivially short-
        // circuits the composite, so the GPU cost is negligible.
        GeometryReader { geo in
            // Reduce Motion: the aurora holds still (a fixed moment of its drift).
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
                let t = reduceMotion ? 120 : ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 6000)
                let rgb = Self.rgb(of: tint)
                Rectangle()
                    .fill(OasesColor.background)
                    .colorEffect(
                        ShaderLibrary.aurora(
                            .float(Float(t)),
                            .float2(Float(geo.size.width),
                                    Float(geo.size.height)),
                            .float3(rgb.x, rgb.y, rgb.z)
                        )
                    )
            }
        }
        .ignoresSafeArea()
    }

    private static func rgb(of color: Color) -> SIMD3<Float> {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }
}

#Preview {
    AuroraBackground(tint: OasesColor.primary)
        .preferredColorScheme(.dark)
}
