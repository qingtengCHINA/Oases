@preconcurrency import SwiftUI
import UIKit
import Photos

/// Shared bounds keep the known-size waiting canvas and the decoded image
/// aligned during the handoff. The image always uses aspect-fit, so no
/// provider output is cropped while the message bubble is resizing.
enum GeneratedImageLayout {
    static let maxHeight: CGFloat = 520
    static let cornerRadius: CGFloat = 18

    /// A frame cap derived from the same aspect ratio as the image. This
    /// prevents a portrait image from receiving a 700pt outer frame with a
    /// 292pt image floating inside it on iPad; wide images can still use all
    /// of the available message column.
    static func widthCap(for ratio: CGFloat) -> CGFloat {
        max(1, ratio * maxHeight)
    }
}

/// Native SwiftUI adaptation of the libraries.dev sweep-gradient idea. The
/// continuous diagonal light is intentionally quiet, runs at 10 fps, and
/// pauses for Reduce Motion or an inactive scene. A plan with no known ratio
/// uses a compact bar, because an automatic provider canvas cannot be predicted.
struct GridRevealView: View {
    var image: UIImage?
    var plan: ImageGenerationPlan? = nil
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()
    @State private var isVisible = false

    var body: some View {
        Group {
            if let image {
                FittedGeneratedImage(image: image)
            } else if let ratio = plan?.expectedAspectRatio {
                TimelineView(.animation(
                    minimumInterval: 0.1,
                    paused: reduceMotion || scenePhase != .active || !isVisible
                )) { timeline in
                    Canvas { context, size in
                        let elapsed = reduceMotion
                            ? 0
                            : timeline.date.timeIntervalSince(started)
                        Self.drawWaiting(in: &context, size: size, elapsed: elapsed)
                    }
                }
                .aspectRatio(CGFloat(ratio), contentMode: .fit)
                .frame(maxWidth: GeneratedImageLayout.widthCap(for: CGFloat(ratio)),
                       maxHeight: GeneratedImageLayout.maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: GeneratedImageLayout.cornerRadius,
                                             style: .continuous))
                .overlay(alignment: .bottomLeading) { captionOverlay }
            } else {
                CompactImagePendingView(caption: caption,
                                        reduceMotion: reduceMotion,
                                        scenePhase: scenePhase)
            }
        }
        .accessibilityLabel(caption ?? String(localized: "生成的图片"))
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    @ViewBuilder
    private var captionOverlay: some View {
        if let caption {
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OasesColor.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(OasesColor.card.opacity(0.78), in: Capsule())
                .padding(10)
        }
    }

    private static func drawWaiting(in context: inout GraphicsContext,
                                    size: CGSize,
                                    elapsed: TimeInterval) {
        let rect = CGRect(origin: .zero, size: size)
        let travel = max(size.width + size.height, 1)
        let sweep = (elapsed / 3.4 + 0.28).truncatingRemainder(dividingBy: 1.0)
        let diagonal = sweep * travel - size.height
        let bandHalfWidth = max(travel * 0.18, 42)

        // A quiet base wash keeps the initial Reduce Motion frame alive while
        // the two wide, translucent bands provide the continuous sweep.
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: OasesColor.card.opacity(0.92), location: 0),
                    .init(color: OasesColor.primary.opacity(0.08), location: 0.48),
                    .init(color: OasesColor.card.opacity(0.88), location: 1)
                ]),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )

        var wideBand = Path()
        wideBand.move(to: CGPoint(x: diagonal - bandHalfWidth, y: 0))
        wideBand.addLine(to: CGPoint(x: diagonal + bandHalfWidth, y: 0))
        wideBand.addLine(to: CGPoint(x: diagonal + bandHalfWidth - size.height, y: size.height))
        wideBand.addLine(to: CGPoint(x: diagonal - bandHalfWidth - size.height, y: size.height))
        wideBand.closeSubpath()
        context.fill(
            wideBand,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: OasesColor.primary.opacity(0.06), location: 0.2),
                    .init(color: OasesColor.primary.opacity(0.22), location: 0.5),
                    .init(color: OasesColor.primary.opacity(0.06), location: 0.8),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: CGPoint(x: diagonal - bandHalfWidth, y: 0),
                endPoint: CGPoint(x: diagonal + bandHalfWidth - size.height, y: size.height)
            )
        )

        let softOffset = travel * 0.16
        var softBand = Path()
        softBand.move(to: CGPoint(x: diagonal - softOffset - bandHalfWidth, y: 0))
        softBand.addLine(to: CGPoint(x: diagonal - softOffset + bandHalfWidth, y: 0))
        softBand.addLine(to: CGPoint(x: diagonal - softOffset + bandHalfWidth - size.height, y: size.height))
        softBand.addLine(to: CGPoint(x: diagonal - softOffset - bandHalfWidth - size.height, y: size.height))
        softBand.closeSubpath()
        context.fill(
            softBand,
            with: .linearGradient(
                Gradient(colors: [
                    .clear,
                    OasesColor.foreground.opacity(0.04),
                    .clear
                ]),
                startPoint: CGPoint(x: diagonal - softOffset - bandHalfWidth, y: 0),
                endPoint: CGPoint(x: diagonal - softOffset + bandHalfWidth - size.height, y: size.height)
            )
        )
    }
}

private struct CompactImagePendingView: View {
    let caption: String?
    let reduceMotion: Bool
    let scenePhase: ScenePhase
    @State private var isVisible = false

