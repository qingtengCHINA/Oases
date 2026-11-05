import SwiftUI

struct SettingsMenuSheet: View {
    var onLanguage: () -> Void = {}
    var onHelp: () -> Void = {}
    var onPrivacy: () -> Void = {}
    var onContact: () -> Void = {}
    var onClearHistory: () -> Void = {}

    @Environment(ThemeManager.self) private var theme
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingsRow(icon: "globe", title: String(localized: "语言选择"), action: onLanguage)

            Button {
                theme.toggle()
                Haptics.select()
            } label: {
                HStack {
                    Image(systemName: theme.mode == .dark ? "moon.fill" : theme.mode == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .frame(width: 24)
                    Text("主题：\(theme.mode.label)")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OasesColor.mutedForeground.opacity(0.5))
                }
                .padding(.horizontal, OasesSpacing.md)
                .padding(.vertical, OasesSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().background(OasesColor.border.opacity(0.4)).padding(.vertical, 2)

            settingsRow(icon: "questionmark.circle", title: String(localized: "帮助"), action: onHelp)
            settingsRow(icon: "lock.shield", title: String(localized: "隐私声明"), action: onPrivacy)
            settingsRow(icon: "envelope", title: String(localized: "联系我们"), action: onContact)

            Divider().background(OasesColor.border.opacity(0.4)).padding(.vertical, 2)

            Button {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(OasesColor.destructive)
                        .frame(width: 24)
                    Text("清空记录")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.destructive)
                    Spacer()
                }
                .padding(.horizontal, OasesSpacing.md)
                .padding(.vertical, OasesSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog("确定要清空所有本地聊天记录吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) {
                    onClearHistory()
                    Haptics.warning()
                }
            }
        }
        .padding(.vertical, OasesSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                .fill(OasesColor.surfaceElevated.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func settingsRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(OasesColor.mutedForeground)
                    .frame(width: 24)
                Text(title)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.5))
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.vertical, OasesSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsMenuSheet()
        .padding()
        .background(OasesColor.background)
        .preferredColorScheme(.dark)
        .environment(ThemeManager())
}
