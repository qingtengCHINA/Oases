import Foundation
import CoreGraphics

/// 一个 sRGB 颜色：`r`、`g`、`b` 是 0～255 的整数值（和 CSS 的 `rgb()` 一样），`a` 是 0～1 的不透明度。
struct IdCardRGBA: Equatable, Sendable {

    /// 红，0～255。
    var r: Double
    /// 绿，0～255。
    var g: Double
    /// 蓝，0～255。
    var b: Double
    /// 不透明度，0～1。
    var a: Double = 1

    /// Core Graphics 颜色（sRGB）。
    /// - Parameter alpha: 再乘上的不透明度（画布的 `globalAlpha`）。
    /// - Returns: 颜色。
    func cgColor(alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a * alpha)
    }
}

/// 账户卡的配色（网站 `id-card/palette.ts` 的逐行移植）：十二对精选的底色 / 线色，再按 UID 的哈希转几度色相，
/// 同一个 UID 永远是同一张卡、和网站上的颜色一样。颜色用 OKLCH 写，按 UID 转色相时每一对的对比度不变。
struct IdCardPalette: Equatable, Sendable {

    /// 这一对的名字（Porcelain、Bamboo……）。
    let name: String
    /// 卡的底色。
    let ground: IdCardRGBA
    /// 底色亮一点、暗一点：卡面的光泽从一头过渡到另一头。
    let groundHigh: IdCardRGBA
    /// 见 `groundHigh`。
    let groundLow: IdCardRGBA
    /// 线、标志、名字和 UID 的颜色。
    let line: IdCardRGBA
    /// 检测框的蓝。
    let detect: IdCardRGBA
    /// 实心检测标签上的字。
    let detectInk: IdCardRGBA
    /// 卡边那一像素的颜色。
    let edge: IdCardRGBA
    /// 浅色底（深色的边、更淡的阴影）。
    let light: Bool

    /// OKLCH 颜色：亮度、彩度、色相（度）。
    typealias LCH = (l: Double, c: Double, h: Double)

    /// 一对颜色：底、线、检测框。
    struct Pair: Sendable {
        let name: String
        let ground: LCH
        let line: LCH
        let detect: LCH
    }

    /// 十二对（顺序和数值都和网站一样，哈希按下标挑）。
    static let pairs: [Pair] = [
        Pair(name: "Porcelain", ground: (0.925, 0.004, 95), line: (0.19, 0.006, 270), detect: (0.54, 0.22, 263)),
        Pair(name: "Cobalt", ground: (0.46, 0.2, 266), line: (0.86, 0.075, 252), detect: (0.9, 0.12, 212)),
        Pair(name: "Sand", ground: (0.88, 0.032, 78), line: (0.29, 0.035, 55), detect: (0.53, 0.2, 262)),
        Pair(name: "Bamboo", ground: (0.28, 0.045, 163), line: (0.86, 0.085, 158), detect: (0.72, 0.15, 243)),
        Pair(name: "Ivory", ground: (0.955, 0.014, 88), line: (0.39, 0.13, 22), detect: (0.53, 0.21, 262)),
        Pair(name: "Graphite", ground: (0.25, 0.006, 275), line: (0.9, 0.18, 122), detect: (0.68, 0.17, 255)),
        Pair(name: "Noir", ground: (0.165, 0.004, 285), line: (0.61, 0.22, 27), detect: (0.66, 0.18, 257)),
        Pair(name: "Terracotta", ground: (0.54, 0.125, 38), line: (0.95, 0.03, 80), detect: (0.86, 0.1, 232)),
        Pair(name: "Lagoon", ground: (0.43, 0.075, 195), line: (0.9, 0.075, 185), detect: (0.82, 0.11, 245)),
        Pair(name: "Blush", ground: (0.9, 0.035, 22), line: (0.36, 0.11, 8), detect: (0.53, 0.2, 263)),
        Pair(name: "Midnight", ground: (0.23, 0.06, 268), line: (0.84, 0.115, 84), detect: (0.7, 0.16, 252)),
        Pair(name: "Violet", ground: (0.5, 0.235, 287), line: (0.91, 0.05, 292), detect: (0.88, 0.11, 222)),
    ]

    /// UID 的 32 位哈希（murmur3 的收尾混合，作用在低 32 位和高 32 位上）：相邻的号码落得很远。
    /// - Parameter uid: 账号的 UID（非负）。
    /// - Returns: 和网站 `uidHash` 逐位相同的结果。
    static func uidHash(_ uid: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: uid) ^ (UInt32(truncatingIfNeeded: uid >> 32) &* 0x9e37_79b1)
        h ^= h >> 16
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    /// 一张卡的噪声种子：每个 UID 一个自己的图案；UID 还不知道时是一个固定图案。
    /// - Parameter uid: UID；`nil` 表示还没读到。
    /// - Returns: 种子。
    static func seed(for uid: Int?) -> UInt32 {
        guard let uid else { return 0x5eed }
        return uidHash(uid)
    }

