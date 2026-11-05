import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    var viewModel: ChatViewModel
    var mode: AppMode = .chat
    var onPickModel: () -> Void = {}
    var onPullNewChat: () -> Void = {}
    var widgetLaunch: Binding<OasesWidgetLaunch?> = .constant(nil)

    @Environment(ThemeManager.self) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var composerFocused: Bool
    @State private var showPromptTemplates = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingAttachments: [Attachment] = []
    @State private var dictation = SpeechRecognizer()
    @State private var isDictating = false
    @State private var showDictationAlert = false
    @State private var previewAttachment: Attachment?
    @State private var attachMenuOpen = false
    @State private var openCameraToken = 0
    /// 分享卡片（长图）生成中 — 阻塞式加载态，避免重复触发。
    @State private var isGeneratingShareCard = false
    /// 生成完毕、待分享的 PNG 临时文件。
    @State private var shareCardFile: ShareCardFile?
    /// True when the scroll view's bottom sentinel is on screen — i.e.
    /// the user is at (or near) the latest message. While false the
    /// streaming auto-scroll is suppressed so the user can scroll up
    /// and read history without being yanked back.
    @State private var isFollowingBottom = true
    @State private var newChatPull: CGFloat = 0
    @State private var newChatPullHapticSent = false
    /// A full pull held for `NewChatPull.hold`: releasing starts a new chat.
    @State private var newChatPullArmed = false
    @State private var newChatHoldTask: Task<Void, Never>?
    /// 严格底部判定（1pt 哨兵驱动）。isFollowingBottom 的哨兵有 80pt 高，
    /// 离底还有一段距离就会亮起，不能用来门控上拉手势。
    @State private var isAtAbsoluteBottom = false
    /// 手势开始时尚未到底的话，持续记录到达底部那一刻的位移基线，
    /// 进度只累计"到底之后继续上拉"的过冲距离——快速滑过内容不算数。
    @State private var newChatPullBaseline: CGFloat = 0

    /// Extra breathing room for the readable iPad chat column. RootView caps
    /// the column itself; these insets keep message text and the composer from
    /// touching that cap when a regular-width window is available.
    private var horizontalContentInset: CGFloat {
        horizontalSizeClass == .regular ? OasesSpacing.lg : OasesSpacing.md
    }

    var body: some View {
        Group {
            if viewModel.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Tap on empty space / plain message text dismisses the keyboard.
        // A plain (non-simultaneous) tap loses to child gestures, so tapping
        // a code block's Copy, a tool pill or an attachment no longer drops
        // the keyboard as the old `simultaneousGesture` did. The composer
        // sits in `safeAreaInset` below, outside this area; scrolling still
        // dismisses via `scrollDismissesKeyboard(.interactively)`.
        .onTapGesture {
            endEditing()
        }
        .overlay(alignment: .top) {
            if let message = viewModel.errorMessage {
                ErrorBanner(message: message)
                    .padding(.top, 8)
                    // Slides in, leaves with a fade (an exit is not the entrance reversed).
                    .transition(OasesMotion.banner(from: .top))
                    .onTapGesture { viewModel.dismissBanner() }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        // Tap-to-dismiss scrim that covers the entire chat surface
        // (everything above the composer) whenever the attach menu is open.
        // The composer's overlay still wins for taps on its own shell, so
        // tapping the menu items still works. Without this, the menu only
        // closed when the user tapped inside the composer footprint — a UX
        // regression vs. every shipping AI-chat app.
        .overlay {
            if attachMenuOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { attachMenuOpen = false }
                    .ignoresSafeArea()
            }
        }
        .animation(.timingCurve(0.22, 0.9, 0.28, 1, duration: 0.46), value: attachMenuOpen)
        .animation(.easeOut(duration: 0.22), value: viewModel.errorMessage)
        .overlay(alignment: .bottom) {
            if newChatPull > newChatPullShowAt {
                newChatPullIndicator
                    .padding(.bottom, 56)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ComposerBar(
                    text: Binding(get: { viewModel.input }, set: { viewModel.input = $0 }),
                    isStreaming: viewModel.isStreaming,
                    modelLabel: ProviderChatRouting.label(for: viewModel.currentModel)
                        ?? Models.label(for: viewModel.currentModel, category: mode.category),
                    placeholder: mode.composerPlaceholder,
                    isFocused: $composerFocused,
                    isDictating: isDictating,
                    pendingAttachments: pendingAttachments,
                    attachMenuOpen: $attachMenuOpen,
                    onSend: {
                        // Ask for consent BEFORE anything is consumed: in
                        // limited mode the text and attachments stay put,
                        // and this same send runs once the user agrees.
                        AIConsentGate.perform {
                            Task {
                                await viewModel.send(attachments: pendingAttachments)
                                pendingAttachments = []
                            }
                        }
                    },
                    onStop: { viewModel.stop() },
                    onAttachPhoto: { showPhotoPicker = true },
                    onCamera: {
                        attachMenuOpen = false
                        showCamera = true
                    },
                    onAttachFile: { showFilePicker = true },
                    onPickRecentPhoto: { image in
                        addImageAttachment(image: image, name: "image-\(pendingAttachments.count + 1).jpg")
                    },
                    onPickRecentAsset: { localIdentifier, thumbnail in
                        addRecentPhotoAttachment(localIdentifier: localIdentifier, fallback: thumbnail)
                    },
                    supportsDeepThink: Models.option(for: viewModel.currentModel)?.supportsEffort == true,
                    deepThinkOn: viewModel.effort == .high,
                    onToggleDeepThink: {
                        viewModel.effort = viewModel.effort == .high ? .medium : .high
                        Haptics.select()
                    },
                    onRemoveAttachment: { id in
                        pendingAttachments.removeAll { $0.id == id }
                        // Evict the decoded UIImage from the cache so removed
                        // attachments don't keep their pixels resident for the
                        // rest of the session.
                        AttachmentImageCache.evict(id)
                        Haptics.tap()
                    },
                    onPreviewAttachment: { previewAttachment = $0 },
                    onPrompt: { showPromptTemplates = true },
                    onPickModel: onPickModel,
                    onMic: { toggleDictation() },
                    openCameraToken: openCameraToken
                )
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? OasesSpacing.sm : 0)
            // Composer backdrop — solid page colour only, no Material/blur.
            // The previous `.ultraThinMaterial` washed the entire bottom of
            // the screen grey in dark mode; user explicitly rejected that
            // look. Now: a tall gradient that washes scroll content out
            // smoothly into the page colour above the shell, then the page
            // colour continues unbroken behind the composer and through the
            // home-indicator zone — no light grey, no hard slice.
            .background(alignment: .top) {
                LinearGradient(
                    colors: [OasesColor.background.opacity(0),
                             OasesColor.background.opacity(0.50),
                             OasesColor.background.opacity(0.85),
                             OasesColor.background],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 72)
                .offset(y: -72)
                .allowsHitTesting(false)
            }
            .background {
                OasesColor.background
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // No keyboard "Done" toolbar — tapping outside / scrolling dismisses
        // the keyboard instead, matching the spec and the other modes.
        .sheet(isPresented: $showPromptTemplates) {
            PromptTemplateSheet { template in
                viewModel.input = template
                composerFocused = true
            }
            .preferredColorScheme(theme.colorScheme)
        }
        .alert("听写不可用", isPresented: $showDictationAlert) {
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text("请开启 Oases Chat 的麦克风与语音识别权限后重试。")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                addImageAttachment(image: image, name: "image-\(pendingAttachments.count + 1).jpg")
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: importableTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileResult(result)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    addImageAttachment(data: data, name: "image-\(pendingAttachments.count + 1).jpg")
                }
                selectedPhoto = nil
            }
        }
        // Live dictation transcript → input field.
        .onChange(of: dictation.transcript) { _, new in
            if isDictating { viewModel.input = new }
        }
        // Recognition can end on its own (final result, silence, error);
        // without this the mic button stayed stuck in "listening".
        .onChange(of: dictation.isListening) { _, listening in
            guard !listening, isDictating else { return }
            if !dictation.transcript.isEmpty { viewModel.input = dictation.transcript }
            isDictating = false
        }
        .onDisappear {
            dictation.stop()
            isDictating = false
        }
        .onAppear {
            viewModel.activeMode = mode
            applyWidgetLaunch(widgetLaunch.wrappedValue)
        }
        .onChange(of: widgetLaunch.wrappedValue) { _, launch in
            applyWidgetLaunch(launch)
        }
        .onChange(of: mode) { _, newMode in
            viewModel.activeMode = newMode
        }
        .sheet(item: $previewAttachment) { item in
            AttachmentPreviewSheet(attachment: item)
                .preferredColorScheme(theme.colorScheme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $shareCardFile) { file in
            OasesShareSheet(url: file.url)
                .preferredColorScheme(theme.colorScheme)
        }
        // 分享卡片生成加载态：遮罩 + 转圈，生成是同步耗时操作（见
        // ShareCardRenderer），期间挡住重复点击。
        .overlay {
            if isGeneratingShareCard {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(OasesColor.primary)
                        Text("正在生成分享图片…")
                            .font(.oasesCallout())
                    }
                    .foregroundStyle(OasesColor.foreground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous))
                }
                .transition(.opacity)
            }
        }
    }

    private var newChatPullDistance: CGFloat { NewChatPull.distance }
    /// 指示器出现所需的过冲距离（pt）——拉过这段才算"明确想触发"，
    /// 之前随手的小过冲什么都不显示。
    private var newChatPullShowAt: CGFloat { NewChatPull.showAt }

    private var newChatPullGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // ChatGPT 式语义：与速度无关。只有内容已经停在最新一条消息
                // （1pt 绝对底部哨兵在屏）时，继续上拉的位移才是"过冲"——
                // 还没到顶就快速滑过，只是在浏览历史，不触发。
                guard isAtAbsoluteBottom, !viewModel.messages.isEmpty else {
                    newChatPullBaseline = value.translation.height
                    newChatPull = 0
                    return
                }
                let dy = -(value.translation.height - newChatPullBaseline)
                // 只认竖直方向占优的上拉
                guard dy > 0, abs(value.translation.height) > abs(value.translation.width) else {
                    newChatPull = 0
                    return
                }
                newChatPull = min(newChatPullDistance, dy)
                if newChatPull >= newChatPullDistance {
                    // Full: arm only after it has been held for a moment.
                    if newChatHoldTask == nil, !newChatPullArmed {
                        newChatHoldTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(NewChatPull.hold))
                            guard !Task.isCancelled, newChatPull >= newChatPullDistance - 1 else { return }
                            newChatPullArmed = true
                            if !newChatPullHapticSent {
                                newChatPullHapticSent = true
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        }
                    }
                } else {
                    cancelNewChatHold()
                }
            }
            .onEnded { _ in
                if newChatPullArmed, newChatPull >= newChatPullDistance - 1 {
                    onPullNewChat()
                }
                cancelNewChatHold()
                newChatPullHapticSent = false
                newChatPullBaseline = 0
                withAnimation(.easeOut(duration: 0.2)) { newChatPull = 0 }
            }
    }

    private func cancelNewChatHold() {
        newChatHoldTask?.cancel()
        newChatHoldTask = nil
        if newChatPullArmed { newChatPullArmed = false }
    }

    private var newChatPullIndicator: some View {
        NewChatPullIndicator(progress: NewChatPull.progress(newChatPull), armed: newChatPullArmed)
    }

    private var emptyState: some View {
        // No local aurora here — RootView already paints one full-screen
        // AuroraBackground behind everything. Stacking a second instance
        // produced a visible seam at the TopBar boundary because the two
        // shader passes ran in different GeometryReaders (different size
        // → different normalised UV → different pattern) and started
        // their TimelineViews at different times (different phase). One
        // global aurora behind a transparent ChatView is the right
        // altitude for this effect.
        GeometryReader { geo in
            let greetingWidth = max(0, min(400, geo.size.width - horizontalContentInset * 2))
            EmptyGreeting(mode: mode)
                .frame(maxWidth: greetingWidth)
                // Vertically centered — the icon + greeting share the
                // middle of the content area (accounting for the composer
                // inset below by nudging slightly above dead center).
                .position(x: geo.size.width / 2, y: geo.size.height / 2 - 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Retry a user message or regenerate a reply, asking for consent first in limited mode.
    private func retryAction(for message: ChatUIMessage) -> (() -> Void)? {
        guard !viewModel.isStreaming, message.role != .system else { return nil }
        let id = message.id
        let isUser = message.role == .user
        return {
            AIConsentGate.perform {
                if isUser { viewModel.retryFromMessage(id) } else { viewModel.regenerate(assistantMessageId: id) }
            }
        }
    }

    /// Edit and resend (user messages): the text and attachments go back to the composer.
    private func editAction(for message: ChatUIMessage) -> (() -> Void)? {
        guard !viewModel.isStreaming, message.role == .user else { return nil }
        let id = message.id
        return {
            guard let edited = viewModel.editMessage(id) else { return }
            viewModel.input = edited.text
            pendingAttachments = edited.attachments
            composerFocused = true
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OasesSpacing.lg) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            mode: mode,
                            signals: viewModel.liveSignals,
                            isLive: viewModel.isStreaming && message.id == viewModel.messages.last?.id,
                            onTapAttachment: { previewAttachment = $0 },
                            onShareAsImage: generateShareCard,
                            onRetry: retryAction(for: message),
                            onEdit: editAction(for: message),
                            onDelete: viewModel.isStreaming ? nil : { viewModel.deleteMessage(message.id) }
                        ).id(message.id)
                    }
                    // Sentinel at the bottom — when this view is on
                    // screen, `isFollowingBottom` is true and incoming
                    // tokens auto-scroll the feed. When the user
                    // scrolls up to read earlier messages, this view
                    // leaves the viewport and the flag flips off,
                    // letting the user inspect history without the
                    // stream yanking them back to bottom every flush.
                    Color.clear
                        .frame(height: 80)
                        .id("bottom")
                        .onAppear { isFollowingBottom = true }
                        .onDisappear { isFollowingBottom = false }
                    // 1pt 绝对底部哨兵——只有真正滚到消息末尾才会亮起，
                    // 上拉新聊天手势只认它，不认上面 80pt 的跟随哨兵。
                    Color.clear
                        .frame(height: 1)
                        .onAppear { isAtAbsoluteBottom = true }
                        .onDisappear { isAtAbsoluteBottom = false }
                }
                .padding(.horizontal, horizontalContentInset)
                .padding(.top, OasesSpacing.md)
            }
            // Transparent ScrollView background so the RootView's
            // AuroraBackground fades through during the Aurora-removal
            // 0.35 s transition on first send. Without this, the
            // ScrollView's default opaque background composited over
            // the aurora the instant the conversation view mounted,
            // and the aurora appeared to "snap" away instead of
            // fading.
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(newChatPullGesture)
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard isFollowingBottom else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.imageUrl) { _, _ in
                guard isFollowingBottom else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Attachment import

    private var importableTypes: [UTType] {
        // Broad set mirroring Web's single <input type="file" multiple>:
        // images + text-like documents + generic binaries.
        [.image, .plainText, .json, .pdf, .text, .data, .sourceCode, .xml, .yaml, .html]
    }

    private func handleFileResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            loadAttachment(from: url)
        }
    }

    /// Reads / extracts a picked file off the main actor — PDF text
    /// extraction, RTF parsing and image downsampling can take seconds.
    private func loadAttachment(from url: URL) {
        Task {
            let attachment = await Task.detached(priority: .userInitiated) {
                AttachmentImporter.makeAttachment(fromFileAt: url)
            }.value
            pendingAttachments.append(attachment)
            Haptics.tap()
        }
    }

    /// Photo bytes (any format, e.g. HEIC from PhotosPicker) → downsampled
    /// JPEG attachment whose MIME matches its bytes, prepared off the main
    /// actor.
    private func addImageAttachment(data: Data, name: String) {
        Task {
            let attachment = await Task.detached(priority: .userInitiated) {
                AttachmentImporter.makeImageAttachment(data: data, name: name)
            }.value
            appendImageAttachment(attachment)
        }
    }

    /// Camera capture → same pipeline.
    private func addImageAttachment(image: UIImage, name: String) {
        Task {
            let attachment = await Task.detached(priority: .userInitiated) {
                AttachmentImporter.makeImageAttachment(image: image, name: name)
            }.value
            appendImageAttachment(attachment)
        }
    }

    /// Quick photo strip / album grid: attach the original asset — the strip
    /// only holds 280 px thumbnails, used here just as a fallback when the
    /// original can't be loaded.
    private func addRecentPhotoAttachment(localIdentifier: String, fallback: UIImage) {
        let name = "image-\(pendingAttachments.count + 1).jpg"
        Task {
            if let data = await RecentPhotoThumb.originalImageData(localIdentifier: localIdentifier) {
                addImageAttachment(data: data, name: name)
            } else {
                addImageAttachment(image: fallback, name: name)
            }
        }
    }

    private func appendImageAttachment(_ attachment: Attachment?) {
        guard let attachment else {
            Haptics.error()
            return
        }
        pendingAttachments.append(attachment)
        Haptics.tap()
    }

    private func endEditing() {
        composerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    // MARK: - Share card (长图分享)

    /// 从当前会话生成分享卡片并经系统分享面板发出。入口由非隔离的
    /// context-menu 闭包调用（与 `onSend` 同款 `Task { await … }` 模式），
    /// 真正的活都在 @MainActor 的 `generateShareCardOnMainActor` 里：
    /// 渲染走 ImageRenderer（@MainActor），PNG 编码与写盘后台执行；
    /// 生成期间 `isGeneratingShareCard` 挡住重复点击。
    private func generateShareCard() {
        guard !isGeneratingShareCard else { return }
        Task { await generateShareCardOnMainActor() }
    }

    @MainActor
    private func generateShareCardOnMainActor() {
        guard !isGeneratingShareCard, !viewModel.messages.isEmpty else { return }
        isGeneratingShareCard = true
        Haptics.tap()
        let messages = viewModel.messages
        let title = viewModel.conversation?.title
        let generatedAt = viewModel.conversation?.updatedAt
            ?? messages.last?.createdAt
            ?? .now
        Task { @MainActor in
            do {
                let model = ShareCardBuilder.make(
                    messages: messages,
                    conversationTitle: title,
                    generatedAt: generatedAt
                )
                guard !model.messages.isEmpty else {
                    throw ShareCardGenerationError.noShareableMessages
                }

                // Resolve all data/remote images before ImageRenderer snapshots
                // the view. AsyncImage is intentionally not used here because
                // it can still be in its loading state during a synchronous
                // renderer pass.
                let resolvedImages = try await ShareCardImageResolver.resolve(model: model)
                guard let image = ShareCardRenderer.render(
                    model: model,
                    resolvedImages: resolvedImages
                ) else {
                    throw ShareCardGenerationError.renderFailed
                }
                guard let url = await ShareCardExporter.writeToTemporaryPNG(image) else {
                    throw ShareCardGenerationError.exportFailed
                }
                isGeneratingShareCard = false
                shareCardFile = ShareCardFile(url: url)
            } catch is CancellationError {
                isGeneratingShareCard = false
            } catch {
                isGeneratingShareCard = false
                viewModel.errorMessage = String(localized: "分享图片失败：\(error.localizedDescription)")
                viewModel.scheduleBannerDismiss()
                Haptics.error()
            }
        }
    }

    // MARK: - Inline dictation

    /// Toggles the device speech recognizer. While listening, the live
    /// transcript fills the input field; tap again to stop. This is plain
    /// dictation into the composer — there's no dedicated voice screen.
    private func applyWidgetLaunch(_ launch: OasesWidgetLaunch?) {
        guard let launch else { return }
        switch launch.action {
        case "camera":
            openCameraToken += 1
        case "voice":
            if !isDictating { toggleDictation() }
        default:
            composerFocused = true
        }
        widgetLaunch.wrappedValue = nil
    }

    private func toggleDictation() {
        if isDictating {
            dictation.stop()
            isDictating = false
            Haptics.tap()
        } else {
            Haptics.tap()
            isDictating = true
            dictation.requestAndStart { result in
                switch result {
                case .started:
                    isDictating = true
                case .denied:
                    isDictating = false
                    showDictationAlert = true
                case .failed:
                    isDictating = false
                    showDictationAlert = true
                }
            }
        }
    }
}

