import SwiftUI

/// Pulling past the newest message starts a new conversation. It is meant to
/// be hard to do by accident: the pull is long, and once it is full it has to
/// be held for a moment (a haptic says it is armed) before letting go counts.
enum NewChatPull {
    /// Overscroll, in points, that fills the ring.
    static let distance: CGFloat = 240
    /// Overscroll before anything is shown.
    static let showAt: CGFloat = 110
    /// How long a full pull has to be held before release starts a chat.
    static let hold: TimeInterval = 0.4

    static func progress(_ pull: CGFloat) -> CGFloat {
        min(1, max(0, (pull - showAt) / (distance - showAt)))
    }
}

/// The ring under the last message while pulling for a new chat.
struct NewChatPullIndicator: View {
    var progress: CGFloat
    /// Held long enough: letting go now starts a new chat.
    var armed: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(OasesColor.mutedForeground.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(armed ? OasesColor.primary : OasesColor.mutedForeground,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: armed ? "square.and.pencil" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(armed ? OasesColor.primary : OasesColor.mutedForeground)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 42, height: 42)
            .scaleEffect(armed ? 1.08 : 1)
            Text(armed
                 ? String(localized: "松手开始新对话", comment: "Pull for a new chat: the pull is armed, release starts a new conversation")
                 : (progress >= 1
                    ? String(localized: "再停一下", comment: "Pull for a new chat: the ring is full, hold a moment longer to arm it")
                    : String(localized: "继续上拉开始新对话", comment: "Pull for a new chat: keep pulling up")))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(armed ? OasesColor.foreground : OasesColor.mutedForeground)
        }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: armed)
        .accessibilityHidden(true)
    }
}
