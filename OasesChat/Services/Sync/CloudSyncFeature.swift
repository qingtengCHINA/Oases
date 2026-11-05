import Foundation

/// iCloud sync and iCloud backup were removed from the product (owner
/// decision, 2026-09-29). The engines under `Services/Sync` stay in the tree
/// but are unreachable:
///   • nothing starts them (`SyncV2Bootstrap`, `SyncCore`, `CloudSyncEngine`,
///     `SyncDirtyScanner` and the fakefs `SessionFileChangeTracker` all check
///     this flag at their entry points);
///   • `ChatStore` records no dirty rows or delete tombstones and drops any
///     queue left over from a build that still synced;
///   • the Settings, sidebar and per-screen entry points are gone, and the
///     iCloud/CloudKit entitlements were removed.
///
/// Turning this back on is not enough to bring the feature back — the UI,
/// the entitlements and the privacy copy would have to return with it.
///
/// Not affected: iCloud Keychain synchronization of provider API keys (a
/// system Keychain attribute, no app-side sync), and the two-phase restore
/// in `PendingBackupRestore`, which only finishes a restore that an older
/// build already staged on this device.
enum CloudSyncFeature {
    static let isEnabled = false

    /// The sync toggles that builds with iCloud sync persisted. Several views
    /// still mirror `cloudSync.v2.enabled` through `@AppStorage`; clearing the
    /// stored value keeps any leftover sync affordance hidden.
    static let storedToggleKeys = ["cloudSync.v2.enabled", "cloudSync.enabled"]

    /// Switch off the toggles an earlier build may have left on. Idempotent
    /// and cheap; called once at launch.
    static func retireStoredToggles(in defaults: UserDefaults = .standard) {
        guard !isEnabled else { return }
        for key in storedToggleKeys where defaults.bool(forKey: key) {
            defaults.set(false, forKey: key)
        }
    }
}
