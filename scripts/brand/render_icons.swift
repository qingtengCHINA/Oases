// Regenerates the brand images in Assets.xcassets from the Twin Pools geometry.
//
//   cd ios && scripts/brand/render_icons.sh
//
// Colours follow qingtengstudio/logos/oases/a-twin-pools*.svg.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct RenderIcons {
    struct RGB { let r, g, b: CGFloat }
    static func hex(_ v: UInt32) -> RGB {
        RGB(r: CGFloat((v >> 16) & 0xFF) / 255, g: CGFloat((v >> 8) & 0xFF) / 255, b: CGFloat(v & 0xFF) / 255)
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func gradient(_ a: RGB, _ b: RGB) -> CGGradient {
        let comps: [CGFloat] = [a.r, a.g, a.b, 1, b.r, b.g, b.b, 1]
        return CGGradient(colorSpace: space, colorComponents: comps, locations: [0, 1], count: 2)!
    }

    enum Ground { case greenNight, white, black, clear }

    /// Draws one image. `size` in pixels; gradients are given in the SVG's 1024 space.
    static func render(size: Int, ground: Ground, glyphFrom: RGB, glyphTo: RGB, fill: CGFloat?, to url: URL) throws {
        let opaque = ground != .clear
        let info: UInt32 = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { throw NSError(domain: "ctx", code: 1) }
        let s = CGFloat(size)
        // y-down, like the SVG.
        ctx.translateBy(x: 0, y: s)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        let unit = CGFloat(size) / 1024

        switch ground {
        case .greenNight:
            ctx.drawLinearGradient(gradient(hex(0x0B2419), hex(0x04110B)),
                                   start: CGPoint(x: 512 * unit, y: 0), end: CGPoint(x: 512 * unit, y: 1024 * unit), options: [])
        case .white:
            ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        case .black:
            ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        case .clear:
            break
        }

        let transform = TwinPoolsGeometry.transform(fitting: CGRect(x: 0, y: 0, width: s, height: s), fill: fill)
        let path = TwinPoolsGeometry.path(transform: transform)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // The glyph gradient runs from (300,760) to (760,260) in the logo's 1024 space; map those
        // points through the same placement as the glyph.
        let logoToUnit = CGAffineTransform(scaleX: 1.0 / 1024, y: 1.0 / 1024)
        let p0 = CGPoint(x: 300, y: 760).applying(logoToUnit).applying(transform)
        let p1 = CGPoint(x: 760, y: 260).applying(logoToUnit).applying(transform)
        ctx.drawLinearGradient(gradient(glyphFrom, glyphTo), start: p0, end: p1,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "png", code: 2) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "png", code: 3) }
        print("wrote \(url.lastPathComponent) \(size)px")
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            print("usage: render_icons <Assets.xcassets>")
            exit(2)
        }
        let assets = URL(fileURLWithPath: args[1], isDirectory: true)
        let icon = assets.appendingPathComponent("AppIcon.appiconset")
        let mark = assets.appendingPathComponent("OasesIcon.imageset")
        let green0 = hex(0x17A35A), green1 = hex(0x8FF5B8)
        let ink = hex(0x000000), paper = hex(0xFFFFFF)

        // Home-screen icon: the black mark on white (qingtengstudio/logos/oases/a-twin-pools-mark.svg).
        try render(size: 1024, ground: .white, glyphFrom: ink, glyphTo: ink, fill: nil,
                   to: icon.appendingPathComponent("AppIcon.png"))
        try render(size: 120, ground: .white, glyphFrom: ink, glyphTo: ink, fill: nil,
                   to: icon.appendingPathComponent("AppIcon60@2x.png"))
        // Dark appearance: the same mark in white on black.
        try render(size: 1024, ground: .black, glyphFrom: paper, glyphTo: paper, fill: nil,
                   to: icon.appendingPathComponent("AppIconDark.png"))
        // Tinted appearance: a greyscale mark on black; iOS tints it by luminance.
        try render(size: 1024, ground: .black, glyphFrom: hex(0xB4B4B4), glyphTo: hex(0xFFFFFF), fill: nil,
                   to: icon.appendingPathComponent("AppIconTinted.png"))
        // The welcome glyph's mask (only alpha matters to the metallic shader). Filled to 84 % of
        // the canvas, the same visual size the previous mark had.
        try render(size: 1728, ground: .clear, glyphFrom: green0, glyphTo: green1, fill: 0.84,
                   to: mark.appendingPathComponent("oases-icon.png"))
    }
}
