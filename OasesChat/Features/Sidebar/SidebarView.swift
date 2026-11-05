import SwiftUI

struct SidebarView: View {
    @Binding var selectedMode: AppMode
    var recents: [RecentConversation]
    var onNewChat: () -> Void
    var onPickMode: (AppMode) -> Void
    var onSelectRecent: (RecentConversation) -> Void
    var onDeleteRecent: (RecentConversation) -> Void
    /// Opens Meeting Notes (recording and notes for in-person meetings).
    var onOpenMeetings: () -> Void = {}
    var onOpenSettings: () -> Void

    var body: some View {
        // Standard drawer pattern: the OUTER frame does NOT ignore safe area
        // (so the VStack content stays clear of the Dynamic Island /
        // status bar and home indicator), while the BACKGROUND extends
        // edge-to-edge underneath via `.background(...).ignoresSafeArea()`.
        // This is the layout convention every shipping iOS drawer uses —
        // `.safeAreaPadding` doesn't reliably pick up insets when an ancestor
        // already ignored them, which was the source of the Dynamic Island
        // clipping in the user's screenshot.
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.top, OasesSpacing.md)
                .padding(.horizontal, OasesSpacing.md)

            newChatButton
                .padding(.top, OasesSpacing.md)
                .padding(.horizontal, OasesSpacing.md)

            featuresSection
                .padding(.top, OasesSpacing.lg)
                .padding(.horizontal, OasesSpacing.md)

            // Recents are the only section that can overflow on long history,
            // so wrap them in a ScrollView. Without this the VStack would
            // stretch outside the parent and push the settings button below
            // the safe area (the bug in screenshot #3).
            //
            // 上下边缘做渐隐 mask：内容滚向"功能"区和底部"设置"按钮时
            // 逐渐淡出，而不是被硬边界切断。
            ScrollView {
                recentsSection
                    .padding(.top, OasesSpacing.lg)
                    .padding(.horizontal, OasesSpacing.md)
                    .padding(.bottom, OasesSpacing.md)
            }
            .scrollIndicators(.hidden)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: OasesSpacing.md)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: OasesSpacing.md)
                }
            }

            settingsButton
                .padding(.horizontal, OasesSpacing.md)
                .padding(.bottom, OasesSpacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OasesColor.sidebar.ignoresSafeArea())
    }

    // MARK: - Sections

    private var brandHeader: some View {
        HStack(spacing: OasesSpacing.xs) {
            MetallicGlyph(size: 28, variant: .sidebarBrand)

            Text("Oases")
                .font(.custom(OasesTypography.serifBold, size: 24, relativeTo: .title2))
                .foregroundStyle(OasesColor.foreground)

            Spacer(minLength: 0)
        }
    }

    private var newChatButton: some View {
        Button(action: onNewChat) {
            HStack(spacing: OasesSpacing.xs) {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                Text(SettingsCopy.t("新对话", "New Chat"))
                    .font(.oasesBody())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.vertical, OasesSpacing.sm)
            .foregroundStyle(OasesColor.foreground)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.pill, style: .continuous)
                    .fill(OasesColor.card.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.pill, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.xs) {
            Text(SettingsCopy.t("功能", "Features"))
                .font(.oasesCaptionBold())
                .foregroundStyle(OasesColor.mutedForeground)

            let columns = [GridItem(.flexible(), spacing: OasesSpacing.xs),
                           GridItem(.flexible(), spacing: OasesSpacing.xs)]
            LazyVGrid(columns: columns, spacing: OasesSpacing.xs) {
                ForEach(AppMode.allCases) { mode in
                    Button(action: { onPickMode(mode) }) {
                        VStack(spacing: 6) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .frame(width: 36, height: 36)
                                .allowsHitTesting(false)
                            Text(mode.featureLabel)
                                .font(.oasesCaptionBold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, OasesSpacing.md)
                        .foregroundStyle(
                            mode == selectedMode ? OasesColor.primary : OasesColor.foreground.opacity(0.8)
                        )
                        .background(
                            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                                .fill(OasesColor.card.opacity(mode == selectedMode ? 0.5 : 0.35))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                                .strokeBorder(
                                    mode == selectedMode ? OasesColor.primary : OasesColor.border.opacity(0.4),
                                    lineWidth: mode == selectedMode ? 1.2 : 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            meetingsTile
        }
    }

    /// Meeting Notes: full width under the mode grid (it is a tool, not a chat mode).
    private var meetingsTile: some View {
        Button(action: onOpenMeetings) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 28, height: 28)
                Text(SettingsCopy.t("会议纪要", "Meeting Notes"))
                    .font(.oasesCaptionBold())
                Spacer(minLength: 0)
                if MeetingRecorder.shared.state != .idle {
                    Circle()
                        .fill(OasesColor.destructive)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(Text(SettingsCopy.t("正在录音", "Recording")))
                }
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.vertical, OasesSpacing.sm)
            .foregroundStyle(OasesColor.foreground.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .fill(OasesColor.card.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("oases.sidebar.meetings")
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.xs) {
            Text(SettingsCopy.t("最近记录", "Recent"))
                .font(.oasesCaptionBold())
                .foregroundStyle(OasesColor.mutedForeground)

            if recents.isEmpty {
                Text(SettingsCopy.t("还没有对话", "No conversations yet"))
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.6))
                    .padding(.top, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(recents) { recent in
                        SwipeToDeleteRow(
                            onDelete: { onDeleteRecent(recent) },
                            onTap: { onSelectRecent(recent) }
                        ) {
                            HStack(spacing: OasesSpacing.xs) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OasesColor.mutedForeground)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(OasesColor.card.opacity(0.4)))

                                VStack(alignment: .leading, spacing: 0) {
                                    Text(ConversationTitleDisplay.text(recent.title))
                                        .font(.oasesBodyBold())
                                        .foregroundStyle(OasesColor.foreground)
                                        .lineLimit(1)
                                    Text(recent.modelLabel)
                                        .font(.oasesCaption())
                                        .foregroundStyle(OasesColor.mutedForeground)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
            Haptics.tap()
        } label: {
            HStack {
                Text("设置")
                    .font(.oasesBody())
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.vertical, OasesSpacing.sm)
            .foregroundStyle(OasesColor.foreground)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.pill, style: .continuous)
                    .fill(OasesColor.card.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.pill, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct RecentConversation: Identifiable, Hashable {
    let id: String
    let title: String
    let modelLabel: String
}

#Preview {
    SidebarView(
        selectedMode: .constant(.chat),
        recents: [
            RecentConversation(id: "1", title: "你好👋", modelLabel: "Oases Pro"), // i18n-ignore: preview sample
            RecentConversation(id: "2", title: "帮我写一封邮件", modelLabel: "Oases Chat"), // i18n-ignore: preview sample
        ],
        onNewChat: {},
        onPickMode: { _ in },
        onSelectRecent: { _ in },
        onDeleteRecent: { _ in },
        onOpenSettings: {}
    )
    .frame(maxWidth: 340)
    .preferredColorScheme(.dark)
    .environment(ThemeManager())
}
