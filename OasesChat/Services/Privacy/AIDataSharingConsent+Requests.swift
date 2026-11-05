import Foundation

/// Request-boundary helpers for the AI data-sharing consent.
///
/// In limited mode (declined, or no current decision) nothing that carries
/// user content may reach an AI service. The gates live where requests are
/// built — `LLMProviderFactory`, `APIClient`, `VoiceProvider`, the App
/// Intents and the view-model send entry points — and they all ask the same
/// question here. A model served on this device (loopback) is exempt.
extension AIDataSharingConsent {
    /// Whether a request carrying user content may go to `url`: the user
    /// agreed, or the target is a loopback model server on this device.
    static func allowsRequest(to url: URL?) -> Bool {
        isAccepted || isOnDevice(url)
    }

    /// Whether `error` is one of the consent refusals thrown by those gates,
    /// so the UI can offer the consent sheet instead of "try again".
    static func isConsentError(_ error: Error) -> Bool {
        if case .dataSharingConsentRequired? = error as? APIError { return true }
        if case .dataSharingConsentRequired? = error as? VoiceProviderError { return true }
        if case .dataSharingConsentRequired? = error as? SessionIntentError { return true }
        if case .dataSharingConsentRequired? = error as? CorrectionError { return true }
        return false
    }
}
