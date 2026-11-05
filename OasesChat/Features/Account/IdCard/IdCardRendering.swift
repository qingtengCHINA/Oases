import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 颜色

extension IdCardRGBA {

    /// SwiftUI 颜色（sRGB）。
    /// - Parameter alpha: 再乘上的不透明度。
    /// - Returns: 颜色。
    func color(alpha: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a * alpha)
    }
}

// MARK: - 底色的渐变

/// 卡的底色和光泽：和网站 CSS 的 `linear-gradient(to bottom right, high, ground 55%, low)` 一样。
///
/// CSS 的 “to bottom right” 不是沿对角线，而是沿和另一条对角线垂直的方向，长度刚好让两个角取到两头的颜色；
/// 卡的比例固定，所以换成单位坐标后和尺寸无关。
enum IdCardGroundGradient {

    /// 三个色标。
    static func stops(_ palette: IdCardPalette) -> [Gradient.Stop] {
        [
            .init(color: palette.groundHigh.color(), location: 0),
            .init(color: palette.ground.color(), location: 0.55),
            .init(color: palette.groundLow.color(), location: 1),
        ]
    }

    /// 渐变线的起点和终点（单位坐标，相对卡的边框）。
    static var unitPoints: (start: UnitPoint, end: UnitPoint) {
        let a = IdCardEngine.aspect
        let p = 1 / (1 + a * a)  // h² / 对角线²
        let q = a * a / (1 + a * a)  // w² / 对角线²
        return (UnitPoint(x: 0.5 - p, y: 0.5 - q), UnitPoint(x: 0.5 + p, y: 0.5 + q))
    }

    /// 尺寸为 `size` 的卡上渐变线的起点和终点（网站 `drawGround` 的算法）。
    static func points(width w: Double, height h: Double) -> (CGPoint, CGPoint) {
        let diagonal = (w * w + h * h).squareRoot()
        let half = w * h / diagonal
        let ux = h / diagonal
        let uy = w / diagonal
        return (CGPoint(x: w / 2 - ux * half, y: h / 2 - uy * half), CGPoint(x: w / 2 + ux * half, y: h / 2 + uy * half))
    }
}

// MARK: - 画到 SwiftUI 上

extension IdCardFrame {

