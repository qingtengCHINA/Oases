import SwiftUI
import UIKit

/// Oases Chat's look for the QingTeng account pages (the shared account layout of
/// 讲真话 (Maat), PlusProMax, Kracker and Stars, in Oases' own tokens): pushed from
/// Settings, so the pages sit on Settings' grouped background with its raised rows
/// (`insetGrouped`), the primary action is Oases' orange (`OasesColor.primary`, as on the
/// privacy onboarding), the bound tick is Oases' green, and red is only for leaving and
/// deleting. Light and dark both come from the asset catalogue and the system colours.
/// The ID card itself keeps the look it has in every QingTeng app.
enum AccountStyle {
    /// Page background: Settings' grouped background, light and dark.
    static let canvas = Color(uiColor: .systemGroupedBackground)
    /// Cards, rows and the payout form: Settings' raised row colour.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// The edge of quiet buttons and the dividers inside a card.
    static let frame = OasesColor.border
    /// Radius of cards, rows and buttons (`OasesRadius.sm`).
    static let radius: CGFloat = OasesRadius.sm
    /// Primary text, secondary text, headings.
    static let text = OasesColor.foreground
    static let secondaryText = OasesColor.mutedForeground
    static let heading = OasesColor.foreground
    /// The sign-in page's buttons (the onboarding's primary button height).
    static let ctaHeight: CGFloat = 52
    /// Bind buttons and the account page's actions.
    static let bindHeight: CGFloat = 48
    /// Side margin and the gap between groups (`OasesSpacing`).
    static let margin: CGFloat = OasesSpacing.md
    /// Inside a card.
    static let rowInset: CGFloat = 14
    static let groupSpacing: CGFloat = 22
    /// Widest column on iPad and wide windows.
    static let readableWidth: CGFloat = 560
    /// Leaving and deleting.
    static let danger = OasesColor.destructive
    /// The bound tick.
    static let bound = OasesColor.emerald
    /// The primary action's fill (Oases' orange) and its text.
    static let primaryFill = OasesColor.primary
    static let onPrimary = Color.white
    /// Links and the navigation bar's buttons.
    static let tint = OasesColor.primary

    /// The system font at `size`, as Settings sets its rows.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Monospaced, for addresses and numbers.
    static func monoFont(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    /// A card's, row's or button's shape.
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension View {
    /// Keeps the account pages at a readable width on wide screens, centred; no effect on a phone.
    func accountReadableWidth(_ maxWidth: CGFloat = AccountStyle.readableWidth) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// A card or a quiet button: Settings' raised row colour with a hairline edge.
    func accountPanel() -> some View {
        background(AccountStyle.shape.fill(AccountStyle.surface))
            .overlay(AccountStyle.shape.strokeBorder(AccountStyle.frame.opacity(0.6), lineWidth: 0.5))
    }

    /// A coloured button face: `fill` in the account shape, with a thin edge of `frame`.
    func accountPanel(fill: Color, frame: Color) -> some View {
        background(AccountStyle.shape.fill(fill))
            .overlay(AccountStyle.shape.strokeBorder(frame, lineWidth: 1))
    }

    /// An inline navigation title, like Settings' pushed pages.
    func accountNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Leaves the account pages. Settings pushes them and hands in exactly what pops back
/// to it, so a page deeper in the stack (注销账号) can close them all at once.
private struct CloseAccountPageKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var closeAccountPage: @MainActor @Sendable () -> Void {
        get { self[CloseAccountPageKey.self] }
        set { self[CloseAccountPageKey.self] = newValue }
    }
}

/// Pressed buttons dim and shrink a little, like the onboarding's buttons (0.97 within ~100 ms).
struct AccountPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A thin divider between rows inside a card.
struct AccountDivider: View {
    var body: some View {
        Divider()
            .background(AccountStyle.frame.opacity(0.3))
    }
}
