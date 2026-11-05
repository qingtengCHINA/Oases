import CoreGraphics

/// Border radius tokens matching Web's `--radius: 1rem` (16pt) + variants.
enum OasesRadius {
    static let sm: CGFloat = 12
    static let md: CGFloat = 14
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    /// Composer shell on mobile — Web `rounded-[1.8rem]` ≈ 28.8pt.
    static let composerShell: CGFloat = 29
    /// User message bubble on mobile — Web `1.2rem` ≈ 19.2pt.
    static let userBubble: CGFloat = 19
    static let pill: CGFloat = 999
}
