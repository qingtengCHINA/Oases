import PhotosUI
import SwiftUI

/// The Profile page: the avatar (which melts into the Dynamic Island as you scroll), the
/// nickname and UID, the QingTeng account card, and links to the account, membership and usage.
/// Presented full screen from Settings — a sheet would never reach the island.
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountStore.self) private var account
    @ObservedObject private var membership = MembershipCenter.shared
    private let store = ProfileStore.shared

    @State private var baseline: CGFloat?
    @State private var scrolled: CGFloat = 0
    @State private var showEditor = false
    @State private var showMembership = false
    @State private var path = NavigationPath()

    static let avatarSide: CGFloat = 120
    private static let topGap: CGFloat = 16

    private enum Route: Hashable { case account, usage }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                let safeTop = geo.safeAreaInsets.top
                let island = IslandGeometry.resolve(width: geo.size.width, safeTop: safeTop,
                                                    isLandscape: geo.size.width > geo.size.height)
                let rest = CGPoint(x: geo.size.width / 2, y: safeTop + Self.topGap + Self.avatarSide / 2)
                let collapse = max(1, rest.y - (island.targetCenter?.y ?? safeTop / 2))
                let progress = scrolled / collapse
                ZStack(alignment: .top) {
                    OasesColor.background.ignoresSafeArea()
                    ScrollView {
                        ProfileContent(
                            uid: account.me?.uid,
                            isSignedIn: account.isSignedIn,
                            membershipTitle: membership.tier.title,
                            onEdit: { showEditor = true },
                            onAccount: { path.append(Route.account) },
                            onMembership: { showMembership = true },
                            onUsage: { path.append(Route.usage) }
                        )
                        .padding(.top, Self.topGap + Self.avatarSide + 20)
                        .frame(minHeight: geo.size.height + collapse, alignment: .top)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named("profile.scroll")).minY
                        } action: { minY in
                            if baseline == nil { baseline = minY }
                            scrolled = (baseline ?? minY) - minY
                        }
                    }
                    .coordinateSpace(name: "profile.scroll")
                    .scrollTargetBehavior(ProfileSnapBehavior(collapse: collapse))
                    .scrollIndicators(.hidden)

                    // The top edge firms up once the avatar is mostly gone.
                    ProgressiveBlur(edge: .top, progress: MetaballIslandHeader<EmptyView>.Motion.ramp(progress, [0.55, 1], [0, 1]))
                        .frame(height: safeTop + 28)
                        .ignoresSafeArea(edges: .top)
                        .frame(maxHeight: .infinity, alignment: .top)

                    MetaballIslandHeader(progress: progress, rest: rest, radius: Self.avatarSide / 2, island: island) {
                        ProfileAvatarView(image: store.avatar, nickname: store.nickname, uid: account.me?.uid)
                    }
                    .ignoresSafeArea()

                    closeButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 16)
                        .padding(.top, 4)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .account:
                    AccountView()
                        .environment(\.closeAccountPage, { path = NavigationPath() })
                case .usage:
                    UsageStatsView()
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditorSheet(uid: account.me?.uid)
        }
        .sheet(isPresented: $showMembership) {
            MembershipPaywallView()
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OasesColor.foreground)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "关闭", comment: "Profile: close the page")))
    }
}

/// Released between rest and fully merged, the page settles on the nearer of the two.
struct ProfileSnapBehavior: ScrollTargetBehavior {
    let collapse: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let y = target.rect.minY
        guard y > 0, y < collapse else { return }
        target.rect.origin.y = y < collapse / 2 ? 0 : collapse
    }
}

/// Everything below the avatar. Kept separate so scrolling (which re-renders the header) does not
/// rebuild it.
private struct ProfileContent: View {
    let uid: Int?
    let isSignedIn: Bool
    let membershipTitle: String
    let onEdit: () -> Void
    let onAccount: () -> Void
    let onMembership: () -> Void
    let onUsage: () -> Void

