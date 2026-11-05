import Darwin
import Foundation

enum BrowserPolicyError: LocalizedError, Equatable, Sendable {
    case unsupportedScheme(String)
    case missingHost
    case blockedHost(String)
    case blockedAddress(String)

    // Returned to the agent as web_browse / browser_use tool errors; the
    // in-app browser shows WebLoadError's generic copy instead of this text.
    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "浏览器策略拒绝 scheme=\(scheme)" // i18n-ignore: model-facing tool error
        case .missingHost:
            return "浏览器策略拒绝没有主机名的 URL" // i18n-ignore: model-facing tool error
        case .blockedHost(let host):
            return "浏览器策略拒绝本地或内部主机：\(host)" // i18n-ignore: model-facing tool error
        case .blockedAddress(let address):
            return "浏览器策略拒绝内部地址：\(address)" // i18n-ignore: model-facing tool error
        }
    }
}

struct BrowserPolicy: Sendable {
    func validate(url: URL, allowLocalCapability: Bool = false) throws {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw BrowserPolicyError.unsupportedScheme(scheme.isEmpty ? "none" : scheme)
        }
        guard let rawHost = url.host, !rawHost.isEmpty else {
            throw BrowserPolicyError.missingHost
        }
        guard !allowLocalCapability else { return }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host == "broadcasthost" {
            throw BrowserPolicyError.blockedHost(host)
        }
        if host == "0.0.0.0" || host == "::" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.") {
            throw BrowserPolicyError.blockedAddress(host)
        }
        if isPrivateIPv4(host) || isPrivateIPv6(host) {
            throw BrowserPolicyError.blockedAddress(host)
        }
        // WebKit also accepts shorthand/numeric IPv4 (`127.1`, `2130706433`,
        // `0x7f.0.0.1`) and IPv4-mapped IPv6 (`::ffff:7f00:1`); check the
        // address they actually resolve to.
        if let ipv4 = Self.embeddedIPv4(host), ipv4 != host,
           ipv4.hasPrefix("127.") || ipv4.hasPrefix("0.") || isPrivateIPv4(ipv4) {
            throw BrowserPolicyError.blockedAddress(host)
        }
    }

    static func embeddedIPv4(_ host: String) -> String? {
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let value = UInt32(bigEndian: v4.s_addr)
            return "\(value >> 24).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        guard bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff else { return nil }
        return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return false }
        let values = parts.compactMap { Int($0) }
        guard values.allSatisfy({ (0...255).contains($0) }) else { return false }
        let first = values[0]
        let second = values[1]
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
            || first == 100 && (64...127).contains(second)
            || first == 198 && (18...19).contains(second)
        || first >= 224
    }

    private func isPrivateIPv6(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "::1"
            || value.hasPrefix("fc")
            || value.hasPrefix("fd")
            || value.hasPrefix("fe8")
            || value.hasPrefix("fe9")
            || value.hasPrefix("fea")
            || value.hasPrefix("feb")
            || value.hasPrefix("ff")
    }
}
