@preconcurrency import FileProvider
import Foundation

private let logger = AppLogger(category: "FileProvider")

/// [P0-3] Registers the `OasesChatFileProvider` extension's domain so it shows
/// up under "浏览 → 位置" in the iOS Files app.
///
/// Ported from OpenMinis `MinisApp.swift::registerFileProviderDomain`, minus its
/// `fileProviderResetGeneration` remove-and-re-add machinery: that exists to
/// repair installs where an older build left the domain in a paused state, which
/// OasesChat has never shipped.
enum FileProviderDomainRegistrar {
    /// Identifier is load-bearing — `FileProviderEnumerator` hardcodes the same
    /// string when it constructs `NSFileProviderDomainIdentifier`.
    private nonisolated(unsafe) static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier("dev.oases.chat.ios.files"),
        displayName: "Oases"
    )

    static func register() {
        let root = AppGroup.fileProviderRoot
        let fm = FileManager.default
        for sub in SharedFolderVisibility.allFolderNames {
            try? fm.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error {
                logger.warning("getDomains failed: \(error.localizedDescription)")
            }

            if domains.contains(where: { $0.identifier == domain.identifier }) {
                NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { signalErr in
                    if let signalErr {
                        logger.warning("signal failed: \(signalErr.localizedDescription)")
                    }
                }
                return
            }

            NSFileProviderManager.add(domain) { addError in
                if let addError {
                    logger.warning("domain add failed: \(addError.localizedDescription)")
                    return
                }
                logger.info("domain registered id=\(domain.identifier.rawValue)")
                NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { _ in }
            }
        }
    }
}
