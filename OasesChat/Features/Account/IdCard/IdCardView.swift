import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 活的卡面

/// 一张卡的引擎，按 UID 建一次（换了 UID 才重建），放在 `@State` 里跟着视图活。
@MainActor
final class IdCardEngineHolder {
    private var engine: IdCardEngine?

    /// 这个 UID 的引擎。
    /// - Parameters:
    ///   - uid: UID。
    ///   - still: 新建时是否“不动”。
    /// - Returns: 引擎。
    func engine(for uid: Int?, still: Bool) -> IdCardEngine {
        if let engine, engine.uid == uid { return engine }
        let made = IdCardEngine(uid: uid, still: still)
        engine = made
        return made
    }

    /// 动画从暂停回来：引擎的下一步不补暂停的时间。
    func resume() {
        engine?.resume()
    }
}

/// 卡面上动的那一层：线、名字、UID、检测框、卡边（底色是后面那层静止的 `IdCardSurface`）。
///
/// `TimelineView(.animation)` 里的 `Canvas`，每帧最多 60 次（和网站的 requestAnimationFrame 一样；弹簧按 60 Hz 一步），
/// 只在这些时候动：在屏幕上（滚出可见区域就停）、App 在前台、没被自己的检查视图盖住、没开“减弱动态效果”。
/// “减弱动态效果”时只画一帧静止的卡，手指按下时框直接出现、不推散。
struct IdCardFace: View {

    /// UID；`nil` 时 UID 的位置是一排淡淡的短横。
    let uid: Int?
    /// 手指的位置（占卡宽高的比例），没按着是 `nil`。
    var pointer: CGPoint?
    /// 暂停（检查视图打开时页面上的那张）。
    var paused = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var holder = IdCardEngineHolder()
    @State private var appeared = false
    @State private var onScreen = true

    /// 能不能动：在屏幕上、前台、没暂停、没开“减弱动态效果”。
    private var running: Bool {
        appeared && onScreen && scenePhase == .active && !paused && !reduceMotion
    }

    var body: some View {
        let running = self.running
        let still = reduceMotion
        let pointer = self.pointer
        let scale = Double(displayScale)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running)) { timeline in
            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let engine = holder.engine(for: uid, still: still)
                let now = timeline.date.timeIntervalSinceReferenceDate
                engine.setStill(still)
                engine.setPointer(pointer, now: now)
                engine.advance(now: now, running: running)
                let width = max(1, Int(IdCardPalette.jsRound(Double(size.width) * scale)))
                let height = max(1, Int(IdCardPalette.jsRound(Double(size.height) * scale)))
                engine.frame(width: width, height: height, dpr: scale, now: now).draw(in: &context, size: size)
            }
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onChange(of: running) { _, on in
            if on { holder.resume() }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // 不在滚动视图里（检查视图）就算在屏幕上；在的话看和可见区域有没有交集。
            guard let visible = proxy.bounds(of: .scrollView) else { return true }
            return visible.intersects(CGRect(origin: .zero, size: proxy.size))
        } action: { onScreen = $0 }
        .accessibilityHidden(true)
    }
}

// MARK: - 一整张卡

/// 卡的阴影：页面上的（深浅色不同）、检查视图里的、没有。
enum IdCardShadow {
    case page
    case inspect
    case none
}

/// 一整张卡：后面一层静止的底色（台阶形、带光泽和阴影，只画一次），前面是活的 `IdCardFace`。银行卡的比例。
struct IdCardSurface: View {

    let uid: Int?
    var pointer: CGPoint?
    var paused = false
    var shadow: IdCardShadow = .page

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let palette = IdCardPalette.forUID(uid)
        let points = IdCardGroundGradient.unitPoints
        ZStack {
            IdCardOutline(displayScale: displayScale)
                .fill(LinearGradient(stops: IdCardGroundGradient.stops(palette), startPoint: points.start, endPoint: points.end))
                .modifier(IdCardShadowModifier(shadow: shadow, dark: colorScheme == .dark))
            IdCardFace(uid: uid, pointer: pointer, paused: paused)
        }
        .aspectRatio(IdCardEngine.aspect, contentMode: .fit)
    }
}

/// 网站 `.qtc-idcard-shadow` 的两层投影（CSS 的模糊半径换成 SwiftUI 的半径要除以 2）。
private struct IdCardShadowModifier: ViewModifier {
    let shadow: IdCardShadow
    let dark: Bool

