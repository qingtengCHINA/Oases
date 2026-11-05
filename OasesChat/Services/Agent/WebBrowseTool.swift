import Foundation
@preconcurrency import WebKit

/// Agent-controlled browser for project/chat tools.
///
/// This is intentionally stateful: sessions reuse `WKWebsiteDataStore.default()`
/// so cookies, localStorage, and normal WebKit website data persist like a real
/// in-app browser. If a page cannot finish in WebKit, URL reads fall back to
/// Agent Reach's Jina Reader pattern instead of forcing the model into iSH curl
/// retries.
final class WebBrowseTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "web_browse",
        summary: """
        Drive the built-in persistent browser. Actions: open/read a URL, load an HTML snapshot, extract current page text and links, \
        click by CSS selector or visible text, type into inputs, go back/forward, set/import a cookie, inspect cookie names, or get status. \
        Browser sessions reuse WebKit's default persistent website data store, so cookies survive across calls. \
        When WebKit navigation fails or times out, URL reads automatically fall back to Agent Reach/Jina Reader.
        """,
        displayName: "浏览网页", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "浏览网页", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{"action":{"type":"string","enum":["open","read","load_html","extract","click","type","back","forward","status","cookies","set_cookie","clear_profile","clear_site_data"],"default":"open"},"session":{"type":"string","description":"Named browser profile/session id. Defaults to project."},"url":{"type":"string","description":"Fully qualified URL for open/read."},"html":{"type":"string","description":"HTML document string for load_html."},"baseURL":{"type":"string","description":"Optional base URL used by load_html for relative links/cookies."},"selector":{"type":"string","description":"CSS selector for extraction or typing."},"target":{"type":"string","description":"CSS selector or visible link/button text for click."},"text":{"type":"string","description":"Text to type into selector."},"submit":{"type":"boolean","description":"Submit the closest form after typing.","default":false},"timeout":{"type":"number","description":"Navigation timeout seconds.","default":35},"name":{"type":"string","description":"Cookie name for set_cookie."},"value":{"type":"string","description":"Cookie value for set_cookie. Values are stored but never printed by cookies."},"domain":{"type":"string","description":"Cookie domain for set_cookie. Defaults to current page host when available."},"path":{"type":"string","description":"Cookie path for set_cookie.","default":"/"},"expiresDays":{"type":"number","description":"Optional cookie expiry in days from now."}}}
        """,
        // The persistent WebKit browser belongs to Ogent; text chat reads a
        // page with the light `web_read` instead.
        surfaces: [.project],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "open").trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = ((args["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let text = try await AgentBrowserController.shared.perform(args: args, onProgress: onProgress)
            let truncated = text.count > 30_000
            return ToolResult(text: truncated ? String(text.prefix(30_000)) : text, truncated: truncated)
        } catch let error as BrowserApprovalError {
            // A user decision is not a transport failure. Do not fall back to
            // a server-side reader after the user explicitly cancelled or
            // when the app has no foreground approval surface.
            throw error
        } catch {
            let webKitError = error
            guard ["open", "read"].contains(action),
                  let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw webKitError
            }
            onProgress("[browser] WebKit failed: \(webKitError.localizedDescription). Trying Agent Reach reader fallback.\n")
            do {
                let fallback = try await Self.readerFallback(url: url)
                let truncated = fallback.count > 30_000
                return ToolResult(text: truncated ? String(fallback.prefix(30_000)) : fallback, truncated: truncated)
            } catch {
                let fallbackError = error
                return .textOnly("""
                ## Browser Read Unavailable

                URL: \(url.absoluteString)
                WebKit error: \(webKitError.localizedDescription)
                Reader fallback error: \(fallbackError.localizedDescription)

                The browser session and cookies remain available. Continue with another URL, a narrower selector, `web_search`, or a cached/extracted page result already in the conversation. Do not stop the full task only because this page read failed.
                """)
            }
        }
    }

    private static func readerFallback(url: URL) async throws -> String {
        try await AgentReachWebBridge.read(url: url)
    }

    static let agentUserAgent = AgentReachWebBridge.userAgent
}

/// Text chat's page reader: fetches one page the user pointed at as plain
/// text over HTTPS. No WebKit session, cookies or Linux runtime — those are
/// Ogent's `web_browse`.
final class WebReadTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "web_read",
        // i18n-ignore: model-facing tool description
        summary: "Read the text of one web page. Use only when the user gives a link, or when a search result's snippet is not enough to answer. Do not use it to search; use web_search for that.",
        displayName: "读取网页", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "读取网页", comment: "Tool name on tool cards: read one web page"),
        inputSchemaJSON: """
        {"type":"object","required":["url"],"properties":{"url":{"type":"string","description":"Full http(s) address of the page."}}}
        """,
        surfaces: [.chat],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let raw = ((args["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .textOnly("web_read requires a full http(s) url.") // i18n-ignore: tool result the model reads
        }
        onProgress("[web_read] \(url.absoluteString)\n")
        do {
            let text = try await AgentReachWebBridge.read(url: url, timeout: 25)
            return .textOnly(text.count > 12_000 ? String(text.prefix(12_000)) : text, truncated: text.count > 12_000)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // i18n-ignore: tool result the model reads
            return .textOnly("""
            ## Page Unavailable
            URL: \(url.absoluteString)
            error=\(error.localizedDescription)

            The page could not be read. Answer from what you have, or say that the page could not be opened.
            """)
        }
    }
}

@MainActor
final class AgentBrowserController {
    static let shared = AgentBrowserController()

    private var sessions: [String: BrowserSession] = [:]

    func perform(
        args: [String: Any],
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let action = ((args["action"] as? String) ?? "open").trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSession((args["session"] as? String) ?? "project")
        let session = browserSession(id: sessionID)
        let timeout = max(5, min((args["timeout"] as? NSNumber)?.doubleValue ?? 35, 180))

        switch action {
        case "open", "read":
            guard let raw = args["url"] as? String,
                  let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return "web_browse open/read requires a valid http/https url."
            }
            try AgentBrowserService.shared.validateNavigation(url: url)
            onProgress("[browser:\(sessionID)] open \(url.absoluteString)\n")
            try await open(url: url, in: session, timeout: timeout)
            return try await extract(from: session, selector: (args["selector"] as? String) ?? "body", sessionID: sessionID)

        case "load_html":
            let html = (args["html"] as? String) ?? ""
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "web_browse load_html requires html."
            }
            let rawBaseURL = ((args["baseURL"] as? String) ?? "https://ogent.local/")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = URL(string: rawBaseURL.isEmpty ? "https://ogent.local/" : rawBaseURL)
                ?? URL(string: "https://ogent.local/")
            if let baseURL { try AgentBrowserService.shared.validateNavigation(url: baseURL) }
            onProgress("[browser:\(sessionID)] load_html base=\(baseURL?.absoluteString ?? "none")\n")
            try await loadHTML(html, baseURL: baseURL, in: session, timeout: timeout)
            return try await extract(from: session, selector: (args["selector"] as? String) ?? "body", sessionID: sessionID)

        case "extract":
            return try await extract(from: session, selector: (args["selector"] as? String) ?? "body", sessionID: sessionID)

        case "click":
            let target = ((args["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return "web_browse click requires target." }
            onProgress("[browser:\(sessionID)] click \(target)\n")
            let clicked = try await click(target: target, in: session)
            try await settle()
            let snapshot = try await extract(from: session, selector: "body", sessionID: sessionID)
            return clicked ? snapshot : "[browser] click target not found: \(target)\n\n\(snapshot)"

        case "type":
            let selector = ((args["selector"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (args["text"] as? String) ?? ""
            let submit = (args["submit"] as? Bool) ?? false
            guard !selector.isEmpty else { return "web_browse type requires selector." }
            onProgress("[browser:\(sessionID)] type into \(selector)\n")
            let ok = try await type(text: text, selector: selector, submit: submit, in: session)
            try await settle()
            let snapshot = try await extract(from: session, selector: "body", sessionID: sessionID)
            return ok ? snapshot : "[browser] input selector not found: \(selector)\n\n\(snapshot)"

        case "back":
            if session.webView.canGoBack {
                onProgress("[browser:\(sessionID)] back\n")
                session.webView.goBack()
                try await settle()
            }
            return try await extract(from: session, selector: "body", sessionID: sessionID)

        case "forward":
            if session.webView.canGoForward {
                onProgress("[browser:\(sessionID)] forward\n")
                session.webView.goForward()
                try await settle()
            }
            return try await extract(from: session, selector: "body", sessionID: sessionID)

        case "cookies":
            return await cookiesSummary(sessionID: sessionID, currentURL: session.webView.url)

        case "set_cookie":
            return await setCookie(args: args, sessionID: sessionID, currentURL: session.webView.url)

        case "clear_profile":
            return await clearProfile(sessionID: sessionID, dataStore: session.dataStore)

        case "clear_site_data":
            return await clearSiteData(args: args, sessionID: sessionID, dataStore: session.dataStore, currentURL: session.webView.url)

        case "status":
            return try await status(sessionID: sessionID, session: session)

        default:
            return "Unknown web_browse action: \(action)"
        }
    }

    private func browserSession(id: String) -> BrowserSession {
        if let existing = sessions[id] { return existing }

        let config = WKWebViewConfiguration()
        let profile = AgentBrowserService.shared.profile(for: id)
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.storageIdentifier)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = WebBrowseTool.agentUserAgent
        let delegate = AgentBrowserNavigationDelegate()
        webView.navigationDelegate = delegate
        let created = BrowserSession(id: id, webView: webView, delegate: delegate, dataStore: config.websiteDataStore, createdAt: Date())
        sessions[id] = created
        return created
    }

    private func open(url: URL, in session: BrowserSession, timeout: TimeInterval) async throws {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        async let wait: Void = session.delegate.waitForLoad(timeout: timeout)
        session.webView.load(request)
        try await wait
        try await settle(milliseconds: 700)
    }

    private func loadHTML(_ html: String, baseURL: URL?, in session: BrowserSession, timeout: TimeInterval) async throws {
        async let wait: Void = session.delegate.waitForLoad(timeout: timeout)
        session.webView.loadHTMLString(html, baseURL: baseURL)
        try await wait
        try await settle(milliseconds: 300)
    }

    func webView(for sessionID: String) -> WKWebView? {
        sessions[normalizedSession(sessionID)]?.webView
    }

    private func extract(
        from session: BrowserSession,
        selector: String,
        sessionID: String,
        requestApproval: Bool = true
    ) async throws -> String {
        let payload = try await evaluateJSON(script: extractionScript(selector: selector), in: session)
        let title = payload["title"] as? String ?? ""
        let url = payload["url"] as? String ?? session.webView.url?.absoluteString ?? ""
        let text = payload["text"] as? String ?? ""
        let links = payload["links"] as? [[String: Any]] ?? []
        let controls = payload["controls"] as? [[String: Any]] ?? []

        let snapshotLinks = links.compactMap { item -> [String: String]? in
            guard let href = item["href"] as? String, !href.isEmpty else { return nil }
            return ["text": (item["text"] as? String ?? ""), "href": href]
        }
        let snapshotForms = controls.compactMap { item -> [String: String]? in
            guard let selector = item["selector"] as? String, !selector.isEmpty else { return nil }
            return [
                "tag": item["tag"] as? String ?? "control",
                "selector": selector,
                "label": item["label"] as? String ?? ""
            ]
        }
        let snapshot = AgentBrowserService.shared.snapshot(
            url: url,
            title: title,
            text: text,
            links: snapshotLinks,
            forms: snapshotForms,
            strategy: .webKit
        )

        var out = """
        ## \(title.isEmpty ? "Untitled page" : title)

        session=\(sessionID)
        URL: \(url)
        \(snapshot.stableMetadataLine)

        \(text)
        """

        if let challenge = snapshot.challenge {
            out += "\n\nchallenge=\(challenge.rawValue) approval_required=1\nDo not retry this action in the background; ask the user to continue in the visible browser."
            if requestApproval {
                let request = BrowserApprovalRequest(
                    runID: AgentToolInvocationContext.current?.runID,
                    callID: AgentToolInvocationContext.current?.callID,
                    sessionID: sessionID,
                    challenge: challenge,
                    url: url,
                    title: title
                )
                let approved = try await BrowserApprovalCenter.shared.waitForApproval(request)
                guard approved else {
                    throw BrowserApprovalError.cancelled
                }
                // The user may have completed a login/CAPTCHA/payment step
                // inside the visible WebView. Re-read the same DOM after the
                // approval without presenting the same challenge twice.
                return try await extract(
                    from: session,
                    selector: selector,
                    sessionID: sessionID,
                    requestApproval: false
                )
            }
        }

        if !links.isEmpty {
            out += "\n\n### Links\n"
            for item in links.prefix(80) {
                let label = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let href = item["href"] as? String ?? ""
                if !href.isEmpty {
                    out += "- \(label.isEmpty ? href : label): \(href)\n"
                }
            }
        }

        if !controls.isEmpty {
            out += "\n### Controls\n"
            for item in controls.prefix(30) {
                let tag = item["tag"] as? String ?? "control"
                let selector = item["selector"] as? String ?? ""
                let label = item["label"] as? String ?? ""
                out += "- \(tag) \(selector) \(label)\n"
            }
        }

        return out
    }

    private func click(target: String, in session: BrowserSession) async throws -> Bool {
        let targetJSON = jsonLiteral(target)
        let script = """
        (function() {
          const target = \(targetJSON);
          function visibleText(el) { return ((el.innerText || el.textContent || el.value || el.getAttribute('aria-label') || '') + '').trim(); }
          let el = null;
          try { el = document.querySelector(target); } catch (e) {}
          if (!el) {
            const all = Array.from(document.querySelectorAll('a,button,[role=button],input[type=submit],input[type=button]'));
            el = all.find(x => visibleText(x).toLowerCase().includes(target.toLowerCase()));
          }
          if (!el) return JSON.stringify({ok:false});
          el.scrollIntoView({block:'center', inline:'center'});
          el.click();
          return JSON.stringify({ok:true});
        })();
        """
        let payload = try await evaluateJSON(script: script, in: session)
        return (payload["ok"] as? Bool) == true
    }

    private func type(text: String, selector: String, submit: Bool, in session: BrowserSession) async throws -> Bool {
        let textJSON = jsonLiteral(text)
        let selectorJSON = jsonLiteral(selector)
        let submitLiteral = submit ? "true" : "false"
        let script = """
        (function() {
          let el = null;
          try { el = document.querySelector(\(selectorJSON)); } catch (e) {}
          if (!el) return JSON.stringify({ok:false});
          el.focus();
          el.value = \(textJSON);
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          if (\(submitLiteral)) {
            const form = el.closest('form');
            if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
          }
          return JSON.stringify({ok:true});
        })();
        """
        let payload = try await evaluateJSON(script: script, in: session)
        return (payload["ok"] as? Bool) == true
    }

    private func status(sessionID: String, session: BrowserSession) async throws -> String {
        let payload = try await evaluateJSON(script: """
        JSON.stringify({title: document.title || '', url: location.href, readyState: document.readyState});
        """, in: session)
        return """
        Browser session
        session=\(sessionID)
        title=\(payload["title"] as? String ?? "")
        url=\(payload["url"] as? String ?? session.webView.url?.absoluteString ?? "")
        readyState=\(payload["readyState"] as? String ?? "unknown")
        canGoBack=\(session.webView.canGoBack)
        canGoForward=\(session.webView.canGoForward)
        createdAt=\(session.createdAt)
        cookieStore=profile:\(AgentBrowserService.shared.profile(for: sessionID).id)
        """
    }

    private func cookiesSummary(sessionID: String, currentURL: URL?) async -> String {
        let cookies = await withCheckedContinuation { continuation in
            sessionDataStore(sessionID: sessionID).httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let host = currentURL?.host
        let filtered = host == nil ? cookies : cookies.filter { cookie in
            host?.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true
        }
        var lines = [
            "Browser cookies",
            "session=\(sessionID)",
            "currentHost=\(host ?? "none")",
            "count=\(filtered.count)",
            "values=hidden"
        ]
        for cookie in filtered.prefix(80) {
            lines.append("- \(cookie.name) domain=\(cookie.domain) path=\(cookie.path) expires=\(cookie.expiresDate?.description ?? "session")")
        }
        return lines.joined(separator: "\n")
    }

    private func setCookie(args: [String: Any], sessionID: String, currentURL: URL?) async -> String {
        let name = ((args["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (args["value"] as? String) ?? ""
        let rawDomain = ((args["domain"] as? String) ?? currentURL?.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = rawDomain
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
        let path = ((args["path"] as? String) ?? "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !domain.isEmpty else {
            return "web_browse set_cookie requires name and domain, or an already-open page with a host."
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path
        ]
        if let expiresDays = args["expiresDays"] as? NSNumber {
            properties[.expires] = Date().addingTimeInterval(max(1, expiresDays.doubleValue) * 86_400)
        }
        guard let cookie = HTTPCookie(properties: properties) else {
            return "web_browse set_cookie could not create cookie for domain=\(domain)."
        }

        await withCheckedContinuation { continuation in
            sessionDataStore(sessionID: sessionID).httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
        let summary = await cookiesSummary(sessionID: sessionID, currentURL: currentURL)
        return """
        Cookie saved
        session=\(sessionID)
        name=\(name)
        domain=\(domain)
        value=hidden

        \(summary)
        """
    }

    private func sessionDataStore(sessionID: String) -> WKWebsiteDataStore {
        browserSession(id: sessionID).dataStore
    }

    private func clearProfile(sessionID: String, dataStore: WKWebsiteDataStore) async -> String {
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        return "Browser profile cleared\nsession=\(sessionID)\nwebsiteData=removed"
    }

    private func clearSiteData(args: [String: Any], sessionID: String, dataStore: WKWebsiteDataStore, currentURL: URL?) async -> String {
        let requestedHost = ((args["domain"] as? String) ?? currentURL?.host ?? "")
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !requestedHost.isEmpty else { return "web_browse clear_site_data requires domain or an open page." }
        let cookies = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where requestedHost.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()) {
            await withCheckedContinuation { continuation in
                dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
        let removedCount = cookies.filter {
            requestedHost.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased())
        }.count
        return "Browser site data cleared\nsession=\(sessionID)\nhost=\(requestedHost)\ncookiesRemoved=\(removedCount)"
    }

    private func evaluateJSON(script: String, in session: BrowserSession) async throws -> [String: Any] {
        let raw = try await session.webView.evaluateJavaScript(script)
        let json = (raw as? String) ?? ""
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private func extractionScript(selector: String) -> String {
        let selectorJSON = jsonLiteral(selector)
        return """
        (function() {
          const selector = \(selectorJSON);
          let root = document.body;
          try { root = document.querySelector(selector) || document.body; } catch (e) {}
          const clone = root ? root.cloneNode(true) : document.body.cloneNode(true);
          clone.querySelectorAll('script,style,noscript,svg,canvas,iframe').forEach(el => el.remove());
          let text = (clone.innerText || clone.textContent || '').replace(/[\\u00a0\\t ]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim();
          const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 100).map(a => ({
            text: ((a.innerText || a.textContent || a.getAttribute('aria-label') || '') + '').replace(/\\s+/g, ' ').trim().slice(0, 160),
            href: a.href
          }));
          function cssPath(el) {
            if (!el) return '';
            if (el.id) return '#' + CSS.escape(el.id);
            let name = el.tagName.toLowerCase();
            if (el.getAttribute('name')) return name + '[name="' + el.getAttribute('name').replace(/"/g, '\\\\"') + '"]';
            if (el.getAttribute('aria-label')) return name + '[aria-label="' + el.getAttribute('aria-label').replace(/"/g, '\\\\"') + '"]';
            return name;
          }
          const controls = Array.from(document.querySelectorAll('input,textarea,select,button,[role=button]')).slice(0, 40).map(el => ({
            tag: el.tagName.toLowerCase(),
            selector: cssPath(el),
            label: ((el.getAttribute('aria-label') || el.placeholder || el.value || el.innerText || '') + '').replace(/\\s+/g, ' ').trim().slice(0, 120)
          }));
          return JSON.stringify({title: document.title || '', url: location.href, text, links, controls});
        })();
        """
    }

    private func jsonLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let raw = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(raw.dropFirst().dropLast())
    }

    private func normalizedSession(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "project" : String(clean.prefix(64))
    }

    private func settle(milliseconds: UInt64 = 1_200) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

@MainActor
private final class BrowserSession {
    let id: String
    let webView: WKWebView
    let delegate: AgentBrowserNavigationDelegate
    let dataStore: WKWebsiteDataStore
    let createdAt: Date

    init(id: String, webView: WKWebView, delegate: AgentBrowserNavigationDelegate, dataStore: WKWebsiteDataStore, createdAt: Date) {
        self.id = id
        self.webView = webView
        self.delegate = delegate
        self.dataStore = dataStore
        self.createdAt = createdAt
    }
}

@MainActor
private final class AgentBrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    func waitForLoad(timeout: TimeInterval) async throws {
        didFinish = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            self.timeoutTask?.cancel()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    guard let self, !self.didFinish else { return }
                    self.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        resume(throwing: error)
    }

    private func resume() {
        timeoutTask?.cancel()
        continuation?.resume()
        continuation = nil
    }

    private func resume(throwing error: Error) {
        timeoutTask?.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
