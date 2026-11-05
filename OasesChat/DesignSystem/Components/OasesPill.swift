import SwiftUI

/// Pill-shaped toggle/button used for model picker, effort selector, mode segments.
/// Matches Web's `composer-model-button` style.
struct OasesPill: View {
    let title: String
    var systemImage: String? = nil
    var isActive: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OasesSpacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.medium))
                }
                Text(title)
                    .font(.oasesCaption())
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.6)
            }
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.xs)
            .foregroundStyle(isActive ? OasesColor.primaryText : OasesColor.foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(OasesColor.card.opacity(0.92))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 36)
    }
}
