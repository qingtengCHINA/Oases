import SwiftUI

/// "用 GitHub 登录" / "绑定 GitHub" and the Microsoft ones, in the shared
/// QingTeng look (词忆 → K线艺术家 → PlusProMax → Stars): GitHub is its dark grey
/// with the white Invertocat, Microsoft is white with the four-square logo and
/// a light grey edge. The account pages' corner radius, as tall as the Apple
/// button next to it. A spinner replaces the logo while busy.
struct ProviderButton: View {
    private let provider: OAuthProvider
    private let title: String
    private let height: CGFloat
    private let busy: Bool
    private let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(_ provider: OAuthProvider, title: String, height: CGFloat, busy: Bool, action: @escaping () -> Void) {
        self.provider = provider
        self.title = title
        self.height = height
        self.busy = busy
        self.action = action
    }

    var body: some View {
        let isGitHub = provider == .github
        let foreground: Color = isGitHub ? .white : Color(red: 0.2, green: 0.2, blue: 0.2)
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .tint(foreground)
                } else if isGitHub {
                    GitHubMark()
                        .fill(foreground)
                        .frame(width: 18, height: 18)
                } else {
                    MicrosoftLogo()
                        .frame(width: 18, height: 18)
                }
                Text(title)
                    .font(AccountStyle.font(17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(AccountStyle.shape.fill(isGitHub ? SignInMethodIcon.gitHubFill : Color.white))
            .overlay(AccountStyle.shape.strokeBorder(borderColor(isGitHub: isGitHub), lineWidth: 1))
            .contentShape(AccountStyle.shape)
        }
        .buttonStyle(AccountPressStyle())
    }

    /// Microsoft's white button needs a light grey edge; GitHub's dark one
    /// only in dark mode, where it would melt into the background.
    private func borderColor(isGitHub: Bool) -> Color {
        if !isGitHub { return Color(red: 0.55, green: 0.55, blue: 0.55).opacity(0.8) }
        return colorScheme == .dark ? Color.white.opacity(0.4) : .clear
    }
}