// MARK: - MessageRow

struct MessageRow: View {
    let message: ChatUIMessage
    var mode: AppMode = .chat
    /// Feeds the thinking mind while this reply is pending.
    var signals: AgentLiveSignals? = nil
    /// True only for the assistant turn that is still in flight. An empty
    /// finished message (e.g. a reply that was only tool calls) must not
    /// keep showing the "model is responding" loader.
    var isLive: Bool = false
    var onTapAttachment: (Attachment) -> Void = { _ in }
    /// 长按菜单里的"分享为图片"——生成整段会话的分享长图（与具体哪条
    /// 气泡无关，入口挂在通用长按菜单上）。
    var onShareAsImage: () -> Void = {}
    /// Message actions; nil while a reply is streaming.
    var onRetry: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var menu: MessageCopyMenu {
        MessageCopyMenu(content: message.content, onShareAsImage: onShareAsImage,
                        onRetry: onRetry, onEdit: onEdit, onDelete: onDelete)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: OasesSpacing.lg) }

            Group {
                if message.role == .assistant {
                    assistantBubble
                } else if message.role == .user {
                    userBubble
                } else {
                    AssistantPendingView(content: "", mode: mode)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer(minLength: OasesSpacing.lg) }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: OasesSpacing.xs) {
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                    .padding(.horizontal, OasesSpacing.sm)
                    .padding(.vertical, OasesSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: OasesRadius.userBubble, style: .continuous)
                            .fill(OasesColor.primary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: OasesRadius.userBubble, style: .continuous)
                            .strokeBorder(OasesColor.primary.opacity(0.16), lineWidth: 0.5)
                    )
                    .textSelection(.enabled)
                    .contextMenu { menu }
            }

            if let attachments = message.attachments, !attachments.isEmpty {
                AttachmentChips(attachments: attachments, onTap: onTapAttachment)
            }
        }
    }

    private var runningCall: ToolCall? {
        message.toolCalls.last { $0.status == .running || $0.status == .pending }
    }

    private var trailCalls: [ToolCall] {
        guard isLive else { return message.toolCalls }
        return message.toolCalls.filter { $0.status != .running && $0.status != .pending }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.xs) {
            if !message.toolCalls.isEmpty {
                if mode == .project {
                    OgentActivityStack(calls: message.toolCalls)
                } else if !trailCalls.isEmpty {
                    // While the reply is live, the running step is shown by the
                    // thinking mind below; the trail keeps the finished ones.
                    ChatToolTrail(calls: trailCalls)
                        .padding(.bottom, 2)
                }
            }
            if let url = message.imageUrl {
                ImageMessageView(imageUrl: url, plan: message.imageGenerationPlan)
            }
            if let audio = message.audioUrl {
                AudioMessageView(audioUrl: audio, mimeType: message.audioMimeType ?? "audio/mpeg")
            }
            // Pending placeholder → show the loader instead of the placeholder
            // text (mirrors Web `isPendingAssistantText` + AssistantPendingState).
            // Only while the turn is live; a finished turn with no text shows
            // just its tool pills / media.
            if AssistantPendingView.isPending(message.content),
               message.imageUrl == nil, message.audioUrl == nil {
                if isLive {
                    AssistantPendingView(content: message.content,
                                         mode: mode,
                                         imageGenerationPlan: message.imageGenerationPlan,
                                         runningTool: runningCall,
                                         signals: signals)
                        .padding(.vertical, OasesSpacing.xs)
                }
            } else if !message.content.isEmpty {
                // While streaming: an append-only text view that reveals new
                // words with a colour trail (re-parsing Markdown on every
                // flush would dominate the render budget on long replies).
                // Shortly after the stream ends it cross-fades to Markdown.
                AssistantStreamingBody(text: message.content, isStreaming: message.isStreaming) { menu }
            }
        }
    }
}

