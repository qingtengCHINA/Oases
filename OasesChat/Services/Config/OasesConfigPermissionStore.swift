import Foundation
import Combine

/// Master switch controlling whether the agent can use the
/// `oases-config` CLI at all.
///
/// This is intentionally a separate store from `OffloadPermissionManager`
/// — that one tracks per-command privacy levels (camera, calendar, …)
/// for shell offloads, while this one is a single boolean gate at the
/// top of the entire oases-config subsystem. Disabling it short-circuits
/// every CLI call before any field lookup, ConfirmationGate enqueue,
/// or audit write.
///
/// The flag itself is intentionally *not* settable through oases-config:
/// the registry registers a hidden placeholder on the same path so any
/// agent attempt to flip the switch (off → silence, on → self-grant)
/// returns `permission_denied`.
@MainActor
final class OasesConfigPermissionStore: ObservableObject {
    static let shared = OasesConfigPermissionStore()

    static let userDefaultsKey = "permissions.oasesConfig.enabled"

    /// Key written by the now-removed `MinisConfigPermissionStore`. That type was
    /// a byte-for-byte duplicate of this one except for the key, and the Settings
    /// toggle was bound to *it* while every actual gate
    /// (`ConfigOffloadBridge`, `ConfigRegistry+Builtins`) read *this* one — so the
    /// switch appeared to work but changed nothing. Adopt the legacy value once so
    /// a user who had deliberately turned the gate off stays off after the fix.
    private static let legacyUserDefaultsKey = "permissions.minisConfig.enabled"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.userDefaultsKey)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.userDefaultsKey) == nil {
            if defaults.object(forKey: Self.legacyUserDefaultsKey) != nil {
                // One-time migration from the duplicate store's key.
                let legacy = defaults.bool(forKey: Self.legacyUserDefaultsKey)
                self.enabled = legacy
                defaults.set(legacy, forKey: Self.userDefaultsKey)
            } else {
                // Default: true (preserves existing behaviour for users who
                // upgrade into a build that adds the gate).
                self.enabled = true
            }
        } else {
            self.enabled = defaults.bool(forKey: Self.userDefaultsKey)
        }
    }
}
