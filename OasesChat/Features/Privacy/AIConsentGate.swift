import SwiftUI

/// Asks for the one-page consent at the moment an AI request is about to leave the device,
/// without losing what the user just typed.
///
/// Send buttons call `requireConsent(then:)` BEFORE they clear any input or
/// attachments. With consent it returns `true` and the caller carries on.
/// Without it (limited mode) the action is kept, the consent page is shown as
/// a sheet (hosted once in `RootView`), and the action runs right after the
/// user agrees — so the message they were sending goes out. 「不同意」 drops the
/// action and leaves the composer untouched.
@MainActor
@Observable
final class AIConsentGate {
    static let shared = AIConsentGate()

    /// Drives the sheet hosted in `RootView`.
    var isPresented = false

    /// The send that was waiting for consent, if any.
    private(set) var pendingAction: (@MainActor () -> Void)?

    private let isAccepted: () -> Bool
    private let recordAcceptance: () -> Void

    init(
        isAccepted: @escaping () -> Bool = { AIDataSharingConsent.isAccepted },
        recordAcceptance: @escaping () -> Void = { AIDataSharingConsent.accept() }
    ) {
        self.isAccepted = isAccepted
        self.recordAcceptance = recordAcceptance
    }

    // MARK: Call sites

    /// `true` when AI requests may be sent now. Otherwise remembers `action`,
    /// presents the consent sheet and returns `false`; the caller must stop
    /// without consuming its input.
    @discardableResult
    static func requireConsent(then action: @escaping @MainActor () -> Void) -> Bool {
        shared.requireConsent(then: action)
    }

    /// Runs `action` now when consent is in place, or after the user agrees.
    static func perform(_ action: @escaping @MainActor () -> Void) {
        if shared.requireConsent(then: action) { action() }
    }

    /// Opens the consent sheet with nothing queued.
    static func presentConsent() {
        shared.present(pending: nil)
    }

    // MARK: Instance API (tests drive this directly)

    @discardableResult
    func requireConsent(then action: @escaping @MainActor () -> Void) -> Bool {
        if isAccepted() { return true }
        present(pending: action)
        return false
    }

    func present(pending action: (@MainActor () -> Void)?) {
        // A newer send replaces an older one that was never confirmed.
        pendingAction = action
        isPresented = true
    }

    /// 「同意并继续」: records consent, closes the sheet, then sends what was waiting.
    func accept() {
        recordAcceptance()
        let action = pendingAction
        pendingAction = nil
        isPresented = false
        action?()
    }

    /// 「不同意」: nothing is sent and the input stays as it was.
    func dismiss() {
        pendingAction = nil
        isPresented = false
    }
}

// MARK: - Sheet

/// The consent page as a sheet (same copy, same two buttons as the welcome flow's last page).
struct AIConsentSheet: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        OnePageConsentView(
            onAgree: {
                Haptics.tap()
                onAccept()
            },
            onDecline: onDecline
        )
        .interactiveDismissDisabled()
        .presentationDetents([.large])
        .presentationBackground(OasesColor.background)
        .accessibilityIdentifier("oases.privacy-consent.sheet")
    }
}

extension View {
    /// Hosts the shared consent sheet. Attach once, at the app root.
    func aiConsentSheetHost(_ gate: AIConsentGate = .shared) -> some View {
        modifier(AIConsentSheetHost(gate: gate))
    }
}

private struct AIConsentSheetHost: ViewModifier {
    @Bindable var gate: AIConsentGate
    @Environment(ThemeManager.self) private var theme

    func body(content: Content) -> some View {
        content.sheet(isPresented: $gate.isPresented, onDismiss: {
            // After 「同意并继续」 this is a no-op.
            gate.dismiss()
        }) {
            AIConsentSheet(
                onAccept: { gate.accept() },
                onDecline: { gate.dismiss() }
            )
            .preferredColorScheme(theme.colorScheme)
            .tint(OasesColor.primary)
        }
    }
}
