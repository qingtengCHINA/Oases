import SwiftUI

/// The Oases mark as a SwiftUI shape. The pool radii are animatable, so the mark can "pour" from
/// one pool into the other while the neck stays smooth (see `TwinPoolsGeometry`).
struct TwinPoolsShape: Shape {
    /// Radius of the upper-right pool, in the unit square.
    var upperRadius: CGFloat = TwinPoolsGeometry.bigRadius
    /// Radius of the lower-left pool, in the unit square.
    var lowerRadius: CGFloat = TwinPoolsGeometry.smallRadius
    /// How much of the frame the mark's bounds fill; nil keeps the logo's own placement (66 %,
    /// as on the app icon).
    var fill: CGFloat? = 0.84

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(upperRadius, lowerRadius) }
        set {
            upperRadius = newValue.first
            lowerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(TwinPoolsGeometry.path(
            upperRadius: upperRadius,
            lowerRadius: lowerRadius,
            transform: TwinPoolsGeometry.transform(fitting: rect, fill: fill)
        ))
    }
}

/// The app icon drawn in code (black mark on white; white on black in dark mode, like the
/// home-screen icon's dark appearance), for places that show "the icon" inside the app: About.
/// Matches `AppIcon.png`, which `scripts/brand/render_icons.sh` renders from the same geometry.
struct OasesAppIconTile: View {
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // iOS's icon mask is a continuous rounded rectangle with a radius of about 22.4 % of
        // the side.
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        let dark = colorScheme == .dark
        ZStack {
            (dark ? Color.black : Color.white)
            TwinPoolsShape(fill: nil)
                .fill(dark ? Color.white : Color.black)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// The Oases mark alone, no tile: the membership page's hero.
struct OasesMark: View {
    var size: CGFloat
    var color: Color = OasesColor.foreground

    var body: some View {
        TwinPoolsShape(fill: 1)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
