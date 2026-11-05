import SwiftUI

/// Shared chat palette used by Ogent message / media views.
/// Tokens come from the Oases catalog so the OpenMinis kernel wears
/// the product chrome instead of UIKit system colors.
enum ChatColors {
    static let background = OasesColor.background
    static let secondaryBg = OasesColor.card
    static let inputIconBg = OasesColor.muted
    static let inputIconBorder = OasesColor.border
    static let inputBg = OasesColor.card
    static let inputBorder = OasesColor.border
    static let primaryText = OasesColor.foreground
    static let secondaryText = OasesColor.mutedForeground
    static let tertiaryText = OasesColor.mutedForeground.opacity(0.72)
    static let userBubble = OasesColor.muted
    static let toolBg = OasesColor.muted
    static let toolBorder = OasesColor.border.opacity(0.5)
    static let accent = OasesColor.primary
    static let sendButton = OasesColor.primary
    static let sendButtonDisabled = OasesColor.mutedForeground.opacity(0.4)
}
