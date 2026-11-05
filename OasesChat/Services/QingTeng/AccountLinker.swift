import Foundation
import Observation

/// Links Apple, GitHub or Microsoft to the signed-in account from the
/// account page (guide §4), then reads the profile again so the row shows
/// "已绑定". Accounts are never merged: a login that belongs to another
/// account is refused (`identity_taken`).
@Observable
@MainActor
final class AccountLinker {
    enum Notice: Equatable {
        /// "这个账号已经属于另一个 QingTeng 账号"
        case identityTaken
        /// "绑定失败，请重试"
        case failed
        /// "这种登录方式暂时不可用"
        case unavailable
    }

    var notice: Notice?
    /// The method being linked; the other buttons wait meanwhile.
    private(set) var linking: LoginMethod?

    @ObservationIgnored private let client: QTCClient
    @ObservationIgnored private let oauth: OAuthSignIn
    @ObservationIgnored private let apple: AppleSignIn.Authorizer
    /// Bumped when the page closes: a link still under way stops before its next step.
    @ObservationIgnored private var generation = 0

    private enum Outcome {
        case linked
        /// Cancelled, or the session ended (sign-in shows instead): nothing to say.
        case quiet
        case refused(Notice)
    }

    init(client: QTCClient = QTCClient(), opener: OAuthSignIn.Opener? = nil, apple: @escaping AppleSignIn.Authorizer = { try await AppleSignIn.authorize() }) {
        self.client = client
        oauth = OAuthSignIn(client: client, opener: opener)
        self.apple = apple
    }

    /// The account page closed for good: links under way are dropped.
    func pageClosed() {
        generation += 1
    }

    /// Starts a link for the account page and returns its task. The task
    /// holds only this linker and `account`, never the page, so the page's
    /// `PageLifetime` can end while the link waits (Codex P2).
    @discardableResult
    func start(_ method: LoginMethod, account: AccountStore) -> Task<Void, Never> {
        Task { [self] in await bind(method, account: account) }
    }

    /// Links `method` to the account signed in now. The session is captured
    /// here, and before each step that binds (the browser, the exchange, the
    /// Apple binding) the link checks it is still the current one and the page
    /// is still open: a login is never bound to an account the user has left.
    func bind(_ method: LoginMethod, account: AccountStore) async {
        guard linking == nil, let session = account.session else { return }
        linking = method
        defer { linking = nil }
        let started = generation
        let isCurrent: @MainActor () -> Bool = { self.generation == started && account.session == session }

        let outcome: Outcome
        if let provider = method.oauthProvider {
            outcome = await link(provider, session: session, account: account, isCurrent: isCurrent)
        } else {
            outcome = await linkApple(session: session, account: account, isCurrent: isCurrent)
        }
        guard isCurrent() else { return }
        switch outcome {
        case .linked:
            // The server is the truth: the row turns "已绑定" from the profile.
            await account.loadMe()
        case .quiet:
            break
        case .refused(let notice):
            self.notice = notice
        }
    }

    private func link(_ provider: OAuthProvider, session: QTCSession, account: AccountStore, isCurrent: @MainActor () -> Bool) async -> Outcome {
        do {
            switch try await oauth.run(provider, linkingTo: session.token, isStillWanted: isCurrent) {
            case .linked: return .linked  // already_bound counts as linked
            case .cancelled, .signedIn, .useExistingAccount: return .quiet
            }
        } catch OAuthError.identityTaken {
            return .refused(.identityTaken)
        } catch OAuthError.unavailable {
            return .refused(.unavailable)
        } catch OAuthError.unauthorized {
            return await afterRefusal(session: session, account: account)
        } catch {
            return .refused(.failed)
        }
    }

    private func linkApple(session: QTCSession, account: AccountStore, isCurrent: @MainActor () -> Bool) async -> Outcome {
        let credential: AppleCredential
        do {
            credential = try await apple()
        } catch is AppleSignIn.Cancelled {
            return .quiet
        } catch {
            return .refused(.failed)
        }
        // Signed out (or into another account) while Apple's sheet was up: bind nothing.
        guard isCurrent() else { return .quiet }
        do {
            _ = try await client.bindApple(idToken: credential.idToken, token: session.token)  // already_bound counts as linked
            return .linked
        } catch {
            switch QTCError.from(error) {
            case .identityTaken: return .refused(.identityTaken)
            case .unauthorized: return await afterRefusal(session: session, account: account)
            default: return .refused(.failed)
            }
        }
    }

    /// A 401 while linking is either the session or the login's own token or
    /// code; QTC doesn't say which. `GET /v1/me` tells: a 401 there too signs
    /// out (back to sign-in, no message); otherwise linking failed, try again.
    private func afterRefusal(session: QTCSession, account: AccountStore) async -> Outcome {
        guard account.session == session else { return .quiet }
        await account.loadMe()
        return account.session == session ? .refused(.failed) : .quiet
    }
}
