@preconcurrency import AVFoundation
import BorderBeamKit
import Photos
import SwiftUI

/// Bottom composer with two rows:
///   row 1: multiline text field
///   row 2: [+] [✨ prompt] [model pill] [🎤 mic] [➤ send]
/// Matches Web's `.composer-shell` layout and is shared across all modes.
struct ComposerBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    var isStreaming: Bool
    var modelLabel: String = "Oases Fast"
    var placeholder: String = String(localized: "今天想聊点什么？")
    var disclaimer: String = String(localized: "Oases 是 AI，也可能犯错。请自行核对重要信息。")

    /// Driven by ChatView so tapping the chat surface dismisses the keyboard.
    var isFocused: FocusState<Bool>.Binding

    /// Inline dictation state — the mic button toggles the device speech
    /// recognizer and feeds the text field live (no dedicated voice screen).
    var isDictating: Bool = false

    var pendingAttachments: [Attachment] = []

    /// Driven by the host so it can render a full-screen tap-to-dismiss
    /// scrim behind the menu. Default falls back to internal state for
    /// previews / tests where the host doesn't care.
    var attachMenuOpen: Binding<Bool>? = nil

    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onAttachPhoto: () -> Void = {}
    var onCamera: () -> Void = {}
    var onAttachFile: () -> Void = {}
    var onPickRecentPhoto: (UIImage) -> Void = { _ in }
    /// Photo picked from the quick strip / album grid: the asset's local
    /// identifier plus its 280 px thumbnail. The host loads the original
    /// asset for the attachment and uses the thumbnail only as a fallback.
    /// When nil, the thumbnail goes to `onPickRecentPhoto` (previews).
    var onPickRecentAsset: ((String, UIImage) -> Void)? = nil
    var supportsDeepThink: Bool = false
    var deepThinkOn: Bool = false
    var onToggleDeepThink: () -> Void = {}
    var onRemoveAttachment: (String) -> Void = { _ in }
    var onPreviewAttachment: (Attachment) -> Void = { _ in }
    var onPrompt: () -> Void = {}
    var onPickModel: () -> Void = {}
    var onMic: () -> Void = {}
    /// Incremented by a home-screen widget deep link to open the in-composer camera.
    var openCameraToken: Int = 0

    private var sendDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingAttachments.isEmpty
    }

    @State private var fallbackAttachMenu = false
    @State private var stage: AttachStage = .closed
    @State private var quickExpanded = false
    @State private var plusPressed = false
    @State private var ignoreNextTap = false
    @State private var recentPhotos: [RecentPhotoThumb] = []
    @State private var cameraPosition: AVCaptureDevice.Position = .back
    @State private var cameraShutter = 0
    /// Camera access, refreshed whenever the camera stage opens. Without the
    /// check a denied camera showed a 540 pt black panel with no way out to
    /// Settings, and a first-time grant left the preview black because the
    /// session was configured before access existed.
    @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)

    private enum AttachStage: Equatable {
        case closed, menu, quick, camera, album
    }

    /// Starts with a little acceleration, then settles. Shared by the menu,
    /// the long-press photo strip, and the morph into camera or the album.
    private var attachMotion: Animation {
        .timingCurve(0.22, 0.9, 0.28, 1, duration: 0.46)
    }
    private var showAttachMenuBinding: Binding<Bool> {
        attachMenuOpen ?? $fallbackAttachMenu
    }
    private var showAttachMenu: Bool {
        get { showAttachMenuBinding.wrappedValue }
    }

    var body: some View {
        // Composer column:
        //   1. The shell (input + toolbar), with the custom attach menu
        //      overlaid above the + button.
        //   2. A gap then the disclaimer — when the keyboard is up the
        //      disclaimer is hidden so the shell can sit flush on the
        //      keyboard.
        //
        // `.padding(.bottom, -X)` extends the column DOWN into the host
        // safeAreaInset's reserved bottom strip so the disclaimer settles
        // close to the device edge ("贴着设备下边缘") instead of floating
        // 30+pt above it. The shift is dropped while typing so the input
        // never tucks under the home indicator with no breathing room.
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                shell
                    .allowsHitTesting(stage == .closed || stage == .menu)
                if stage != .closed {
                    attachWindow
                        .padding(.horizontal, stage == .menu || stage == .quick ? 8 : 4)
                        .padding(.bottom, 62)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }

            if !isFocused.wrappedValue {
                Color.clear.frame(height: 12)
                Text(disclaimer)
                    .font(.custom(OasesTypography.serif, size: 11, relativeTo: .footnote))
                    .foregroundStyle(OasesColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, isFocused.wrappedValue ? 4 : -18)
        .animation(.easeOut(duration: 0.18), value: isFocused.wrappedValue)
        .animation(attachMotion, value: stage)
        .animation(attachMotion, value: quickExpanded)
        .onChange(of: showAttachMenu) { _, open in
            if !open, stage != .closed {
                stage = .closed
                quickExpanded = false
            }
        }
        .onChange(of: openCameraToken) { _, token in
            if token > 0 { setStage(.camera) }
        }
        // No internal dismiss scrim — the host ChatView renders a
        // full-screen tap-to-dismiss layer behind the menu when
        // `attachMenuOpen` is bound, which is the correct UX (tap
        // ANYWHERE outside the menu to close, not just inside the
        // composer footprint).
    }

    private var attachWindow: some View {
        ZStack(alignment: .topLeading) {
            if stage == .menu { attachMenu }
            if stage == .quick { quickPhotos }
            if stage == .camera { cameraStage }
            if stage == .album { albumStage }
        }
        .frame(maxWidth: stage == .menu ? 268 : .infinity, alignment: .leading)
        .frame(height: panelHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                .fill(stage == .menu ? AnyShapeStyle(OasesColor.card) : AnyShapeStyle(.ultraThinMaterial))
                .opacity(stage == .camera || stage == .album ? 0 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
        .oasesShadow(stage == .quick ? .card : .floating)
        .scaleEffect(stage == .quick && !quickExpanded ? 0.22 : 1, anchor: .bottomLeading)
        .opacity(stage == .quick && !quickExpanded ? 0.35 : 1)
    }

    private var panelHeight: CGFloat? {
        switch stage {
        case .camera: return 540
        case .album: return 460
        default: return nil
        }
    }

    private var panelRadius: CGFloat {
        switch stage {
        case .menu: return 22
        case .quick: return 18
        default: return 28
        }
    }

    private var attachMenu: some View {
        VStack(spacing: 4) {
            attachMenuRow(icon: "camera", title: String(localized: "相机")) {
                setStage(.camera)
            }
            attachMenuRow(icon: "photo", title: String(localized: "照片")) {
                setStage(.album)
                Task { recentPhotos = await RecentPhotoThumb.load(limit: 90) }
            }
            attachMenuRow(icon: "paperclip", title: String(localized: "文件")) {
                setStage(.closed)
                onAttachFile()
            }
            if supportsDeepThink {
                attachMenuRow(icon: "sparkle", title: String(localized: "深入思考"), checked: deepThinkOn) {
                    onToggleDeepThink()
                    SoundEffects.shared.play(.toggle)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 248)
    }

    @ViewBuilder
    private func attachMenuRow(icon: String, title: String, checked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(OasesColor.muted.opacity(0.55)))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                Spacer(minLength: 0)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OasesColor.primary)
                }
            }
            .foregroundStyle(checked ? OasesColor.primary : OasesColor.foreground)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickPhotos: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentPhotos.prefix(6)) { photo in
                    Image(uiImage: photo.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            pickRecent(photo)
                            setStage(.closed)
                        }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 92)
        .clipped()
    }

    private var cameraStage: some View {
        ZStack {
            if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                VStack(spacing: 12) {
                    Text("这台设备没有相机")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                    Button("关闭") { setStage(.closed) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cameraAuthorization == .notDetermined {
                // Ask first; the preview is created only once access exists.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
                    }
            } else if cameraAuthorization != .authorized {
                cameraAccessDeniedView
            } else {
                FillCameraPreview(position: cameraPosition, shutter: cameraShutter) { image in
                    onPickRecentPhoto(image)
                    setStage(.closed)
                }
                VStack {
                    Spacer()
                    HStack {
                        Button { setStage(.closed) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { cameraShutter += 1 } label: {
                            Circle()
                                .fill(.white)
                                .frame(width: 68, height: 68)
                                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 4).padding(-6))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            cameraPosition = cameraPosition == .back ? .front : .back
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
                }
            }
        }
        .onAppear {
            cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    /// Denied or restricted camera: explain and offer the app's Settings page.
    private var cameraAccessDeniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(OasesColor.mutedForeground)
                .accessibilityHidden(true)
            Text("没有相机权限。请在“设置”中允许 Oases Chat 使用相机。")
                .font(.oasesBody())
                .foregroundStyle(OasesColor.mutedForeground)
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button("关闭") { setStage(.closed) }
                if cameraAuthorization == .denied,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    // `.restricted` (parental controls / MDM) cannot be
                    // changed in our Settings page, so no button there.
                    Button("前往设置") { UIApplication.shared.open(url) }
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumStage: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(recentPhotos) { photo in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(uiImage: photo.image)
                                .resizable()
                                .scaledToFill()
                                .allowsHitTesting(false)
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            pickRecent(photo)
                            setStage(.closed)
                        }
                }
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Button { setStage(.menu) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    setStage(.closed)
                    onAttachPhoto()
                } label: {
                    Text("全部照片")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.72), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func pickRecent(_ photo: RecentPhotoThumb) {
        if let onPickRecentAsset {
            onPickRecentAsset(photo.id, photo.image)
        } else {
            onPickRecentPhoto(photo.image)
        }
    }

    private func setStage(_ next: AttachStage) {
        withAnimation(attachMotion) {
            stage = next
            showAttachMenuBinding.wrappedValue = next != .closed
            if next != .quick { quickExpanded = next == .closed ? false : quickExpanded }
        }
        if next == .quick {
            quickExpanded = false
            DispatchQueue.main.async {
                withAnimation(attachMotion) { quickExpanded = true }
            }
        }
    }

    private func openQuickPhotos() {
        Haptics.medium()
        Task { recentPhotos = await RecentPhotoThumb.load(limit: 6) }
        setStage(.quick)
    }

    private var shell: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingAttachments.isEmpty {
                attachmentRow
            }
            if isDictating {
                DictationIndicator()
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text, axis: .vertical)
                    .focused(isFocused)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                    .tint(OasesColor.primary)
                    .lineLimit(1...6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 14)
                    .frame(minHeight: 48)
            }

            toolbar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: OasesRadius.composerShell, style: .continuous)
                .fill(OasesColor.card.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.composerShell, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5)
        )
        .oasesShadow(.overlay)
        // Border beam while the model streams — web `border-beam` recipe
        // "Chat composer while the model streams". Pure overlay: with
        // `active: false` the effect layers unmount after the fade-out, so
        // idle has zero rendering cost. `borderRadius` must be passed
        // explicitly (SwiftUI can't read the corner radius); 29 matches
        // `OasesRadius.composerShell` on the background/overlay above.
        .borderBeam(
            .md,
            colorVariant: .colorful,
            theme: .auto,
            // Reduce Motion: no travelling beam.
            active: isStreaming && !reduceMotion,
            borderRadius: Double(OasesRadius.composerShell),
            strength: 0.8
        )
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OasesSpacing.xs) {
                ForEach(pendingAttachments) { item in
                    PendingAttachmentChip(
                        item: item,
                        onPreview: { onPreviewAttachment(item) },
                        onRemove: { onRemoveAttachment(item.id) }
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            // The + button toggles a custom floating menu anchored from the
            // ComposerBar's overlay (see `attachMenu`). SwiftUI's `.popover`
            // renders an empty bubble on iPhone compact, so the manual panel
            // is what actually works in production.
            Image(systemName: stage == .closed ? "plus" : "xmark")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(stage == .closed ? OasesColor.foreground : OasesColor.primary)
                .scaleEffect(plusPressed ? 0.82 : 1)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.38, pressing: { pressing in
                    withAnimation(.easeOut(duration: 0.12)) { plusPressed = pressing }
                }, perform: {
                    ignoreNextTap = true
                    plusPressed = false
                    openQuickPhotos()
                })
                .onTapGesture {
                    if ignoreNextTap {
                        ignoreNextTap = false
                        return
                    }
                    Haptics.tap()
                    setStage(stage == .closed ? .menu : .closed)
                }
                .accessibilityLabel("添加附件")
                .accessibilityHint("轻点打开菜单，长按选择最近照片")

            toolIcon("sparkles", action: onPrompt, label: String(localized: "提示词模板"))

            Button(action: onPickModel) {
                HStack(spacing: 4) {
                    Text(modelLabel)
                        .font(.custom(OasesTypography.serifBold, size: 14, relativeTo: .caption))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(OasesColor.foreground.opacity(0.9))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OasesColor.background.opacity(0.7))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择模型")

            Spacer(minLength: 0)

            // Single mic button — toggles the device dictation that fills the
            // input field live. The separate "voice mode" button was removed
            // (it was a duplicate of this).
            Button(action: onMic) {
                Image(systemName: isDictating ? "mic.fill" : "mic")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(isDictating ? OasesColor.destructive : OasesColor.mutedForeground)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: isDictating)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDictating ? "停止听写" : "开始听写")

            // The accent is for the primary action only: Send. Stop and a disabled Send sit on
            // the neutral muted fill.
            Button(action: isStreaming ? onStop : onSend) {
                let neutral = isStreaming || sendDisabled
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: isStreaming ? 15 : 17, weight: .bold))
                    .foregroundStyle(isStreaming ? OasesColor.foreground : (sendDisabled ? OasesColor.mutedForeground : .white))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(neutral ? OasesColor.muted : OasesColor.primary))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(OasesMotion.feedback, value: neutral)
            }
            .buttonStyle(OasesPressStyle(scale: 0.94))
            .disabled(sendDisabled && !isStreaming)
            // iPad hardware keyboard: ⌘↩ sends (plain Return keeps inserting
            // a newline in the multiline field). Not bound while streaming,
            // so the chord can't stop a reply by accident.
            .keyboardShortcut(isStreaming ? nil : KeyboardShortcut(.return, modifiers: .command))
            .accessibilityLabel(isStreaming ? "停止生成" : "发送消息")
        }
    }

    @ViewBuilder
    private func toolIcon(_ systemName: String, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(OasesColor.mutedForeground)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Pending attachment chip (with remove button)

private struct PendingAttachmentChip: View {
    let item: Attachment
    var onPreview: () -> Void = {}
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Uses `AttachmentImageCache` so each chip decodes the base64
            // data URL exactly once — without this, every keystroke caused
            // a full base64→UIImage decode pass on every attached chip
            // (the typing lag the user reported in this round). The chip
            // gets a small thumbnail, not the full image.
            if item.kind == .image, let img = AttachmentImageCache.thumbnail(for: item) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: item.kind == .text ? "doc.text" : "paperclip")
                    .font(.system(size: 11))
            }
            Text(item.name)
                .font(.oasesCaption())
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(OasesColor.card.opacity(0.8)))
        .overlay(Capsule().strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5))
        // Tap the body (anywhere except the × button) to open the preview.
        .contentShape(Capsule())
        .onTapGesture { onPreview() }
    }
}

