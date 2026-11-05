import SwiftUI

struct ModelPickerSheet: View {
    let options: [Models.Option]
    @Binding var selectedId: String
    @Binding var effort: Models.Effort
    var onPick: (Models.Option) -> Void
    var onPickEffort: (Models.Effort) -> Void = { _ in }

    @State private var showEffortPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("切换模型")
                    .font(.custom(OasesTypography.serifBold, size: 20, relativeTo: .title3))
                    .foregroundStyle(OasesColor.foreground)
                Spacer()
            }
            .padding(.bottom, OasesSpacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: OasesSpacing.xs) {
                    ForEach(stableOptions) { option in
                        modelRow(option: option)
                    }
                    if !customOptions.isEmpty {
                        Text("我的供应商")
                            .font(.oasesCaption())
                            .foregroundStyle(OasesColor.mutedForeground)
                            .padding(.top, OasesSpacing.sm)
                            .padding(.bottom, 2)
                        ForEach(customOptions) { option in
                            modelRow(option: option)
                        }
                    }
                    if !betaOptions.isEmpty {
                        Text("Oases 尝鲜模型")
                            .font(.oasesCaption())
                            .foregroundStyle(OasesColor.mutedForeground)
                            .padding(.top, OasesSpacing.sm)
                            .padding(.bottom, 2)
                        ForEach(betaOptions) { option in
                            modelRow(option: option)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
                .background(OasesColor.border.opacity(0.6))
                .padding(.vertical, OasesSpacing.sm)

            if selectedOption?.supportsEffort == true {
                effortRow
            }
        }
        .padding(OasesSpacing.md)
    }

    private var selectedOption: Models.Option? {
        options.first(where: { $0.id == selectedId })
    }

    private var oasesOptions: [Models.Option] {
        options.filter { !ProviderChatRouting.isEntryId($0.id) && !$0.isBeta }
    }

    private var customOptions: [Models.Option] {
        options.filter { ProviderChatRouting.isEntryId($0.id) }
    }

    private var stableOptions: [Models.Option] {
        oasesOptions
    }

    private var betaOptions: [Models.Option] {
        options.filter { $0.isBeta && !ProviderChatRouting.isEntryId($0.id) }
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(option: Models.Option) -> some View {
        Button { onPick(option) } label: {
            HStack(alignment: .center, spacing: OasesSpacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.custom(OasesTypography.serifBold, size: 17, relativeTo: .headline))
                            .foregroundStyle(OasesColor.foreground)
                        if option.isBeta {
                            Text("Beta")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OasesColor.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OasesColor.primary.opacity(0.12), in: Capsule())
                        }
                        if option.isPromoFree {
                            PromoFreeBadge()
                        }
                        if option.supportsImageInput, option.category == .text || option.category == .project {
                            Text("多模态")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OasesColor.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OasesColor.muted.opacity(0.7), in: Capsule())
                        }
                    }
                    Text(option.descriptionText)
                        .font(.oasesCallout())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: OasesSpacing.sm)
                if option.id == selectedId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(OasesColor.primary)
                }
            }
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .fill(option.id == selectedId ? OasesColor.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .strokeBorder(
                        option.id == selectedId ? OasesColor.primary.opacity(0.3) : OasesColor.border.opacity(0.2),
                        lineWidth: option.id == selectedId ? 1 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Effort Row

    private var effortRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showEffortPicker.toggle() }
        } label: {
            VStack(spacing: 0) {
                HStack {
                    Text("模型强度")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                    Spacer()
                    Text(effort.label)
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OasesColor.mutedForeground.opacity(0.5))
                        .rotationEffect(.degrees(showEffortPicker ? 90 : 0))
                }
                .padding(.vertical, OasesSpacing.xs)
                .contentShape(Rectangle())

                if showEffortPicker {
                    HStack(spacing: OasesSpacing.xs) {
                        ForEach(Models.Effort.allCases) { level in
                            Button {
                                onPickEffort(level)
                            } label: {
                                Text(level.label)
                                    .font(.oasesBody())
                                    .foregroundStyle(level == effort ? OasesColor.primary : OasesColor.foreground.opacity(0.8))
                                    .padding(.horizontal, OasesSpacing.md)
                                    .padding(.vertical, OasesSpacing.xs)
                                    .background(
                                        Capsule()
                                            .fill(level == effort ? OasesColor.primary.opacity(0.12) : OasesColor.card.opacity(0.4))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                level == effort ? OasesColor.primary : OasesColor.border.opacity(0.3),
                                                lineWidth: level == effort ? 1 : 0.5
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.top, OasesSpacing.xs)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .buttonStyle(.plain)
    }

}

#Preview {
    ModelPickerSheet(
        options: Models.chat,
        selectedId: .constant(Models.defaultChat),
        effort: .constant(.high),
        onPick: { _ in }
    )
    .padding()
    .background(OasesColor.background)
    .preferredColorScheme(.dark)
}
