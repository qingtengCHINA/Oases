import AuthenticationServices
import SwiftUI

/// Settings › QingTeng 账号, in the owner's shared QingTeng layout
/// (integration guide §5 "账号页设计规范", ported from 讲真话's (Maat's), Stars', PlusProMax's
/// and Kracker's `AccountView`, themselves from Xplate, 去做, K线艺术家 and 词忆),
/// in Oases Chat's Settings look (`AccountStyle`, from `OasesColor`):
///
/// 1. The account's QingTeng Studio ID card on top, fading into the page at
///    its lower edge. It carries the UID; no avatar, name block or balance
///    (Oases Chat uses the account system only: no QingTengStudio积分 anywhere).
/// 2. 登录方式: bound methods with their official marks and a green check;
///    the unbound ones as bind buttons (Apple's own button, GitHub, Microsoft
///    with its small print). Linking runs through `AccountLinker` (session-bound,
///    dropped once the page is gone: `PageLifetime`).
/// 3. 收币地址, only outside mainland China (`PayoutRegion`: device region and
///    first preferred language), the same rule that hides the Arc wallet row.
/// 4. 退出登录 at the bottom (red, outlined), confirmed first, and 注销账号
///    right below it.
///
/// Signed out (never signed in, signed out elsewhere, or a 401), the page is
/// the sign-in page instead; after signing in it turns into the account page.
/// Without the one-page consent, that page comes first, as a sheet (不同意 goes
/// back to Settings). The account is
/// optional: chat works signed out. Signing out or deleting the account never
/// touches the chats, the Ogent sessions, the providers and API keys, the
/// provider sign-ins or the membership.
///
/// Pushed from Settings: `closePage()` pops back to Settings (`closeAccountPage`).
struct AccountView: View {
    @Environment(AccountStore.self) private var account
    /// The one-page consent, observed so the page turns into sign-in once it is given.
    @AppStorage(AIDataSharingConsent.versionKey) private var consentVersion: String = ""
    @AppStorage(AIDataSharingConsent.statusKey) private var consentStatus: String = ""
    /// Back to Settings (Settings hands this in).
    @Environment(\.closeAccountPage) private var closePage
    @State private var linker: AccountLinker
    /// Drops links under way once the page is gone for good.
    @State private var lifetime: PageLifetime
    /// Signing out closes the page; it keeps its look while it slides away.
    @State private var signingOut = false
    @State private var confirmsSignOut = false
    /// Without the consent: the consent page as a sheet before sign-in.
    @State private var showsConsent = false

    init() {
        let linker = AccountLinker()
        _linker = State(initialValue: linker)
        _lifetime = State(initialValue: PageLifetime { linker.pageClosed() })
    }

    var body: some View {
        Group {
            if account.isSignedIn || signingOut {
                content(AccountPageContent.onThisDevice(account.me))
            } else if allowsQingTengAccount {
                SignInView()
            } else {
                consentRequired
            }
        }
        .background(AccountStyle.canvas.ignoresSafeArea())
        .accountNavigationTitle(QT("account.navTitle"))
    }

    private var allowsQingTengAccount: Bool {
        _ = consentVersion
        _ = consentStatus
        return AIDataSharingConsent.isAccepted
    }

    /// Without the one-page consent: the same page as a sheet. 同意并继续 turns this into the
    /// sign-in page; 不同意 goes back to Settings.
    private var consentRequired: some View {
        AccountStyle.canvas
            .ignoresSafeArea()
            .onAppear { showsConsent = true }
            .sheet(isPresented: $showsConsent, onDismiss: {
                if !AIDataSharingConsent.isAccepted { closePage() }
            }) {
                AIConsentSheet(
                    onAccept: {
                        AIDataSharingConsent.accept()
                        showsConsent = false
                    },
                    onDecline: { showsConsent = false }
                )
            }
    }

    private func content(_ page: AccountPageContent) -> some View {
        ScrollView {
            VStack(spacing: AccountStyle.groupSpacing) {
                AccountCardHeader(uid: page.uid)
                if account.me != nil {
                    signInMethods(page)
                }
                if page.showsPayoutAddress {
                    payoutEntry(page.payoutAddress)
                }
                Spacer().frame(height: 4)
                actions
            }
            .padding(.horizontal, AccountStyle.margin)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .accountReadableWidth()
        }
        .background(AccountStyle.canvas.ignoresSafeArea())
        .refreshable { [account] in await account.loadMe() }
        .task { [account] in await account.loadMe() }
        .alert(QT("account.confirmSignout"), isPresented: $confirmsSignOut) {
            Button(QT("common.cancel"), role: .cancel) {}
            Button(QT("account.signout"), role: .destructive) { signOut() }
        }
    }

    // MARK: - 登录方式

    private func signInMethods(_ page: AccountPageContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The section heading, like the AI jury's section headers.
            Text(QT("account.methods"))
                .font(AccountStyle.font(15, weight: .semibold))
                .foregroundStyle(AccountStyle.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if !page.boundProviders.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(page.boundProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 {
                            AccountDivider()
                        }
                        boundRow(provider)
                    }
                }
                .padding(.horizontal, AccountStyle.rowInset)
                .accountPanel()
            }

