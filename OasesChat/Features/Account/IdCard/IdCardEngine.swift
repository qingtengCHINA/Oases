import Foundation
import CoreGraphics

/// QingTeng Studio 账户卡的引擎：网站 `account/id-card/engine.ts` 的逐行移植（同样的常量、同样的算法、同样的舍入），
/// 只负责“世界”的一步和一帧的几何，不碰任何界面：
///
/// 1. 字标（"QingTeng" 是 Allura、"Studio" 是 Geist，`IdCardLockup`）一次性画进离屏位图，按格子采样成亮度表
///    （96 列 × 110 行）；表只和卡的构图有关，所有卡共用一份。
/// 2. 96 条等距竖线铺满卡面。每一帧每条线按格子走一遍亮度表：亮的格子粗、暗的格子细，只有四种粗细，所以线一节一节的，像竹子。
/// 3. 一层缓缓往下流的值噪声叠在表上，没人碰时线也在微微动。
/// 4. 手指附近的线被弹簧推开、松手后回位。手指在卡上时，蓝色的框吸附到字标最亮的两三处，角上标网格坐标，框之间有细线连着。
/// 5. 所有几何都在设备像素里算、对齐到整像素（和网站一样），所以任何尺寸下都清楚。
///
/// 构图（卡的单位：宽是 100）：左上是像素 QT 标志和 "QingTeng Studio"，左下是 UID。
/// 引擎只在一个线程上用（页面上是主线程；保存图片时是后台任务里新建的那一个），不做同步。
final class IdCardEngine {

    // MARK: - 常量（和网站一样）

    /// ISO/IEC 7810 ID-1，银行卡的比例。
    static let aspect = 85.6 / 53.98

    static let W = 100.0
    static let H = W / aspect
    static let cols = 96
    static let rows = 110
    static let cellW = W / Double(cols)
    static let cellH = H / Double(rows)

    /// 线宽（占线距的比例）和它们的不透明度：细线退后，粗线撑起字标。
    static let tierWidth: [Double] = [0.14, 0.32, 0.54, 0.8]
    static let tierAlpha: [Double] = [0.46, 0.74, 0.94, 1]
    /// 线升到下一档粗细的亮度。
    static let tierStep: [Double] = [0.24, 0.5, 0.74]

    static let pad = 6.4
    /// 像素标志的大小、旁边字标的缩放（字标单位 → 卡的单位）。
    static let icon = 6.0
    static let labelK = 0.037
    static let labelGap = 2.3
    /// UID 的字号（每 em 的卡单位）和数字之间多出的间距（em）。
    static let uidSize = 5.2
    static let uidTrack = 0.06
    /// 线离名字和 UID 这么远。
    static let clearance = 1.7

    /// 线画出来的大字标：从左边距到右边距，墨迹在卡上居中。
    static let artK = (W - 2 * pad) / (IdCardLockup.box[2] - IdCardLockup.box[0])
    static let artX = pad - IdCardLockup.box[0] * artK
    static let artBaseline = H / 2 + 0.6 - ((IdCardLockup.box[1] + IdCardLockup.box[3]) / 2) * artK

    /// 噪声：对表的影响有多大、颗粒（每个格点几格）、下落速度（每秒几行）。
    static let noiseAmount = 0.56
    static let noiseCols = 5.0
    static let noiseRows = 13.0
    static let noiseFall = 5.5

    /// 手指附近的推力：范围和力度（卡的单位），然后是把线拉回来的弹簧。
    static let scatterReach = 15.0
    static let scatterPush = 3.4
    static let spring = 0.16
    static let damping = 0.8

    /// 检测框：多久重新找一次（秒）、找的窗口（格）、两个框至少隔多少列、第三个框至少多强；
    /// 锁上和画连线用网站的 base 时长，消失用 fast 时长。
    static let detectEvery = 0.24
    static let detectCols = 6
    static let detectRows = 12
    static let detectApart = 15
    static let detectThird = 0.7
    static let lockIn = 0.25
    static let lockOut = 0.18

    /// 设备像素宽这么多的卡，台阶形圆角的一级台阶有几个设备像素。
    /// - Parameter deviceWidth: 卡的宽（设备像素）。
    /// - Returns: 台阶大小（设备像素），至少 2。
    static func step(deviceWidth: Int) -> Int {
        max(2, Int(IdCardPalette.jsRound(1.5 * Double(deviceWidth) / W)))
    }

    // MARK: - 共享的形状和亮度表

    /// 解析好的字标和字形（只解析一次）。
    /// （静态常量要可跨线程；`CGPath` 没标 Sendable，但这几条路径建好后再不改动。）
    struct Shapes: @unchecked Sendable {
        let script: CGPath
        let sans: CGPath
        let glyphs: [Character: CGPath]
    }

    static let shapes = Shapes(
        script: SVGPathParser.path(IdCardLockup.script),
        sans: SVGPathParser.path(IdCardLockup.sans),
        glyphs: IdCardLockup.monoGlyphs.mapValues { SVGPathParser.path($0) }
    )

