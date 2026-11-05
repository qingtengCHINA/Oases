import Foundation
import QuartzCore
import UIKit
import UniformTypeIdentifiers
import WebKit

private let sandboxLogger = AppLogger(category: "LocalHTMLSandbox")

/// Shared sandbox for HTML that is loaded from a local file with JavaScript on:
/// the file browser's HTML preview and Home Screen WebApps.
///
/// That HTML is written by the agent or downloaded from the web, so it is
/// untrusted. Without these limits a page could `fetch()` other files it can
/// read and send them out as `<img src="https://…?d=…">` or a beacon.
///   - Read access: callers grant the HTML's own folder only (siblings and
///     subfolders), never the session root.
///   - No network: a content rule list blocks every http(s)/ws(s) load —
///     images, scripts, styles, fonts, fetch/XHR, beacons, WebSockets and
///     frames — so nothing the page reads can leave the device. Pages that use
///     sibling CSS/JS/images keep working; libraries, styles, fonts and images
///     from the public CDNs in `libraryCDNHosts` load too (those only).
///   - Navigation: a link the user taps to http(s) opens outside the app
///     (Safari). Script-driven navigations, form posts, redirects and other
///     schemes are cancelled, so a page cannot ship data out through the URL
///     of a navigation the user did not start.
///   - JavaScript only runs once the rule list is installed. If it ever fails
///     to compile, pages render with JavaScript off instead of unprotected.
@MainActor
enum LocalHTMLSandbox {
    /// Bump the suffix whenever the rules change so the stored copy is replaced.
    private static let ruleListIdentifier = "oases.local-html.no-network.v2"

    /// Public library CDNs a generated page may load scripts, styles, fonts and images from.
    /// Only those resource types: fetch/XHR, beacons and sockets to these hosts stay blocked,
    /// and a script URL to a CDN can carry data only to a host nobody can read logs from.
    static let libraryCDNHosts: [String] = [
        "cdn.jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com", "cdn.tailwindcss.com", "esm.sh",
        "code.jquery.com", "d3js.org", "fonts.googleapis.com", "fonts.gstatic.com",
        "cdn.bootcdn.net", "cdn.staticfile.org", "lib.baomitu.com",
    ]

