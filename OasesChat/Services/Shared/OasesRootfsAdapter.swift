import Foundation

/// Stand-in for OpenMinis `RootfsManager.shared.dataPath`. OasesChat keeps the
/// data dir on `ISHRootfsManager.dataURL`. Computed so a rootfs reset is picked
/// up immediately.
///
/// Centralised here so multiple subsystems (ModelUse, BrowserUse, …) reference
/// one symbol instead of duplicating the adapter per file. When OpenMinis'
/// `RootfsManager` is fully ported (or the equivalent is renamed), this is the
/// single swap point.
enum OasesRootfsAdapter {
    static var dataPath: URL { ISHRootfsManager.dataURL }
}
