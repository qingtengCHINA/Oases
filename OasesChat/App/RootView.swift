import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Effective appearance (the window adopts `theme.colorScheme`), so the
    /// top-bar theme button can flip what the user actually sees.
    @Environment(\.colorScheme) private var colorScheme
    // scenePhase also dismisses soft-finished Live Activities (OpenMinis pattern).

    @Query(sort: \ConversationModel.updatedAt, order: .reverse)
    private var conversations: [ConversationModel]

    @State private var selectedMode: AppMode = .chat
    /// Drawer position in points: 0 = fully closed, `drawerWidth` = fully
    /// open. This is the SINGLE source of truth for the sidebar — both the
    /// edge-pan-open and drag-close gestures drive it directly, the
    /// drawer's `.offset` and the scrim's opacity read from it. The old
    /// `Bool showSidebar + CGFloat sidebarDrag` pair had a discontinuity:
    /// at gesture-end, `sidebarDrag` snapped to 0 BEFORE `showSidebar`
    /// animated to true, so the translation formula's branch flipped and
    /// the drawer flashed back to fully-closed for one frame before
    /// opening — the bug in the user's report. One continuous variable
    /// physically cannot flash.
    @State private var sidebarOffset: CGFloat = 0
    /// Regular-width windows (iPad full screen, landscape, wide Split View)
    /// keep the sidebar as a column. Compact windows keep the phone drawer.
    @State private var availableWidth: CGFloat = 0
    @State private var sidebarPinned = true
    @State private var showModelPicker = false
    @State private var showSettings = false
    @State private var showMeetings = false
    @State private var showSearch = false
    @State private var chatVM = ChatViewModel()
    @State private var browserApprovalCenter = BrowserApprovalCenter.shared
    /// [Stage 1.1] Observes ConfigConfirmationGate so `.sheet(item:)` re-evaluates
    /// when the agent enqueues a oases-config write (OpenMinis MinisApp pattern).
    @ObservedObject private var configConfirmGate = ConfigConfirmationGate.shared
    @ObservedObject private var providerStore = ProviderConfigStore.shared
    @State private var activeConversationId: UUID?
    @State private var showTerminal = false
    @State private var terminalInitCommand: String?
    /// 1.5-second Metal-driven splash overlay shown once per cold launch.
    /// Stays in the view tree only while true; the splash flips it back
    /// to false via its `onComplete` callback after the dissolve plays.
    /// On first launch the onboarding already played it, so RootView
    /// (mounted right after onboarding) fades in instead of replaying it.
    @State private var showLaunchSplash = !LaunchSplashPlayback.hasPlayed
    @State private var showEntranceFade = LaunchSplashPlayback.hasPlayed
    // showAurora removed — aurora opacity now binds directly to
    // `chatVM.messages.isEmpty` in the body, no intermediate state.
    /// The top chrome (top bar, and Ogent's model row) the chat scrolls under; measured so the
    /// list can start its content below it.
    @State private var topChromeHeight: CGFloat = 0
    /// Ogent stays inside this chrome. `nil` session means a fresh draft
    /// identified by `ogentDraftToken`.
    @State private var ogentSessionId: String?
    @State private var ogentDraftToken = UUID().uuidString
    @State private var ogentSeeded = false
    @State private var ogentRecents: [RecentConversation] = []
    @State private var showOgentSearch = false
    @State private var widgetLaunch: OasesWidgetLaunch?
    @State private var showMembership = false

    /// Maximum drawer/column width. The drawer is reduced for very narrow
    /// windows so its trailing edge always stays inside the scene.
    private let sidebarWidth: CGFloat = 320
    /// A regular size class can still describe a narrow iPad Stage Manager or
    /// Split View window. Keep a column only when the chat has room beside it.
    private let columnLayoutMinimumWidth: CGFloat = 850
    /// Chat column cap so a 13-inch iPad does not stretch bubbles edge to edge.
    private let readableWidth: CGFloat = 820

    /// The drawer width follows the actual scene width. The 24pt allowance
    /// leaves a small reveal area even in an unusually narrow window.
    private var drawerWidth: CGFloat {
        guard availableWidth > 0 else { return sidebarWidth }
        return min(sidebarWidth, max(1, availableWidth - 24))
    }

    /// Wide window: sidebar beside the chat. Narrow window, including iPad
    /// Slide Over and a one-third Split View: the existing drawer. The width
    /// check matters because an iPad window can retain a regular size class
    /// while being too narrow for a 320pt sidebar plus useful chat content.
    private var usesColumnLayout: Bool {
        shouldUseColumnLayout(for: availableWidth)
    }

    private func shouldUseColumnLayout(for width: CGFloat) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
            && width >= columnLayoutMinimumWidth
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 0.5 else { return }
        // Width changes cover rotation, Stage Manager resizing, and Split View
        // transitions. A drawer offset from the previous scene size must not
        // survive into the new layout geometry.
        availableWidth = width
        sidebarOffset = 0
    }

    var body: some View {
        // Every mode, including Ogent, uses the same top bar and sidebar.
        // Ogent chat is embedded; it does not replace this chrome with the
        // engineering session-list home or open Settings on entry.
        oasesModeRoot
        .preferredColorScheme(theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            startNewConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .membershipPaywall)) { _ in
            showMembership = true
        }
        .onAppear {
            MembershipCenter.shared.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oasesWidgetOpen)) { note in
            let action = note.userInfo?["action"] as? String ?? "ask"
            if selectedMode == .project { selectedMode = .chat }
            widgetLaunch = OasesWidgetLaunch(action: action)
        }
        .onAppear {
            chatVM.bind(context: modelContext)
            browserApprovalCenter.setPresentationAvailable(scenePhase == .active)
            // [T-ios-session-crash-loop] Resuming an interrupted run at launch
            // re-runs whatever was in flight when the app died. After two
            // foreground crashes in a row that may be what killed it, so this
            // launch starts idle instead; the run stays resumable later.
            if !CrashReporter.shared.shouldBypassSessionRestore {
                Task { await chatVM.resumeLatestInterruptedProjectRunIfNeeded() }
            }
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil {
                showSettings = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            browserApprovalCenter.setPresentationAvailable(phase == .active)
            if phase == .active {
                AgentLiveActivityManager.shared.dismissFinishedActivityOnForeground()
                refreshUsageWidget()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionFromIntent)) { note in
            guard let sessionId = note.userInfo?["sessionId"] as? String,
                  let conv = conversations.first(where: { $0.id.uuidString == sessionId })
            else { return }
            // Intent targets Oases SwiftData sessions. Project rows belong
            // to Ogent and are routed there; chat/voice/image leave engineering.
            selectConversation(conv)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTerminalRequested)) { note in
            terminalInitCommand = note.userInfo?["initCommand"] as? String
            showTerminal = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .oasesExitEngineeringMode)) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                selectedMode = .chat
            }
        }
        // Offload permission prompts can come from any surface (chat,
        // terminal, automations); the presenter shows them above everything.
        .offloadPermissionDialog()
        .appIntake(.init(
            newChat: startNewChatFromShortcut,
            share: acceptShare,
            openSettings: {
                closeSidebar()
                showSettings = true
            },
            openSession: openSession,
            showSessionList: openSidebar
        ))
        .fullScreenCover(isPresented: $showTerminal) {
            NavigationStack {
                ISHTerminalView(showCloseButton: true, initCommand: terminalInitCommand)
            }
        }
        .overlay {
            if showLaunchSplash {
                LaunchSplashView(onComplete: { showLaunchSplash = false })
                    .transition(.opacity)
                    .zIndex(1000)
            } else if showEntranceFade {
                // Arriving from onboarding (or a language rebuild): start
                // under the same centred mark onboarding faded into.
                LaunchHandoffCover()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showEntranceFade = false
                        }
                    }
            }
        }
    }

    /// Shared surface for text, voice, image, and Ogent.
    @ViewBuilder
    private var oasesModeRoot: some View {
        rootSurface
            .preferredColorScheme(theme.colorScheme)
            .onChange(of: horizontalSizeClass) { _, _ in
                sidebarOffset = 0
            }
            .background { keyboardCommands }
            .sheet(isPresented: $showModelPicker) { modelPickerSheet }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .fullScreenCover(isPresented: $showMeetings) {
                MeetingHomeView()
                    .preferredColorScheme(theme.colorScheme)
            }
            .sheet(isPresented: $showMembership) {
                MembershipPaywallView()
                    .preferredColorScheme(theme.colorScheme)
            }
            // Limited mode: a send asks for AI data-sharing consent here,
            // then goes out once the user agrees (`AIConsentGate`).
            .aiConsentSheetHost()
            .sheet(isPresented: $showSearch) { searchSheet }
            .sheet(isPresented: $showOgentSearch) { ogentSearchSheet }
            .sheet(item: $browserApprovalCenter.pending) { request in
                browserApprovalSheet(request)
            }
            .sheet(item: Binding(
                get: { configConfirmGate.pending },
                set: { _ in /* dismissal goes through gate.userReject() */ }
            )) { _ in
                ConfigConfirmSheet(gate: configConfirmGate)
                    .preferredColorScheme(theme.colorScheme)
            }
    }

    @ViewBuilder
    private var rootSurface: some View {
        GeometryReader { geometry in
            Group {
                adaptiveSurface
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("oases.root.surface")
            .onAppear {
                updateAvailableWidth(geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                updateAvailableWidth(width)
            }
        }
    }

    /// Hardware keyboard on iPad (and iPhone with a keyboard).
    private var keyboardCommands: some View {
        Group {
            Button(action: startNewConversation) { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
            Button(action: openSearch) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
            Button(action: { showSettings = true }) { EmptyView() }
                .keyboardShortcut(",", modifiers: .command)
            Button(action: openSidebar) { EmptyView() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func openSearch() {
        if selectedMode == .project {
            showOgentSearch = true
        } else {
            showSearch = true
        }
    }

    /// The chat column keeps one stable position in this tree while the
    /// sidebar changes between a column and an overlay. This preserves local
    /// ChatView state while rotating or resizing across the 850pt breakpoint.
    private var adaptiveSurface: some View {
        HStack(spacing: 0) {
            if usesColumnLayout && sidebarPinned {
                sidebarPane
                    .frame(width: sidebarWidth)
                Rectangle()
                    .fill(OasesColor.border.opacity(0.7))
                    .frame(width: 0.5)
                    .ignoresSafeArea()
            }
            chatColumn
        }
        .background(OasesColor.background.ignoresSafeArea())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    guard !usesColumnLayout, sidebarOffset < drawerWidth else { return }
                    let isEdgePan = value.startLocation.x < 24
                    guard isEdgePan, value.translation.width > 0 else { return }
                    if sidebarOffset < 1 { dismissKeyboard() }
                    sidebarOffset = min(drawerWidth, max(0, value.translation.width))
                }
                .onEnded { value in
                    guard !usesColumnLayout, sidebarOffset > 0, sidebarOffset < drawerWidth else { return }
                    let flick = value.predictedEndTranslation.width > drawerWidth * 0.5
                    let target: CGFloat = (sidebarOffset > drawerWidth / 2 || flick) ? drawerWidth : 0
                    withAnimation(.easeOut(duration: 0.22)) { sidebarOffset = target }
                }
        )
        .overlay {
            if !usesColumnLayout {
                sidebarOverlay
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("oases.chat.surface")
    }

    /// Ogent's model row under the top bar: the current model, tap to pick another.
    private var ogentModelRow: some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .ogentRequestModelPicker, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Text(SessionModelDisplay(store: providerStore).displayName(for: ogentSessionId))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OasesColor.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OasesColor.card, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var chatColumn: some View {
        // GeometryReader 只为量状态栏高度，让渐进模糊盖住屏幕最顶端——
        // 消息会一路滚进状态栏下面，模糊从屏幕顶开始才对。
        GeometryReader { rootGeo in
            ZStack {
                OasesColor.background.ignoresSafeArea()
                AuroraBackground(tint: Color(uiColor: selectedMode.metallicTint.tintColor))
                    .opacity(selectedMode == .project ? 0 : (chatVM.messages.isEmpty ? 1 : 0))
                    .animation(.easeOut(duration: 0.35), value: chatVM.messages.isEmpty)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Group {
                        if selectedMode == .project {
                            OgentEmbeddedChat(sessionId: ogentSessionId, draftToken: ogentDraftToken, topChromeInset: topChromeHeight)
                                .id(ogentSessionId ?? ogentDraftToken)
                        } else {
                            ChatView(
                                viewModel: chatVM,
                                mode: selectedMode,
                                onPickModel: { showModelPicker = true },
                                onPullNewChat: { startNewConversation() },
                                widgetLaunch: $widgetLaunch
                            )
                        }
                    }
                    // Keep a readable chat width whenever the window has
                    // spare room, including a wide drawer layout with its
                    // sidebar hidden. The outer chat column still fills the
                    // window so the background and top bar remain edge to
                    // edge.
                    .frame(maxWidth: availableWidth > readableWidth ? readableWidth : .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The chrome is a safeAreaInset: the chat's own scroll view insets its
                // content under it (SwiftUI ScrollView), and Ogent's list ignores the inset
                // and gets its height through the environment instead, so messages scroll up
                // beneath the whole chrome. One progressive blur covers it all: opaque at the
                // status bar, fading out just below the model row.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        TopBar(
                            onMenu: { openSidebar() },
                            onSearch: { openSearch() },
                            onTheme: { theme.toggle(relativeTo: colorScheme) }
                        )
                        if selectedMode == .project {
                            ogentModelRow
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topChromeHeight = $0 }
                    .background(alignment: .top) {
                        ProgressiveBlur(edge: .top, wash: 1, intensity: 0.34)
                            .frame(height: rootGeo.safeAreaInsets.top + topChromeHeight + 56)
                            .offset(y: -rootGeo.safeAreaInsets.top)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("oases.chat.column")
    }

    private var modelPickerSheet: some View {
        ModelPickerSheet(
            options: Models.options(for: selectedMode.category)
                + ProviderChatRouting.selectableOptions(matching: selectedMode.category),
            selectedId: $chatVM.currentModel,
            effort: $chatVM.effort,
            onPick: { option in
                chatVM.currentModel = option.id
                if let conv = chatVM.conversation {
                    conv.modelId = option.id
                }
                Haptics.select()
                showModelPicker = false
            },
            onPickEffort: { next in
                chatVM.effort = next
                Haptics.select()
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(OasesColor.background)
        .preferredColorScheme(theme.colorScheme)
    }

    private var settingsSheet: some View {
        SettingsView(onClearHistory: {
            activeConversationId = nil
            chatVM.reset()
        })
        .environment(theme)
        .preferredColorScheme(theme.colorScheme)
    }

    private var searchSheet: some View {
        SearchView(onSelectConversation: { conv in
            selectConversation(conv)
            closeSidebar()
        })
        .preferredColorScheme(theme.colorScheme)
    }

    private var ogentSearchSheet: some View {
        OgentSessionSearchSheet { sessionId in
            ogentSessionId = sessionId
            ogentSeeded = true
            showOgentSearch = false
            Task { await reloadOgentRecents() }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    private func browserApprovalSheet(_ request: BrowserApprovalRequest) -> some View {
        BrowserApprovalSheet(
            request: request,
            webView: browserApprovalCenter.webView(for: request.sessionID),
            onApprove: { browserApprovalCenter.approve() },
            onCancel: { browserApprovalCenter.cancel() }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(OasesColor.background)
        .preferredColorScheme(theme.colorScheme)
    }

    private func openSidebar() {
        dismissKeyboard()
        if usesColumnLayout {
            withAnimation(.easeOut(duration: 0.22)) { sidebarPinned.toggle() }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { sidebarOffset = drawerWidth }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func closeSidebar() {
        guard !usesColumnLayout else { return }
        withAnimation(.easeOut(duration: 0.22)) { sidebarOffset = 0 }
    }

    private var sidebarPane: some View {
        SidebarView(
            selectedMode: $selectedMode,
            recents: selectedMode == .project
                ? ogentRecents
                : conversations.filter { $0.mode != .project }.map { conv in
                    RecentConversation(
                        id: conv.id.uuidString,
                        title: conv.title,
                        modelLabel: Models.label(for: conv.modelId, category: conv.mode.category)
                    )
                },
            onNewChat: {
                startNewConversation()
                closeSidebar()
            },
            onPickMode: { mode in
                switchMode(mode)
                closeSidebar()
            },
            onSelectRecent: { recent in
                if selectedMode == .project {
                    ogentSessionId = recent.id
                    ogentSeeded = true
                } else if let conv = conversations.first(where: { $0.id.uuidString == recent.id }) {
                    selectConversation(conv)
                }
                closeSidebar()
            },
            onDeleteRecent: { recent in
                if selectedMode == .project {
                    Task {
                        await ChatStore.shared.deleteSession(recent.id)
                        if ogentSessionId == recent.id {
                            ogentSessionId = nil
                            ogentDraftToken = UUID().uuidString
                        }
                        await reloadOgentRecents()
                    }
                } else if let conv = conversations.first(where: { $0.id.uuidString == recent.id }) {
                    deleteConversation(conv)
                }
            },
            onOpenMeetings: {
                closeSidebar()
                showMeetings = true
            },
            onOpenSettings: {
                if usesColumnLayout {
                    showSettings = true
                } else {
                    closeSidebar()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showSettings = true
                    }
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("oases.sidebar")
    }

    // MARK: - Sidebar overlay

    private var sidebarOverlay: some View {
        // Drawer's translation is `sidebarOffset - drawerWidth`, which is
        // -drawerWidth when closed (offset = 0) and 0 when fully open
        // (offset = drawerWidth). Scrim opacity is offset / drawerWidth.
        // Single source of truth, no branches, no discontinuity.
        let drawerX = sidebarOffset - drawerWidth
        let scrimAlpha = sidebarOffset / drawerWidth

        return ZStack(alignment: .leading) {
            Color.black.opacity(0.45 * scrimAlpha)
                .contentShape(Rectangle())
                .onTapGesture { closeSidebar() }
                .ignoresSafeArea()
                // When the drawer is fully closed the invisible scrim
                // must NOT swallow taps in the chat surface.
                .allowsHitTesting(sidebarOffset > 0.5)

            sidebarPane
            .frame(width: drawerWidth)
            .offset(x: drawerX)
            .accessibilityHidden(sidebarOffset <= 0.5)
            // Drag the drawer LEFT to close — every onChanged tick writes
            // `sidebarOffset` directly so the drawer tracks the finger.
            // On release, snap to 0 or drawerWidth based on threshold.
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        // Only respond while the drawer is open / opening.
                        guard sidebarOffset > 0 else { return }
                        // A recents row is being swiped to delete: the drawer stays put.
                        if SidebarRowSwipe.shared.isActive {
                            if sidebarOffset != drawerWidth { sidebarOffset = drawerWidth }
                            return
                        }
                        let next = drawerWidth + value.translation.width
                        sidebarOffset = min(drawerWidth, max(0, next))
                    }
                    .onEnded { value in
                        if SidebarRowSwipe.shared.isActive || sidebarOffset >= drawerWidth - 0.5 {
                            withAnimation(.easeOut(duration: 0.22)) { sidebarOffset = drawerWidth }
                            return
                        }
                        let flick = value.predictedEndTranslation.width < -drawerWidth * 0.5
                        let target: CGFloat = (sidebarOffset < drawerWidth / 2 || flick) ? 0 : drawerWidth
                        withAnimation(.easeOut(duration: 0.22)) { sidebarOffset = target }
                    }
            )
        }
    }

    // MARK: - External entry points (AppIntakeCoordinator)

    /// Close anything covering the chat so an external entry lands visibly.
    private func surfaceChat() {
        showSettings = false
        showSearch = false
        showOgentSearch = false
        showModelPicker = false
        closeSidebar()
    }

    /// Home Screen quick action: a fresh Oases chat, then dictation / camera.
    private func startNewChatFromShortcut(_ action: ChatLaunchAction?) {
        surfaceChat()
        selectedMode = .chat
        startNewConversation()
        switch action {
        case .startVoice: widgetLaunch = OasesWidgetLaunch(action: "voice")
        case .openCamera: widgetLaunch = OasesWidgetLaunch(action: "camera")
        case nil: break
        }
    }

    /// Share Extension hand-off. Text goes into the current chat composer.
    /// Files need Ogent's composer (the Oases chat composer has no external
    /// attachment intake yet), so a share with files opens a fresh Ogent
    /// draft; `AIChatView` injects the buffer when it appears — or, if Ogent
    /// is already on screen, when `bufferVersion` changes.
    private func acceptShare(_ share: PendingShare) {
        surfaceChat()
        let hasFiles = share.items.contains { $0.kind == .attachment }
        if selectedMode == .project || hasFiles {
            if selectedMode != .project {
                ogentSessionId = nil
                ogentDraftToken = UUID().uuidString
                ogentSeeded = true
                selectedMode = .project
            }
            ShareCoordinator.shared.storeBuffer(share)
            return
        }
        let text = share.items.map(\.value).joined(separator: "\n")
        chatVM.input = chatVM.input.isEmpty ? text : chatVM.input + "\n" + text
        widgetLaunch = OasesWidgetLaunch(action: "ask")
    }

    /// Deep link / notification tap. Oases chats are SwiftData rows; anything
    /// else is tried as an Ogent (ChatStore) session.
    private func openSession(_ id: String) {
        surfaceChat()
        if let conv = conversations.first(where: { $0.id.uuidString == id }) {
            selectConversation(conv)
            return
        }
        Task {
            let sessions = await ChatStore.shared.listSessions()
            guard sessions.contains(where: { $0.id == id }) else { return }
            await MainActor.run {
                ogentSessionId = id
                ogentSeeded = true
                selectedMode = .project
            }
        }
    }

    /// `UsageStatsViewModel.load()` publishes the Home Screen usage widget's
    /// snapshot (`UsageWidgetSnapshot`); the view model itself is discarded.
    private func refreshUsageWidget() {
        Task { await UsageStatsViewModel().load() }
    }

    // MARK: - Conversation Management

    private func startNewConversation() {
        if selectedMode == .project {
            ogentSessionId = nil
            ogentDraftToken = UUID().uuidString
            ogentSeeded = true
            Haptics.tap()
            return
        }
        activeConversationId = nil
        chatVM.reset()
        chatVM.activeMode = .chat
        chatVM.bind(context: modelContext)
        selectedMode = .chat
        Haptics.tap()
    }

    /// Mirrors Web `handleCategorySelect`: if the current conversation is
    /// empty, switch its model in place; otherwise start a fresh one of the
    /// chosen mode.
    private func switchMode(_ mode: AppMode) {
        if mode == .project {
            selectedMode = .project
            Task { await seedOgentEntry() }
            Haptics.select()
            return
        }
        chatVM.activeMode = mode
        if chatVM.messages.isEmpty {
            // Reuse the empty surface — just swap the model + tint.
            chatVM.currentModel = mode.preferredModel
        } else {
            activeConversationId = nil
            chatVM.resetFor(mode: mode)
            chatVM.bind(context: modelContext)
        }
        selectedMode = mode
        Haptics.select()
    }

    /// First entry into Ogent opens a chat, using the Appearance "进入 Ogent"
    /// preference. Later visits keep the chat already on screen.
    private func seedOgentEntry() async {
        if ogentSeeded {
            await reloadOgentRecents()
            return
        }
        // The app ended while this session was loading, sending or switching models: open a
        // draft instead of it. Only a switch of its model is undone (the model may be what
        // brought the app down); a kill during a load or a send keeps the user's model.
        let unstable = UserDefaults.standard.string(forKey: AIChatViewModel.unstableSessionDefaultsKey)
        let unstableDuringModelSwitch = UserDefaults.standard.string(forKey: AIChatViewModel.unstableSessionPhaseDefaultsKey)
            == AIChatViewModel.unstableModelSwitchPhase
        UserDefaults.standard.removeObject(forKey: AIChatViewModel.unstableSessionDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AIChatViewModel.unstableSessionPhaseDefaultsKey)
        if let unstable, unstableDuringModelSwitch, await ChatStore.shared.sessionExists(id: unstable) {
            let fallback = OasesBuiltinProvider.defaultTextEntry
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(
                    sessionId: unstable,
                    primarySource: .directEntry(modelEntryId: fallback.id),
                    subModelSource: nil
                ),
                for: unstable
            )
            await ChatStore.shared.updateSessionModelId(unstable, modelId: fallback.model.id)
        }
        let pref = UserDefaults.standard.integer(forKey: "launchScreen")
        let sessions = await ChatStore.shared.listSessions()
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        // [T-ios-session-crash-loop] The last two launches both died in the
        // foreground within a minute: the signature of a session that crashes
        // the app every time it is reopened here. Open a draft instead, so the
        // app stays usable and the session can be deleted from the list. The
        // unstable mark above only covers a crash during the load itself.
        let crashLoop = CrashReporter.shared.shouldBypassSessionRestore
        let openLast: Bool
        if crashLoop {
            openLast = false
        } else {
            switch pref {
            case 1:
                openLast = sorted.first != nil
            case 2, 3:
                openLast = false
            default:
                if let latest = sorted.first {
                    openLast = Date().timeIntervalSince(latest.updatedAt) < 15 * 60
                } else {
                    openLast = false
                }
            }
        }
        let mapped = sorted.prefix(30).map { session in
            RecentConversation(
                id: session.id,
                title: session.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "新对话", comment: "Fallback title for an untitled conversation"),
                modelLabel: session.lastMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Ogent"
            )
        }
        await MainActor.run {
            ogentRecents = Array(mapped)
            if openLast, let id = sorted.first?.id, id != unstable {
                ogentSessionId = id
            } else if unstable != nil {
                ogentSessionId = nil
                ogentDraftToken = UUID().uuidString
            }
            ogentSeeded = true
        }
    }

    private func reloadOgentRecents() async {
        let sessions = await ChatStore.shared.listSessions()
        let mapped = sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(30).map { session in
            RecentConversation(
                id: session.id,
                title: session.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "新对话", comment: "Fallback title for an untitled conversation"),
                modelLabel: session.lastMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Ogent"
            )
        }
        await MainActor.run { ogentRecents = Array(mapped) }
    }

    private func selectConversation(_ conv: ConversationModel) {
        guard conv.mode != .project else {
            selectedMode = .project
            Task { await seedOgentEntry() }
            return
        }
        guard conv.id != activeConversationId else { return }
        activeConversationId = conv.id
        selectedMode = conv.mode
        chatVM.reset()
        chatVM.bind(context: modelContext)
        chatVM.load(conversation: conv)
        Haptics.select()
    }

    private func deleteConversation(_ conv: ConversationModel) {
        if conv.id == activeConversationId {
            activeConversationId = nil
            chatVM.reset()
            chatVM.bind(context: modelContext)
        }
        modelContext.delete(conv)
        try? modelContext.save()
        Haptics.medium()
    }
}

// MARK: - Ogent inside the shared chrome

/// Ogent chat under the Oases top bar. No session-list home and no system
/// navigation title — the sidebar is how you leave.
private struct OgentEmbeddedChat: View {
    var sessionId: String?
    var draftToken: String
    /// Height of the chrome above (top bar + model row), for the list's top inset.
    var topChromeInset: CGFloat

    var body: some View {
        AIChatView(
            sessionId: sessionId,
            draftId: sessionId == nil ? "__new__\(draftToken)" : nil,
            usesOasesChrome: true
        )
        .environment(\.oasesTopChromeInset, topChromeInset)
        // Under the chrome: the list insets itself by `topChromeInset` instead.
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct OgentSessionSearchSheet: View {
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSession] = []
    @State private var query = ""

    private var filtered: [ChatSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            let title = session.title ?? ""
            let last = session.lastMessage ?? ""
            return title.localizedCaseInsensitiveContains(trimmed)
                || last.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { session in
                Button {
                    onSelect(session.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "新对话", comment: "Fallback title for an untitled conversation"))
                            .foregroundStyle(OasesColor.foreground)
                        if let last = session.lastMessage, !last.isEmpty {
                            Text(last)
                                .font(.caption)
                                .foregroundStyle(OasesColor.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索 Ogent 对话")
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let loaded = await ChatStore.shared.listSessions()
                sessions = loaded.sorted { $0.updatedAt > $1.updatedAt }
            }
        }
    }
}

// MARK: - ThemeManager toggle

extension ThemeManager {
    /// Top-bar sun/moon button: flip the appearance the user is looking at.
    /// Cycling system → dark → light did nothing visible on a dark device.
    func toggle(relativeTo effective: ColorScheme) {
        mode = effective == .dark ? .light : .dark
    }

    func toggle() {
        switch mode {
        case .system: mode = .dark
        case .dark: mode = .light
        case .light: mode = .system
        }
    }
}
