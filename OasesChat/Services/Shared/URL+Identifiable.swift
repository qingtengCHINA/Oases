import Foundation

/// Shared `URL: Identifiable` for `.sheet(item:)` / fullScreenCover(item:) call sites.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