    /// 把这一帧画进 SwiftUI 的 `Canvas`（设备像素缩放到 `size` 个点）。
    /// - Parameters:
    ///   - context: Canvas 的绘图上下文。
    ///   - size: Canvas 的大小（点）。
    func draw(in context: inout GraphicsContext, size: CGSize) {
        context.scaleBy(x: size.width / CGFloat(width), y: size.height / CGFloat(height))
        var inner = context
        inner.clip(to: Path(clip))
        if paintsGround {
            let (start, end) = IdCardGroundGradient.points(width: Double(width), height: Double(height))
            inner.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)),
                       with: .linearGradient(Gradient(stops: IdCardGroundGradient.stops(palette)), startPoint: start, endPoint: end))
        }
        for (tier, path) in tiers.enumerated() {
            inner.fill(Path(path), with: .color(palette.line.color(alpha: IdCardEngine.tierAlpha[tier])))
        }
        let ink = palette.line.color()
        for path in label { inner.fill(Path(path), with: .color(ink)) }
        if let labelFaint { inner.fill(Path(labelFaint), with: .color(palette.line.color(alpha: 0.32))) }
        for op in boxes {
            switch op {
            case let .fill(path, color, alpha):
                inner.fill(Path(path), with: .color(color.color(alpha: alpha)))
            case let .stroke(path, color, alpha, width):
                inner.stroke(Path(path), with: .color(color.color(alpha: alpha)),
                             style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            }
        }
        context.stroke(Path(edge), with: .color(palette.edge.color()),
                       style: StrokeStyle(lineWidth: edgeWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    }

    /// 把这一帧画进 Core Graphics（保存图片、快照工具）。上下文必须已经是 y 向下、单位是设备像素。
    /// - Parameter cg: 绘图上下文。
    func draw(in cg: CGContext) {
        cg.saveGState()
        cg.addPath(clip)
        cg.clip()
        if paintsGround, let space = CGColorSpace(name: CGColorSpace.sRGB) {
            let colors = [palette.groundHigh.cgColor(), palette.ground.cgColor(), palette.groundLow.cgColor()] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
                let (start, end) = IdCardGroundGradient.points(width: Double(width), height: Double(height))
                cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        func fill(_ path: CGPath, _ color: CGColor) {
            cg.setFillColor(color)
            cg.addPath(path)
            cg.fillPath(using: .winding)
        }
        for (tier, path) in tiers.enumerated() { fill(path, palette.line.cgColor(alpha: IdCardEngine.tierAlpha[tier])) }
        for path in label { fill(path, palette.line.cgColor()) }
        if let labelFaint { fill(labelFaint, palette.line.cgColor(alpha: 0.32)) }
        cg.setLineCap(.butt)
        cg.setLineJoin(.miter)
        cg.setMiterLimit(10)
        for op in boxes {
            switch op {
            case let .fill(path, color, alpha):
                fill(path, color.cgColor(alpha: alpha))
            case let .stroke(path, color, alpha, width):
                cg.setStrokeColor(color.cgColor(alpha: alpha))
                cg.setLineWidth(width)
                cg.addPath(path)
                cg.strokePath()
            }
        }
        cg.restoreGState()
        cg.setStrokeColor(palette.edge.cgColor())
        cg.setLineWidth(edgeWidth)
        cg.setLineCap(.butt)
        cg.setLineJoin(.miter)
        cg.addPath(edge)
        cg.strokePath()
    }
}

// MARK: - 台阶形的卡

/// 四个角各往里退两级台阶的矩形（网站 `.qtc-px` 和账户卡的轮廓）。
struct SteppedRectangle: Shape {

    /// 一级台阶多大（点）。
    var step: CGFloat

    /// 轮廓。
    /// - Parameter rect: 边框。
    /// - Returns: 路径。
    func path(in rect: CGRect) -> Path {
        let s = step
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        var path = Path()
        path.addLines([
            CGPoint(x: x0, y: y0 + 2 * s), CGPoint(x: x0 + s, y: y0 + 2 * s), CGPoint(x: x0 + s, y: y0 + s),
            CGPoint(x: x0 + 2 * s, y: y0 + s), CGPoint(x: x0 + 2 * s, y: y0),
            CGPoint(x: x1 - 2 * s, y: y0), CGPoint(x: x1 - 2 * s, y: y0 + s), CGPoint(x: x1 - s, y: y0 + s),
            CGPoint(x: x1 - s, y: y0 + 2 * s), CGPoint(x: x1, y: y0 + 2 * s),
            CGPoint(x: x1, y: y1 - 2 * s), CGPoint(x: x1 - s, y: y1 - 2 * s), CGPoint(x: x1 - s, y: y1 - s),
            CGPoint(x: x1 - 2 * s, y: y1 - s), CGPoint(x: x1 - 2 * s, y: y1),
            CGPoint(x: x0 + 2 * s, y: y1), CGPoint(x: x0 + 2 * s, y: y1 - s), CGPoint(x: x0 + s, y: y1 - s),
            CGPoint(x: x0 + s, y: y1 - 2 * s), CGPoint(x: x0, y: y1 - 2 * s),
        ])
        path.closeSubpath()
        return path
    }
}

/// 账户卡的台阶形轮廓（点）。台阶按设备像素算（`IdCardEngine.step`），和 Canvas 里的裁剪严丝合缝。
struct IdCardOutline: Shape {

    /// 每个点几个设备像素。
    var displayScale: CGFloat

    /// 轮廓。
    /// - Parameter rect: 卡的边框。
    /// - Returns: 路径。
    func path(in rect: CGRect) -> Path {
        let scale = max(1, displayScale)
        let step = CGFloat(IdCardEngine.step(deviceWidth: Int(IdCardPalette.jsRound(Double(rect.width * scale))))) / scale
        return SteppedRectangle(step: step).path(in: rect)
    }
}

// MARK: - 保存图片

/// 账户卡存成图片（网站 `id-card/export.ts`）：不是拷贝屏幕上的画面，而是用同一个引擎、同样的颜色和种子在离屏重新画一帧，
/// 至少是卡的三倍大，连底色一起画。画的是“静止”的卡（“减弱动态效果”看到的那一帧）：噪声静止、没有推散、没有检测框。
/// 台阶形的四个角是透明的，放在什么底上都行；深色、浅色模式下一模一样。
enum IdCardExport {

    /// 图片宽多少像素：显示的卡的三倍，不小于 2400、不大于 4096。
    /// - Parameter cardWidth: 卡显示时的宽（点）。
    /// - Returns: 像素。
    static func imageWidth(cardWidth: CGFloat) -> Int {
        Int(IdCardPalette.jsRound(min(4096, max(2400, Double(cardWidth) * 3))))
    }

    /// 文件名，例如 `QingTeng-ID-000001.png`（UID 和卡上一样补零）。
    /// - Parameter uid: UID。
    /// - Returns: 文件名。
    static func fileName(uid: Int) -> String {
        "QingTeng-ID-\(IdCardPalette.format(uid).dropFirst()).png"
    }

    /// 画出静止的卡。
    /// - Parameters:
    ///   - uid: UID。
    ///   - width: 宽（像素）；高按卡的比例。
    /// - Returns: 图片；位图建不出来时为 `nil`。
    static func image(uid: Int, width: Int) -> CGImage? {
        let height = max(1, Int(IdCardPalette.jsRound(Double(width) / IdCardEngine.aspect)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let engine = IdCardEngine(uid: uid, still: true, paintsGround: true)
        engine.advance(now: 0, running: false)
        engine.frame(width: width, height: height, dpr: 1, now: 0).draw(in: cg)
        return cg.makeImage()
    }

    /// PNG 数据。
    /// - Parameter image: 图片。
    /// - Returns: PNG；编码失败为 `nil`。
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 画好、编码、写进临时目录（分享面板从这里拿文件，iOS 在面板里给出“存储图像”）。
    /// - Parameters:
    ///   - uid: UID。
    ///   - width: 宽（像素）。
    /// - Returns: 文件地址和预览图。
    /// - Throws: 画不出来、编码或写文件失败。
    static func file(uid: Int, width: Int) throws -> (url: URL, image: CGImage) {
        guard let image = image(uid: uid, width: width), let data = png(image) else { throw CocoaError(.fileWriteUnknown) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IdCard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(uid: uid))
        try data.write(to: url, options: .atomic)
        return (url, image)
    }
}
