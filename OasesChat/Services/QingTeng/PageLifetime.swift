import Foundation

/// Kept in a page's `@State`: runs `onEnd` once SwiftUI lets go of the page
/// for good (sheet dismissed, page popped). Unlike `onDisappear`, it does not
/// fire while the page is merely covered — by Apple's sheet or the GitHub /
/// Microsoft browser — so a sign-in in progress is never mistaken for an
/// abandoned one.
final class PageLifetime: Sendable {
    private let onEnd: @MainActor @Sendable () -> Void

    init(onEnd: @escaping @MainActor @Sendable () -> Void) {
        self.onEnd = onEnd
    }

    deinit {
        let onEnd = onEnd
        Task { @MainActor in onEnd() }
    }
}