    func body(content: Content) -> some View {
        switch shadow {
        case .page where dark:
            content
                .shadow(color: .black.opacity(0.5), radius: 1, y: 2)
                .shadow(color: .black.opacity(0.55), radius: 13, y: 16)
        case .page:
            let ink = Color(.sRGB, red: 20 / 255, green: 16 / 255, blue: 48 / 255)
            content
                .shadow(color: ink.opacity(0.1), radius: 0.5, y: 1)
                .shadow(color: ink.opacity(0.16), radius: 9, y: 12)
        case .inspect:
            content.shadow(color: .black.opacity(0.55), radius: 30, y: 30)
        case .none:
            content
        }
    }
}

// MARK: - 页面上的卡

/// 网站的那条缓动曲线（0.23, 1, 0.32, 1）。
private func idCardEase(_ duration: Double) -> Animation {
    .timingCurve(0.23, 1, 0.32, 1, duration: duration)
}

/// 页面上的账户卡：手指按着时线被推开、框出现；轻点打开全屏的检查视图（保存图片在那里）；长按拷贝 UID（`#000001`）。
///
/// 检查视图打开时这张卡暂停、隐去（不会同时看到两张）。网站上的同一个组件：`account/IdCard.tsx`。
struct IdCard: View {

    /// UID；还没读到时是 `nil`（卡上是短横，没有拷贝和保存）。
    let uid: Int?

    @GestureState private var touch: CGPoint?
    @State private var size: CGSize = .zero
    /// 检查视图开着（页面上的卡暂停、隐去）。
    @State private var inspecting = false
    /// 全屏视图挂着（关闭动画放完才放下）。
    @State private var presented = false

