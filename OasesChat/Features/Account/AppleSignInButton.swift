import AuthenticationServices
import SwiftUI

/// Apple's own "Sign in with Apple" button (its required look), wired to
/// `AppleSignIn.authorize()` through the caller's action. Black on light
/// backgrounds, white on dark; the account pages' corner radius.
/// `.signIn` on the sign-in page, `.continue` for linking Apple on the
/// account page.
struct AppleSignInButton: View {
    private let type: ASAuthorizationAppleIDButton.ButtonType
    private let height: CGFloat
    private let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(type: ASAuthorizationAppleIDButton.ButtonType = .signIn, height: CGFloat = AccountStyle.ctaHeight, action: @escaping () -> Void) {
        self.type = type
        self.height = height
        self.action = action
    }

    var body: some View {
        AppleIDButton(type: type, style: colorScheme == .dark ? .white : .black, cornerRadius: AccountStyle.radius, action: action)
            // The type and style are fixed when the button is made: a new one per scheme.
            .id(colorScheme)
            .frame(height: height)
    }
}

private struct AppleIDButton: UIViewRepresentable {
    let type: ASAuthorizationAppleIDButton.ButtonType
    let style: ASAuthorizationAppleIDButton.Style
    let cornerRadius: CGFloat
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: style)
        button.cornerRadius = cornerRadius
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.cornerRadius = cornerRadius
        button.isEnabled = context.environment.isEnabled
        button.alpha = context.environment.isEnabled ? 1 : 0.4
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func tapped() {
            action()
        }
    }
}
