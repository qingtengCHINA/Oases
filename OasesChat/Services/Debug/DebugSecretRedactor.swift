#if DEBUG
import Foundation

/// Masks credentials in captured LLM traffic before the debug server hands it
/// to a client (`debug.llmRequests`). The capture ring (`LastAPIRequestBody`)
/// keeps raw data for on-device copying; everything that leaves through the
/// debug RPC goes through here, so provider code doesn't have to remember to
/// scrub what it records.
enum DebugSecretRedactor {
    static let mask = "[REDACTED]"

    /// Header names whose value is always a credential.
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
    ]
    /// Name fragments that mark a header as credential-bearing
    /// (`x-api-key`, `x-goog-api-key`, `…-token`, App Attest assertions, …).
    private static let sensitiveHeaderFragments = [
        "api-key", "apikey", "token", "secret", "session", "signature", "assertion",
    ]

    static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return sensitiveHeaderNames.contains(lower)
            || sensitiveHeaderFragments.contains { lower.contains($0) }
    }

    static func headers(_ headers: [String: String]) -> [String: String] {
        var out = headers
        for key in headers.keys where isSensitiveHeader(key) {
            out[key] = mask
        }
        return out
    }

    /// Query parameters that carry keys (Gemini `?key=`, `access_token=`, …).
    static func url(_ string: String) -> String {
        replace(queryParameter, in: string, template: "$1\(mask)")
    }

    /// Request / response bodies (JSON, SSE, free text): credential-named
    /// JSON fields, `Bearer …`, well-known key shapes, and key query params.
    static func text(_ string: String) -> String {
        var out = replace(jsonCredentialField, in: string, template: "$1\(mask)$2")
        out = replace(bearerToken, in: out, template: "$1\(mask)")
        out = replace(keyShapes, in: out, template: mask)
        out = replace(queryParameter, in: out, template: "$1\(mask)")
        return out
    }

    // MARK: - Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `"api_key": "…"`, `"access_token":"…"`, `"authorization": "…"`, …
    private static let jsonCredentialField = regex(
        #"("(?:api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|secret|password|authorization|token)"\s*:\s*")[^"]*(")"#
    )
    /// `Bearer <token>` anywhere in text.
    private static let bearerToken = regex(#"(bearer\s+)[A-Za-z0-9._~+/=-]+"#)
    /// OpenAI / Anthropic (`sk-…`, `sk-ant-…`), Google API keys and OAuth
    /// access tokens, xAI, Groq.
    private static let keyShapes = regex(
        #"\b(?:sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z._-]+|xai-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,})"#
    )
    /// `?key=…` / `&access_token=…` style query parameters.
    private static let queryParameter = regex(
        #"([?&](?:key|api[_-]?key|access[_-]?token|token|sig|signature)=)[^&#\s"]+"#
    )

    private static func replace(_ regex: NSRegularExpression, in string: String, template: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
    }
}
#endif
