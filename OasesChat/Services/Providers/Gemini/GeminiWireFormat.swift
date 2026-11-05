import Foundation

/// [T-gemini-empty-part-oneof-400] Pure, testable helpers that enforce Gemini's
/// wire-format invariants when building `contents[].parts[]`.
///
/// Gemini's REST API models a part's payload as a protobuf `oneof` ("data"). An
/// EMPTY text part — `{"text": ""}` — is treated as an *uninitialized* oneof and
/// rejected:
///
///   contents[N].parts[M].data: required oneof field 'data' must have one
///   initialized field  (HTTP 400 INVALID_ARGUMENT)
///
/// This bites Gemini 3.x / 3.5 Flash especially: a thinking-heavy turn (whole
/// budget spent thinking) or a safety-stripped candidate can yield an empty
/// assistant text, and a naive `{"text": text}` then ships `{"text": ""}` → 400,
/// surfacing to users as "tool format errors". The fix (cc-plugins #99, verified
/// against the live gateway: `{"text":""}`→400, `{"text":" "}`→200) is to never
/// emit an empty text part — substitute a single space.
///
/// Centralised here so every call site shares one guarantee and a regression
/// test can pin the behaviour.
enum GeminiWireFormat {

    /// Placeholder used in place of an empty text so the `oneof` is always
    /// initialised. A single space is the minimal non-empty, semantically-inert
    /// value (mirrors the Anthropic path's "never send an empty text block").
    static let nonEmptyPlaceholder = " "

    /// Coerce a text value so it is never the empty string. `nil`/`""` → `" "`.
    static func nonEmptyText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return nonEmptyPlaceholder }
        return text
    }

    /// Build a text part guaranteed to satisfy the oneof constraint (never empty).
    static func textPart(_ text: String?) -> [String: Any] {
        ["text": nonEmptyText(text)]
    }

    /// The `response` object for a `functionResponse` part, guaranteeing the
    /// wrapped `result` string is never empty (an empty tool result would ship an
    /// empty string into the response payload).
    static func functionResponseResult(_ content: String?) -> [String: Any] {
        ["result": nonEmptyText(content)]
    }

    /// [T-gemini-block-reasons] Candidate finish reasons meaning the output was
    /// withheld or cut off by a filter instead of completing normally.
    static let blockedFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
        "IMAGE_SAFETY", "LANGUAGE", "MALFORMED_FUNCTION_CALL",
    ]

    /// Error for a response Gemini blocked (`promptFeedback.blockReason`) or
    /// stopped with a blocked finish reason; nil for a normal response. `json`
    /// is the unwrapped response object (Cloud Code envelopes already removed).
    /// Callers raise it only when nothing usable was produced — without it a
    /// blocked turn surfaced as a silent empty reply.
    static func blockError(in json: [String: Any]) -> LLMError? {
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            return .providerError(message: String(localized: "Gemini blocked the prompt (\(reason))", comment: "Error: Gemini refused the request for safety/policy reasons; argument is Gemini's block reason code"))
        }
        if let first = (json["candidates"] as? [[String: Any]])?.first,
           let reason = first["finishReason"] as? String,
           blockedFinishReasons.contains(reason) {
            return .providerError(message: String(localized: "Gemini returned no content (finishReason \(reason))", comment: "Error: Gemini stopped without output; argument is Gemini's finish reason code"))
        }
        return nil
    }
}
