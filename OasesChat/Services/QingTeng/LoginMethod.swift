import Foundation

/// The sign-in methods this app offers and lists on the account page.
/// QTC's `identities[].provider` is an open set (wallets, passkeys later…);
/// anything not listed here is simply not shown.
enum LoginMethod: String, CaseIterable, Identifiable, Sendable {
    case apple
    case github
    case microsoft

    init(_ provider: OAuthProvider) {
        switch provider {
        case .github: self = .github
        case .microsoft: self = .microsoft
        }
    }

    var id: String { rawValue }

    /// GitHub and Microsoft go through the browser; Apple through its own sheet.
    var oauthProvider: OAuthProvider? {
        switch self {
        case .apple: nil
        case .github: .github
        case .microsoft: .microsoft
        }
    }

    /// The same name the account page lists it under (`IdentityDisplay`).
    @MainActor var name: String {
        IdentityDisplay.label(for: rawValue) ?? rawValue
    }

    /// The methods bound to the account, in display order. `subject` is never read.
    static func bound(in identities: [QTCMe.Identity]) -> [LoginMethod] {
        let providers = Set(identities.map(\.provider))
        return allCases.filter { providers.contains($0.rawValue) }
    }
}