struct RecentPhotoThumb: Identifiable {
    let id: String
    let image: UIImage

    /// Original bytes of the asset (HEIC / JPEG / PNG as stored, iCloud
    /// download allowed). The strip's 280 px thumbnails are far too small to
    /// send as an attachment.
    static func originalImageData(localIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier], options: nil
            ).firstObject else {
                continuation.resume(returning: nil)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func load(limit: Int) async -> [RecentPhotoThumb] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let allowed: Bool
        if status == .notDetermined {
            let next = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            allowed = next == .authorized || next == .limited
        } else {
            allowed = status == .authorized || status == .limited
        }
        guard allowed else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            let manager = PHImageManager.default()
            let request = PHImageRequestOptions()
            request.deliveryMode = .highQualityFormat
            request.resizeMode = .fast
            request.isSynchronous = true
            request.isNetworkAccessAllowed = true
            var thumbs: [RecentPhotoThumb] = []
            assets.enumerateObjects { asset, _, _ in
                var image: UIImage?
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 280, height: 280),
                    contentMode: .aspectFill,
                    options: request
                ) { result, _ in
                    image = result
                }
                if let image {
                    thumbs.append(RecentPhotoThumb(id: asset.localIdentifier, image: image))
                }
            }
            return thumbs
        }.value
    }
}