// MARK: - Message context menu (copy)

/// Shared long-press menu for both user and assistant bubbles. Copy is the
/// only universal action; "选择文本" routes to SwiftUI's native text
/// selection UI so the user can grab a substring instead of the whole
/// message. "分享为图片" renders the whole conversation as a share card
/// (see ShareCardView) — conversation-level, but the per-bubble menu is the
/// chat page's only existing share-adjacent entry point.
struct MessageCopyMenu: View {
    let content: String
    var onShareAsImage: (() -> Void)? = nil
    /// User message: send it again. Assistant message: regenerate it.
    var onRetry: (() -> Void)? = nil
    /// User message: put it back in the composer, dropping it and everything after it.
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        Button {
            UIPasteboard.general.string = content
            Haptics.tap()
            SoundEffects.shared.play(.copy)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        if let onRetry {
            Button(action: onRetry) {
                Label(String(localized: "重试", comment: "Chat message menu: send the message again / regenerate the reply"), systemImage: "arrow.clockwise")
            }
        }
        if let onEdit {
            Button(action: onEdit) {
                Label(String(localized: "编辑并重发", comment: "Chat message menu: put the message back in the composer, removing it and later messages"), systemImage: "pencil")
            }
        }
        if let onShareAsImage {
            Button {
                onShareAsImage()
            } label: {
                Label("分享为图片", systemImage: "square.and.arrow.up")
            }
        }
        if let onDelete {
            Button(role: .destructive, action: onDelete) {
                Label(String(localized: "删除这条消息", comment: "Chat message menu: delete this one message"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Attachment chips (under user bubble + in composer)

struct AttachmentChips: View {
    let attachments: [Attachment]
    var onTap: (Attachment) -> Void = { _ in }

    var body: some View {
        FlowLayout(spacing: OasesSpacing.xs) {
            ForEach(attachments) { item in
                chip(item)
                    .contentShape(Capsule())
                    .onTapGesture { onTap(item) }
            }
        }
    }

    @ViewBuilder
    private func chip(_ item: Attachment) -> some View {
        if item.kind == .image, let img = AttachmentImageCache.thumbnail(for: item) {
            HStack(spacing: 4) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.name).font(.oasesCaption()).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(OasesColor.card.opacity(0.7)))
            .overlay(Capsule().strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5))
        } else {
            Label {
                Text(item.name).font(.oasesCaption()).lineLimit(1)
            } icon: {
                Image(systemName: item.kind == .text ? "doc.text" : "paperclip")
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(OasesColor.card.opacity(0.7)))
            .overlay(Capsule().strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5))
        }
    }
}

// MARK: - Lightweight flow layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Assistant pending loaders (ports of Web MatrixLoader + ImageFxLoader)

/// Mirrors Web `isPendingAssistantText` + `AssistantPendingState`: picks the
/// right loader from the placeholder content + mode.
struct AssistantPendingView: View {
    let content: String
    let mode: AppMode
    var imageGenerationPlan: ImageGenerationPlan? = nil
    /// The tool call running right now, if any: the mind takes its object.
    var runningTool: ToolCall? = nil
    var signals: AgentLiveSignals? = nil

    // i18n-ignore: stored placeholder sentinels (compared, never displayed as-is)
    private static let pendingTexts: Set<String> = ["", "正在生成图片…", "正在合成语音…"]

    static func isPending(_ text: String) -> Bool {
        pendingTexts.contains(text.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        let text = content.trimmingCharacters(in: .whitespaces)
        switch text {
        case "正在生成图片…": // i18n-ignore: stored placeholder sentinel
            GridRevealView(image: nil, plan: imageGenerationPlan, caption: String(localized: "正在生成图片"))
        case "正在合成语音…": // i18n-ignore: stored placeholder sentinel
            ThinkingMindRow(shape: .notes, label: String(localized: "正在合成语音"), signals: signals)
        default:
            if let runningTool {
                ThinkingMindRow(
                    shape: DitherMindShape.forTool(named: runningTool.name),
                    label: ChatToolTrail.activeLabel(for: runningTool),
                    signals: signals
                )
            } else {
                ThinkingMindRow(shape: nil, label: String(localized: "正在思考…"), signals: signals)
            }
        }
    }
}

/// The thinking "mind" with one status line: what text chat shows while a
/// reply has nothing to read yet (the same mind Ogent uses).
struct ThinkingMindRow: View {
    /// The object; nil lets the mind pick one from the prompt.
    let shape: DitherMindShape?
    let label: String
    let signals: AgentLiveSignals?
    static let side: CGFloat = 88

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DitherMindView(shape: shape, signals: signals)
                .frame(width: Self.side, height: Self.side)
                .accessibilityHidden(true)
            Text(label)
                .font(.oasesCallout())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(1)
                .modifier(TrailShimmer(active: true))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Metallic chromium-flow loader for image generation — a Canvas-based
/// approximation of the Web `ImageFxLoader` (img-fx `pixels-organic` preset):
/// a charcoal card with a grid of dots coloured by flowing fbm ridge-noise,
/// throttled to ~10fps to match the original loading cadence, plus a shimmer
/// sweep and a footer "label / Image model warmup".
struct ImageFxLoaderView: View {
    var label: String

    private let palette: [Double] = [
        0x0f / 255, 0x4a / 255, 0xb9 / 255, 0x0f / 255, 0xd8 / 255, 0x0f / 255, 0x2f / 255
    ]
    private let cardBg = Color(red: 20/255, green: 22/255, blue: 24/255)

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    // Throttle to ~10fps (matches img-fx `1e3/10`).
                    let t = Self.throttledTime(timeline.date)
                    drawChromiumFlow(ctx: ctx, size: size, time: t)
                }
            }
            .frame(height: 150)
            .background(cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
            )
            .overlay(alignment: .leading) { shimmer }

            HStack {
                Text(label)
                    .font(.oasesCallout())
                    .foregroundStyle(OasesColor.foreground)
                Spacer()
                Text("Image model warmup")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(OasesColor.mutedForeground)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OasesColor.background.opacity(0.9))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
        )
        .frame(maxWidth: 360)
    }

