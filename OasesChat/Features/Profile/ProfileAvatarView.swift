import SwiftUI

/// The user's avatar: their photo, or a generated one (a calm gradient picked from the UID with
/// the nickname's first letter, or the Oases mark when there is no nickname).
struct ProfileAvatarView: View {
    let image: UIImage?
    let nickname: String
    let uid: Int?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Self.gradient(for: uid)
                    if let initial {
                        Text(verbatim: initial)
                            .font(.system(size: side * 0.42, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                    } else {
                        TwinPoolsShape(fill: 0.5)
                            .fill(.white.opacity(0.92))
                            .frame(width: side, height: side)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var initial: String? {
        let t = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.first.map { String($0).uppercased() }
    }

    /// Greens and teals around the brand colour, stable for a UID.
    static func gradient(for uid: Int?) -> LinearGradient {
        let seed = Double(abs((uid ?? 7) &* 2_654_435_761) % 360)
        let hue = (140 + seed.truncatingRemainder(dividingBy: 60)) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.62, brightness: 0.62),
                     Color(hue: hue + 0.05, saturation: 0.42, brightness: 0.86)],
            startPoint: .bottomLeading, endPoint: .topTrailing
        )
    }
}