    /// JavaScript 的 `Math.round`：0.5 一律往大的方向进（负数也是），和 Swift 的 `rounded()` 不同。
    /// - Parameter x: 数。
    /// - Returns: 舍入后的数。
    @inline(__always)
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// OKLCH → sRGB 0～255（网站 `oklchToRgb` 的逐行移植，超出色域的截到边上）。
    /// - Parameter lch: 颜色。
    /// - Returns: 红绿蓝。
    static func oklchToRGB(_ lch: LCH) -> (Double, Double, Double) {
        let a = lch.c * cos(lch.h * .pi / 180)
        let b = lch.c * sin(lch.h * .pi / 180)
        let l_ = pow3(lch.l + 0.3963377774 * a + 0.2158037573 * b)
        let m_ = pow3(lch.l - 0.1055613458 * a - 0.0638541728 * b)
        let s_ = pow3(lch.l - 0.0894841775 * a - 1.291485548 * b)
        let linear = [
            4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_,
        ]
        let encoded = linear.map { v -> Double in
            let g = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055
            return jsRound(min(1, max(0, g)) * 255)
        }
        return (encoded[0], encoded[1], encoded[2])
    }

    /// 三次方（JavaScript 的 `x ** 3`）。
    @inline(__always)
    private static func pow3(_ x: Double) -> Double { x * x * x }

    /// OKLCH 颜色转成 `IdCardRGBA`。
    /// - Parameters:
    ///   - lch: 颜色。
    ///   - alpha: 不透明度。
    /// - Returns: sRGB 颜色。
    static func rgba(_ lch: LCH, alpha: Double = 1) -> IdCardRGBA {
        let (r, g, b) = oklchToRGB(lch)
        return IdCardRGBA(r: r, g: g, b: b, a: alpha)
    }

    /// 一对颜色，色相转 `turn` 度（底色再亮或暗 `lift`）。
    /// - Parameters:
    ///   - pair: 一对。
    ///   - turn: 色相转的度数。
    ///   - lift: 底色亮度的增减。
    /// - Returns: 配色。
    static func make(_ pair: Pair, turn: Double = 0, lift: Double = 0) -> IdCardPalette {
        // 几乎没有彩度的底色转色相几乎看不出来：它淡淡的色调转得更多。
        func swing(_ lch: LCH, _ extra: Double = 0) -> LCH {
            (lch.l + extra, lch.c, lch.h + (lch.c < 0.02 ? turn * 6 : turn))
        }
        let ground = swing(pair.ground, lift)
        let line = swing(pair.line)
        let light = ground.l > 0.7
        return IdCardPalette(
            name: pair.name,
            ground: rgba(ground),
            groundHigh: rgba((ground.l + 0.035, ground.c, ground.h - 6)),
            groundLow: rgba((ground.l - 0.035, ground.c * 1.1, ground.h + 6)),
            line: rgba(line),
            detect: rgba(pair.detect),
            detectInk: pair.detect.l > 0.7 ? rgba((0.2, 0.05, pair.detect.h)) : IdCardRGBA(r: 255, g: 255, b: 255),
            edge: light ? IdCardRGBA(r: 10, g: 10, b: 20, a: 0.12) : IdCardRGBA(r: 255, g: 255, b: 255, a: 0.14),
            light: light
        )
    }

    /// 一个 UID 的卡的颜色；还没有 UID 时是原样的 Porcelain。
    /// - Parameter uid: UID；`nil` 表示还没读到。
    /// - Returns: 配色（和网站 `idCardPalette` 一样）。
    static func forUID(_ uid: Int?) -> IdCardPalette {
        guard let uid else { return make(pairs[0]) }
        let h = uidHash(uid)
        // 高位挑一对（按比例缩放，不取余，十二对机会均等），低位转色相、调亮度。
        let index = Int((Double(h >> 20) / 0x1000 * Double(pairs.count)).rounded(.down))
        let turn = Double(h & 0x3ff) / 0x3ff * 20 - 10
        let lift = Double((h >> 10) & 0x3ff) / 0x3ff * 0.04 - 0.02
        return make(pairs[index], turn: turn, lift: lift)
    }

    /// UID 在卡上的写法：`#` 加至少 6 位数字（1 → `#000001`，1234567 → `#1234567`）。
    /// - Parameter uid: UID。
    /// - Returns: 文本。
    static func format(_ uid: Int) -> String {
        let digits = String(uid)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }
}
