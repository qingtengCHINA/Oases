import SwiftUI

/// Renders the Oases brand mark with the real MetallicPaint shader — Metal
/// port of Web/src/components/MetallicPaint.tsx (see MetallicPaint.metal).
/// The greeting variant is tinted per `AppMode` so each mode's welcome icon
/// gets its own metallic hue (pink/red/blue/iridescent purple) while the
/// rest of the empty state stays identical.
struct MetallicGlyph: View {
    enum Variant {
        case greeting
        case sidebarBrand
    }

    var size: CGFloat = 48
    var variant: Variant = .greeting
    /// Per-mode metallic hue for the greeting variant. Ignored for `.sidebarBrand`.
    var mode: AppMode = .chat

    var body: some View {
        let frame = size * 1.1
        Group {
            switch variant {
            case .greeting:
                let tint = mode.metallicTint
                MetallicPaintView(
                    imageName: "OasesIcon",
                    seed: 42, scale: 4, refraction: 0.01, blur: 0.015, liquid: 0.75,
                    speed: 0.3, brightness: 2, contrast: 0.5, angle: 0, fresnel: 1,
                    patternSharpness: 1, waveAmplitude: 1, noiseScale: 0.5,
                    chromaticSpread: tint.chromaticSpread, distortion: 1, contour: 0.2,
                    lightColor: tint.lightColor,
                    darkColor: tint.darkColor,
                    tintColor: tint.tintColor
                )
            case .sidebarBrand:
                MetallicPaintView(
                    imageName: "OasesIcon",
                    seed: 42, scale: 4, refraction: 0.01, blur: 0.015, liquid: 0.75,
                    speed: 0.3, brightness: 2, contrast: 0.5, angle: 0, fresnel: 1,
                    patternSharpness: 1, waveAmplitude: 1, noiseScale: 0.5,
                    chromaticSpread: 2, distortion: 1, contour: 0.2,
                    lightColor: UIColor(red: 0xd7 / 255, green: 0xff / 255, blue: 0xdc / 255, alpha: 1),
                    darkColor: UIColor(red: 0x02 / 255, green: 0x1e / 255, blue: 0x13 / 255, alpha: 1),
                    tintColor: UIColor(red: 0x39 / 255, green: 0xf2 / 255, blue: 0x89 / 255, alpha: 1),
                    cropTransparent: true
                )
            }
        }
        .frame(width: frame, height: frame)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.245, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: size * 0.08, x: 0, y: size * 0.05)
    }
}

#Preview {
    HStack(spacing: 24) {
        ForEach(AppMode.allCases) { mode in
            VStack {
                MetallicGlyph(size: 48, variant: .greeting, mode: mode)
                Text(mode.featureLabel).font(.caption)
            }
        }
    }
    .padding()
    .background(Color(red: 0.97, green: 0.96, blue: 0.94))
}
