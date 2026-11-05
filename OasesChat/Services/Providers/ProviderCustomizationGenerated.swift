import Foundation

/// Stand-in for OpenMinis' build-time "Generate Provider Customization" script.
/// That script reads `ANTHROPIC_OAUTH_IDENTIFIER_PROMPT` from a private
/// `Configs/ProviderCustomization.xcconfig` and emits this symbol.
///
/// Stage 2 ships an empty default so the API-key Anthropic path compiles and
/// runs. Claude Code OAuth still needs a real identifier prompt — set
/// `OASES_ANTHROPIC_OAUTH_IDENTIFIER_PROMPT` in the environment (or fill
/// Secrets / a future xcconfig) before using Claude OAuth login.
enum ProviderCustomizationGenerated {
    static var anthropicOAuthIdentifierPrompt: String {
        if let env = ProcessInfo.processInfo.environment["OASES_ANTHROPIC_OAUTH_IDENTIFIER_PROMPT"],
           !env.isEmpty {
            return env
        }
        // Optional compile-time override via Secrets if present later.
        return ""
    }
}
