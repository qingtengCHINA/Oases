import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// GitHub 的标志（Invertocat）：官方标志的矢量路径（取自 simple-icons 的 `github`，CC0，24 × 24 的画板），
/// 按给的框等比放大、居中。用 `.fill(_:)` 上色：GitHub 的规范只允许黑色或白色，深色底上白、浅色底上黑。
struct GitHubMark: Shape {

    /// simple-icons `github.svg` 的路径数据（viewBox 0 0 24 24）。
    static let pathData =
        "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"

    /// 解析好的路径（24 × 24 的画板）。
    /// （`CGPath` 没标 Sendable，这条路径建好后不再改动。）
    nonisolated(unsafe) static let base: CGPath = SVGPathParser.path(pathData)

    /// 标志放进 `rect`：按短边缩放，居中。
    /// - Parameter rect: 边框。
    /// - Returns: 路径。
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let k = side / 24
        let transform = CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                          tx: rect.midX - side / 2, ty: rect.midY - side / 2)
        return Path(Self.base).applying(transform)
    }
}

/// 微软的四色方块标志：按微软登录按钮的官方素材（21 × 21 的画板里四个 9 × 9 的方块，间隔 1），
/// 颜色 #F25022、#7FBA00、#00A4EF、#FFB900。登录页和账号页（绑定微软、登录方式一栏）共用。
struct MicrosoftLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let gap = side / 19
            let square = side * 9 / 19
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Rectangle().fill(Color(red: 0.949, green: 0.314, blue: 0.133)).frame(width: square, height: square)
                    Rectangle().fill(Color(red: 0.498, green: 0.729, blue: 0.0)).frame(width: square, height: square)
                }
                HStack(spacing: gap) {
                    Rectangle().fill(Color(red: 0.0, green: 0.643, blue: 0.937)).frame(width: square, height: square)
                    Rectangle().fill(Color(red: 1.0, green: 0.725, blue: 0.0)).frame(width: square, height: square)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// 账号页“登录方式”一栏的小图标（圆角方块里的标志）：Apple 是黑底白色的系统 Apple 标志，GitHub 是 GitHub 深灰底上白色的
/// Invertocat，微软是白底四色方块，其他（Arc 钱包）是天蓝底的钱包。四种都是同样大小、和 Oases 设置行图标一样圆角（8 点）的方块。
struct SignInMethodIcon: View {

    /// 登录方式（`"apple"`、`"github"`、`"microsoft"`，其他按钱包画）。
    let provider: String

    /// GitHub 按钮和图标的底色（GitHub 的深灰 #24292E）。
    static let gitHubFill = Color(red: 0.14, green: 0.16, blue: 0.18)

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
        switch provider {
        case "apple":
            Image(systemName: "applelogo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black, in: tile)
        case "github":
            GitHubMark()
                .fill(.white)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.gitHubFill, in: tile)
        case "microsoft":
            MicrosoftLogo()
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white, in: tile)
                .overlay(tile.strokeBorder(Self.separator, lineWidth: 0.5))
        default:
            // 钱包：彩色方块配白色图形（天蓝 #0EA5E9，和其他 QingTeng App 一样），和收币地址那一行同一个图标。
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 14 / 255, green: 165 / 255, blue: 233 / 255), in: tile)
        }
    }

    /// 系统的分隔线颜色。
    private static var separator: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }
}

/// 设置里「QingTeng 账号」那一行的图标：账户卡左上角的像素 QT 标志（`IdCardEngine.markGrid`，14 × 14），
/// 和 Oases 设置里其他行的图标一样：前景色的标志放在淡灰的圆角方块里（`SettingsView.settingsLabel`）。
/// 每一格对齐到物理像素，边缘不发虚。
struct QingTengMarkIcon: View {
    @Environment(\.displayScale) private var displayScale
    /// The mark's colour and the tile behind it (Settings' row icons by default).
    var mark: Color = OasesColor.foreground.opacity(0.82)
    var tile: Color = OasesColor.muted.opacity(0.55)

    var body: some View {
        Canvas { context, size in
            let grid = IdCardEngine.markGrid.map { Array($0) }
            let cells = CGFloat(grid.count)
            let side = min(size.width, size.height) * 0.62
            let cell = max(1, (side * displayScale / cells).rounded(.down)) / displayScale
            let originX = ((size.width - cell * cells) * displayScale / 2).rounded(.down) / displayScale
            let originY = ((size.height - cell * cells) * displayScale / 2).rounded(.down) / displayScale
            var path = Path()
            for (y, row) in grid.enumerated() {
                for (x, mark) in row.enumerated() where mark == "#" {
                    path.addRect(CGRect(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(mark))
        }
        .background(tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
