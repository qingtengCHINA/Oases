import Foundation

// MARK: - Token Storage Model

/// Persisted Kimi Code OAuth credentials. Kept UIKit-free (this file compiles
/// into the unit-test target) so the refresh-race logic below is testable in
/// isolation. Mirrors `ClaudeTokenStorage`, plus the RFC 8628 device identity.
struct KimiTokenStorage: Codable {
    let accessToken: String
    let refreshToken: String?
    let expireDate: Date?
    /// Persisted device ID from the device-authorization step (RFC 8628).
    let deviceId: String
    let lastRefresh: Date?

    var isExpired: Bool {
        guard let expire = expireDate else { return false }
        return expire < Date()
    }
}

// MARK: - Refresh-failure resolution (single-flight backstop)

/// [T-oauth-refresh-race] Pure decision logic for "a refresh attempt failed —
/// now what?", split out from `KimiOAuthManager` so it has NO UIKit / network
/// dependency and can be unit-tested against the exact concurrent ordering that
/// bit Anthropic (A=200 rotates + writes the new token, stale B=400 must NOT
/// delete it). All I/O is injected so the test drives credential state
/// deterministically without touching the real Keychain.
///
/// This is a deliberate copy of `ClaudeOAuthRefreshCoordinator`'s shape: the
/// compare-before-delete guard is the load-bearing correctness requirement for
/// Kimi too, and reusing the proven contract avoids re-deriving it.
enum KimiOAuthRefreshCoordinator {

    /// Classify a refresh error as "refresh token itself invalid" (revoked /
    /// reused / expired → clear credentials) vs transient (network → keep).
    /// Pure + in the test target so both the coordinator and its tests share
    /// one classification.
    ///
    /// [T-oauth-refresh-race-classify] Delegates to the shared structured
    /// classifier (real HTTP status marker + parsed OAuth `error` code). The old
    /// substring test deleted credentials on a 5xx whose body merely mentioned
    /// "refresh_token" or contained "400" in a request id.
    static func isRefreshTokenInvalid(_ error: LLMError) -> Bool {
        OAuthRefreshErrorClassifier.isTokenInvalid(
            error,
            fatalErrorCodes: ["invalid_grant", "invalid_token", "invalid_request",
                              "unauthorized_client", "refresh_token_reused"]
        )
    }

    /// Decide what storage to use (or whether to clear credentials) after a
    /// refresh attempt threw `error`.
    ///
    /// Critical guard — *compare-before-delete*: on a token-invalid error we
    /// clear stored credentials ONLY when the currently-persisted refresh token
    /// is still the one we failed with. If a concurrent refresh already rotated
    /// it, this request is stale and returning `current` preserves the
    /// freshly-written token instead of wiping it.
    static func resolveAfterRefreshFailure(
        staleRefreshToken: String,
        existingStorage: KimiTokenStorage,
        error: Error,
        isFatal: (LLMError) -> Bool,
        loadCurrent: () -> KimiTokenStorage?,
        deleteCredentials: () -> Void,
        log: ((String) -> Void)? = nil
    ) throws -> KimiTokenStorage {
        // Re-load the latest persisted state — a concurrent winner may have
        // rotated the token while we were awaiting.
        let current = loadCurrent()

        if let llmError = error as? LLMError, isFatal(llmError) {
            if let current, current.refreshToken != staleRefreshToken {
                log?("Stale invalid_grant ignored — token already rotated; keeping new credentials")
                return current
            }
            log?("Refresh token invalid, clearing credentials: \(llmError)")
            deleteCredentials()
            let vendorName = "Kimi"
            throw LLMError.invalidAPIKey(detail: String(localized: "\(vendorName): refresh token invalid — \(String(describing: llmError))", comment: "Sign-in error: the OAuth refresh token was rejected, user must sign in again; arguments are the provider name and the underlying error"))
        }

        // Non-fatal (network / transient). Prefer whatever is now stored (a
        // concurrent winner may have refreshed); else keep the caller's copy.
        let fallback = current ?? existingStorage
        log?("Refresh failed, keeping existing token: \(error)")
        if fallback.isExpired {
            log?("Existing token is also expired — re-auth required")
            let vendorName = "Kimi"
            throw LLMError.invalidAPIKey(detail: String(localized: "\(vendorName): token expired and refresh failed — \(String(describing: error))", comment: "Sign-in error: the OAuth token expired and could not be refreshed; arguments are the provider name and the underlying error"))
        }
        return fallback
    }
}