    var body: some View {
            TimelineView(.animation(minimumInterval: 0.1,
                                paused: reduceMotion || scenePhase != .active || !isVisible)) { context in
            let phase = reduceMotion
                ? 0.5
                : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.8) / 2.8
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OasesColor.card.opacity(0.78))
                GeometryReader { proxy in
                    let bandWidth = max(proxy.size.width * 0.22, 44)
                    LinearGradient(
                        colors: [.clear, OasesColor.primary.opacity(0.2), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: bandWidth)
                    .rotationEffect(.degrees(18))
                    .offset(x: (proxy.size.width + bandWidth) * phase - bandWidth)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(OasesColor.primary)
                    Text(caption ?? String(localized: "正在生成图片"))
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.foreground)
                }
                .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption ?? String(localized: "正在生成图片"))
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

struct FittedGeneratedImage: View {
    let image: UIImage

    var body: some View {
        let ratio = image.size.width / max(image.size.height, 1)
        Image(uiImage: image)
            .resizable()
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: GeneratedImageLayout.widthCap(for: ratio),
                   maxHeight: GeneratedImageLayout.maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: GeneratedImageLayout.cornerRadius,
                                         style: .continuous))
    }
}

struct ImageMessageView: View {
    let imageUrl: String
    var plan: ImageGenerationPlan? = nil

    @State private var showFullscreen = false
    @State private var loadedImage: UIImage?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var saveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.sm) {
            mediaFrame
                .onTapGesture {
                    Haptics.tap()
                    showFullscreen = true
                }
            actions
        }
        .padding(.top, OasesSpacing.xs)
        .task(id: imageUrl) {
            await loadImage()
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenImageViewer(imageUrl: imageUrl, plan: plan) { showFullscreen = false }
        }
    }

    @ViewBuilder
    private var mediaFrame: some View {
        if let image = loadedImage {
            FittedGeneratedImage(image: image)
                .overlay(
                    RoundedRectangle(cornerRadius: GeneratedImageLayout.cornerRadius,
                                     style: .continuous)
                        .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
                )
        } else if isLoading || loadError == nil {
            GridRevealView(image: nil, plan: plan, caption: String(localized: "正在加载图片"))
        } else if let loadError {
            failedPlaceholder(loadError)
        } else {
            GridRevealView(image: nil, plan: plan, caption: String(localized: "正在加载图片"))
        }
    }

    private func failedPlaceholder(_ text: String) -> some View {
        RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
            .fill(OasesColor.card.opacity(0.4))
            .aspectRatio(CGFloat(plan?.expectedAspectRatio ?? 2.2), contentMode: .fit)
            .frame(maxWidth: GeneratedImageLayout.widthCap(for: CGFloat(plan?.expectedAspectRatio ?? 2.2)),
                   maxHeight: GeneratedImageLayout.maxHeight)
            .overlay {
                VStack(spacing: OasesSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(OasesColor.mutedForeground)
                    Text(text).font(.oasesCaption()).foregroundStyle(OasesColor.mutedForeground)
                    Button("重试加载") {
                        Task { await loadImage() }
                    }
                    .font(.oasesCaptionBold())
                    .buttonStyle(.bordered)
                }
            }
    }

    private var actions: some View {
        HStack(spacing: OasesSpacing.sm) {
            Button {
                saveToAlbum()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            .buttonStyle(.plain)
            if let saveStatus {
                Text(saveStatus)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Save & share

    private func saveToAlbum() {
        Haptics.tap()
        Task { @MainActor in
            do {
                let image: UIImage
                if let loadedImage {
                    image = loadedImage
                } else {
                    image = try await GeneratedImageLoader.load(source: imageUrl)
                }
                loadedImage = image
                saveImageToAlbum(image)
            } catch {
                saveStatus = String(localized: "图片加载失败，可重试后保存")
            }
        }
    }

    @MainActor
    private func loadImage() async {
        guard !imageUrl.isEmpty else {
            loadError = String(localized: "图片地址无效")
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let image = try await GeneratedImageLoader.load(source: imageUrl)
            try Task.checkCancellation()
            loadedImage = image
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func saveImageToAlbum(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            let allowed = status == .authorized || status == .limited
            guard allowed else {
                DispatchQueue.main.async { saveStatus = String(localized: "需要相册权限才能保存") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    saveStatus = ok ? String(localized: "已保存到相册") : String(localized: "保存失败")
                }
            }
        }
    }
}

/// Full-screen image viewer. Pinch and double-tap zoom; the close button dismisses.
struct FullscreenImageViewer: View {
    let imageUrl: String
    var plan: ImageGenerationPlan? = nil
    var onDismiss: () -> Void
    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea()
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text(loadError)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("重试加载") { Task { await loadImage() } }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white.opacity(0.9))
            } else {
                GridRevealView(image: nil, plan: plan, caption: String(localized: "正在加载图片"))
                    .padding(.horizontal, 24)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.9), .black.opacity(0.35))
                            .padding()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .task(id: imageUrl) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard !imageUrl.isEmpty else {
            loadError = String(localized: "图片地址无效")
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await GeneratedImageLoader.load(source: imageUrl)
            try Task.checkCancellation()
            image = loaded
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.setImage(image)
    }
}

private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let photo = UIImageView()
    private var didFit = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        photo.contentMode = .scaleAspectFit
        addSubview(photo)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { nil }

    func setImage(_ image: UIImage) {
        guard photo.image !== image else { return }
        photo.image = image
        didFit = false
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = photo.image, bounds.width > 1, bounds.height > 1 else { return }
        if !didFit {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            photo.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            didFit = true
        }
        centerPhoto()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }

    private func centerPhoto() {
        let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
        let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
        photo.center = CGPoint(x: contentSize.width * 0.5 + offsetX, y: contentSize.height * 0.5 + offsetY)
    }

    @objc private func toggleZoom() {
        setZoomScale(zoomScale > 1.01 ? 1 : 2.5, animated: true)
    }
}