    private var shimmer: some View {
        // `@keyframes thinking-shimmer` — a diagonal highlight sweeping 2.6s.
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, OasesColor.foreground.opacity(0.10), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: 120)
            .offset(x: -160)
            .modifier(ShimmerLoop())
            .mask(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static var start = Date()
    private static func throttledTime(_ now: Date) -> Double {
        let elapsed = now.timeIntervalSinceReferenceDate
        let frame = Int(elapsed * 10)          // 10fps
        return Double(frame) / 10.0
    }

    private func drawChromiumFlow(ctx: GraphicsContext, size: CGSize, time: Double) {
        let cell = 9.0
        let gap = 3.0
        let step = cell + gap
        let cols = Int(size.width / step)
        let rows = Int(size.height / step)
        let t = time * 0.3                       // u_speed

        for row in 0..<rows {
            for col in 0..<cols {
                let cx = Double(col)
                let cy = Double(row)
                // Two domain-warped noise fields → ridge → chromium streaks.
                let n1 = fbm(cx * 0.22, cy * 0.22, t: t * 0.5)
                let n2 = fbm(cx * 0.30 + 5.0, cy * 0.30 + 3.0, t: t * 0.3)
                let ridge1 = pow(1.0 - abs(n1), 5.0)
                let ridge2 = pow(1.0 - abs(n2), 4.0)
                let base = (n1 + n2) * 0.25 + 0.5
                let w1 = base * 0.6 + ridge1 * 1.2
                let w2 = (1.0 - base) * 0.6 + ridge2 * 1.0
                let v = clamp01(w1 * 0.5 + w2 * 0.5)

                let color = paletteColor(v)
                let radius = cell * 0.4 * (0.7 + 0.3 * ridge1)
                let rect = CGRect(
                    x: CGFloat(Double(col) * step + (step - radius * 2) / 2),
                    y: CGFloat(Double(row) * step + (step - radius * 2) / 2),
                    width: CGFloat(radius * 2), height: CGFloat(radius * 2)
                )
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.68)))
            }
        }
    }

    private func paletteColor(_ v: Double) -> Color {
        // Map 0..1 through the 7-colour greyscale palette via nearest pair.
        let f = max(0, min(Double(palette.count - 1), v * Double(palette.count - 1)))
        let i0 = Int(f)
        let i1 = min(i0 + 1, palette.count - 1)
        let frac = f - Double(i0)
        let g = palette[i0] + (palette[i1] - palette[i0]) * frac
        return Color(white: g)
    }

    private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
}