    /// QTC 像素标志（14 × 14，和网站 `qtc-mark-grid.ts` 一样）。
    static let markGrid: [String] = [
        "....######....",
        "..##########..",
        ".###......###.",
        ".##........##.",
        "##..######..##",
        "##..######..##",
        "##....##....##",
        "##....##....##",
        "##....###...##",
        ".##....###.##.",
        ".###....###...",
        "..#####..###..",
        "....####..###.",
        "...........###",
    ]

    /// 像素标志按列拆成的竖条：`(列, 起始行, 行数)`。
    static let markRuns: [(x: Int, y: Int, n: Int)] = {
        let grid = markGrid.map { Array($0) }
        let size = grid.count
        var runs: [(x: Int, y: Int, n: Int)] = []
        for x in 0..<size {
            var start = -1
            for y in 0...size {
                let on = y < size && grid[y][x] == "#"
                if on && start < 0 { start = y }
                if !on && start >= 0 {
                    runs.append((x, start, y - start))
                    start = -1
                }
            }
        }
        return runs
    }()

    /// 亮度表（`cols × rows`，0～1），第一次用到时生成，所有卡共用。
    static let table: [Float] = makeTable()

    /// 把字标画进离屏位图，按格子平均成亮度表，再轻轻模糊、归一化（网站 `brightnessTable`）。
    /// - Returns: 亮度表；位图建不出来时全是 0。
    private static func makeTable() -> [Float] {
        let sx = 8
        let sy = 6
        let cw = cols * sx
        let ch = rows * sy
        var table = [Float](repeating: 0, count: cols * rows)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return table }
        // y 向下，和画布一样（数据的第 0 行就是画布的第 0 行）。
        ctx.translateBy(x: 0, y: CGFloat(ch))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(Double(cw) / W), y: CGFloat(Double(ch) / H))
        ctx.translateBy(x: CGFloat(artX), y: CGFloat(artBaseline))
        ctx.scaleBy(x: CGFloat(artK), y: CGFloat(artK))
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        ctx.setFillColor(white)
        ctx.setStrokeColor(white)
        ctx.addPath(shapes.script)
        ctx.fillPath()
        ctx.addPath(shapes.sans)
        ctx.fillPath()
        // Allura 的发丝线比 Studio 的竖画细得多：描粗一点，两半都能读成线。
        ctx.setLineWidth(7)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.butt)
        ctx.addPath(shapes.script)
        ctx.strokePath()
        guard let data = ctx.data else { return table }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cw * ch * 4)

        var raw = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum = 0
                for y in (r * sy)..<((r + 1) * sy) {
                    var p = (y * cw + c * sx) * 4 + 3
                    for _ in 0..<sx {
                        sum += Int(pixels[p])
                        p += 4
                    }
                }
                raw[r * cols + c] = Float(Double(sum) / Double(255 * sx * sy))
            }
        }
        // 横竖都轻轻模糊一下：落在两条线之间的笔画也能把两边都提亮一点。
        var maxValue = 0.0
        func at(_ rr: Int, _ cc: Int) -> Double {
            Double(raw[min(rows - 1, max(0, rr)) * cols + min(cols - 1, max(0, cc))])
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let v = 0.64 * Double(raw[r * cols + c]) + 0.08 * (at(r, c - 1) + at(r, c + 1)) + 0.1 * (at(r - 1, c) + at(r + 1, c))
                table[r * cols + c] = Float(v)
                if v > maxValue { maxValue = v }
            }
        }
        for i in 0..<table.count {
            table[i] = maxValue > 0 ? Float(pow(min(1, Double(table[i]) / (maxValue * 0.82)), 0.8)) : 0
        }
        return table
    }

    // MARK: - 噪声

    static let nx = Int((Double(cols) / noiseCols).rounded(.up)) * 2 + 4
    static let ny = 64

    /// 噪声格点（mulberry32，种子相同结果和网站逐位相同）。
    /// - Parameter seed: 种子；0 当作 1。
    /// - Returns: `nx × ny` 个 0～1 的值。
    static func lattice(seed: UInt32) -> [Float] {
        var s: UInt32 = seed == 0 ? 1 : seed
        var values = [Float](repeating: 0, count: nx * ny)
        for i in 0..<values.count {
            s = s &+ 0x6d2b_79f5
            var t = s
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            values[i] = Float(Double(t ^ (t >> 14)) / 4_294_967_296)
        }
        return values
    }

    /// 平滑的值噪声（0～1）；y 方向循环，所以可以一直往下落。
    @inline(__always)
    static func valueNoise(_ grid: UnsafeBufferPointer<Float>, _ x: Double, _ y: Double) -> Double {
        let xi = x.rounded(.down)
        let yf = y.rounded(.down)
        let tx = x - xi
        let ty = y - yf
        let y0 = ((Int(yf) % ny) + ny) % ny
        let y1 = (y0 + 1) % ny
        let x0 = Int(xi) % nx
        let x1 = (x0 + 1) % nx
        let sx = tx * tx * (3 - 2 * tx)
        let sy = ty * ty * (3 - 2 * ty)
        let g00 = Double(grid[y0 * nx + x0])
        let a = g00 + (Double(grid[y0 * nx + x1]) - g00) * sx
        let g10 = Double(grid[y1 * nx + x0])
        let b = g10 + (Double(grid[y1 * nx + x1]) - g10) * sx
        return a + (b - a) * sy
    }

    // MARK: - 一张卡的状态

    /// 一个检测框（格子坐标，含两端）和它的强度。
    struct Box: Equatable {
        var c0: Int
        var r0: Int
        var c1: Int
        var r1: Int
        var score: Double
    }

    let uid: Int?
    let palette: IdCardPalette
    /// UID 的文本（`#000001`），还没有 UID 时是 `nil`。
    let uidText: String?
    /// 连地面一起画（保存的图片；页面上底色是卡后面一层静止的视图）。
    let paintsGround: Bool

    private let grid: [Float]
    private var live: [Float]
    private var sums: [Float]
    private var shift: [Float]
    private var speed: [Float]
    private var settled = true

    /// 一帧不动：噪声不落、没有推散；检测框出现和消失不带动画（“减弱动态效果”）。
    private(set) var still: Bool

    private var time = 0.0
    private var last: Double?

    /// 手指的位置（占卡宽高的比例）；`nil` 表示不在卡上。
    private var pointer: CGPoint?
    /// 0 → 1 是框在锁上，回到 0 是在消失。
    private var lock = 0.0
    private var lockSince = 0.0
    private(set) var boxes: [Box] = []
    private var detectIn = 0.0

    /// 名字和 UID 两块不画线的区域（卡的单位）：`(x0, y0, x1, y1)`。
    private let clear: [(Double, Double, Double, Double)]
    private let uidBaseline = H - pad

    /// 按尺寸缓存的静态几何（裁剪形状、名字和 UID、卡边）。
    private var cached: (width: Int, height: Int, statics: Statics)?

    /// 创建一张卡。
    /// - Parameters:
    ///   - uid: UID；`nil` 时 UID 的位置是一排淡淡的短横，绝不编一个号码。
    ///   - still: 是否一帧不动（“减弱动态效果”或保存图片）。
    ///   - paintsGround: 是否连底色一起画。
    init(uid: Int?, still: Bool, paintsGround: Bool = false) {
        self.uid = uid
        self.palette = IdCardPalette.forUID(uid)
        self.uidText = uid.map(IdCardPalette.format)
        self.still = still
        self.paintsGround = paintsGround
        self.grid = Self.lattice(seed: IdCardPalette.seed(for: uid))
        let count = Self.cols * Self.rows
        live = [Float](repeating: 0, count: count)
        sums = [Float](repeating: 0, count: (Self.rows + 1) * (Self.cols + 1))
        shift = [Float](repeating: 0, count: count)
        speed = [Float](repeating: 0, count: count)

        let labelWidth = (IdCardLockup.box[2] - IdCardLockup.box[0]) * Self.labelK
        let uidWidth = Self.monoWidth(uidText ?? "#000000", size: Self.uidSize, track: Self.uidTrack)
        let p = Self.pad
        let cl = Self.clearance
        clear = [
            (p - cl, p - cl, p + Self.icon + Self.labelGap + labelWidth + cl, p + Self.icon + cl),
            (p - cl, (Self.H - p) - (IdCardLockup.monoCap / 100) * Self.uidSize - cl, p + uidWidth + cl, (Self.H - p) + cl),
        ]
    }

    /// 一串等宽字的宽度（卡的单位）。
    static func monoWidth(_ text: String, size: Double, track: Double = 0) -> Double {
        Double(text.count) * (IdCardLockup.monoAdvance / 100 + track) * size - track * size
    }

    /// 框要不要出现：手指在卡上。
    private var wanted: Bool { pointer != nil }

    // MARK: - 输入

    /// 手指的位置变了。
    /// - Parameters:
    ///   - point: 占卡宽高的比例（0～1）；`nil` 表示手指离开了。
    ///   - now: 现在（秒，和 `advance` 的同一个时钟）。
    func setPointer(_ point: CGPoint?, now: Double) {
        guard point != pointer else { return }
        let was = wanted
        pointer = point
        if !was && wanted { lockSince = now }
    }

    /// 切换“一帧不动”。
    /// - Parameter on: 是否不动。
    func setStill(_ on: Bool) {
        guard on != still else { return }
        still = on
        if on {
            for i in 0..<shift.count {
                shift[i] = 0
                speed[i] = 0
            }
            settled = true
        }
        last = nil
    }

    /// 从暂停回来（回到屏幕上、回到前台、检查视图关了）：下一步按 1/60 秒算，不补暂停的那段时间（网站 `schedule` 里的 `last = 0`）。
    func resume() {
        last = nil
    }

    /// 往前走到 `now`：在跑（屏幕上、前台、没被检查视图盖住）且不是“不动”时按经过的时间走一步，否则走一个零步
    /// （网站的 `paintNow`）。同一个时刻重复调用不会多走。
    /// - Parameters:
    ///   - now: 现在（秒）。
    ///   - running: 能不能动。
    func advance(now: Double, running: Bool) {
        if running && !still {
            if let last, abs(now - last) < 0.0005 { return }
            let dt = last.map { min(0.1, max(0, now - $0)) } ?? (1.0 / 60)
            last = now
            step(dt)
        } else {
            last = nil
            step(0)
        }
    }

    // MARK: - 世界的一步

    /// 世界的一步（网站 `step`）。
    /// - Parameter dt: 经过的秒数。
    private func step(_ dt: Double) {
        let cols = Self.cols
        let rows = Self.rows
        if !still { time += dt }
        let fall = time * Self.noiseFall
        Self.table.withUnsafeBufferPointer { table in
            grid.withUnsafeBufferPointer { grid in
                live.withUnsafeMutableBufferPointer { live in
                    for r in 0..<rows {
                        // 往下落：场随时间往行号大的方向移，所以每一行取的是更上面的一段。
                        let y = (Double(r) - fall) / Self.noiseRows
                        for c in 0..<cols {
                            let x = Double(c) / Self.noiseCols
                            let n = 0.68 * Self.valueNoise(grid, x, y) + 0.32 * Self.valueNoise(grid, x * 2.1 + 7, y * 2.1 + 13)
                            let i = r * cols + c
                            let t = Double(table[i])
                            // 噪声主要动暗的底，字标本身动得最少：字稳住，底在流。
                            live[i] = Float(t * 0.94 + 0.05 + (n - 0.5) * Self.noiseAmount * (1 - 0.6 * t))
                        }
                    }
                }
            }
        }

        // 推散：每个格子从原位被弹簧拉向它的推力位置，固定 60 Hz 一步，不管这一帧多长。
        if !still && (pointer != nil || !settled) {
            let px = pointer.map { Double($0.x) * Self.W } ?? 0
            let py = pointer.map { Double($0.y) * Self.H } ?? 0
            let steps = min(4, max(1, Int(IdCardPalette.jsRound(dt * 60))))
            var energy = 0.0
            let hasPointer = pointer != nil
            shift.withUnsafeMutableBufferPointer { shift in
                speed.withUnsafeMutableBufferPointer { speed in
                    for r in 0..<rows {
                        let dy = (Double(r) + 0.5) * Self.cellH - py
                        for c in 0..<cols {
                            let i = r * cols + c
                            var target = 0.0
                            if hasPointer {
                                let dx = (Double(c) + 0.5) * Self.cellW - px
                                let d = (dx * dx + dy * dy * 0.55).squareRoot()
                                if d < Self.scatterReach {
                                    let f = 1 - d / Self.scatterReach
                                    target = Self.scatterPush * f * f * (dx / (abs(dx) + 1.1))
                                }
                            }
                            var p = Double(shift[i])
                            var v = Double(speed[i])
                            for _ in 0..<steps {
                                v = (v + (target - p) * Self.spring) * Self.damping
                                p += v
                            }
                            shift[i] = Float(p)
                            speed[i] = Float(v)
                            energy = max(energy, abs(p) + abs(v))
                        }
                    }
                }
            }
            settled = !hasPointer && energy < 0.004
            if settled {
                for i in 0..<shift.count {
                    shift[i] = 0
                    speed[i] = 0
                }
            }
        }

        // 手指在卡上时框锁上，离开后淡出。
        let target = wanted ? 1.0 : 0.0
        if still {
            lock = target
        } else {
            lock = target > lock ? min(1, lock + dt / Self.lockIn) : max(0, lock - dt / Self.lockOut)
        }
        if lock > 0 {
            detectIn -= dt
            if boxes.isEmpty || (detectIn <= 0 && !still) {
                boxes = detect(previous: boxes)
                detectIn = Self.detectEvery
            }
        } else {
            boxes = []
            detectIn = 0
        }
    }

    // MARK: - 检测

    /// 字标最亮的两三处，按格子框起来；还差不多强的旧框留着，免得在几个差不多的地方之间跳。
    /// - Parameter previous: 上一次的框。
    /// - Returns: 新的框，按列从左到右。
    private func detect(previous: [Box]) -> [Box] {
        let cols = Self.cols
        let rows = Self.rows
        let wc = Self.detectCols
        let wr = Self.detectRows
        let stride = cols + 1
        live.withUnsafeBufferPointer { live in
            sums.withUnsafeMutableBufferPointer { sums in
                for r in 0..<rows {
                    var row = 0.0
                    for c in 0..<cols {
                        row += max(0, Double(live[r * cols + c]) - 0.25)
                        sums[(r + 1) * stride + c + 1] = Float(Double(sums[r * stride + c + 1]) + row)
                    }
                }
            }
        }
        var picked: [Box] = []
        sums.withUnsafeBufferPointer { sums in
            func area(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int) -> Double {
                Double(sums[r1 * stride + c1]) - Double(sums[r0 * stride + c1]) - Double(sums[r1 * stride + c0]) + Double(sums[r0 * stride + c0])
            }
            // 贪心：最亮的窗口，再找离它够远的最亮的一个，够强的话再要第三个。
            for k in 0..<3 {
                var best = 0.0
                var bc = -1
                var br = 0
                var c = 0
                while c + wc <= cols {
                    let near = picked.contains { abs($0.c0 - c) < Self.detectApart }
                    if !near {
                        var r = 0
                        while r + wr <= rows {
                            let score = area(c, r, c + wc, r + wr)
                            if score > best {
                                best = score
                                bc = c
                                br = r
                            }
                            r += 1
                        }
                    }
                    c += 1
                }
                if bc < 0 || (k == 2 && best < picked[0].score * Self.detectThird) { break }
                picked.append(Box(c0: bc, r0: br, c1: bc + wc - 1, r1: br + wr - 1, score: best))
            }
        }
        let found = picked.map(spread)
        let held = found.map { box -> Box in
            if let kept = previous.first(where: { Self.overlap($0, box) > 0.35 }), kept.score * 1.08 >= box.score {
                var copy = kept
                copy.score = box.score
                return copy
            }
            return box
        }
        // 稳定排序（和 JavaScript 的 sort 一样）。
        return held.enumerated().sorted { a, b in
            a.element.c0 != b.element.c0 ? a.element.c0 < b.element.c0 : a.offset < b.offset
        }.map(\.element)
    }

    /// 从一个亮窗口扩到它周围亮的格子（按亮度表本身的形状，所以边不会乱动）。
    private func spread(_ seed: Box) -> Box {
        let cols = Self.cols
        let rows = Self.rows
        var c0 = cols
        var r0 = rows
        var c1 = -1
        var r1 = -1
        let table = Self.table
        for r in max(0, seed.r0 - 5)...min(rows - 1, seed.r1 + 5) {
            for c in max(0, seed.c0 - 2)...min(cols - 1, seed.c1 + 2) {
                if table[r * cols + c] < 0.5 { continue }
                c0 = min(c0, c)
                c1 = max(c1, c)
                r0 = min(r0, r)
                r1 = max(r1, r)
            }
        }
        if c1 < 0 {
            c0 = seed.c0
            r0 = seed.r0
            c1 = seed.c1
            r1 = seed.r1
        }
        c0 = max(0, c0 - 1)
        c1 = min(cols - 1, c1 + 1)
        r0 = max(0, r0 - 2)
        r1 = min(rows - 1, r1 + 2)
        return Box(c0: c0, r0: r0, c1: c1, r1: r1, score: seed.score)
    }

    /// 两个框的交并比。
    private static func overlap(_ a: Box, _ b: Box) -> Double {
        let w = min(a.c1, b.c1) - max(a.c0, b.c0) + 1
        let h = min(a.r1, b.r1) - max(a.r0, b.r0) + 1
        if w <= 0 || h <= 0 { return 0 }
        let inter = Double(w * h)
        func size(_ x: Box) -> Double { Double((x.c1 - x.c0 + 1) * (x.r1 - x.r0 + 1)) }
        return inter / (size(a) + size(b) - inter)
    }

    // MARK: - 一帧的几何

    /// 只和尺寸有关的几何：裁剪用的台阶形状、名字和 UID、卡边。
    struct Statics {
        let clip: CGPath
        let label: [CGPath]
        let labelFaint: CGPath?
        let edge: CGPath
        let edgeWidth: CGFloat
    }

    /// 画这一帧要的全部几何（设备像素）。
    /// - Parameters:
    ///   - width: 宽（设备像素）。
    ///   - height: 高（设备像素）。
    ///   - dpr: 每个点几个设备像素（检测框标签的最小字号按它算）。
    ///   - now: 现在（秒）。
    /// - Returns: 这一帧。
    func frame(width: Int, height: Int, dpr: Double, now: Double) -> IdCardFrame {
        let statics: Statics
        if let cached, cached.width == width, cached.height == height {
            statics = cached.statics
        } else {
            statics = makeStatics(width: width, height: height)
            cached = (width, height, statics)
        }
        let unit = Double(width) / Self.W
        return IdCardFrame(
            width: width,
            height: height,
            palette: palette,
            paintsGround: paintsGround,
            clip: statics.clip,
            tiers: lines(unit: unit),
            label: statics.label,
            labelFaint: statics.labelFaint,
            boxes: boxOps(unit: unit, dpr: dpr, now: now),
            edge: statics.edge,
            edgeWidth: statics.edgeWidth
        )
    }

    /// 台阶形的卡的轮廓（设备像素），每边往里缩 `inset`。
    /// - Parameters:
    ///   - width: 宽（设备像素）。
    ///   - height: 高（设备像素）。
    ///   - inset: 往里缩多少。
    /// - Returns: 闭合路径。
    static func stepped(width: Int, height: Int, inset: Double) -> CGPath {
        let s = Double(step(deviceWidth: width))
        let w = Double(width) - inset
        let h = Double(height) - inset
        let o = inset
        let points: [(Double, Double)] = [
            (o, o + 2 * s), (o + s, o + 2 * s), (o + s, o + s), (o + 2 * s, o + s), (o + 2 * s, o),
            (w - 2 * s, o), (w - 2 * s, o + s), (w - s, o + s), (w - s, o + 2 * s), (w, o + 2 * s),
            (w, h - 2 * s), (w - s, h - 2 * s), (w - s, h - s), (w - 2 * s, h - s), (w - 2 * s, h),
            (o + 2 * s, h), (o + 2 * s, h - s), (o + s, h - s), (o + s, h - 2 * s), (o, h - 2 * s),
        ]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }

    /// 只和尺寸有关的那部分几何。
    private func makeStatics(width: Int, height: Int) -> Statics {
        let unit = Double(width) / Self.W
        let mark = CGMutablePath()

        // 像素 QT 标志画成线：每一列的竖条比格子窄一点，落在整像素上。
        let cell = max(2, IdCardPalette.jsRound(Self.icon * unit / 14))
        let bar = cell >= 4 ? cell - max(1, IdCardPalette.jsRound(cell * 0.3)) : cell - 1
        let ix = IdCardPalette.jsRound(Self.pad * unit)
        let iy = IdCardPalette.jsRound(Self.pad * unit + (Self.icon * unit - cell * 14) / 2)
        for run in Self.markRuns {
            mark.addRect(CGRect(x: ix + Double(run.x) * cell + ((cell - bar) / 2).rounded(.down), y: iy + Double(run.y) * cell,
                                 width: bar, height: Double(run.n) * cell))
        }
        // "QingTeng Studio"：Studio 的大写字母和标志垂直居中。
        let k = Self.labelK * unit
        let x = (Self.pad + Self.icon + Self.labelGap) * unit - IdCardLockup.box[0] * k
        let baseline = iy + (cell * 14) / 2 + (IdCardLockup.sansCap * k) / 2
        let lockup = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: IdCardPalette.jsRound(x), ty: IdCardPalette.jsRound(baseline))
        // 和网站一样一块一块分开填（同一条路径里方向相反的轮廓重叠时会互相抵消）。
        var label: [CGPath] = [
            mark,
            Self.shapes.script.copy(using: [lockup]) ?? Self.shapes.script,
            Self.shapes.sans.copy(using: [lockup]) ?? Self.shapes.sans,
        ]

        // UID，或者在它的位置上一排淡淡的短横。
        let ux = Self.pad * unit
        let uy = uidBaseline * unit
        var faint: CGMutablePath?
        if let uidText {
            let text = CGMutablePath()
            Self.addText(uidText, to: text, x: ux, baseline: uy, size: Self.uidSize, track: Self.uidTrack, unit: unit)
            label.append(text)
        } else {
            let dashes = CGMutablePath()
            Self.addText("#", to: dashes, x: ux, baseline: uy, size: Self.uidSize, track: Self.uidTrack, unit: unit)
            let advance = (IdCardLockup.monoAdvance / 100 + Self.uidTrack) * Self.uidSize * unit
            let cap = (IdCardLockup.monoCap / 100) * Self.uidSize * unit
            let dash = max(1, IdCardPalette.jsRound(0.11 * Self.uidSize * unit))
            for i in 1..<7 {
                dashes.addRect(CGRect(x: IdCardPalette.jsRound(ux + Double(i) * advance + advance * 0.12),
                                      y: IdCardPalette.jsRound(uy - cap / 2 - dash / 2),
                                      width: IdCardPalette.jsRound(advance * 0.62), height: dash))
            }
            faint = dashes
        }

        // 卡边就在轮廓里面：页面上一个设备像素，卡更大时按比例。
        let edge = max(1, IdCardPalette.jsRound(unit / 8))
        return Statics(
            clip: Self.stepped(width: width, height: height, inset: 0),
            label: label,
            labelFaint: faint,
            edge: Self.stepped(width: width, height: height, inset: edge / 2),
            edgeWidth: CGFloat(edge)
        )
    }

    /// 用等宽字形写一串字（网站 `text`）。
    /// - Parameters:
    ///   - value: 文本（只有 `IdCardLockup.monoGlyphs` 里的字符会画出来）。
    ///   - path: 加到这条路径上。
    ///   - x: 起点（设备像素）。
    ///   - baseline: 基线（设备像素）。
    ///   - size: 字号（卡的单位）。
    ///   - track: 额外字距（em）。
    ///   - unit: 每个卡单位几个设备像素。
    static func addText(_ value: String, to path: CGMutablePath, x: Double, baseline: Double, size: Double, track: Double = 0, unit: Double) {
        let k = size * unit / 100
        let advance = (IdCardLockup.monoAdvance / 100 + track) * size * unit
        for (i, ch) in value.enumerated() {
            guard let glyph = shapes.glyphs[ch] else { continue }
            let transform = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                              tx: IdCardPalette.jsRound(x + Double(i) * advance), ty: IdCardPalette.jsRound(baseline))
            path.addPath(glyph, transform: transform)
        }
    }

    /// 96 条线，按四种粗细各一条路径（网站 `drawLines`）。
    private func lines(unit: Double) -> [CGPath] {
        let cols = Self.cols
        let rows = Self.rows
        let spacing = Self.cellW * unit
        let rowH = Self.cellH * unit
        let widths = Self.tierWidth.map { max(1, IdCardPalette.jsRound($0 * spacing)) }
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath()]
        let boxes = clear.map { ($0.0 * unit, $0.1 * unit, $0.2 * unit, $0.3 * unit) }
        let step0 = Self.tierStep[0]
        let step1 = Self.tierStep[1]
        let step2 = Self.tierStep[2]

        live.withUnsafeBufferPointer { live in
            shift.withUnsafeBufferPointer { shift in
                for c in 0..<cols {
                    let base = (Double(c) + 0.5) * spacing
                    var runTier = -1
                    var runStart = 0
                    var runShift = 0.0
                    func flush(_ endRow: Int) {
                        guard runTier >= 0 else { return }
                        let w = widths[runTier]
                        let x = IdCardPalette.jsRound(base + runShift - w / 2)
                        let y0 = IdCardPalette.jsRound(Double(runStart) * rowH)
                        let y1 = IdCardPalette.jsRound(Double(endRow) * rowH)
                        if y1 > y0 { paths[runTier].addRect(CGRect(x: x, y: y0, width: w, height: y1 - y0)) }
                        runTier = -1
                    }
                    for r in 0..<rows {
                        let i = r * cols + c
                        let v = Double(live[i])
                        let tier = v < step0 ? 0 : v < step1 ? 1 : v < step2 ? 2 : 3
                        let dx = Double(shift[i]) * unit
                        let x = base + dx
                        let top = Double(r) * rowH
                        let bottom = top + rowH
                        var hidden = false
                        for (x0, y0, x1, y1) in boxes where x > x0 && x < x1 && bottom > y0 && top < y1 { hidden = true }
                        if hidden {
                            flush(r)
                            continue
                        }
                        // 同样粗细（同样推开）的一段是一个矩形：粗细一变就是两节之间的“竹节”。
                        if tier == runTier && abs(dx - runShift) < 0.5 { continue }
                        flush(r)
                        runTier = tier
                        runStart = r
                        runShift = dx
                    }
                    flush(rows)
                }
            }
        }
        return paths
    }

    /// 网站 EASE（0.23, 1, 0.32, 1）是很强的缓出；笔画用五次缓出就够接近。
    private static func easeOut(_ t: Double) -> Double {
        let u = 1 - min(1, max(0, t))
        return 1 - u * u * u * u * u
    }

    /// 检测框的绘制步骤（网站 `drawBoxes`），按顺序。
    private func boxOps(unit: Double, dpr: Double, now: Double) -> [IdCardFrame.Op] {
        guard lock > 0, !boxes.isEmpty else { return [] }
        let round = IdCardPalette.jsRound
        let e = still ? 1 : Self.easeOut(lock)
        let spacing = Self.cellW * unit
        let rowH = Self.cellH * unit
        let line = max(1, round(0.2 * unit))
        // 标签的字：比标志小一点，但不小于 8 个点。
        let tag = max(8 * dpr, 1.9 * unit)
        let corner = max(4, round(1.9 * unit))
        let inflate = (1 - e) * 2.4 * unit
        let detect = palette.detect
        var ops: [IdCardFrame.Op] = []

        let rects = boxes.map { b in
            (b: b,
             x0: round(Double(b.c0) * spacing - inflate),
             y0: round(Double(b.r0) * rowH - inflate),
             x1: round(Double(b.c1 + 1) * spacing + inflate),
             y1: round(Double(b.r1 + 1) * rowH + inflate))
        }

        // 相邻两个框之间的连线：从一个框的侧边出来，横过去，进下一个框的侧边，都在格子上。
        let traced = still ? 1 : Self.easeOut((now - lockSince - Self.lockIn * 0.5) / Self.lockIn)
        if traced > 0 {
            let width = max(1, round(line * 0.75))
            let o = width.truncatingRemainder(dividingBy: 2) / 2
            let path = CGMutablePath()
            var i = 0
            while i + 1 < rects.count {
                let a = rects[i]
                let b = rects[i + 1]
                let ay = round((a.y0 + a.y1) / 2) + o
                let by = round((b.y0 + b.y1) / 2) + o
                let ax = a.x1
                let bx = b.x0
                let mid = round((ax + bx) / 2) + o
                let total = abs(mid - ax) + abs(by - ay) + abs(bx - mid)
                var left = total * traced
                path.move(to: CGPoint(x: ax, y: ay))
                func seg(_ x: Double, _ y: Double, _ fx: Double, _ fy: Double) {
                    let len = abs(x - fx) + abs(y - fy)
                    if left <= 0 { return }
                    let t = min(1, left / max(1, len))
                    path.addLine(to: CGPoint(x: fx + (x - fx) * t, y: fy + (y - fy) * t))
                    left -= len
                }
                seg(mid, ay, ax, ay)
                seg(mid, by, mid, ay)
                seg(bx, by, mid, by)
                i += 1
            }
            ops.append(.stroke(path, detect, alpha: e, width: width))
            // 连线出发和到达的地方各一个节点。
            if traced >= 1 {
                let dot = max(2, round(0.7 * unit))
                let half = (dot / 2).rounded(.down)
                let nodes = CGMutablePath()
                var j = 0
                while j + 1 < rects.count {
                    let a = rects[j]
                    let b = rects[j + 1]
                    nodes.addRect(CGRect(x: a.x1 - half, y: round((a.y0 + a.y1) / 2) - half, width: dot, height: dot))
                    nodes.addRect(CGRect(x: b.x0 - half, y: round((b.y0 + b.y1) / 2) - half, width: dot, height: dot))
                    j += 1
                }
                ops.append(.fill(nodes, detect, alpha: e))
            }
        }

        for (b, x0, y0, x1, y1) in rects {
            // 里面一层淡淡的底、细框、更粗的角。
            ops.append(.fill(CGPath(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), transform: nil), detect, alpha: e * 0.1))
            let o = line.truncatingRemainder(dividingBy: 2) / 2
            ops.append(.stroke(CGPath(rect: CGRect(x: x0 + o, y: y0 + o, width: x1 - x0 - line, height: y1 - y0 - line), transform: nil),
                               detect, alpha: e, width: line))
            let k = line * 2
            let corners = CGMutablePath()
            for (cx, cy, sx, sy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
                corners.addRect(CGRect(x: sx > 0 ? cx : cx - corner, y: sy > 0 ? cy : cy - k, width: corner, height: k))
                corners.addRect(CGRect(x: sx > 0 ? cx : cx - k, y: sy > 0 ? cy : cy - corner, width: k, height: corner))
            }
            ops.append(.fill(corners, detect, alpha: e))

            // 角上的网格坐标：左上是实心标签，右下是框下面的数字。
            let size = tag / unit
            let pad = round(tag * 0.32)
            let top = "x\(Self.pad2(b.c0)) y\(Self.pad2(b.r0))"
            let tw = Self.monoWidth(top, size: size) * unit
            let th = round(tag * 1.12)
            let tx = x0
            let ty = y0 - th
            ops.append(.fill(CGPath(rect: CGRect(x: tx, y: ty, width: round(tw + pad * 2), height: th), transform: nil), detect, alpha: e))
            let topText = CGMutablePath()
            Self.addText(top, to: topText, x: tx + pad, baseline: ty + th / 2 + ((IdCardLockup.monoCap / 100) * tag) / 2, size: size, unit: unit)
            ops.append(.fill(topText, palette.detectInk, alpha: e))
            let bottom = "x\(Self.pad2(b.c1 + 1)) y\(Self.pad2(b.r1 + 1))"
            let bw = Self.monoWidth(bottom, size: size) * unit
            // 垫一块卡的底色，数字压在什么线上都看得清。
            ops.append(.fill(CGPath(rect: CGRect(x: round(x1 - bw - pad), y: y1, width: round(bw + pad * 2), height: th), transform: nil),
                             palette.ground, alpha: e * 0.86))
            let bottomText = CGMutablePath()
            Self.addText(bottom, to: bottomText, x: x1 - bw, baseline: y1 + th / 2 + ((IdCardLockup.monoCap / 100) * tag) / 2, size: size, unit: unit)
            ops.append(.fill(bottomText, detect, alpha: e))
        }
        return ops
    }

    /// 至少两位的数字（`padStart(2, "0")`）。
    private static func pad2(_ n: Int) -> String { n < 10 && n >= 0 ? "0\(n)" : "\(n)" }
}

/// 一帧要画的东西（设备像素，y 向下），由 `IdCardEngine.frame` 生成，`IdCardRendering` 画到 SwiftUI 或 Core Graphics 上。
struct IdCardFrame {

    /// 一个绘制步骤。
    enum Op {
        /// 填充（非零环绕），颜色再乘不透明度。
        case fill(CGPath, IdCardRGBA, alpha: Double)
        /// 描边（尖角、平头），颜色再乘不透明度。
        case stroke(CGPath, IdCardRGBA, alpha: Double, width: Double)
    }

    let width: Int
    let height: Int
    let palette: IdCardPalette
    /// 连底色一起画（保存的图片）。
    let paintsGround: Bool
    /// 台阶形的卡：底色、线、名字、框都裁在里面。
    let clip: CGPath
    /// 四种粗细的线。
    let tiers: [CGPath]
    /// 标志、名字和 UID（分开填）。
    let label: [CGPath]
    /// 还没有 UID 时那一排淡淡的短横（不透明度 0.32）。
    let labelFaint: CGPath?
    /// 检测框。
    let boxes: [Op]
    /// 卡边。
    let edge: CGPath
    let edgeWidth: CGFloat
}
