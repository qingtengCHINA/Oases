import Foundation

@MainActor
final class AgentBrowserService {
    static let shared = AgentBrowserService()

    private let policy = BrowserPolicy()

    func profile(for workspaceID: String) -> BrowserProfile {
        BrowserProfile(workspaceID: workspaceID)
    }

    func validateNavigation(url: URL, allowLocalCapability: Bool = false) throws {
        try policy.validate(url: url, allowLocalCapability: allowLocalCapability)
    }

    func snapshot(
        url: String,
        title: String,
        text: String,
        links: [[String: String]],
        forms: [[String: String]],
        strategy: BrowserReadStrategy,
        navigationStatus: String = "complete",
        screenshotReference: String? = nil,
        maxTextBytes: Int = 30_000
    ) -> BrowserSnapshot {
        let data = Data(text.utf8)
        let truncated = data.count > maxTextBytes
        let output = truncated ? String(decoding: data.prefix(maxTextBytes), as: UTF8.self) : text
        return BrowserSnapshot(
            url: url,
            title: title,
            text: output,
            links: links,
            forms: forms,
            strategy: strategy,
            navigationStatus: navigationStatus,
            screenshotReference: screenshotReference,
            truncated: truncated,
            challenge: Self.detectChallenge(title: title, text: output)
        )
    }

    nonisolated static func detectChallenge(title: String, text: String) -> BrowserChallenge? {
        let haystack = "\(title) \(text)".lowercased()
        // Page-text detection keywords (matched against web page content), not UI copy.
        if containsAny(haystack, ["captcha", "验证码", "i'm not a robot", "我不是机器人"]) { // i18n-ignore: page-text detection keywords
            return .captcha
        }
        if containsAny(haystack, ["sign in", "log in", "login", "登录", "注册", "password", "密码"]) { // i18n-ignore: page-text detection keywords
            return .login
        }
        if containsAny(haystack, ["credit card", "付款", "支付", "checkout", "billing", "cvv"]) { // i18n-ignore: page-text detection keywords
            return .payment
        }
        if containsAny(haystack, ["delete permanently", "永久删除", "confirm deletion", "不可逆", "destroy"]) { // i18n-ignore: page-text detection keywords
            return .destructiveAction
        }
        return nil
    }

    private nonisolated static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.localizedCaseInsensitiveContains($0) }
    }
}
