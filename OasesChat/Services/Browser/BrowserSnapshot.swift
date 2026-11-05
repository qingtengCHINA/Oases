import Foundation

enum BrowserReadStrategy: String, Codable, Sendable {
    case webKit
    case agentReachReader
    case searchCache
}

enum BrowserChallenge: String, Codable, Sendable {
    case login
    case captcha
    case payment
    case destructiveAction
}

struct BrowserSnapshot: Codable, Sendable, Equatable {
    let url: String
    let title: String
    let text: String
    let links: [[String: String]]
    let forms: [[String: String]]
    let strategy: BrowserReadStrategy
    let navigationStatus: String
    let screenshotReference: String?
    let truncated: Bool
    let challenge: BrowserChallenge?

    var stableMetadataLine: String {
        "strategy=\(strategy.rawValue) navigation=\(navigationStatus) truncated=\(truncated) challenge=\(challenge?.rawValue ?? "none")"
    }
}
