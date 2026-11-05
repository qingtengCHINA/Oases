import Foundation

/// 账号页"登录方式"一栏怎么显示服务器给的 `identities`（从词忆移植，`Services/Account/IdentityDisplay.swift`；
/// 经 K线艺术家、Xplate、PlusProMax、Stars、讲真话移植到 Oases Chat：`QTCMe.Identity`，文案走 `QT()` 表）。
///
/// - `provider` 是开放字符串（接入说明第 5 节），认不出的一律不显示（例如 `passkey`、以后新加的）。
/// - `solana` 也不显示：2026-10-23 起 Solana 取消，服务器还可能返回这一项，App 一律忽略（接入说明第 5、6 节）。
/// - 钱包（`ethereum`，在网站上绑定的 Arc 钱包）显示成"Arc 钱包"，而且和收币地址入口同一条规则：
///   设备是中国大陆的（系统地区或第一个首选语言是中国大陆）不显示（`PayoutRegion.showsPayoutAddresses`）。
/// - `subject` 是内部标识，任何地方都不显示。
enum IdentityDisplay {

    /// App 里能绑定的三种登录方式，按账号页上的顺序（钱包只能在网站上绑定）。
    static let bindableProviders = ["apple", "github", "microsoft"]

    /// 钱包类的登录方式：设备是中国大陆的不显示。
    static let walletProviders: Set<String> = ["ethereum"]

    /// 一种登录方式在界面上的名字。
    /// - Parameter provider: 服务器给的 `provider`（区分大小写，服务器只发小写）。
    /// - Returns: `apple` → "Apple"，`github` → "GitHub"，`microsoft` → "微软"，`ethereum`（在网站上绑定的 Arc 钱包）→ "Arc 钱包"；
    ///   其他（含 `solana`）为 `nil`，不显示。
    static func label(for provider: String) -> String? {
        switch provider {
        case "apple": return "Apple"
        case "github": return "GitHub"
        case "microsoft": return QT("account.microsoft")
        case "ethereum": return QT("account.arcWallet")
        default: return nil
        }
    }

    /// 要在"登录方式"里显示的那些 `provider`：按服务器给的顺序，认不出的去掉，名字相同的只留第一个；
    /// 设备是中国大陆的（`PayoutRegion.showsPayoutAddresses` 为假）钱包也去掉。
    /// - Parameters:
    ///   - identities: `GET /v1/me` 的 `identities`。
    ///   - regionIdentifier: 设备的系统地区（`Locale.current.region?.identifier`）；`nil` 按"不是中国大陆"处理。
    ///   - preferredLanguage: 第一个首选语言（`Locale.preferredLanguages.first`）；`nil` 只看地区。
    /// - Returns: 要显示的 `provider`，每个都有 `label(for:)`。
    static func displayedProviders(for identities: [QTCMe.Identity], regionIdentifier: String?, preferredLanguage: String? = nil) -> [String] {
        let showsWallets = PayoutRegion.showsPayoutAddresses(regionIdentifier: regionIdentifier, preferredLanguage: preferredLanguage)
        var seen = Set<String>()
        var result: [String] = []
        for identity in identities {
            if walletProviders.contains(identity.provider) && !showsWallets { continue }
            guard let label = label(for: identity.provider), seen.insert(label).inserted else { continue }
            result.append(identity.provider)
        }
        return result
    }

    /// 要显示的名字（`displayedProviders(for:regionIdentifier:preferredLanguage:)` 的名字版）。
    static func labels(for identities: [QTCMe.Identity], regionIdentifier: String?, preferredLanguage: String? = nil) -> [String] {
        displayedProviders(for: identities, regionIdentifier: regionIdentifier, preferredLanguage: preferredLanguage).compactMap { label(for: $0) }
    }

    /// 这个账号有没有绑定某种登录方式。
    static func isBound(_ provider: String, in identities: [QTCMe.Identity]) -> Bool {
        identities.contains { $0.provider == provider }
    }
}

/// What the signed-in account page shows, worked out from the profile and
/// this device's region and first language. Oases Chat shows no QingTeng balance
/// anywhere (account system only): the page leads with the ID card.
struct AccountPageContent: Equatable {
    /// On the card; nil until the profile is read (the card shows dashes).
    let uid: Int?
    /// Bound sign-in methods to list, in the server's order (`IdentityDisplay`).
    let boundProviders: [String]
    /// Methods that can still be linked here, in page order; empty until the profile is read.
    let unboundMethods: [LoginMethod]
    /// The 收币地址 row: profile read and the device is outside mainland China.
    let showsPayoutAddress: Bool
    /// The Arc address on that row.
    let payoutAddress: String?

    init(me: QTCMe?, regionIdentifier: String?, preferredLanguage: String?) {
        uid = me?.uid
        guard let me else {
            boundProviders = []
            unboundMethods = []
            showsPayoutAddress = false
            payoutAddress = nil
            return
        }
        boundProviders = IdentityDisplay.displayedProviders(
            for: me.identities, regionIdentifier: regionIdentifier, preferredLanguage: preferredLanguage
        )
        unboundMethods = LoginMethod.allCases.filter { !IdentityDisplay.isBound($0.rawValue, in: me.identities) }
        showsPayoutAddress = PayoutRegion.showsPayoutAddresses(regionIdentifier: regionIdentifier, preferredLanguage: preferredLanguage)
        payoutAddress = showsPayoutAddress ? me.payoutAddresses.arc : nil
    }

    /// The page for this device (its region and first preferred language).
    static func onThisDevice(_ me: QTCMe?) -> AccountPageContent {
        AccountPageContent(
            me: me, regionIdentifier: PayoutRegion.deviceRegionIdentifier, preferredLanguage: PayoutRegion.devicePreferredLanguage
        )
    }
}
