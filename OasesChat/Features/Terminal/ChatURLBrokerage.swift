import AVFoundation
import Foundation

private let logger = AppLogger(category: "AIChatVM")

// OpenMinis also declares `SpeechFinishedDelegate` in this file — it restarts
// silent-audio keep-alive after a TTS utterance ends. It has nothing to do
// with URL brokering (it just shares the file), and it needs
// `BackgroundKeepAliveManager`, which isn't ported. Omitted.

// MARK: - Oases URL Capture Broker

/// Shared broker for URLs captured from shell tool stdout via the OSC
/// OasesOpenURL marker (emitted by /usr/local/bin/oases-open). Both
/// `AIChatView` and `ToolLiveSheet` observe `pendingURL`; ToolLiveSheet
/// wins when presented (it's topmost), otherwise AIChatView wins. Whoever
/// handles it calls `consume()` which nils out `pendingURL` so the other
/// observer doesn't fire a second sheet.
@MainActor
final class OasesOpenURLBroker: ObservableObject {
    static let shared = OasesOpenURLBroker()
    @Published var pendingURL: URL?
    /// True while `ToolLiveSheet` is on-screen. When set, `AIChatView`
    /// skips auto-presenting *web* URLs so ToolLiveSheet can show the
    /// preview nested on top of itself instead. `oases://` resource
    /// previews are still dispatched by AIChatView because ToolLiveSheet
    /// cannot host image/markdown/QuickLook sheets.
    @Published var toolSheetVisible: Bool = false
    /// True while the full-screen interactive iSH terminal
    /// (`ISHTerminalView` under `.fullScreenCover`) is on-screen. AIChatView
    /// skips auto-presenting web URLs when this is set so its own
    /// `.sheet(item: $safariURL)` doesn't fight the fullScreenCover (which
    /// would dismiss the terminal before presenting). The terminal has its
    /// own `.sheet(item: $linkPreviewURL)` which takes responsibility.
    @Published var terminalVisible: Bool = false
    private init() {}

    func offer(_ url: URL) { pendingURL = url }
    func consume() { pendingURL = nil }

    /// Schemes that `oases-open` may emit and that the host knows how to
    /// route. `http`/`https`/`about` → WKWebView preview, `oases` → built-in
    /// file preview via `handleOasesURLTap`.
    nonisolated static func isSupportedScheme(_ scheme: String?) -> Bool {
        guard let s = scheme?.lowercased() else { return false }
        return s == "http" || s == "https" || s == "about" || s == "oases"
    }

    /// True for schemes that render as an in-chat WKWebView (safariURL /
    /// ToolLiveSheet.linkPreviewURL). `oases://` resources render as
    /// full-screen file previews instead and must be dispatched by
    /// AIChatView even when a tool sheet is on top.
    nonisolated static func isWebScheme(_ scheme: String?) -> Bool {
        guard let s = scheme?.lowercased() else { return false }
        return s == "http" || s == "https" || s == "about"
    }
}

// MARK: - Oases URL Marker Parser

/// Recognises the OSC 1337 `OasesOpenURL` escape sequence emitted by the
/// rootfs shim at `/usr/local/bin/oases-open` (see default_mount). The shim
/// replaces `xdg-open`, `sensible-browser`, etc. Whenever an in-sandbox
/// command tries to open a URL, it prints:
///
///     ESC ] 1337 ; OasesOpenURL = <url> BEL
///
/// which this parser strips from the displayed shell output and returns
/// as a list of URLs to present in the in-app WKWebView preview.
enum OasesURLMarker {
    /// ESC ] 1337 ; OasesOpenURL = ... BEL
    /// Also accepts ST (ESC \) as terminator for robustness.
    static let pattern = "\u{1B}\\]1337;OasesOpenURL=([^\u{07}\u{1B}]*)(?:\u{07}|\u{1B}\\\\)"

    /// Returns (cleaned text with markers removed, captured URL strings).
    static func extract(from text: String) -> (cleaned: String, urls: [String]) {
        guard text.contains("OasesOpenURL="),
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return (text, []) }

        var urls: [String] = []
        var cleaned = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                cleaned += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            if m.numberOfRanges >= 2 {
                let urlRange = m.range(at: 1)
                if urlRange.location != NSNotFound {
                    urls.append(ns.substring(with: urlRange))
                }
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            cleaned += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return (cleaned, urls)
    }
}
