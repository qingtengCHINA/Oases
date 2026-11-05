import SwiftUI
import UIKit
import WebKit

private let webAppWebLogger = AppLogger(category: "WebAppWeb")

/// Fullscreen, immersive WKWebView host that renders one WebAppShortcut.
/// Hides the status bar and the host nav bar to give the HTML the entire
/// screen. Intentionally minimal — no tab strip, no URL bar, no JS bridge.
///
/// Security posture (see `LocalHTMLSandbox`):
///   - Loads only via `loadFileURL(_:allowingReadAccessTo:)`, with read access
///     limited to the HTML's own folder (`WebAppPathResolver`).
///   - No network: a content rule list blocks every http(s)/ws(s) load, so a
///     page cannot send out what it reads. JavaScript runs only once that
///     rule list is installed.
///   - Navigation: `file:` inside the read-access folder and `about:` stay in
///     the page; a link the user taps to http(s) opens in Safari; anything
///     else (script-driven web navigations, `data:`, `oases://`, `tel:`, …)
///     is cancelled so a hostile HTML can't escape into the host app.
///   - Persistent website data store, isolated per shortcut by its UUID
///     (iOS 17+ `WKWebsiteDataStore(forIdentifier:)`; `.default()` on older
///     OSes). Cookies / localStorage / sessionStorage carry over between
///     launches so logged-in shortcuts stay logged in, and each shortcut's
///     session is walled off from every other shortcut's.
///   - No `WKScriptMessageHandler` registered. `window.webkit` is unset.
final class WebAppWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let shortcut: WebAppShortcut
    private let resolved: WebAppPathResolver.Resolved
    private var webView: WKWebView!
    private var dismissEdgeRecognizer: UIScreenEdgePanGestureRecognizer!
    /// Lets only a real tap send a web link to Safari.
    private let tapTracker = LocalHTMLTapTracker()
    /// nil until the no-network rule list is installed; then whether page
    /// JavaScript may run (false only if the rules failed to compile).
    private var scriptsAllowed: Bool?

    init(shortcut: WebAppShortcut, resolved: WebAppPathResolver.Resolved) {
        self.shortcut = shortcut
        self.resolved = resolved
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        // Persistent, per-shortcut-isolated storage so cookies / localStorage /
        // sessionStorage survive across launches (no repeated logins). iOS 17+
        // gives each shortcut its own on-disk store keyed by its UUID, so two
        // shortcuts never share a session; older OSes fall back to the shared
        // default store (still persistent, but not isolated).
        if #available(iOS 17.0, *) {
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: shortcut.id) ?? UUID())
        } else {
            cfg.websiteDataStore = .default()
        }
        cfg.suppressesIncrementalRendering = false
        cfg.allowsInlineMediaPlayback = true
        // No JS bridge: leave userContentController bare (apart from the
        // no-network rule list). Don't register any WKScriptMessageHandler,
        // don't inject a WKUserScript that exposes native APIs.
        // JavaScript starts off and is switched on per navigation once the
        // no-network rules are in place (`decidePolicyFor … preferences:`).
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false

        let wv = WKWebView(frame: view.bounds, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.allowsBackForwardNavigationGestures = false
        // Don't let UIKit add safe-area insets on top of the WebView's
        // own viewport-fit=cover handling. Otherwise the status-bar slot
        // shows as a black bar at the top and the home-indicator slot
        // doubles up at the bottom (page already uses env(safe-area-…)).
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        tapTracker.install(on: wv)
        view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = wv

        // Left-edge swipe — iOS-canonical "go back" gesture. Kept as a
        // belt-and-braces escape hatch in case the user dismisses the
        // floating menu without picking Close.
        let r = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
        r.edges = .left
        view.addGestureRecognizer(r)
        dismissEdgeRecognizer = r

        // Always-on "…" floating menu in the bottom-right. Mirrors
        // the chat Safari view's bottom-right dot menu so the two immersive
        // paths feel the same. Without this the user has no visible
        // way out of a Home-Screen-launched WebApp.
        installMenuButton()

        webAppWebLogger.info("loading shortcut id=\(shortcut.id.prefix(8)) scope=\(shortcut.pathScope.rawValue) htmlURL=\(resolved.htmlURL.lastPathComponent) readRoot=\(resolved.readAccessRoot.lastPathComponent)")
        LocalHTMLSandbox.prepare(wv) { [weak self] scriptsAllowed in
            guard let self else { return }
            self.scriptsAllowed = scriptsAllowed
            self.webView.loadFileURL(self.resolved.htmlURL, allowingReadAccessTo: self.resolved.readAccessRoot)
        }
    }

    @objc private func edgePanned(_ r: UIScreenEdgePanGestureRecognizer) {
        guard r.state == .recognized else { return }
        dismiss(animated: true)
    }

    // MARK: - Floating menu

    private func installMenuButton() {
        // The button itself is just the menu host + hit target. The
        // visible "pill" is a separate UIVisualEffectView placed BEHIND
        // the button in the view hierarchy — putting the effect view
        // inside a UIButton's subviews turned out to render the glyph
        // beneath the blur on some iOS versions, leaving an empty grey
        // circle. Sibling layout instead.
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // Container itself owns the shadow so the blur view's
        // cornerRadius+masksToBounds doesn't clip it.
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.3
        container.layer.shadowRadius = 12
        container.layer.shadowOffset = CGSize(width: 0, height: 4)

        let bg = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.isUserInteractionEnabled = false
        bg.layer.cornerRadius = 22
        bg.layer.masksToBounds = true
        bg.layer.borderWidth = 0.5
        bg.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        let glyph = UIImage(systemName: "ellipsis", withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        button.setImage(glyph, for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.adjustsImageWhenHighlighted = false
        button.accessibilityLabel = String(localized: "More")
        button.backgroundColor = .clear
        button.menu = makeMenu()
        button.showsMenuAsPrimaryAction = true

        container.addSubview(bg)
        container.addSubview(button)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 44),
            container.heightAnchor.constraint(equalToConstant: 44),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            bg.topAnchor.constraint(equalTo: container.topAnchor),
            bg.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    private func makeMenu() -> UIMenu {
        let reload = UIAction(title: String(localized: "Reload"),
                              image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.reload()
        }
        let share = UIAction(title: String(localized: "Share"),
                             image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.share()
        }
        let close = UIAction(title: String(localized: "Close"),
                             image: UIImage(systemName: "xmark"),
                             attributes: .destructive) { [weak self] _ in
            self?.dismiss(animated: true)
        }
        return UIMenu(children: [reload, share, close])
    }

    private func reload() {
        // Nothing has loaded until the sandbox is ready; the first load follows.
        guard scriptsAllowed != nil else { return }
        // Local file — re-grant read access via loadFileURL so the
        // in-place reload survives resource regeneration. Web URLs
        // (theoretically reachable here if a future entry point lets
        // them in) get plain reload().
        if resolved.htmlURL.isFileURL {
            webView.loadFileURL(resolved.htmlURL,
                                allowingReadAccessTo: resolved.readAccessRoot)
        } else {
            webView.reload()
        }
    }

    private func share() {
        let sheet = UIActivityViewController(activityItems: [resolved.htmlURL],
                                             applicationActivities: nil)
        // iPad popover anchor
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.maxX - 40,
                                    y: view.bounds.maxY - 40,
                                    width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @MainActor @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // JavaScript only with the no-network rules installed.
        preferences.allowsContentJavaScript = scriptsAllowed == true
        switch LocalHTMLSandbox.decide(navigationAction,
                                       readAccessRoot: resolved.readAccessRoot,
                                       userTappedRecently: tapTracker.tappedRecently,
                                       tappedLink: tapTracker.tappedLink) {
        case .allow:
            decisionHandler(.allow, preferences)
        case .cancel:
            if let url = navigationAction.request.url, url.isFileURL {
                webAppWebLogger.warning("blocking file:// nav outside the HTML folder target=\(url.lastPathComponent)")
            }
            decisionHandler(.cancel, preferences)
        case .openExternally(let url):
            decisionHandler(.cancel, preferences)
            LocalHTMLSandbox.openExternally(url)
        }
    }

    /// Directory-boundary containment: `…/session1` must not admit
    /// `…/session10/…`, which a bare `hasPrefix(root)` did.
    nonisolated static func isInside(root: String, target: String) -> Bool {
        if target == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(prefix)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webAppWebLogger.error("didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webAppWebLogger.error("didFailProvisional: \(error.localizedDescription)")
    }

    // MARK: - WKUIDelegate

    /// The WebApp stays single-frame: window.open / target="_blank" never
    /// get a new web view. A target="_blank" web link the user tapped opens
    /// in Safari like any other tapped link; script-opened windows are dropped.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if case .openExternally(let url) = LocalHTMLSandbox.decide(
            navigationAction,
            readAccessRoot: resolved.readAccessRoot,
            userTappedRecently: tapTracker.tappedRecently,
            tappedLink: tapTracker.tappedLink
        ) {
            LocalHTMLSandbox.openExternally(url)
        }
        return nil
    }
}

// MARK: - SwiftUI Bridge

/// SwiftUI wrapper presented full-screen. Hosts the WebView VC inside a
/// plain (no-nav) navigation container so the immersive look is preserved
/// regardless of how the surrounding app chrome is configured.
struct WebAppWebViewScreen: UIViewControllerRepresentable {
    let shortcut: WebAppShortcut
    let resolved: WebAppPathResolver.Resolved

    func makeUIViewController(context: Context) -> WebAppWebViewController {
        WebAppWebViewController(shortcut: shortcut, resolved: resolved)
    }

    func updateUIViewController(_ uiViewController: WebAppWebViewController, context: Context) {
        // No-op — the controller manages its own state.
    }
}
