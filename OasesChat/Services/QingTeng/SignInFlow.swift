import Foundation
import Observation

/// The sign-in page's state: Sign in with Apple, GitHub or Microsoft into
/// `AccountStore`, the new-account question, and what to tell the user
/// (guide §4). Cancelling anywhere is silent.
///
/// Once the page has closed (`pageClosed()`, from its `PageLifetime`), the
/// flow is finished for good: a run still under way stops before its next
/// step, asks nothing, and never writes a session. The same holds once the
/// transfer consent is taken back (`AccountStore.SignInTicket`), from any window.
@Observable
@MainActor
final class SignInFlow {
    enum Notice: Equatable {
        /// "登录失败，请重试"
        case failed
        /// The result code expired while the new-account question was open: "登录超时，请重新登录".
        case timedOut
        /// The user chose "已有账号": sign in the old way, then link on the account page.
        case useExistingAccount
        /// The provider isn't switched on at QTC; its button is hidden too.
        case unavailable
    }

    /// Shown once, then cleared by the page.
    var notice: Notice?
    /// The method being signed in with; every button waits meanwhile.
    private(set) var inProgress: LoginMethod?
    /// Providers QTC answered `provider_unavailable` for: their buttons go.
    private(set) var hiddenProviders: Set<OAuthProvider> = []
    /// No account has this GitHub / Microsoft login: ask "新建账号" or "已有账号".
    private(set) var asksToCreateAccount = false
    /// The page is gone: nothing more is asked or signed in.
    private(set) var isClosed = false

    @ObservationIgnored private let client: QTCClient
    @ObservationIgnored private let oauth: OAuthSignIn
    @ObservationIgnored private let apple: AppleSignIn.Authorizer
    @ObservationIgnored private var newAccountAnswer: CheckedContinuation<Bool, Never>?

    init(client: QTCClient = QTCClient(), opener: OAuthSignIn.Opener? = nil, apple: @escaping AppleSignIn.Authorizer = { try await AppleSignIn.authorize() }) {
        self.client = client
        oauth = OAuthSignIn(client: client, opener: opener)
        self.apple = apple
    }

    /// Starts a sign-in for the page and returns its task. The task holds
    /// only this flow, `account` and `onDone` (run after a sign-in), never
    /// the page: once the page is gone, its `PageLifetime` ends at once and
    /// closes the flow, so a late answer saves no session (Codex P2).
    @discardableResult
    func start(_ method: LoginMethod, into account: AccountStore, onDone: @escaping () -> Void) -> Task<Void, Never> {
        Task { [self] in
            let signedIn: Bool
            if let provider = method.oauthProvider {
                signedIn = await signIn(with: provider, into: account)
            } else {
                signedIn = await signInWithApple(into: account)
            }
            if signedIn { onDone() }
        }
    }

    /// Sign in with Apple. True once signed in.
    func signInWithApple(into account: AccountStore) async -> Bool {
        guard inProgress == nil, !isClosed, let ticket = account.beginSignIn() else { return false }
        inProgress = .apple
        defer { inProgress = nil }
        let credential: AppleCredential
        do {
            credential = try await apple()
        } catch is AppleSignIn.Cancelled {
            return false
        } catch {
            show(.failed)
            return false
        }
        // The token is never sent for a closed page, nor after the consent was taken back.
        guard !isClosed, account.accepts(ticket) else { return false }
        do {
            // The identity token goes to QTC at once and nowhere else.
            let login = try await client.signInWithApple(idToken: credential.idToken)
            guard !isClosed else { return false }
            return await account.signedIn(login.session, ticket: ticket)
        } catch {
            show(.failed)
            return false
        }
    }

    /// Sign in with GitHub or Microsoft. True once signed in.
    func signIn(with provider: OAuthProvider, into account: AccountStore) async -> Bool {
        guard inProgress == nil, !isClosed, let ticket = account.beginSignIn() else { return false }
        inProgress = LoginMethod(provider)
        defer { inProgress = nil }
        do {
            let result = try await oauth.run(
                provider,
                confirmNewAccount: { await self.askToCreateAccount() },
                isStillWanted: { !self.isClosed && account.accepts(ticket) }
            )
            switch result {
            case .signedIn(let token, let userId, _):
                guard !isClosed else { return false }
                return await account.signedIn(QTCSession(token: token, userId: userId), ticket: ticket)
            case .useExistingAccount:
                show(.useExistingAccount)
            case .cancelled, .linked:
                break
            }
        } catch OAuthError.unavailable {
            hiddenProviders.insert(provider)
            show(.unavailable)
        } catch OAuthError.unauthorized {
            show(.timedOut)
        } catch {
            show(.failed)
        }
        return false
    }

    /// The new-account question's answer (true: "新建账号").
    func answerNewAccount(_ createNew: Bool) {
        guard let answer = newAccountAnswer else { return }
        newAccountAnswer = nil
        asksToCreateAccount = false
        answer.resume(returning: createNew)
    }

    /// The page closed for good: an open question counts as "已有账号" (no
    /// account is created for a page nobody is looking at), and any run
    /// still under way ends without signing in.
    func pageClosed() {
        isClosed = true
        answerNewAccount(false)
    }

    private func askToCreateAccount() async -> Bool {
        // No alert can show on a closed page: never wait for one.
        guard !isClosed else { return false }
        return await withCheckedContinuation { continuation in
            newAccountAnswer = continuation
            asksToCreateAccount = true
        }
    }

    private func show(_ notice: Notice) {
        guard !isClosed else { return }
        self.notice = notice
    }
}
