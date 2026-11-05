import SwiftUI

/// Design tokens copied from Web's index.css OKLCH palette.
/// Asset Catalog provides Light/Dark variants automatically via `Color(_:)`.
enum OasesColor {
    static let background = Color("Background")
    static let foreground = Color("Foreground")
    static let card = Color("Card")
    static let surfaceElevated = Color("SurfaceElevated")
    static let primary = Color("Primary")
    static let muted = Color("Muted")
    static let mutedForeground = Color("MutedForeground")
    static let border = Color("Border")
    static let sidebar = Color("Sidebar")
    static let destructive = Color("Destructive")
    static let emerald = Color("Emerald")
    static let accent = Color("AccentColor")
    /// The accent used as text (links, selected pills): the fill colour falls under 3:1 on
    /// the light background, this one meets 4.5:1 in both appearances.
    static let primaryText = Color("PrimaryText")
    /// Disclaimers, timestamps and other 11–12 pt secondary text (4.5:1+), in place of
    /// `mutedForeground.opacity(0.72)`.
    static let textTertiary = Color("TextTertiary")
    /// Attention that isn't an error: unauthenticated, approaching a limit.
    static let warning = Color("Warning")
}
