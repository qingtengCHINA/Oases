import BotAvatarsKit
import SwiftUI

/// Settings page for SOUL.md — Minis's persistent personality file.
/// Lives between Skills and Memory in the Agent Runtime section.
struct SoulSettingsView: View {
    /// SOUL.md was changed from the shell and waits for the user (`SoulStore` "Approved copy").
    @State private var hasUnapprovedChanges = false
    @State private var name: String = SoulMetadata.default.name
    /// Raw emoji value loaded from SOUL.md. Not user-editable; preserved
    /// verbatim on save so we don't rewrite a value the user (or another
    /// device) may have set in the file. UI always shows `displayEmoji`.
    @State private var rawEmoji: String = SoulMetadata.default.emoji
    @State private var style: String = SoulMetadata.default.style
    @State private var lang: String = SoulMetadata.default.lang
    @State private var bodyText: String = ""
    @State private var saveError: String? = nil
    @State private var didJustSave: Bool = false
    /// Pending avatar look (shape + colour, nil = 品牌默认), persisted on
    /// Save via `SoulStore.saveAvatarAppearance` and previewed live in the
    /// card above and the pickers below.
    @State private var avatarType: BotAvatarType = SoulStore.avatarAppearance.type
    @State private var avatarColorHex: String? = SoulStore.avatarAppearance.colorHex
    /// Appearance as last loaded / saved, for dirty tracking.
    @State private var savedAvatarAppearance: SoulAvatarAppearance = SoulStore.avatarAppearance
    /// Read so the preview avatar's brand colour re-resolves its dark
    /// variant on theme changes.
    @Environment(\.colorScheme) private var colorScheme
    @State private var showRestoreConfirm: Bool = false
    @StateObject private var loadedRef = LoadedFileRef()

    private static var langOptions: [(label: String, value: String)] {
        [
            (String(localized: "Auto"), "auto"),
            (String(localized: "Chinese"), "zh"),
            (String(localized: "English"), "en"),
        ]
    }