    private let store = ProfileStore.shared

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(verbatim: store.displayName)
                    .font(.oasesTitle())
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let uid {
                    Text(verbatim: QTCMe.formatUid(uid))
                        .font(.system(.footnote, design: .monospaced).weight(.medium))
                        .foregroundStyle(OasesColor.mutedForeground)
                } else if !isSignedIn {
                    Text(verbatim: QT("account.signedOut"))
                        .font(.footnote)
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                Button(action: onEdit) {
                    Text(String(localized: "编辑资料", comment: "Profile: edit the avatar and nickname"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OasesColor.foreground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(OasesColor.muted, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)

            if isSignedIn {
                AccountCardHeader(uid: uid)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                ProfileRow(title: QT("account.rowTitle"), systemImage: "person.text.rectangle", action: onAccount)
                Divider().padding(.leading, 52)
                ProfileRow(title: String(localized: "会员", comment: "Profile: membership row"), systemImage: "crown",
                           detail: membershipTitle, action: onMembership)
                Divider().padding(.leading, 52)
                ProfileRow(title: String(localized: "用量", comment: "Profile: usage statistics row"), systemImage: "chart.bar", action: onUsage)
            }
            .background(OasesColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5))
            .padding(.horizontal, 20)

            Text(String(localized: "头像和昵称只保存在这台设备上，不会上传。", comment: "Profile: footer explaining where the avatar and nickname are kept"))
                .font(.footnote)
                .foregroundStyle(OasesColor.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 40)
    }
}

private struct ProfileRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OasesColor.foreground.opacity(0.82))
                    .frame(width: 28, height: 28)
                    .background(OasesColor.muted.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(verbatim: title)
                    .foregroundStyle(OasesColor.foreground)
                Spacer(minLength: 8)
                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Change the avatar (from Photos, no library access needed) and the nickname.
private struct ProfileEditorSheet: View {
    let uid: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfileStore.shared.nickname
    @State private var pick: PhotosPickerItem?
    @State private var loading = false
    private let store = ProfileStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatarView(image: store.avatar, nickname: draft, uid: uid)
                            .frame(width: 96, height: 96)
                            .overlay {
                                if loading { ProgressView() }
                            }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(String(localized: "选择照片", comment: "Profile editor: pick an avatar photo"), systemImage: "photo")
                    }
                    if store.avatar != nil {
                        Button(role: .destructive) {
                            store.removeAvatar()
                        } label: {
                            Label(String(localized: "移除照片", comment: "Profile editor: go back to the generated avatar"), systemImage: "trash")
                        }
                    }
                }
                Section {
                    TextField(String(localized: "昵称", comment: "Profile editor: nickname field"), text: $draft)
                        .onChange(of: draft) { _, value in
                            if value.count > ProfileStore.nicknameLimit {
                                draft = String(value.prefix(ProfileStore.nicknameLimit))
                            }
                        }
                } footer: {
                    Text(String(localized: "头像和昵称只保存在这台设备上，不会上传。", comment: "Profile: footer explaining where the avatar and nickname are kept"))
                }
            }
            .navigationTitle(String(localized: "编辑资料", comment: "Profile: edit the avatar and nickname"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消", comment: "Profile editor: discard changes")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成", comment: "Profile editor: save changes")) {
                        store.nickname = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                loading = true
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    if let data, let image = UIImage(data: data) {
                        store.setAvatar(image)
                    }
                    loading = false
                    pick = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings' top row: avatar, nickname and UID, leading to the Profile page.
struct ProfileCardRow: View {
    let uid: Int?
    private let store = ProfileStore.shared

    var body: some View {
        HStack(spacing: 14) {
            ProfileAvatarView(image: store.avatar, nickname: store.nickname, uid: uid)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: store.displayName)
                    .font(.headline)
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(1)
                Text(String(localized: "个人资料", comment: "Settings: subtitle of the profile card"))
                    .font(.footnote)
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OasesColor.mutedForeground.opacity(0.6))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