            if !page.unboundMethods.isEmpty {
                VStack(spacing: 12) {
                    ForEach(page.unboundMethods) { method in
                        bindControl(method)
                    }
                }
                .padding(.top, page.boundProviders.isEmpty ? 0 : 6)
            }

            if let noticeText {
                Text(noticeText)
                    .font(AccountStyle.font(13))
                    .foregroundStyle(AccountStyle.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    /// A bound method: its official mark, its name, a green check. `subject` is never shown.
    private func boundRow(_ provider: String) -> some View {
        HStack(spacing: 12) {
            SignInMethodIcon(provider: provider)
                .frame(width: 30, height: 30)
            Text(verbatim: IdentityDisplay.label(for: provider) ?? provider)
                .font(AccountStyle.font(16, weight: .medium))
                .foregroundStyle(AccountStyle.text)
            Spacer(minLength: 8)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(AccountStyle.bound)
                .accessibilityLabel(Text(QT("account.bound")))
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// The bind control of a method not bound yet: Apple's own "continue with
    /// Apple" button, GitHub's and Microsoft's in their colours (Microsoft's
    /// small print under it). All wait while one link runs.
    @ViewBuilder
    private func bindControl(_ method: LoginMethod) -> some View {
        switch method {
        case .apple:
            AppleSignInButton(type: .continue, height: AccountStyle.bindHeight) { bind(.apple) }
                .opacity(linker.linking == .apple ? 0.6 : 1)
                .disabled(linker.linking != nil)
        case .github:
            ProviderButton(.github, title: QT("account.bindGithub"), height: AccountStyle.bindHeight, busy: linker.linking == .github) { bind(.github) }
                .disabled(linker.linking != nil)
        case .microsoft:
            VStack(spacing: 6) {
                ProviderButton(.microsoft, title: QT("account.bindMicrosoft"), height: AccountStyle.bindHeight, busy: linker.linking == .microsoft) { bind(.microsoft) }
                    .disabled(linker.linking != nil)
                // Required next to the Microsoft button (guide §4).
                Text(QT("account.msNote"))
                    .font(AccountStyle.font(12))
                    .foregroundStyle(AccountStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bind(_ method: LoginMethod) {
        guard linker.linking == nil else { return }
        linker.notice = nil
        // The task holds the linker and the account, not this page (its PageLifetime must be able to end).
        linker.start(method, account: account)
    }

    /// The last link's outcome under the buttons (cancelling and an ended session say nothing).
    private var noticeText: String? {
        switch linker.notice {
        case .identityTaken: return QT("account.errTaken")
        case .unavailable: return QT("account.errUnavailable")
        case .failed: return QT("account.errBindFailed")
        case nil: return nil
        }
    }

    // MARK: - 收币地址

    /// The payout row (only outside mainland China), with the address filled in, middle-truncated.
    private func payoutEntry(_ address: String?) -> some View {
        NavigationLink {
            PayoutAddressView()
        } label: {
            HStack(spacing: 12) {
                SignInMethodIcon(provider: "payout")
                    .frame(width: 30, height: 30)
                Text(QT("account.payout"))
                    .font(AccountStyle.font(16, weight: .medium))
                    .foregroundStyle(AccountStyle.text)
                Spacer(minLength: 8)
                if let address {
                    Text(verbatim: address)
                        .font(AccountStyle.monoFont(13))
                        .foregroundStyle(AccountStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
                // Settings' arrow.
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AccountStyle.secondaryText.opacity(0.4))
            }
            .padding(.horizontal, AccountStyle.rowInset)
            .padding(.vertical, 10)
            .accountPanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(AccountPressStyle())
    }

    // MARK: - 退出登录 and 注销账号

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                confirmsSignOut = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .medium))
                    Text(QT("account.signout"))
                        .font(AccountStyle.font(17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: AccountStyle.bindHeight)
                .foregroundStyle(AccountStyle.danger)
                .accountPanel(fill: .clear, frame: AccountStyle.danger.opacity(0.6))
                .contentShape(AccountStyle.shape)
            }
            .buttonStyle(AccountPressStyle())
            .disabled(signingOut)

            // 注销账号: the confirmation page (three paragraphs, Apple re-authorization, the outcome).
            NavigationLink {
                DeleteAccountView(onDeleted: { [closePage, signingOut = $signingOut] in
                    // Deleted: back to Settings (holding only what it sets, not this page).
                    signingOut.wrappedValue = true
                    closePage()
                })
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .medium))
                    Text(QT("account.delete"))
                        .font(AccountStyle.font(17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: AccountStyle.bindHeight)
                .foregroundStyle(AccountStyle.danger.opacity(0.85))
                .accountPanel(fill: AccountStyle.danger.opacity(0.12), frame: AccountStyle.danger.opacity(0.25))
                .contentShape(AccountStyle.shape)
            }
            .buttonStyle(AccountPressStyle())
            .disabled(signingOut)
        }
    }

    private func signOut() {
        signingOut = true
        closePage()
        account.signOut()
    }
}