    var body: some View {
        Form {
            if hasUnapprovedChanges {
                Section {
                    Label {
                        Text(String(localized: "SOUL.md was changed outside Settings, for example by a command in Ogent. The change is not used until you accept it.", comment: "Soul settings: SOUL.md was edited from the shell and waits for approval"))
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    }
                    Button(String(localized: "Use This Version", comment: "Soul settings: accept the SOUL.md edited outside Settings")) {
                        SoulStore.approveCurrentFile()
                        reload()
                    }
                    Button(String(localized: "Keep the Previous Version", comment: "Soul settings: undo the SOUL.md edit made outside Settings"), role: .destructive) {
                        SoulStore.restoreApproved()
                        reload()
                    }
                }
            }

            Section {
                previewCard
            }

            Section(String(localized: "Identity")) {
                LabeledContent(String(localized: "Name")) {
                    TextField(OasesBrand.assistantFallbackName, text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                LabeledContent(String(localized: "Style")) {
                    TextField(String(localized: "e.g. Warm, direct, opinionated"), text: $style)
                        .multilineTextAlignment(.trailing)
                }
                Picker(String(localized: "Language"), selection: $lang) {
                    ForEach(Self.langOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
            }

            Section {
                avatarShapeGrid
                avatarColorSwatches
            } header: {
                Text(String(localized: "Avatar"))
            } footer: {
                Text(String(localized: "The assistant's look on every assistant message header."))
            }

            Section {
                personalityEditor
            } header: {
                Text(String(localized: "Personality Prompt"))
            } footer: {
                bodyLengthFooter
            }

            Section {
                Button(role: .destructive) {
                    showRestoreConfirm = true
                } label: {
                    Label(String(localized: "Restore Default"), systemImage: "arrow.uturn.backward")
                }
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(localized: "Soul"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "Save")) { save() }
                    .disabled(!isDirty || isBodyOverLimit)
            }
        }
        .onAppear(perform: reload)
        // Using .alert (not .confirmationDialog) so the dialog stays
        // centered on iPad / Mac. confirmationDialog without a source
        // rect renders as a popover anchored to the screen's top edge
        // on regular-width size classes.
        .alert(
            String(localized: "Restore Default"),
            isPresented: $showRestoreConfirm
        ) {
            Button(String(localized: "Restore Default"), role: .destructive, action: restoreDefault)
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Restore default SOUL.md? Your current personality will be replaced."))
        }
        .overlay(alignment: .bottom) {
            if didJustSave {
                Text(String(localized: "Saved"))
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.green.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Subviews

    // Standard Form row — the insetGrouped section provides the rounded
    // card chrome automatically, so we only render content here. Matches
    // the visual width of every other section on the page.
    private var previewCard: some View {
        HStack(alignment: .center, spacing: 12) {
            // Header preview mirrors the real assistant header: the pending
            // shape + colour selection (idle state), so the pickers below
            // are what-you-see-is-what-you-get.
            BotAvatar(
                type: avatarType,
                state: .default,
                size: 32,
                color: pendingAvatarBotColor
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? OasesBrand.assistantFallbackName : name)
                    .font(.title3.weight(.semibold))
                if !style.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(style)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Avatar pickers

    /// Colour used by every live preview on this page: the pending swatch,
    /// or the brand colour when "品牌默认" is picked.
    private var pendingAvatarBotColor: BotColor {
        _ = colorScheme
        return SoulStore.botColor(for: SoulAvatarAppearance(type: avatarType, colorHex: avatarColorHex))
    }

    /// Shape picker: every cell renders a live BotAvatar of that type in
    /// the pending colour — tap to select, selected cell gets a brand-tinted
    /// highlight. Laid out as plain HStack rows (not LazyVGrid) because a
    /// Form section gives only the row's width; 6 columns × 3 rows covers
    /// all eighteen types.
    private var avatarShapeGrid: some View {
        let columns = 6
        let types = BotAvatarType.allCases
        return VStack(spacing: 8) {
            ForEach(0..<(types.count + columns - 1) / columns, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < types.count {
                            avatarShapeCell(types[index])
                        } else {
                            Color.clear.frame(width: 48, height: 48)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func avatarShapeCell(_ type: BotAvatarType) -> some View {
        let selected = type == avatarType
        return BotAvatar(
            type: type,
            state: .default,
            size: 40,
            color: pendingAvatarBotColor
        )
        .padding(4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OasesColor.primary.opacity(0.15))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? OasesColor.primary : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { avatarType = type }
        .accessibilityLabel(type.preset.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Colour swatches: "品牌默认" tracks OasesColor.primary (sparkle mark,
    /// echoing the fixed displayEmoji), then eight colours taken verbatim
    /// from BotAvatarsKit's `botAvatarPresets` palette — each is one body
    /// shape's own tuned colour, so every swatch is a colour the renderer
    /// is calibrated for.
    private static let avatarColorOptions: [String] = [
        "#FF7AB8", // flower pink
        "#FF7F6E", // puddle coral
        "#FF8C42", // hexagon orange
        "#FFD32B", // star yellow
        "#2FCB7A", // blob green
        "#1ED3C6", // drop teal
        "#35B8FF", // clover blue
        "#9A62FF", // circle violet
    ]

    private var avatarColorSwatches: some View {
        // 9 × 28pt + 8 × 8pt = 316pt — fits the insetGrouped content width
        // (≈335pt on the narrowest supported phone).
        HStack(spacing: 8) {
            brandDefaultSwatch
            ForEach(Self.avatarColorOptions, id: \.self) { hex in
                avatarColorSwatch(hex: hex)
            }
        }
        .padding(.vertical, 6)
    }

    private var brandDefaultSwatch: some View {
        let selected = avatarColorHex == nil
        return ZStack {
            Circle()
                .fill(OasesColor.primary)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .overlay {
            Circle()
                .stroke(Color.primary, lineWidth: selected ? 2.5 : 0)
        }
        .scaleEffect(selected ? 1.12 : 1)
        .onTapGesture { avatarColorHex = nil }
        .accessibilityLabel(String(localized: "Brand default"))
    }

    private func avatarColorSwatch(hex: String) -> some View {
        let selected = avatarColorHex == hex
        return Circle()
            .fill(BotColor(hex)?.color ?? .gray)
            .frame(width: 28, height: 28)
            .overlay {
                Circle()
                    .stroke(Color.primary, lineWidth: selected ? 2.5 : 0)
            }
            .scaleEffect(selected ? 1.12 : 1)
            .onTapGesture { avatarColorHex = hex }
            .accessibilityLabel(hex)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var personalityEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $bodyText)
                .frame(minHeight: 220)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
            // SwiftUI's TextEditor has no native placeholder. We render
            // a greyed hint on top when the body is empty + not being
            // typed into. allowsHitTesting(false) so taps fall through
            // to the editor below.
            if bodyText.isEmpty {
                Text(String(localized: "Describe the personality and voice you want for your agent"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Footer under the personality editor. Renders a green count when the
    /// body is within budget and a red over-limit message when it isn't.
    /// Save is disabled in the over-limit branch.
    private var bodyLengthFooter: some View {
        let check = SoulStore.isOverLimit(bodyText)
        return HStack(spacing: 6) {
            if check.isOverLimit {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            switch check {
            case .ok:
                Text(soulBodyCountText(bodyText))
                    .foregroundStyle(.secondary)
            case .overLimit(let count, let cap):
                Text(String(localized: "Over limit: \(count) / \(cap) tokens. Each CJK character and each Latin word counts as one."))
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
    }

    /// Counter shown when the body is within budget.
    private func soulBodyCountText(_ body: String) -> String {
        let count = SoulStore.tokenCount(body)
        return String(localized: "\(count) / \(SoulStore.bodyTokenLimit) tokens")
    }

    private var isBodyOverLimit: Bool {
        SoulStore.isOverLimit(bodyText).isOverLimit
    }

    // MARK: - Persistence

    private var currentFile: SoulFile {
        SoulFile(
            metadata: SoulMetadata(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                // Round-trip the on-disk emoji untouched — UI no longer
                // edits this field, but a SOUL.md authored elsewhere
                // (other device / hand-edit) should not have its emoji
                // rewritten on save.
                emoji: rawEmoji,
                style: style,
                lang: lang
            ),
            body: bodyText
        )
    }

    private var isDirty: Bool {
        currentFile != loadedRef.value
            || avatarType != savedAvatarAppearance.type
            || avatarColorHex != savedAvatarAppearance.colorHex
    }

    private func reload() {
        hasUnapprovedChanges = SoulStore.hasUnapprovedChanges
        let file = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        name = file.metadata.name
        rawEmoji = file.metadata.emoji
        style = file.metadata.style
        lang = file.metadata.lang
        bodyText = file.body
        loadedRef.value = file
        let appearance = SoulStore.avatarAppearance
        avatarType = appearance.type
        avatarColorHex = appearance.colorHex
        savedAvatarAppearance = appearance
        saveError = nil
    }

    private func save() {
        do {
            let f = currentFile
            try SoulStore.save(f)
            hasUnapprovedChanges = false
            // Persist the picked look and broadcast `.soulAvatarChanged` so
            // every assistant header updates immediately.
            SoulStore.saveAvatarAppearance(SoulAvatarAppearance(type: avatarType, colorHex: avatarColorHex))
            savedAvatarAppearance = SoulStore.avatarAppearance
            loadedRef.value = f
            saveError = nil
            withAnimation { didJustSave = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { didJustSave = false }
            }
        } catch {
            saveError = String(localized: "Save failed: \(error.localizedDescription)")
        }
    }

    private func restoreDefault() {
        let parsed = SoulMDParser.parse(SoulStore.defaultContent)
        name = parsed.metadata.name
        rawEmoji = parsed.metadata.emoji
        style = parsed.metadata.style
        lang = parsed.metadata.lang
        // "Restore Default" covers the whole Soul page, including the
        // picked look — reset it to clover + brand colour as well.
        avatarType = SoulAvatarAppearance.default.type
        avatarColorHex = SoulAvatarAppearance.default.colorHex
        bodyText = parsed.body
        save()
    }

    private final class LoadedFileRef: ObservableObject {
        var value: SoulFile = SoulFile(metadata: .default, body: "")
    }
}
