import SwiftUI

/// Sign in to the QingTeng account: Apple (always there, first — App Review
/// 4.8), GitHub and Microsoft. Shown on the account page (Settings ›
/// QingTeng 账号) whenever nobody is signed in, including after the session
/// ended. `onDone` runs after a sign-in.
struct SignInView: View {
    private let onDone: () -> Void

    @Environment(AccountStore.self) private var account
    @State private var flow: SignInFlow
    /// Ends the flow when the page is gone for good (not when a system sheet covers it).
    @State private var lifetime: PageLifetime

    init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
        let flow = SignInFlow()
        _flow = State(initialValue: flow)
        _lifetime = State(initialValue: PageLifetime { flow.pageClosed() })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(QT("account.signinTitle"))
                    .font(AccountStyle.font(24, weight: .bold))
                    .foregroundStyle(AccountStyle.heading)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 12) {
                    AppleSignInButton { flow.start(.apple, into: account, onDone: onDone) }
                        .overlay(alignment: .trailing) { spinner(for: .apple) }
                    ForEach(OAuthProvider.allCases.filter { !flow.hiddenProviders.contains($0) }, id: \.self) { provider in
                        providerButton(provider)
                    }
                }
                .disabled(flow.inProgress != nil)
            }
            .padding(.horizontal, AccountStyle.margin)
            .padding(.vertical, 20)
            .accountReadableWidth()
        }
        .background(AccountStyle.canvas.ignoresSafeArea())
        // Only the two buttons answer (an alert can't be dismissed otherwise).
        .alert(
            QT("account.notFoundTitle"),
            isPresented: Binding(get: { flow.asksToCreateAccount }, set: { _ in })
        ) {
            Button(QT("account.newAccount")) { flow.answerNewAccount(true) }
            Button(QT("account.existingAccount"), role: .cancel) { flow.answerNewAccount(false) }
        } message: {
            Text(QT("account.notFoundMsg"))
        }
        .alert(
            noticeText,
            isPresented: Binding(get: { flow.notice != nil }, set: { if !$0 { flow.notice = nil } })
        ) {
            Button(QT("common.confirm"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func providerButton(_ provider: OAuthProvider) -> some View {
        let title = provider == .github ? QT("account.signinGithub") : QT("account.signinMicrosoft")
        VStack(spacing: 8) {
            // Official marks (owner's account-page rules, guide §5): the Invertocat, Microsoft's four squares.
            ProviderButton(provider, title: title, height: AccountStyle.ctaHeight, busy: flow.inProgress == LoginMethod(provider)) {
                flow.start(LoginMethod(provider), into: account, onDone: onDone)
            }
            if provider == .microsoft {
                // Required next to the button (guide §4): the QTC Microsoft app
                // is not publisher-verified, so some organisations block it.
                Text(QT("account.msNote"))
                    .font(AccountStyle.font(12))
                    .foregroundStyle(AccountStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func spinner(for method: LoginMethod) -> some View {
        if flow.inProgress == method {
            ProgressView()
                .tint(Color(uiColor: .systemBackground))
                .padding(.trailing, 20)
        }
    }

    private var noticeText: String {
        switch flow.notice {
        case .timedOut: return QT("account.errTimeout")
        case .useExistingAccount: return QT("account.errUseExisting")
        case .unavailable: return QT("account.errUnavailableApple")
        case .failed, nil: return QT("account.errSigninFailed")
        }
    }
}
