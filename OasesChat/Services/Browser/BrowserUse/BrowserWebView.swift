import SwiftUI
import WebKit

/// UIViewRepresentable wrapper that displays a `BrowserUseManager`'s WKWebView.
///
/// The manager may swap in a rebuilt WKWebView (UA / viewport change), so the
/// representable hosts it inside a container and re-parents the current
/// instance on every update instead of pinning the one it was created with.
struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var manager: BrowserUseManager

    func makeUIView(context: Context) -> BrowserWebViewContainer {
        let container = BrowserWebViewContainer()
        container.host(manager.webView)
        return container
    }

    func updateUIView(_ container: BrowserWebViewContainer, context: Context) {
        container.host(manager.webView)
    }
}

final class BrowserWebViewContainer: UIView {
    private weak var hosted: WKWebView?

    func host(_ webView: WKWebView) {
        guard hosted !== webView || webView.superview !== self else { return }
        if hosted !== webView { hosted?.removeFromSuperview() }
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
        hosted = webView
    }
}
