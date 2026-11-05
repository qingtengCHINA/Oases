import SwiftUI

/// Translucent rounded panel matching Web's `.panel-soft` / `.composer-shell`
/// (backdrop blur + subtle border + soft shadow).
struct OasesPanel<Content: View>: View {
    var radius: CGFloat = OasesRadius.lg
    var padding: CGFloat = OasesSpacing.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5)
            )
            .oasesShadow(.overlay)
    }
}