private struct ShimmerLoop: ViewModifier {
    @State private var x: CGFloat = -160
    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false)) {
                    x = 480
                }
            }
    }
}

// MARK: - Compact 2D value noise + fbm (for the chromium-flow field)

private func hash2(_ x: Int, _ y: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x) &* 374761393 &+ Int64(y) &* 668265263)
    h = (h ^ (h >> 13)) &* 1274126177
    return Double(h % 100000) / 100000.0
}

private func valueNoise(_ x: Double, _ y: Double) -> Double {
    let xi = Int(floor(x)); let yi = Int(floor(y))
    let xf = x - floor(x); let yf = y - floor(y)
    let u = xf * xf * (3 - 2 * xf)
    let v = yf * yf * (3 - 2 * yf)
    let a = hash2(xi, yi)
    let b = hash2(xi + 1, yi)
    let c = hash2(xi, yi + 1)
    let d = hash2(xi + 1, yi + 1)
    return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v
}

private func fbm(_ x: Double, _ y: Double, t: Double) -> Double {
    var val = 0.0, amp = 0.5, px = x, py = y
    let dx = cos(t) * 0.15, dy = sin(t) * 0.15
    for _ in 0..<4 {
        val += amp * valueNoise(px + dx, py + dy)
        px *= 2; py *= 2; amp *= 0.5
    }
    return val * 2 - 1
}

