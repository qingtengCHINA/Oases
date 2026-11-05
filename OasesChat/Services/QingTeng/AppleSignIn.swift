import AuthenticationServices
import UIKit

/// What Sign in with Apple hands back: the identity token (sent to QTC at
/// once, it is short-lived) and the authorization code (only used to revoke
/// the authorization when the account is deleted). Neither is stored or logged.
struct AppleCredential: Sendable, Equatable {
    let idToken: String
    let authorizationCode: String
}

/// Sign in with Apple. No email and no name are asked for (`requestedScopes`
/// is empty): QTC knows people only by Apple's user identifier.
enum AppleSignIn {
    /// The user closed Apple's sheet: nothing to say.
    struct Cancelled: Error {}
    /// Apple's answer had no usable token or code.
    struct Failed: Error {}

    /// Runs Sign in with Apple; injected in tests.
    typealias Authorizer = @MainActor () async throws -> AppleCredential

    @MainActor
    static func authorize() async throws -> AppleCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        // The controller holds its delegate weakly: keep it until Apple answers.
        let delegate = AppleAuthorizationDelegate()
        defer { withExtendedLifetime(delegate) {} }
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            controller.performRequests()
        }
    }
}

@MainActor
private final class AppleAuthorizationDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var continuation: CheckedContinuation<AppleCredential, any Error>?

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, let idToken = String(data: tokenData, encoding: .utf8),
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8)
        else {
            finish(.failure(AppleSignIn.Failed()))
            return
        }
        finish(.success(AppleCredential(idToken: idToken, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(AppleSignIn.Cancelled()))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        PresentationAnchor.current()
    }

    private func finish(_ result: Result<AppleCredential, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// The window system sheets (Apple's, the sign-in browser) are shown over.
enum PresentationAnchor {
    @MainActor
    static func current() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
        if let window = active?.keyWindow ?? scenes.lazy.compactMap(\.keyWindow).first {
            return window
        }
        if let scene = active ?? scenes.first {
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
}
