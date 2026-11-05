import UIKit

/// Haptic feedback, off when the user turns "Haptics" off in Sounds & Haptics.
@MainActor
enum Haptics {
    static func tap()     { guard on else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()  { guard on else { return }; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy()   { guard on else { return }; UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func soft()    { guard on else { return }; UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { guard on else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { guard on else { return }; UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()   { guard on else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func select()  { guard on else { return }; UISelectionFeedbackGenerator().selectionChanged() }

    private static var on: Bool { HapticsPreference.isEnabled }
}
