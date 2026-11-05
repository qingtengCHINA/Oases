import UIKit

/// Where the hardware Dynamic Island sits, for effects that reach into it.
///
/// There is no API for the island's frame; this follows its published geometry (about
/// 125 × 37 pt, 11 pt from the top on current iPhones) and only claims an island on an iPhone in
/// portrait with the tall top inset those devices have. Everything else gets `.none`, so effects
/// fall back to a plain collapse.
enum IslandGeometry: Equatable {
    /// The hardware island (in window coordinates) and a slightly smaller rect inside it to aim
    /// shapes at, so their anti-aliased edges stay inside the physical black area.
    case island(hardware: CGRect, target: CGRect)
    /// No island, but a notch-style top inset: shapes shrink into a small dot instead.
    case dot(CGRect)
    case none

    @MainActor
    static func resolve(width: CGFloat, safeTop: CGFloat, isLandscape: Bool) -> IslandGeometry {
        guard UIDevice.current.userInterfaceIdiom == .phone, !isLandscape,
              !ProcessInfo.processInfo.isiOSAppOnMac else { return .none }
        if safeTop >= 59 {
            let size = CGSize(width: 125.33, height: 36.67)
            let top = max(11, safeTop - 48)
            let hardware = CGRect(x: (width - size.width) / 2, y: top, width: size.width, height: size.height)
            let target = hardware.insetBy(dx: (size.width - 96) / 2, dy: (size.height - 31) / 2)
            return .island(hardware: hardware, target: target)
        }
        if safeTop >= 20 {
            let side: CGFloat = 18
            let y = max(safeTop / 2, 12)
            return .dot(CGRect(x: (width - side) / 2, y: y - side / 2, width: side, height: side))
        }
        return .none
    }

    var targetCenter: CGPoint? {
        switch self {
        case .island(_, let target): return CGPoint(x: target.midX, y: target.midY)
        case .dot(let rect): return CGPoint(x: rect.midX, y: rect.midY)
        case .none: return nil
        }
    }
}