// MARK: - Attachment preview

/// Sheet that opens when an attachment chip is tapped — for images shows the
/// full-resolution picture (pinch / zoom via SwiftUI's built-in gestures),
/// for text-like files shows the inlined content, and for opaque binaries
/// surfaces the metadata so the user at least confirms what was attached.
struct AttachmentPreviewSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch attachment.kind {
                case .image:
                    imagePreview
                case .text:
                    textPreview
                case .file:
                    filePreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OasesColor.background.ignoresSafeArea())
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(OasesColor.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image = AttachmentImageCache.image(for: attachment) {
            ChatZoomableImageView(image: image)
        } else {
            placeholder(String(localized: "无法预览图片"))
        }
    }

    private var textPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(attachment.mimeType)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                Text(attachment.textContent ?? String(localized: "（空文件）"))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(OasesColor.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
        }
    }

    private var filePreview: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(OasesColor.mutedForeground)
            Text(attachment.name)
                .font(.oasesBodyBold())
                .foregroundStyle(OasesColor.foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(attachment.mimeType)
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
            Text("二进制文件正文未解析，已作为附件提示发送给模型。")
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
        }
        .padding()
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(OasesColor.mutedForeground)
            Text(text)
                .font(.oasesBody())
                .foregroundStyle(OasesColor.mutedForeground)
        }
    }
}

