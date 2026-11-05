import Foundation

enum LLMError: LocalizedError {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    /// Transient server-side errors (HTTP 500/502/503/504/529) that should be
    /// retried on the same model rather than triggering a group fallback.
    case transientError(message: String)
    case decodingError(underlying: Error)
    case rateLimited
    case cancelled
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty
                ? String(localized: "Invalid API key", comment: "LLM error: the API key / credentials were rejected")
                : String(localized: "Invalid API key: \(detail)", comment: "LLM error: the API key / credentials were rejected; argument is the provider's detail message")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)", comment: "LLM error: network failure; argument is the system error description")
        case .providerError(let message):
            return String(localized: "Provider error: \(message)", comment: "LLM error: the provider rejected the request; argument is the provider's message")
        case .transientError(let message):
            return String(localized: "Service temporarily unavailable: \(message)", comment: "LLM error: temporary server-side failure (5xx); argument is the provider's message")
        case .decodingError(let error):
            return String(localized: "Decoding error: \(error.localizedDescription)", comment: "LLM error: the response could not be parsed; argument is the error description")
        case .rateLimited:
            return String(localized: "Rate limited — please try again later", comment: "LLM error: too many requests")
        case .cancelled:
            return String(localized: "Request was cancelled", comment: "LLM error: the request was cancelled")
        case .unknown(let error):
            if let error {
                return String(localized: "Unknown error: \(error.localizedDescription)", comment: "LLM error: unclassified failure; argument is the error description")
            }
            return String(localized: "Unknown error: no details", comment: "LLM error: unclassified failure without any detail")
        }
    }

    var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Errors that should be retried with countdown on the same provider.
    /// Includes both network errors and transient server-side errors (5xx).
    var isRetryable: Bool {
        switch self {
        case .networkError, .transientError:
            return true
        case .invalidAPIKey, .providerError, .decodingError, .rateLimited, .cancelled, .unknown:
            return false
        }
    }

    /// Errors that indicate the provider itself cannot serve this request
    /// (rate limit, invalid key, permanent provider-side rejection). These trigger
    /// an immediate fallback to the next model in a group, without retry countdown.
    ///
    /// Note: transientError and networkError are also fallbackable — after
    /// auto-retry is exhausted on the current model, group fallback kicks in.
    var fallbackReason: String {
        switch self {
        case .rateLimited: return String(localized: "Rate limited", comment: "Short reason shown in the model-fallback trail: too many requests")
        case .invalidAPIKey: return String(localized: "Invalid API key", comment: "LLM error: the API key / credentials were rejected")
        case .providerError(let msg): return String(localized: "Provider error: \(String(msg.prefix(60)))", comment: "LLM error: the provider rejected the request; argument is the provider's message")
        default: return String(localized: "Error", comment: "Generic short reason shown in the model-fallback trail")
        }
    }

    var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError:
            return true
        case .transientError, .networkError, .decodingError, .cancelled, .unknown:
            return false
        }
    }
}
