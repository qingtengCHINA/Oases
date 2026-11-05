import SwiftUI

/// Top toolbar matching Web's mobile header — 2 left icons + 2 right icons,
/// transparent over the chat background.
struct TopBar: View {
    var onMenu: () -> Void = {}
    var onSearch: () -> Void = {}
    var onTheme: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Web `<header className="mobile-safe-shell ... px-3 pb-3">`: two icon
        // groups (menu + search / file + theme) flanking a flexible gap.
        HStack(spacing: 6) {
            iconButton(systemName: "line.3.horizontal", action: onMenu, label: String(localized: "打开侧栏"))
            iconButton(systemName: "magnifyingglass", action: onSearch, label: String(localized: "搜索"))
            Spacer()
            // The icon names what a tap switches to, relative to what is shown now.
            iconButton(
                systemName: colorScheme == .dark ? "sun.max" : "moon",
                action: onTheme,
                label: colorScheme == .dark ? String(localized: "切换到浅色") : String(localized: "切换到深色")
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func iconButton(systemName: String, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(OasesColor.mutedForeground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
