import SwiftUI

/// The real marks of the services a user can connect, for the provider pages. The SVGs in
/// Assets.xcassets/ProviderLogos come from LobeHub Icons (MIT); the marks belong to their
/// companies and are shown only to say which service a row is.
enum ProviderBrand {
    struct Logo {
        /// Image-set name, or nil for a neutral SF Symbol.
        let asset: String?
        let symbol: String
        /// A one-colour mark drawn in the tile's ink colour.
        let isTemplate: Bool
    }

    static func logo(for type: ProviderType) -> Logo {
        switch type {
        case .anthropic: return Logo(asset: "provider-anthropic", symbol: "a.circle", isTemplate: true)
        case .gemini: return Logo(asset: "provider-gemini", symbol: "sparkle", isTemplate: false)
        case .openRouter: return Logo(asset: "provider-openrouter", symbol: "arrow.triangle.branch", isTemplate: true)
        case .xAI: return Logo(asset: "provider-xai", symbol: "x.circle", isTemplate: true)
        case .kimiCode: return Logo(asset: "provider-kimi", symbol: "moon.stars", isTemplate: false)
        // A protocol rather than a company: a neutral mark.
        case .openAI, .openAIResponses: return Logo(asset: nil, symbol: "point.3.connected.trianglepath.dotted", isTemplate: true)
        case .antigravity: return Logo(asset: nil, symbol: "ant", isTemplate: true)
        case .unsupported: return Logo(asset: nil, symbol: "questionmark.circle", isTemplate: true)
        }
    }

    static func logo(forVoiceTemplate id: String) -> Logo {
        switch id {
        case "elevenlabs": return Logo(asset: "provider-elevenlabs", symbol: "waveform", isTemplate: true)
        case "azure-tts": return Logo(asset: "provider-azure", symbol: "cloud", isTemplate: false)
        case "minimax": return Logo(asset: "provider-minimax", symbol: "waveform", isTemplate: false)
        case "alibaba": return Logo(asset: "provider-bailian", symbol: "waveform", isTemplate: false)
        case "doubao": return Logo(asset: "provider-doubao", symbol: "waveform", isTemplate: false)
        case "xunfei": return Logo(asset: "provider-iflytek", symbol: "waveform", isTemplate: false)
        case "mimo": return Logo(asset: "provider-mimo", symbol: "waveform", isTemplate: true)
        default: return Logo(asset: nil, symbol: "mic.and.signal.meter", isTemplate: true)
        }
    }
}

/// A brand mark on a light tile — the same tile in light and dark mode, so the logos keep
/// their own colours.
struct ProviderLogoTile: View {
    let logo: ProviderBrand.Logo
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(Color.white)
            if let asset = logo.asset {
                Image(asset)
                    .resizable()
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(Color(white: 0.08))
                    .padding(size * 0.22)
            } else {
                Image(systemName: logo.symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color(white: 0.2))
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
