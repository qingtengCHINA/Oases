import UIKit

/// The Share Extension's principal view controller.
@MainActor
final class ShareViewController: UIViewController {

    /// Set to true once async processing + redirect is done, so viewDidAppear can dismiss.
    /// MainActor-isolated (class is `@MainActor`) so viewDidLoad Task and
    /// viewDidAppear share a single-threaded flag — no data race.
    private var processingDone = false
    private var didCompleteRequest = false
    /// Upper bound on the whole share. Each `loadItem` already has its own
    /// timeout in `ShareViewModel`; this is the backstop that guarantees
    /// `completeRequest` runs so the share sheet can never hang.
    private static let processingTimeout: TimeInterval = 60

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        NSLog("[ShareExt] viewDidLoad — starting processing")

        let processing = Task { @MainActor in
            let vm = ShareViewModel()
            let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            NSLog("[ShareExt] inputItems count: %d", items.count)
            await vm.processExtensionItems(items)
            // The watchdog below already dismissed the sheet — don't hand a
            // late share to the host app behind the user's back.
            guard !didCompleteRequest else { return }
            let saved = vm.save()
            NSLog("[ShareExt] save() returned: %@", saved ? "true" : "false")

            // Verify what was saved
            if let pending = SharedContainerStore.loadPendingShare() {
                NSLog("[ShareExt] Verified pending share: %d items", pending.items.count)
                for (i, item) in pending.items.enumerated() {
                    NSLog("[ShareExt]   item[%d] kind=%@ value=%@", i, item.kind.rawValue, String(item.value.prefix(100)))
                }
            } else {
                NSLog("[ShareExt] WARNING: loadPendingShare returned nil after save!")
            }

            // Verify shared file directory
            if let dir = SharedContainerStore.sharedFileDirectory {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                NSLog("[ShareExt] Shared file dir: %@ — files: %@", dir.path, files.description)
            } else {
                NSLog("[ShareExt] WARNING: sharedFileDirectory is nil!")
            }

            // Verify sharedDefaults accessible
            if let defaults = SharedContainerStore.sharedDefaults {
                let hasKey = defaults.data(forKey: "pendingShare") != nil
                NSLog("[ShareExt] sharedDefaults accessible, pendingShare key present: %@", hasKey ? "YES" : "NO")
            } else {
                NSLog("[ShareExt] WARNING: sharedDefaults is nil — App Group not configured?")
            }

            redirectToHostApp()

            processingDone = true
            NSLog("[ShareExt] Processing done, completing request")
            finishRequestIfNeeded()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.processingTimeout * 1_000_000_000))
            guard let self, !self.didCompleteRequest else { return }
            NSLog("[ShareExt] processing exceeded %.0fs — completing request anyway", Self.processingTimeout)
            processing.cancel()
            self.finishRequestIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only dismiss if async processing is already done.
        // If not done yet, the Task completion above will dismiss.
        if processingDone {
            NSLog("[ShareExt] viewDidAppear — processingDone, completing request")
            finishRequestIfNeeded()
        } else {
            NSLog("[ShareExt] viewDidAppear — processing still in progress, deferring dismiss")
        }
    }

    private func finishRequestIfNeeded() {
        guard !didCompleteRequest else { return }
        didCompleteRequest = true
        extensionContext?.completeRequest(returningItems: [])
    }

    // MARK: - Redirect to main app

    private func redirectToHostApp() {
        // Must match the host app's CFBundleURLSchemes (`oases`, project.yml)
        // and `DeepLinkRouter.scheme`. OpenMinis used minis://.
        guard let url = URL(string: "oases://share") else {
            NSLog("[ShareExt] ERROR: Failed to create oases://share URL")
            return
        }

        let selectorOpenURL = sel_registerName("openURL:")
        var responder: UIResponder? = self
        var found = false
        while responder != nil {
            if let application = responder as? UIApplication {
                NSLog("[ShareExt] Found UIApplication in responder chain, opening URL")
                application.open(url, options: [:], completionHandler: nil)
                found = true
                break
            }
            // Fallback for extension process where UIApplication isn't in the chain.
            if responder?.responds(to: selectorOpenURL) == true {
                _ = responder?.perform(selectorOpenURL, with: url)
                found = true
                break
            }
            responder = responder?.next
        }
        if !found {
            NSLog("[ShareExt] WARNING: UIApplication not found in responder chain!")
        }
    }
}