/// Image preview that honours the source asset's natural size — small images
/// (icons, thumbs) render at their actual pixel size centred on screen
/// instead of being upscaled to fill the sheet, fixing the blurry "stretched"
/// look in screenshot #3. Double-tap toggles a 2× zoom; pinch magnification
/// is honoured smoothly via SwiftUI's MagnificationGesture.
private struct ChatZoomableImageView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1.0
    @State private var pendingScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var pendingOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let baseFit = min(
                geo.size.width / image.size.width,
                geo.size.height / image.size.height,
                1.0 // never upscale beyond 1:1 pixel for clarity
            )
            let display = CGSize(
                width: image.size.width * baseFit,
                height: image.size.height * baseFit
            )
            let liveScale = scale * pendingScale
            // Bound the pan so the image can't be flicked off-screen — once
            // the user zooms past 1×, they can drag to inspect the edges,
            // but the displayed image never leaves the viewport.
            let maxOffsetX = max(0, (display.width * liveScale - geo.size.width) / 2)
            let maxOffsetY = max(0, (display.height * liveScale - geo.size.height) / 2)
            let clampedX = min(max(offset.width + pendingOffset.width, -maxOffsetX), maxOffsetX)
            let clampedY = min(max(offset.height + pendingOffset.height, -maxOffsetY), maxOffsetY)

            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: display.width, height: display.height)
                .scaleEffect(liveScale)
                .offset(x: clampedX, y: clampedY)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { pendingScale = $0 }
                            .onEnded { _ in
                                let next = min(max(scale * pendingScale, 1.0), 4.0)
                                scale = next
                                pendingScale = 1.0
                                if next == 1.0 { offset = .zero }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1.0 else { return }
                                pendingOffset = value.translation
                            }
                            .onEnded { _ in
                                offset.width = clampedX
                                offset.height = clampedY
                                pendingOffset = .zero
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        if scale > 1.0 {
                            scale = 1.0
                            offset = .zero
                        } else {
                            scale = 2.0
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ChatView(viewModel: ChatViewModel())
        .preferredColorScheme(.dark)
}