    var body: some View {
        IdCardSurface(uid: uid, pointer: Self.fraction(touch, in: size), paused: inspecting)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(touch == nil ? 1 : 0.985)
            .animation(idCardEase(0.18), value: touch == nil)
            .opacity(inspecting ? 0 : 1)
            .animation(idCardEase(0.25), value: inspecting)
            .contentShape(Rectangle())
            // 页面上手指也能上下滚动：拖动和滚动同时生效。
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touch) { value, state, _ in state = value.location })
            .onTapGesture { open() }
            .contextMenu {
                if let uid {
                    Button {
                        Self.copy(IdCardPalette.format(uid))
                    } label: {
                        Label(QT("account.copyUid"), systemImage: "doc.on.doc")
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Self.accessibilityName(uid))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityActions {
                if let uid {
                    Button(QT("account.copyUid")) { Self.copy(IdCardPalette.format(uid)) }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $presented) {
                IdCardInspectView(uid: uid, onClose: close)
                    .presentationBackground(.clear)
            }
            #else
            .sheet(isPresented: $presented) {
                IdCardInspectView(uid: uid, onClose: close)
            }
            #endif
    }

    /// 打开检查视图：不用系统的上滑动画，检查视图自己淡入。
    private func open() {
        inspecting = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presented = true }
    }

    /// 检查视图的关闭动画放完了：放下全屏视图，页面上的卡回来。
    private func close() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presented = false }
        inspecting = false
    }

    /// 手指位置换成占卡宽高的比例。
    /// - Parameters:
    ///   - point: 手指位置（卡的坐标）。
    ///   - size: 卡的大小。
    /// - Returns: 比例；没按着或还不知道大小时为 `nil`。
    static func fraction(_ point: CGPoint?, in size: CGSize) -> CGPoint? {
        guard let point, size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    /// 读屏念的名字：“QingTeng Studio 账户卡 #000001”。
    static func accessibilityName(_ uid: Int?) -> String {
        QT("account.cardName") + (uid.map { " " + IdCardPalette.format($0) } ?? "")
    }

    /// 拷贝到剪贴板。
    /// - Parameter text: 文本。
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - 检查视图

/// 画好的图片文件（分享面板用）和它的预览图。
struct IdCardImageFile: @unchecked Sendable {
    let url: URL
    let image: CGImage
}

/// 全屏看卡（网站的 inspect 对话框）：页面压暗，卡尽量大（手机上左右各留 16 点），右上角上方是关闭，右下角下方是“保存图片”。
/// 卡按这个尺寸重新画；手指在卡上任何地方都推线、出框（这里不滚动）。点卡外面也关闭。两种外观下都是深色。
///
/// “保存图片”打开系统分享面板（面板里有“存储图像”）：图片在视图打开时就开始画（静止的卡，至少三倍大，`IdCardExport`），
/// 画好之前按钮上转圈。
struct IdCardInspectView: View {

    let uid: Int?
    /// 关闭动画放完之后调用。
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var touch: CGPoint?
    @State private var shown = false
    @State private var leaving = false
    @State private var cardSize: CGSize = .zero
    @State private var file: IdCardImageFile?
    @State private var preparing = false

    /// 网站深色主题的前景（按钮底）和背景（按钮字）。
    private static let ink = Color(.sRGB, red: 243 / 255, green: 242 / 255, blue: 248 / 255)
    private static let inkText = Color(.sRGB, red: 8 / 255, green: 6 / 255, blue: 14 / 255)

    var body: some View {
        GeometryReader { proxy in
            let width = Self.cardWidth(in: proxy.size)
            ZStack {
                Color(.sRGB, red: 4 / 255, green: 3 / 255, blue: 10 / 255, opacity: 0.9)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .opacity(shown ? 1 : 0)

                VStack(alignment: .trailing, spacing: 12) {
                    closeButton
                    IdCardSurface(uid: uid, pointer: IdCard.fraction(touch, in: cardSize), shadow: .inspect)
                        .frame(width: width)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).updating($touch) { value, state, _ in state = value.location })
                        .accessibilityElement()
                        .accessibilityLabel(IdCard.accessibilityName(uid))
                    saveButton(cardWidth: width)
                }
                .frame(width: width)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || reduceMotion ? 1 : (leaving ? 0.97 : 0.94))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { prepare(cardWidth: width) }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(idCardEase(0.25)) { shown = true }
        }
    }

    /// 卡的宽：不超过可用宽度（左右留边）、1024 点，也不超过高度允许的（上下给按钮留地方）。
    /// - Parameter size: 可用区域。
    /// - Returns: 宽（点）。
    static func cardWidth(in size: CGSize) -> CGFloat {
        let wide = size.width >= 640
        let horizontal: CGFloat = wide ? 40 : 16
        let vertical: CGFloat = wide ? 80 : 72
        return max(1, min(size.width - 2 * horizontal, 1024, (size.height - 2 * vertical) * IdCardEngine.aspect))
    }

    /// 右上角的关闭按钮。
    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(QT("common.close"))
    }

    /// “保存图片”：图片画好了是分享按钮，没画好是转圈（画失败了点一下再画）。
    @ViewBuilder
    private func saveButton(cardWidth: CGFloat) -> some View {
        if let uid {
            if let file {
                ShareLink(item: file.url,
                          preview: SharePreview(IdCardExport.fileName(uid: uid), image: Image(decorative: file.image, scale: 1))) {
                    saveLabel(busy: false)
                }
                .buttonStyle(.plain)
            } else {
                Button { prepare(cardWidth: cardWidth) } label: { saveLabel(busy: preparing) }
                    .buttonStyle(.plain)
                    .disabled(preparing)
            }
        }
    }

    /// 按钮的样子：网站的 ink 按钮（深色主题：近白的底、近黑的字，台阶形的角）。
    private func saveLabel(busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(Self.inkText)
            }
            Text(QT("account.saveImage"))
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(Self.inkText)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(SteppedRectangle(step: 6).fill(Self.ink))
        .contentShape(Rectangle())
    }

    /// 开始画图片（每个 UID、每个尺寸只画一次；在后台画，不卡界面）。
    /// - Parameter cardWidth: 卡的宽（点），图片宽是它的三倍（2400～4096 像素）。
    private func prepare(cardWidth: CGFloat) {
        guard let uid, file == nil, !preparing else { return }
        preparing = true
        let width = IdCardExport.imageWidth(cardWidth: cardWidth)
        // Holds only the two values it sets, never the view.
        Task { [preparing = $preparing, file = $file] in
            let made = await Task.detached(priority: .userInitiated) { () -> IdCardImageFile? in
                guard let result = try? IdCardExport.file(uid: uid, width: width) else { return nil }
                return IdCardImageFile(url: result.url, image: result.image)
            }.value
            preparing.wrappedValue = false
            file.wrappedValue = made
        }
    }

    /// 关闭：淡出、略微缩小，放完再告诉页面。
    private func dismiss() {
        guard shown else { return }
        leaving = true
        withAnimation(idCardEase(0.25)) {
            shown = false
        } completion: {
            onClose()
        }
    }
}
