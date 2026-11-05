import SwiftUI

/// 「限免」: a built-in model that is free for a limited time and outside the
/// membership limits (`Models.Option.isPromoFree`).
struct PromoFreeBadge: View {
    var body: some View {
        Text(String(localized: "限免", comment: "Badge on a built-in model that is free for a limited time and doesn't use the membership quota"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(OasesColor.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(OasesColor.primary.opacity(0.12), in: Capsule())
            .accessibilityLabel(Text(String(localized: "限时免费", comment: "VoiceOver label of the limited-time free model badge")))
    }
}
