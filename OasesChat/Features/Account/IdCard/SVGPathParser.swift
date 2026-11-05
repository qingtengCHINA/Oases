import Foundation
import CoreGraphics

/// 把 SVG 的路径数据（`d` 属性）解析成 `CGPath`。
///
/// 支持 `M L H V C S Q T Z` 的绝对和相对写法、命令的隐式重复（`m` 之后的坐标对按 `l` 处理），
/// 以及紧凑的数字写法（`-2 0-3`、`.6.113`、`1e-3`）。不支持圆弧 `A`（账户卡和 GitHub 标志都用不到），遇到就停在那里。
enum SVGPathParser {

    /// 解析一条路径。
    /// - Parameter d: SVG 路径数据。
    /// - Returns: 路径（坐标原样，不缩放）。
    static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(Array(d.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek() else { break }
            if Scanner.isCommand(byte) {
                command = byte
                scanner.advance()
            } else if command == 0 {
                break
            } else if command == UInt8(ascii: "M") {
                command = UInt8(ascii: "L")  // M 之后多出来的坐标对是直线
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            }

            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }

            switch command | 0x20 {  // 小写
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case UInt8(ascii: "s"):
                let reflects = [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCommand | 0x20)
                let c1 = reflects ? reflected(lastControl, about: current) : current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastControl = c
            case UInt8(ascii: "t"):
                let reflects = [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCommand | 0x20)
                let c = reflects ? reflected(lastControl, about: current) : current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastControl = c
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    /// 上一个控制点关于当前点的对称点（`S`、`T` 的第一个控制点）。
    /// - Parameters:
    ///   - control: 上一个控制点；没有时就是当前点。
    ///   - point: 当前点。
    /// - Returns: 对称点。
    private static func reflected(_ control: CGPoint?, about point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// 逐字节读路径数据。
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func advance() { index += 1 }

        /// 跳过空白和逗号。
        mutating func skipSeparators() {
            while let b = peek(), b == 0x20 || b == 0x2C || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
        }

        /// 是不是路径命令字母（`e` 只出现在数字的指数里，不算）。
        static func isCommand(_ b: UInt8) -> Bool {
            let lower = b | 0x20
            return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z") && lower != UInt8(ascii: "e")
        }

        /// 读一个数：可选的正负号、整数部分、至多一个小数点、可选的指数。第二个小数点开始下一个数。
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if let b = peek(), b == UInt8(ascii: "-") || b == UInt8(ascii: "+") { index += 1 }
            var digits = 0
            while let b = peek(), b >= 0x30 && b <= 0x39 { index += 1; digits += 1 }
            if peek() == UInt8(ascii: ".") {
                index += 1
                while let b = peek(), b >= 0x30 && b <= 0x39 { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = begin; return nil }
            if let b = peek(), b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
                let mark = index
                index += 1
                if let s = peek(), s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { index += 1 }
                var exp = 0
                while let d = peek(), d >= 0x30 && d <= 0x39 { index += 1; exp += 1 }
                if exp == 0 { index = mark }
            }
            guard let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else { return nil }
            return CGFloat(value)
        }
    }
}
