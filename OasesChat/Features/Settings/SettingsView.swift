import SwiftUI
import SwiftData

/// Unified Oases settings root.
///
/// The first level holds what people change from day to day (profile, membership, default
/// model, appearance, sound, persona, memory, usage, alarms, privacy, about). Everything for
/// builders — providers, model groups, skills, MCP, the Ogent runtime and its files,
/// permissions, logs — lives one level down under 高级, so it is on level three or four.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AccountStore.self) private var account

    /// When true, show the engineering-host action that returns to chat/voice/image.
    var showsExitEngineeringMode: Bool = false
    var onClearHistory: () -> Void = {}

    @State private var path = NavigationPath()
    @State private var showClearConfirm = false
    @State private var isClearing = false
    @State private var clearReport: DataEraser.Report?
    @State private var showFeedbackDialog = false
    @State private var showTerminal = false
    @State private var showMembership = false
    @State private var showProfile = false
    @ObservedObject private var membership = MembershipCenter.shared

    @ObservedObject private var deepLink = DeepLinkCoordinator.shared

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 22) {
                    profileCard
                    everydayGroup
                    privacyGroup
                    if showsExitEngineeringMode {
                        SettingsCardGroup(title: SettingsCopy.t("模式", "Oases Modes")) {
                            SettingsActionRow(title: SettingsCopy.t("退出工程模式", "Exit Engineering Mode"), systemImage: "arrow.uturn.backward") {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    NotificationCenter.default.post(name: .oasesExitEngineeringMode, object: nil)
                                }
                            }
                        }
                    }
                    SettingsCardGroup(footer: String(localized: "供应商与模型分组、技能、MCP、Ogent 运行时与文件、权限、日志。", comment: "Settings: what the Advanced page holds")) {
                        SettingsNavRow(route: .advanced, title: String(localized: "高级", comment: "Settings: the Advanced page"), systemImage: "slider.horizontal.below.square.and.square.filled")
                    }
                    aboutGroup
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(OasesColor.background.ignoresSafeArea())
            .settingsPageChrome()
            .navigationTitle(SettingsCopy.t("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(SettingsCopy.t("完成", "Done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
            }
            .onAppear {
                consumePendingDeepLink()
                consumeLanguageReopen()
            }
            .onChange(of: deepLink.pendingSettingsTarget) { _, _ in
                consumePendingDeepLink()
            }
            .alert(SettingsCopy.t("反馈", "Feedback"), isPresented: $showFeedbackDialog) {
                Button(SettingsCopy.t("前往 QingTeng Studio", "Open QingTeng Studio")) {
                    UIApplication.shared.open(OasesBrand.issuesNewURL)
                }
                Button(SettingsCopy.t("邮件反馈", "Feedback (Email)")) {
                    if let url = feedbackMailtoURL { UIApplication.shared.open(url) }
                }
                Button(SettingsCopy.t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(SettingsCopy.t("选择一种方式把问题发给我们。", "Choose how to send feedback."))
            }
            .fullScreenCover(isPresented: $showProfile) {
                ProfileView()
                    .environment(account)
                    .preferredColorScheme(theme.colorScheme)
            }
            .sheet(isPresented: $showMembership) {
                MembershipPaywallView()
                    .preferredColorScheme(theme.colorScheme)
            }
            .sheet(isPresented: $showTerminal) {
                NavigationStack {
                    ISHTerminalView(showCloseButton: true)
                }
            }
            .alert(
                SettingsCopy.t("清除全部对话？", "Clear all conversations?"),
                isPresented: $showClearConfirm
            ) {
                Button(SettingsCopy.t("清除对话", "Clear Conversations"), role: .destructive) {
                    clearAllConversations()
                }
                Button(SettingsCopy.t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(SettingsCopy.t(
                    "会清除这台设备上的全部对话和会话文件，以及内置浏览器的历史、标签页和网站数据（含 Cookie）。你在内置浏览器里登录过的网站都会退出登录。此操作无法撤销。",
                    "This removes every conversation and its session files on this device, plus the built-in browser's history, tabs and website data (including cookies). You'll be signed out of every website you signed in to in the built-in browser. It cannot be undone."
                ))
            }
            .alert(
                SettingsCopy.t("已清除", "Cleared"),
                isPresented: Binding(
                    get: { clearReport != nil },
                    set: { if !$0 { clearReport = nil } }
                ),
                presenting: clearReport
            ) { _ in
                Button(SettingsCopy.t("好", "OK"), role: .cancel) {}
            } message: { report in
                Text(SettingsCopy.t(
                    "已清除 \(report.conversations) 个对话和 \(report.sessions) 个 Ogent 会话。",
                    "Removed \(report.conversations) conversations and \(report.sessions) Ogent sessions."
                ))
            }
        }
    }

    // MARK: - Groups

    /// The profile card on its own card: opens the Profile page full screen (the avatar there
    /// reaches into the Dynamic Island, which a sheet can't).
    private var profileCard: some View {
        Button {
            Haptics.tap()
            showProfile = true
        } label: {
            ProfileCardRow(uid: account.me?.uid)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(OasesColor.card))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5))
        .accessibilityIdentifier("oases.settings.profile")
    }

    /// What people change from day to day.
    private var everydayGroup: some View {
        SettingsCardGroup(title: String(localized: "常用", comment: "Settings: section of everyday settings")) {
            SettingsActionRow(
                title: SettingsCopy.t("会员", "Membership"),
                systemImage: "crown",
                detail: membership.tier.title
            ) {
                membership.pendingReason = nil
                membership.suggestedTier = membership.tier == .ultra ? .ultra : .pro
                showMembership = true
            }
            SettingsNavRow(route: .modelPrefs, title: SettingsCopy.t("默认模型", "Default Models"), systemImage: "cpu")
            SettingsNavRow(route: .appearance, title: SettingsCopy.t("外观", "Appearance"), systemImage: "circle.lefthalf.filled")
            SettingsNavRow(route: .soundsHaptics, title: SettingsCopy.t("声音与触感", "Sounds & Haptics"), systemImage: "speaker.wave.2")
            SettingsNavRow(route: .soul, title: SettingsCopy.t("人格", "Soul"), systemImage: "person.crop.circle")
            SettingsNavRow(route: .memory, title: SettingsCopy.t("记忆", "Memory"), systemImage: "text.book.closed")
            SettingsNavRow(route: .usage, title: SettingsCopy.t("用量", "Usage"), systemImage: "chart.bar")
            SettingsNavRow(route: .alarms, title: SettingsCopy.t("闹钟", "Alarms"), systemImage: "alarm")
        }
    }

    private var privacyGroup: some View {
        SettingsCardGroup(title: String(localized: "账号与隐私", comment: "Settings: section of account, privacy and security")) {
            SettingsNavRow(
                route: .qingTengAccount,
                title: QT("account.rowTitle"),
                systemImage: "person.badge.key",
                detail: account.me?.uid.map { QTCMe.formatUid($0) } ?? (account.isSignedIn ? nil : QT("account.signedOut"))
            )
            .accessibilityIdentifier("oases.settings.qingteng-account")
            if BiometricAuth.isAvailable {
                SettingsNavRow(
                    route: .faceID,
                    title: SettingsCopy.t("\(BiometricAuth.biometryDisplayName) 保护", "\(BiometricAuth.biometryDisplayName) Protection"),
                    systemImage: BiometricAuth.biometryIconName
                )
            }
            SettingsNavRow(route: .dataPrivacy, title: SettingsCopy.t("数据与隐私", "Data & Privacy"), systemImage: "hand.raised")
        }
    }

    private var aboutGroup: some View {
        SettingsCardGroup(title: SettingsCopy.t("关于", "About"), footer: SettingsCopy.t("版本", "Version") + " " + appVersion) {
            SettingsNavRow(route: .about, title: SettingsCopy.t("关于 Oases Chat", "About Oases Chat"), systemImage: "info.circle")
            SettingsActionRow(title: SettingsCopy.t("反馈", "Feedback"), systemImage: "envelope") {
                showFeedbackDialog = true
            }
            SettingsActionRow(title: SettingsCopy.t("隐私政策", "Privacy Policy"), systemImage: "doc.text", showsChevron: false) {
                UIApplication.shared.open(OasesBrand.privacyPolicyURL)
            }
            SettingsActionRow(title: SettingsCopy.t("用户协议", "Terms of Use"), systemImage: "signature", showsChevron: false) {
                UIApplication.shared.open(OasesBrand.termsOfUseURL)
            }
        }
    }

    /// Level two: everything for builders.
    private var advancedPage: some View {
        ScrollView {
            VStack(spacing: 22) {
                SettingsCardGroup(
                    title: SettingsCopy.t("模型", "LLM Providers"),
                    footer: SettingsCopy.t(
                        "Ogent 开箱即可使用内置的 Oases 系统模型，不必先配置供应商。只有在你要使用自己的 API Key、OAuth 账号或本地模型时，才需要添加供应商。",
                        "Ogent works out of the box with the built-in Oases system model — no provider setup required. Add custom providers only if you want your own API keys, OAuth accounts, or local model endpoints."
                    )
                ) {
                    SettingsNavRow(route: .providers, title: SettingsCopy.t("管理供应商", "Manage Providers"), systemImage: "key.horizontal")
                    SettingsNavRow(route: .modelGroups, title: SettingsCopy.t("模型分组", "Model Groups"), systemImage: "square.grid.2x2")
                }
                SettingsCardGroup(title: SettingsCopy.t("Ogent 工程", "Agent Runtime")) {
                    SettingsNavRow(route: .skills, title: SettingsCopy.t("技能", "Skills"), systemImage: "wand.and.stars")
                    SettingsNavRow(route: .mcp, title: SettingsCopy.t("MCP 集成", "MCP Integrations"), systemImage: "point.3.connected.trianglepath.dotted")
                    SettingsNavRow(route: .environments, title: SettingsCopy.t("环境变量", "Environment Variables"), systemImage: "switch.2")
                    SettingsNavRow(route: .agent, title: SettingsCopy.t("\(OasesBrand.engineeringName) 运行时", OasesBrand.runtimeSettingsTitle), systemImage: "gearshape.2")
                }
                SettingsCardGroup(
                    title: SettingsCopy.t("设备内 Linux", "On-Device Linux"),
                    footer: SettingsCopy.t(
                        "\(OasesBrand.engineeringName) 用来跑命令、根文件系统和本地运行时的 iSH 工作区。",
                        "iSH workspace used by \(OasesBrand.engineeringName) for shell tools, rootfs, and local runtimes."
                    )
                ) {
                    SettingsNavRow(route: .rootfs, title: SettingsCopy.t("根文件系统", "Rootfs"), systemImage: "shippingbox")
                    SettingsActionRow(title: SettingsCopy.t("终端", "Terminal"), systemImage: "apple.terminal") {
                        showTerminal = true
                    }
                    SettingsNavRow(route: .storage, title: SettingsCopy.t("存储", "Storage"), systemImage: "internaldrive")
                    SettingsNavRow(route: .sharedFolders, title: SettingsCopy.t("共享文件夹", "Shared Folders"), systemImage: "folder")
                    SettingsNavRow(route: .mountedFolders, title: SettingsCopy.t("挂载外部文件夹", "Mount External Folders"), systemImage: "arrow.down.doc")
                }
                SettingsCardGroup(title: SettingsCopy.t("权限", "Permissions")) {
                    SettingsNavRow(route: .permissions, title: SettingsCopy.t("权限", "Permissions"), systemImage: "checkerboard.shield")
                    SettingsNavRow(route: .automation, title: SettingsCopy.t("自动化", "Automation"), systemImage: "clock.arrow.2.circlepath")
                }
                SettingsCardGroup(
                    title: SettingsCopy.t("数据", "Data"),
                    footer: SettingsCopy.t(
                        "会同时清除这台设备上的文本、音频、图像对话，Ogent 工程会话及其文件，以及内置浏览器的历史、标签页和网站数据，并退出你在内置浏览器里登录的网站。",
                        "Clears text, voice, and image chats on this device, Ogent engineering sessions and their files, and the built-in browser's history, tabs and website data — which signs you out of websites in the built-in browser."
                    )
                ) {
                    SettingsNavRow(route: .logs, title: SettingsCopy.t("日志", "Logs"), systemImage: "list.bullet.rectangle")
                    SettingsActionRow(
                        title: SettingsCopy.t("清除全部对话", "Clear Chat Conversations"),
                        systemImage: "trash",
                        role: .destructive,
                        showsChevron: false
                    ) {
                        showClearConfirm = true
                    }
                    .disabled(isClearing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(OasesColor.background.ignoresSafeArea())
        .navigationTitle(String(localized: "高级", comment: "Settings: the Advanced page"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Destinations

    private func destination(for route: SettingsRoute) -> some View {
        destinationContent(for: route)
            .settingsPageChrome()
    }

    @ViewBuilder
    private func destinationContent(for route: SettingsRoute) -> some View {
        switch route {
        case .advanced:
            advancedPage
        case .providers:
            ProviderInstancesView()
        case .modelGroups:
            ModelGroupsView()
        case .modelPrefs:
            ModelPrefsView()
        case .usage:
            UsageStatsView()
        case .appearance:
            EngineeringAppearanceSettingsView()
        case .soundsHaptics:
            SoundsHapticsSettingsView()
        case .skills:
            SkillsManagementView()
        case .soul:
            SoulSettingsView()
        case .memory:
            MemoryManagementView()
        case .mcp:
            MCPIntegrationsView()
        case .environments:
            EnvironmentVariablesView()
        case .agent:
            AgentSettingsView()
        case .rootfs:
            RootfsManagementView()
        case .storage:
            StorageManagementView()
        case .sharedFolders:
            SharedFoldersSettingsView()
        case .mountedFolders:
            MountedFoldersSettingsView()
        case .permissions:
            OffloadPermissionSettingsView()
        case .automation:
            AutomationPermissionSettingsView()
        case .faceID:
            FaceIDProtectionSettingsView()
        case .logs:
            LogManagementView(initialTab: deepLink.pendingLogsTab ?? "logs")
                .onAppear { deepLink.pendingLogsTab = nil }
        case .dataPrivacy:
            DataPrivacyView()
        case .about:
            AboutView()
        case .alarms:
            AlarmListView()
        case .background:
            EnhancedBackgroundSettingsView()
        case .qingTengAccount:
            // Pops back to Settings' root: deleting the account closes every account page at once.
            AccountView()
                .environment(\.closeAccountPage, { path = NavigationPath() })
        }
    }

    // MARK: - Deep link

    /// Appearance writes this before flipping `appLanguage`, which rebuilds the
    /// root. Re-open settings on the appearance page in the newly chosen language.
    private func consumeLanguageReopen() {
        guard let dest = UserDefaults.standard.string(forKey: "pendingSettingsReopen") else { return }
        UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
        if dest == "appearance" {
            path.append(SettingsRoute.appearance)
        }
    }

    private func consumePendingDeepLink() {
        guard let target = deepLink.pendingSettingsTarget else { return }
        deepLink.pendingSettingsTarget = nil
        if let route = SettingsRoute(deepLink: target) {
            path.append(route)
        }
    }

    // MARK: - Actions

    private func clearAllConversations() {
        guard !isClearing else { return }
        isClearing = true
        Task {
            let report = await DataEraser.eraseAllConversations(modelContext: modelContext)
            isClearing = false
            onClearHistory()
            clearReport = report
        }
    }

    private var feedbackMailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = OasesBrand.feedbackEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: OasesBrand.feedbackSubject),
        ]
        return components.url
    }
}

// MARK: - Routing

enum SettingsRoute: Hashable {
    case advanced
    case providers
    case modelGroups
    case modelPrefs
    case usage
    case appearance
    case soundsHaptics
    case background
    case skills
    case soul
    case memory
    case mcp
    case environments
    case agent
    case rootfs
    case storage
    case sharedFolders
    case mountedFolders
    case permissions
    case automation
    case faceID
    case logs
    case dataPrivacy
    case about
    case alarms
    case qingTengAccount

    init?(deepLink target: SettingsDeepLinkTarget) {
        switch target {
        case .home:
            return nil
        case .providers, .providerDetail:
            self = .providers
        case .modelGroups, .modelGroupDetail:
            self = .modelGroups
        case .usage:
            self = .usage
        case .skills:
            self = .skills
        case .memory:
            self = .memory
        case .storage:
            self = .storage
        case .mountedFolders:
            self = .mountedFolders
        case .sharedFolders:
            self = .sharedFolders
        case .logs:
            self = .logs
        case .appearance:
            self = .appearance
        case .background:
            self = .background
        case .about:
            self = .about
        case .environments:
            self = .environments
        case .permissions:
            self = .permissions
        case .automation:
            self = .automation
        case .mcpIntegrations, .mcpServerDetail:
            self = .mcp
        case .privacy:
            self = .dataPrivacy
        }
    }
}
