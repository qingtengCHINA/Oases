import SwiftUI

/// 注销账号: the confirmation page (guide §9), as in K线艺术家 and 词忆:
/// three paragraphs, 注销账号 (destructive) and 取消. 取消 sends nothing.
/// 注销账号 first takes a fresh Apple authorization code when the account
/// uses Apple (cancelling Apple's sheet cancels the deletion; any other
/// Apple failure deletes without the code, so only the revocation is
/// skipped), then `AccountStore.deleteAccount`. Deleted: back to Settings,
/// with the chats, Ogent sessions, providers, API keys, provider sign-ins and the
/// membership untouched; any other result stays here, worded under the paragraphs.
struct DeleteAccountView: View {
    private let apple: AppleSignIn.Authorizer
    /// The account is gone: leave the account pages.
    private let onDeleted: () -> Void

    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var message: String?

    init(apple: @escaping AppleSignIn.Authorizer = { try await AppleSignIn.authorize() }, onDeleted: @escaping () -> Void) {
        self.apple = apple
        self.onDeleted = onDeleted
    }

    /// The three paragraphs, word for word (guide §9, as in the other QingTeng apps). Oases Chat shows
    /// no QingTeng balance, so the only mention of points is "账号和 QingTengStudio积分".
    static var warningLines: [String] {
        [QT("account.deleteLine1"), QT("account.deleteLine2"), QT("account.deleteLine3")]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 38))
                    .foregroundStyle(AccountStyle.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.warningLines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(AccountStyle.font(16))
                            .foregroundStyle(AccountStyle.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AccountStyle.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accountPanel()

                if let message {
                    Text(verbatim: message)
                        .font(AccountStyle.font(13))
                        .foregroundStyle(AccountStyle.secondaryText)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button(role: .destructive) {
                        confirm()
                    } label: {
                        Group {
                            if deleting {
                                ProgressView().tint(.white)
                            } else {
                                Text(QT("account.delete"))
                            }
                        }
                        .font(AccountStyle.font(17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: AccountStyle.bindHeight)
                        .foregroundStyle(.white)
                        .accountPanel(fill: AccountStyle.danger.opacity(deleting ? 0.5 : 1), frame: AccountStyle.danger.opacity(0.5))
                        .contentShape(AccountStyle.shape)
                    }
                    .buttonStyle(AccountPressStyle())
                    .disabled(deleting || !account.isSignedIn)

                    Button {
                        dismiss()
                    } label: {
                        Text(QT("common.cancel"))
                            .font(AccountStyle.font(17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: AccountStyle.bindHeight)
                            .foregroundStyle(AccountStyle.text)
                            .accountPanel()
                            .contentShape(AccountStyle.shape)
                    }
                    .buttonStyle(AccountPressStyle())
                    .disabled(deleting)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, AccountStyle.margin)
            .padding(.bottom, 32)
            .accountReadableWidth()
        }
        .background(AccountStyle.canvas.ignoresSafeArea())
        .accountNavigationTitle(QT("account.delete"))
        .navigationBarBackButtonHidden(deleting)
    }

    /// The account signed in now is the one deleted (fixed before any wait, so
    /// a sign-out or switch while Apple's sheet is up deletes nothing). Whether
    /// it uses Apple is decided by the loaded profile only (`delete`). The task
    /// holds only what it needs, never this page.
    private func confirm() {
        guard !deleting else { return }
        guard let session = account.session else {
            message = Self.message(for: .accountChanged)
            return
        }
        deleting = true
        message = nil
        Task { [apple, account, onDeleted, deleting = $deleting, message = $message] in
            let outcome = await Self.delete(session, apple: apple, account: account)
            deleting.wrappedValue = false
            if outcome == .deleted {
                onDeleted()
            } else {
                message.wrappedValue = Self.message(for: outcome)
            }
        }
    }

    /// How a confirmed deletion ended.
    enum Outcome: Equatable {
        case deleted
        /// Apple's sheet was cancelled: nothing was sent.
        case appleCancelled
        /// No answer, and the old session is refused: sign in again to know.
        case unconfirmed
        /// Someone else is signed in now: nothing was sent.
        case accountChanged
        /// The profile couldn't be read, so whether the account uses Apple is
        /// unknown: nothing was sent (Apple's grant must not go unrevoked).
        case profileUnknown
        case signedOut
        case offline
        case failed
    }

    /// Deletes `session`'s account. The profile decides whether the account
    /// uses Apple: when it isn't loaded yet (a cold start before `/v1/me`, or
    /// a failed load) it is read first, and if it is still unknown nothing is
    /// sent. Then a fresh Apple authorization code when the account uses Apple
    /// (cancelling Apple's sheet cancels the deletion; any other Apple failure
    /// deletes without the code, so only the revocation is skipped), then
    /// `AccountStore.deleteAccount`.
    static func delete(_ session: QTCSession, apple: AppleSignIn.Authorizer, account: AccountStore) async -> Outcome {
        if account.me == nil, account.session == session {
            await account.loadMe()
        }
        guard let current = account.session else { return .signedOut }  // the read answered 401
        guard current == session else { return .accountChanged }
        guard let me = account.me else { return .profileUnknown }
        let usesApple = IdentityDisplay.isBound("apple", in: me.identities)

        var code: String?
        if usesApple {
            do {
                code = try await apple().authorizationCode
            } catch is AppleSignIn.Cancelled {
                return .appleCancelled
            } catch {
                code = nil
            }
        }
        do {
            switch try await account.deleteAccount(session, appleAuthorizationCode: code) {
            case .deleted: return .deleted
            case .unconfirmed: return .unconfirmed
            case .accountChanged: return .accountChanged
            }
        } catch QTCError.unauthorized {
            return .signedOut
        } catch QTCError.offline {
            return .offline
        } catch {
            return .failed
        }
    }

    /// What the page says under the paragraphs (nothing once deleted: the page leaves).
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .deleted: return nil
        case .appleCancelled: return QT("account.deleteCancelled")
        case .unconfirmed: return QT("account.deleteUnconfirmed")
        case .accountChanged: return QT("account.deleteChanged")
        case .profileUnknown: return QT("account.deleteProfileUnknown")
        case .signedOut: return QT("account.deleteSignedOut")
        case .offline: return QT("account.deleteOffline")
        case .failed: return QT("account.deleteFailed")
        }
    }
}
