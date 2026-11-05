import SwiftUI

/// Shadow levels. In dark mode shadows keep their shape and only get darker; they never use
/// the foreground colour (which turned them into a white glow).
enum OasesElevation {
    /// Bubbles, small tiles.
    case card
    /// Pills, tabs.
    case raised
    /// The composer, banners, panels.
    case overlay
    /// Menus and popovers that float over everything.
    case floating
}

struct OasesShadow: ViewModifier {
    let level: OasesElevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        switch level {
        case .card:
            content.shadow(color: .black.opacity(dark ? 0.14 : 0.05), radius: 0.5, y: 1)
        case .raised:
            content
                .shadow(color: .black.opacity(dark ? 0.12 : 0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(dark ? 0.16 : 0.10), radius: 1.5, y: 1)
        case .overlay:
            content
                .shadow(color: .black.opacity(dark ? 0.10 : 0.05), radius: 3, y: 4)
                .shadow(color: .black.opacity(dark ? 0.18 : 0.10), radius: 7.5, y: 10)
        case .floating:
            content
                .shadow(color: .black.opacity(dark ? 0.42 : 0.32), radius: 0.5)
                .shadow(color: .black.opacity(dark ? 0.16 : 0.06), radius: 6, y: 1)
                .shadow(color: .black.opacity(dark ? 0.22 : 0.16), radius: 32)
        }
    }
}

extension View {
    func oasesShadow(_ level: OasesElevation) -> some View { modifier(OasesShadow(level: level)) }
}

/// Timings and curves: quick feedback, a soft landing on the way in, a quiet fade on the way
/// out (an exit never looks like the entrance played backwards).
enum OasesMotion {
    /// Colour, highlight.
    static let feedback = Animation.easeOut(duration: 0.15)
    static let pressIn = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)
    static let pressOut = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.42)
    static let toggle = Animation.easeInOut(duration: 0.2)
    /// Entrances: a soft landing.
    static let enter = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    /// Menus and panels.
    static let surface = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.46)
    /// Exits: opacity only.
    static let exit = Animation.easeOut(duration: 0.2)
    /// Interruptible, follows the finger.
    static let follow = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Enter by sliding in from `edge` with a fade; leave by fading only.
    static func banner(from edge: Edge) -> AnyTransition {
        .asymmetric(insertion: .move(edge: edge).combined(with: .opacity).animation(enter),
                    removal: .opacity.animation(exit))
    }
}

/// Press feedback: wide buttons scale to 0.98, round icon buttons to 0.94. With Reduce Motion
/// the press dims instead of scaling.
struct OasesPressStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .opacity(reduceMotion && configuration.isPressed ? 0.7 : 1)
            .animation(configuration.isPressed ? OasesMotion.pressIn : OasesMotion.pressOut, value: configuration.isPressed)
    }
}