    /// `url-filter` is a restricted regex without alternation, so each scheme
    /// family gets its own rule. No `resource-type` means every type, including
    /// the main document, fetch/XHR, pings and WebSockets. The CDN rules come
    /// after the blocks and lift them for library loads only.
    private static let ruleListJSON: String = {
        var rules: [String] = [
            #"{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}}"#,
            #"{"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}"#,
        ]
        for host in libraryCDNHosts {
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            rules.append(#"{"trigger": {"url-filter": "^https://"# + escaped
                + #"/", "resource-type": ["script", "style-sheet", "font", "image"]}, "action": {"type": "ignore-previous-rules"}}"#)
        }
        return "[" + rules.joined(separator: ",\n") + "]"
    }()

    private static var compiled: WKContentRuleList?
    private static var didFail = false
    private static var isCompiling = false
    private static var waiters: [@MainActor (WKContentRuleList?) -> Void] = []

    /// The no-network rule list, compiled once per launch. nil only if
    /// compilation failed; callers then keep JavaScript off.
    static func noNetworkRuleList(_ completion: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let compiled {
            completion(compiled)
            return
        }
        if didFail {
            completion(nil)
            return
        }
        waiters.append(completion)
        guard !isCompiling else { return }
        isCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: ruleListJSON
        ) { list, error in
            // WebKit calls back on the main thread.
            MainActor.assumeIsolated {
                isCompiling = false
                if let list {
                    compiled = list
                } else {
                    didFail = true
                    sandboxLogger.error("no-network rule list failed to compile: \(error?.localizedDescription ?? "unknown")")
                }
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter(list) }
            }
        }
    }

    /// Installs the rule list on `webView`, then calls `load` with whether
    /// JavaScript may run (true only with the rules in place).
    static func prepare(_ webView: WKWebView, then load: @escaping @MainActor (_ scriptsAllowed: Bool) -> Void) {
        noNetworkRuleList { [weak webView] list in
            guard let webView else { return }
            if let list {
                let controller = webView.configuration.userContentController
                controller.add(list)
                // STUN/TURN traffic from a peer connection bypasses content rules, and a
                // page could put what it read into an ICE server host name. Gone before
                // the page's first script runs, in every frame.
                controller.addUserScript(WKUserScript(
                    source: "try{delete window.RTCPeerConnection;delete window.webkitRTCPeerConnection;delete window.RTCDataChannel;Object.defineProperty(window,'RTCPeerConnection',{value:undefined,writable:false,configurable:false});}catch(e){}",
                    injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            load(list != nil)
        }
    }

    // MARK: - Navigation

    enum NavigationDecision: Equatable {
        case allow
        case cancel
        /// A user tap on an http(s) link: open it outside the app.
        case openExternally(URL)
    }

    /// Navigation policy for a locally loaded page whose read access is
    /// `readAccessRoot`. `allowsMinisScheme` is true when a scoped `minis://`
    /// handler is registered. `userTappedRecently` comes from `LocalHTMLTapTracker`.
    static func decide(_ action: WKNavigationAction,
                       readAccessRoot: URL,
                       userTappedRecently: Bool,
                       allowsMinisScheme: Bool = false,
                       tappedLink: String? = nil) -> NavigationDecision {
        guard let url = action.request.url else { return .cancel }
        switch url.scheme?.lowercased() ?? "" {
        case "about", "blob", "data":
            // about:blank / srcdoc frames and in-page generated content. WebKit
            // itself refuses top-level data: navigations.
            return .allow
        case "file":
            return isInside(readAccessRoot, url) ? .allow : .cancel
        case "minis":
            return allowsMinisScheme ? .allow : .cancel
        case "http", "https":
            // Only for the page itself (or a target=_blank link, which has no
            // target frame), only right after a real tap, and only to the link
            // that was under the finger: WebKit also reports a script's
            // `a.click()` as `.linkActivated`, and a tap anywhere on the page
            // must not turn a script-built URL (carrying whatever the page read)
            // into something Safari opens.
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            if action.navigationType == .linkActivated, isMainFrame, userTappedRecently,
               let tapped = tappedLink, tapped == url.absoluteString {
                return .openExternally(url)
            }
            sandboxLogger.info("blocked web navigation from a local page type=\(action.navigationType.rawValue) mainFrame=\(isMainFrame) tapped=\(userTappedRecently) matchesTappedLink=\(tappedLink == url.absoluteString)")
            return .cancel
        default:
            return .cancel
        }
    }

    static func openExternally(_ url: URL) {
        sandboxLogger.info("opening a tapped link outside the app host=\(url.host ?? "")")
        UIApplication.shared.open(url)
    }

    /// One normalisation for every containment check: lexical `..` collapse
    /// plus symlink resolution (which also folds `/private/var` into `/var`),
    /// applied the same way to both sides.
    nonisolated static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func isInside(_ root: URL, _ target: URL) -> Bool {
        WebAppWebViewController.isInside(root: normalized(root).path, target: normalized(target).path)
    }
}

// MARK: - Tap tracking

/// Remembers when the user last tapped the web view, so a link opened by a
/// script without any tap is not sent to Safari. Recognises alongside
/// WebKit's own gestures and never cancels or delays their touches.
@MainActor
final class LocalHTMLTapTracker: NSObject, UIGestureRecognizerDelegate {
    private var lastTap: CFTimeInterval = 0
    /// WebKit decides the navigation a few milliseconds after the tap ends.
    private static let window: CFTimeInterval = 1.0
    private weak var webView: WKWebView?
    /// The href of the link under the last tap, read in a content world the page's scripts
    /// cannot reach (so `closest`/`href` can't be overridden). nil when the tap hit no link.
    private(set) var lastTappedLink: String?

    var tappedRecently: Bool { CACurrentMediaTime() - lastTap < Self.window }

    /// The tapped link while the tap is recent, else nil.
    var tappedLink: String? { tappedRecently ? lastTappedLink : nil }

    private static let linkWorld = WKContentWorld.world(name: "oases.local-html.tap")

    /// The recognizer does not retain its target: keep the tracker alive as
    /// long as `view`.
    func install(on view: UIView) {
        webView = view as? WKWebView
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let now = CACurrentMediaTime()
        lastTap = now
        lastTappedLink = nil
        guard let webView else { return }
        // Window coordinates → page CSS pixels: the web view's scroll view maps the point.
        let inView = recognizer.location(in: webView)
        let scale = webView.scrollView.zoomScale
        let x = inView.x / max(scale, 0.01)
        let y = inView.y / max(scale, 0.01)
        let script = "(function(){var e=document.elementFromPoint(\(x),\(y));while(e&&e.nodeType===1){if(e.tagName==='A'&&e.hasAttribute('href')){return e.href;}e=e.parentElement;}return null;})()"
        webView.evaluateJavaScript(script, in: nil, in: Self.linkWorld) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.lastTap == now, case .success(let value) = result else { return }
                self.lastTappedLink = value as? String
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Scoped minis:// handler

/// `minis://` for a locally previewed page, limited to the page's read-access
/// folder. The shared `MinisURLSchemeHandler` resolves any session, skills,
/// memory and shared file, which would hand a previewed page everything the
/// folder grant was meant to withhold.
@MainActor
final class ScopedMinisSchemeHandler: NSObject, WKURLSchemeHandler {
    private let readAccessRoot: URL

    init(readAccessRoot: URL) {
        self.readAccessRoot = readAccessRoot
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = AIChatViewModel.resolveMinisURL(url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard LocalHTMLSandbox.isInside(readAccessRoot, fileURL) else {
            sandboxLogger.warning("minis:// outside the preview folder denied file=\(fileURL.lastPathComponent)")
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.cannotOpenFile))
            return
        }
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Served synchronously; nothing to cancel.
    }
}
