import SwiftUI

// Oases settings building blocks: rows grouped on soft cards, plain line icons (no tinted
// tiles), and a navigation bar that lets content blur away underneath it.

/// A titled card of rows. Rows are separated by hairlines that start after the icon.
struct SettingsCardGroup<Rows: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(SettingsDividedLayout()) {
                    rows()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(OasesColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
            )
            if let footer {
                Text(footer)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Puts a hairline between the card's rows.
private struct SettingsDividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle()
                    .fill(OasesColor.border.opacity(0.55))
                    .frame(height: 0.5)
                    .padding(.leading, 52)
            }
        }
    }
}

/// One row's content: icon, title, optional detail, chevron.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var tint: Color = OasesColor.foreground
    var showsChevron = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 24)
            Text(title)
                .font(.oasesBody())
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// A row that pushes `route`.
struct SettingsNavRow: View {
    let route: SettingsRoute
    let title: String
    let systemImage: String
    var detail: String? = nil

    var body: some View {
        NavigationLink(value: route) {
            SettingsRowLabel(title: title, systemImage: systemImage, detail: detail)
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// A row that runs an action.
struct SettingsActionRow: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var role: ButtonRole? = nil
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            SettingsRowLabel(
                title: title,
                systemImage: systemImage,
                detail: detail,
                tint: role == .destructive ? OasesColor.destructive : OasesColor.foreground,
                showsChevron: showsChevron
            )
        }
        .buttonStyle(SettingsRowButtonStyle())
    }
}

/// Rows highlight while pressed (they don't scale).
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(OasesColor.foreground.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.2), value: configuration.isPressed)
    }
}

/// The settings pages' bar: transparent, with content blurring progressively as it scrolls
/// under it (no hard bar edge). Apply to each page inside the settings NavigationStack —
/// the blur sits above the page's content but below the bar's own title and buttons.
struct SettingsPageChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // One page colour for every settings page (lists keep their own row cards).
            .scrollContentBackground(.hidden)
            .background(OasesColor.background.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                ProgressiveBlur(edge: .top)
                    .frame(height: 28)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func settingsPageChrome() -> some View { modifier(SettingsPageChrome()) }
}