/// Camera preview that fills the attach window. Shutter and flip sit on top of the picture.
private struct FillCameraPreview: UIViewControllerRepresentable {
    var position: AVCaptureDevice.Position
    var shutter: Int
    var onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> FillCameraController {
        let controller = FillCameraController()
        controller.onCapture = onCapture
        controller.use(position: position)
        return controller
    }

    func updateUIViewController(_ controller: FillCameraController, context: Context) {
        controller.onCapture = onCapture
        if controller.position != position {
            controller.use(position: position)
        }
        if context.coordinator.lastShutter != shutter {
            context.coordinator.lastShutter = shutter
            if shutter > 0 { controller.capture() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastShutter = 0
    }
}

@objcMembers
final class FillCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: (UIImage) -> Void = { _ in }
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let preview = AVCaptureVideoPreviewLayer()
    private(set) var position: AVCaptureDevice.Position = .back
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.videoGravity = .resizeAspectFill
        preview.session = session
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
    }

    func use(position: AVCaptureDevice.Position) {
        self.position = position
        let apply = { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if !self.configured, self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
                self.configured = true
            }
            self.session.commitConfiguration()
        }
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async(execute: apply)
        } else {
            apply()
        }
    }

    func capture() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { self.onCapture(image) }
    }
}

#Preview {
    struct ComposerPreview: View {
        @State var text = ""
        @FocusState var focused: Bool
        var body: some View {
            VStack {
                Spacer()
                ComposerBar(text: $text, isStreaming: false, isFocused: $focused, onSend: {})
            }
            .background(OasesColor.background)
            .preferredColorScheme(.dark)
        }
    }
    return ComposerPreview()
}
