import Foundation

/// 收币地址区块和"登录方式"里的 Arc 钱包显示不显示（接入说明第 2 节第 2 条和第 5 节"账号页设计规范"第 4 条；
/// 主人 2026-10-23 补充了语言）：这台设备是中国大陆的就不显示——系统地区是中国大陆（`CN`），**或者**第一个首选语言
/// 带着中国大陆的地区（例如 `zh-Hans-CN`）；其他地方都显示，包括香港、澳门、台湾。不看 IP；服务器不按地区限制，
/// 这条规则只在 App 里执行。两处都只经过 `showsPayoutAddresses(regionIdentifier:preferredLanguage:)` 这一个函数。
///
/// 从词忆移植（`Services/Account/PayoutAddress.swift`，提交 54216d5），逻辑一字不改。
enum PayoutRegion {

    /// 要不要显示收币地址（和 Arc 钱包）。
    /// - Parameters:
    ///   - regionIdentifier: 设备的系统地区（`Locale.current.region?.identifier`，如 `"CN"`、`"US"`）；读不到时为 `nil`。
    ///   - preferredLanguage: 第一个首选语言（`Locale.preferredLanguages.first`，如 `"zh-Hans-CN"`、`"en-GB"`）；没有时为 `nil`。
    /// - Returns: 地区是 `CN`，或首选语言的地区是 `CN`，就不显示；其他（含都读不到）显示。
    static func showsPayoutAddresses(regionIdentifier: String?, preferredLanguage: String? = nil) -> Bool {
        if regionIdentifier?.uppercased() == "CN" { return false }
        if let preferredLanguage, regionSubtag(of: preferredLanguage) == "CN" { return false }
        return true
    }

    /// 这台设备要不要显示收币地址（和 Arc 钱包）：系统地区和第一个首选语言代进 `showsPayoutAddresses`。
    /// - Returns: 不是中国大陆的设备为真。
    static func showsPayoutAddressesOnThisDevice() -> Bool {
        showsPayoutAddresses(regionIdentifier: deviceRegionIdentifier, preferredLanguage: devicePreferredLanguage)
    }

    /// 设备的系统地区（"设置 → 通用 → 语言与地区 → 地区"），不是 App 里选的显示语言。
    static var deviceRegionIdentifier: String? { Locale.current.region?.identifier }

    /// 设备的第一个首选语言。
    static var devicePreferredLanguage: String? { Locale.preferredLanguages.first }

    /// 语言标识（BCP 47）里的地区：语言之后、第一个单字母扩展（`-u-`、`-x-`……）之前，两个字母或三位数字的那一段。
    /// - Parameter languageIdentifier: 例如 `"zh-Hans-CN"`、`"en_GB"`、`"zh-Hans"`、`"es-419"`。
    /// - Returns: 大写的地区（`"CN"`、`"GB"`、`"419"`）；没有地区时为 `nil`。
    static func regionSubtag(of languageIdentifier: String) -> String? {
        let tag = languageIdentifier.split(separator: "@", maxSplits: 1).first ?? ""
        let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" })
        for part in parts.dropFirst() {
            if part.count == 1 { break }
            if part.count == 2, part.allSatisfy({ $0.isASCII && $0.isLetter }) { return part.uppercased() }
            if part.count == 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) { return String(part) }
        }
        return nil
    }
}

/// The payout address ("收币地址"): where future QTC coins would be sent.
/// Arc only — Solana is cancelled (2026-10-23). Typed by hand; it never
/// signs anyone in, and there is no wallet in the app (QTC guide §2, §6).
/// Whether it shows at all is `PayoutRegion`'s call.
enum PayoutAddress {
    /// An Arc address's shape: `0x` and 40 ASCII hex digits, either case.
    /// The EIP-55 checksum of a mixed-case address is QTC's to check (its
    /// `400 invalid_address`); CryptoKit has no Keccak (ruling C13).
    static func isPlausibleArc(_ address: String) -> Bool {
        let utf8 = Array(address.utf8)
        guard utf8.count == 42, utf8[0] == UInt8(ascii: "0"), utf8[1] == UInt8(ascii: "x") else { return false }
        return utf8.dropFirst(2).allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
