import Foundation

final class AgentReachTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "agent_reach",
        summary: """
        Agent Reach bridge for web discovery. Use search for broad web search via no-key app-side search, \
        read_url for persistent-browser page extraction with a shared Agent Reach/Jina Reader fallback, and doctor to inspect available app-side channels.
        """,
        displayName: "Agent Reach",
        inputSchemaJSON: """
        {"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["search","read_url","doctor"]},"query":{"type":"string"},"url":{"type":"string"},"session":{"type":"string","description":"Persistent browser profile id. Defaults to project."},"limit":{"type":"integer","default":5}}}
        """,
        surfaces: [.project],
        requiresPermission: false
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "doctor").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "search":
            let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = max(1, min((args["limit"] as? Int) ?? 5, 10))
            guard !query.isEmpty else { return .textOnly("agent_reach search requires query.") }
            onProgress("[agent-reach] search \(query)\n")
            return await WebSearchTool.runSearch(
                query: query,
                limit: limit,
                readTopResult: false,
                onProgress: onProgress
            )
        case "read_url":
            guard let raw = args["url"] as? String,
                  let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .textOnly("agent_reach read_url requires url.")
            }
            let session = ((args["session"] as? String) ?? "project").trimmingCharacters(in: .whitespacesAndNewlines)
            onProgress("[agent-reach] read \(url.absoluteString) session=\(session.isEmpty ? "project" : session)\n")
            return try await Self.read(url: url, session: session.isEmpty ? "project" : session, onProgress: onProgress)
        default:
            return .textOnly("""
            Agent Reach bridge
            channels=web_search_duckduckgo_lite, jina_reader, web_browse_persistent_browser, svg_logo_fetcher, video_downloader
            cookies=web_browse uses WKWebsiteDataStore.default and keeps browser cookies locally
            unavailable_in_app=mcporter/exa/social CLIs unless installed inside iSH or exposed by MCP
            """)
        }
    }

    private static func read(
        url: URL,
        session: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        let browserPayload: [String: Any] = [
            "action": "read",
            "session": session,
            "url": url.absoluteString,
            "timeout": 35
        ]
        let browserData = try JSONSerialization.data(withJSONObject: browserPayload)
        let browserJSON = String(data: browserData, encoding: .utf8) ?? "{}"

        do {
            let result = try await WebBrowseTool().invoke(argumentsJSON: browserJSON, onProgress: onProgress)
            let browserText = result.text ?? ""
            if !browserText.contains("## Browser Read Unavailable") {
                let output = """
                ## Agent Reach Browser
                session=\(session)
                source=web_browse_persistent_browser

                \(browserText)
                """
                return ToolResult(text: output, truncated: result.truncated)
            }
            onProgress("[agent-reach] persistent browser unavailable; trying Jina Reader\n")
        } catch {
            if error is BrowserApprovalError {
                throw error
            }
            onProgress("[agent-reach] browser read failed: \(error.localizedDescription); trying Jina Reader\n")
        }

        do {
            let reader = try await AgentReachWebBridge.read(url: url)
            let truncated = reader.count > 30_000
            return ToolResult(text: truncated ? String(reader.prefix(30_000)) : reader, truncated: truncated)
        } catch {
            return .textOnly("""
            ## Agent Reach Unavailable
            action=read_url
            target=\(url.absoluteString)
            error=\(error.localizedDescription)

            This is a recoverable browser bridge failure, not a task failure. Continue with `web_browse`, `web_search`, or any already successful page extraction in the conversation, and still produce a final delivery.
            """)
        }
    }
}

final class SVGLogoFetcherTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "svg_logo_fetcher",
        summary: """
        Find and download SVG logos/icons for brands. Uses SVGLOGO for common Chinese brands and thesvg for global brands. \
        Saves SVG files to iOS Documents/Ogent Artifacts and returns an openable file marker.
        """,
        displayName: "SVG Logo",
        inputSchemaJSON: """
        {"type":"object","required":["query"],"properties":{"query":{"type":"string","description":"Brand/company/app name."},"variant":{"type":"string","description":"thesvg variant, e.g. default, mono, wordmark.","default":"default"},"download":{"type":"boolean","default":true}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = ((args["variant"] as? String) ?? "default").trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDownload = (args["download"] as? Bool) ?? true
        guard !query.isEmpty else { return .textOnly("svg_logo_fetcher requires query.") }

        if let domestic = Self.domesticLogo(query: query) {
            onProgress("[svg-logo] SVGLOGO \(domestic.category)/\(domestic.filename)\n")
            guard let url = Self.assetURL(
                base: "https://raw.githubusercontent.com/HeyHuazi/SVGLOGO/main/static/library",
                segments: [domestic.category, domestic.filename]
            ) else {
                return .textOnly("svg_logo_fetcher: invalid SVGLOGO path.")
            }
            if shouldDownload {
                let target = try await SkillBridgeFileStore.download(url: url, filename: domestic.filename)
                return .textOnly(Self.downloadSummary(title: query, source: "SVGLOGO", url: url, target: target))
            }
            return .textOnly("SVGLOGO candidate: \(url.absoluteString)")
        }

        onProgress("[svg-logo] thesvg search \(query)\n")
        var components = URLComponents(string: "https://thesvg.org/api/icons")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let searchURL = components.url else { return .textOnly("invalid search") }
        let (data, response) = try await URLSession.shared.data(from: searchURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = object["icons"] as? [[String: Any]],
              let first = icons.first,
              let slug = first["slug"] as? String else {
            return .textOnly("No SVG logo candidate found for \(query).")
        }

        let selectedVariant = variant.isEmpty ? "default" : variant
        let title = (first["title"] as? String) ?? slug
        guard let cdn = Self.assetURL(
            base: "https://cdn.jsdelivr.net/gh/glincker/thesvg@main/public/icons",
            segments: [slug, "\(selectedVariant).svg"]
        ) else {
            return .textOnly("svg_logo_fetcher: invalid slug or variant (\(slug) / \(selectedVariant)).")
        }
        if shouldDownload {
            let target = try await SkillBridgeFileStore.download(url: cdn, filename: "\(slug)-\(selectedVariant).svg")
            return .textOnly(Self.downloadSummary(title: title, source: "thesvg", url: cdn, target: target))
        }

        let names = icons.prefix(10).map { icon in
            "- \((icon["title"] as? String) ?? "?") slug=\((icon["slug"] as? String) ?? "?")"
        }.joined(separator: "\n")
        return .textOnly("SVG logo candidates:\n\(names)")
    }

    /// `base` followed by percent-encoded path segments, or nil when a
    /// segment could change the path (empty, `.`/`..`, or containing a
    /// separator). Slugs come from the thesvg API and variants from the
    /// model, so neither may steer the request elsewhere.
    static func assetURL(base: String, segments: [String]) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        var url = base
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..",
                  !segment.contains("/"), !segment.contains("\\"),
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            url += "/" + encoded
        }
        return URL(string: url)
    }

    private static func downloadSummary(title: String, source: String, url: URL, target: URL) -> String {
        """
        SVG logo downloaded
        title=\(title)
        source=\(source)
        remote=\(url.absoluteString)
        ios=\(target.path)
        [oases:open]\(target.path)
        """
    }

    private static func domesticLogo(query: String) -> (category: String, filename: String)? {
        let key = query.lowercased()
        let map: [(String, String, String)] = [
            // i18n-ignore: logo lookup keywords matched against the query
            ("微信", "social", "weiXin.svg"), ("wechat", "social", "weiXin.svg"),
            // i18n-ignore: logo lookup keywords matched against the query
            ("微博", "social", "weiBo.svg"), ("weibo", "social", "weiBo.svg"),
            // i18n-ignore: logo lookup keywords matched against the query
            ("抖音", "social", "douYin.svg"), ("douyin", "social", "douYin.svg"),
            // i18n-ignore: logo lookup keywords matched against the query
            ("bilibili", "social", "bilibili.svg"), ("哔哩", "social", "bilibili.svg"), ("b站", "social", "bilibili.svg"),
            // i18n-ignore: logo lookup keywords matched against the query
            ("支付宝", "pay", "alipay.svg"), ("alipay", "pay", "alipay.svg"),
            ("chatgpt", "aigc", "ChatGPT.svg"), ("claude", "aigc", "Claude.svg")
        ]
        return map.first { key.contains($0.0) }.map { ($0.1, $0.2) }
    }
}

final class VideoDownloaderTool: AgentTool, @unchecked Sendable {
    private let toolName: String
    private let label: String
    private let youtubeOnly: Bool

    init(youtubeOnly: Bool = false) {
        self.youtubeOnly = youtubeOnly
        self.toolName = youtubeOnly ? "youtube_downloader" : "video_downloader"
        self.label = youtubeOnly ? "YouTube Downloader" : "Video Downloader"
    }

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: toolName,
            summary: youtubeOnly
                ? "Download a YouTube video/audio inside iSH using yt-dlp, saving the result to Ogent artifacts and auto-exporting it to iOS Documents."
                : "Download a video/audio URL inside iSH using yt-dlp. Supports YouTube, Twitter/X, Bilibili, Douyin, Reddit, and most yt-dlp sites. Prefers single-file MP4 to avoid ffmpeg merge failures.",
            displayName: label,
            localizedDisplayName: youtubeOnly
                ? String(localized: "YouTube Downloader", comment: "Tool name on tool cards")
                : String(localized: "Video Downloader", comment: "Tool name on tool cards"),
            inputSchemaJSON: """
            {"type":"object","required":["url"],"properties":{"url":{"type":"string"},"filename":{"type":"string"},"quality":{"type":"string","enum":["best","1080p","720p","480p","360p","worst"],"default":"best"},"audioOnly":{"type":"boolean","default":false},"timeout":{"type":"number","default":1200}}}
            """,
            surfaces: [.project],
            requiresPermission: true
        )
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let rawURL = ((args["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return .textOnly("\(toolName) requires url.") }
        if youtubeOnly, !rawURL.localizedCaseInsensitiveContains("youtube.com"), !rawURL.localizedCaseInsensitiveContains("youtu.be") {
            return .textOnly("youtube_downloader only accepts YouTube URLs. Use video_downloader for other sites.")
        }

        let filename = ((args["filename"] as? String) ?? "video").trimmingCharacters(in: .whitespacesAndNewlines)
        let quality = ((args["quality"] as? String) ?? "best").trimmingCharacters(in: .whitespacesAndNewlines)
        let audioOnly = (args["audioOnly"] as? Bool) ?? false
        let timeout = max(120, min((args["timeout"] as? NSNumber)?.doubleValue ?? 1200, 3600))
        let script = Self.script(url: rawURL, filename: filename, quality: quality, audioOnly: audioOnly)
        return try await Self.runOgentScript(title: label, script: script, timeout: timeout, onProgress: onProgress)
    }

    private static func script(url: String, filename: String, quality: String, audioOnly: Bool) -> String {
        let safeBase = safeFilename(filename.isEmpty ? "video" : filename)
        // `format` needs no merging; `mergedFormat` (separate video + audio
        // streams, remuxed to mp4) is used when ffmpeg is available, which it
        // is in the bundled rootfs.
        let format: String
        let mergedFormat: String
        if audioOnly {
            format = "bestaudio/best"
            mergedFormat = format
        } else if quality == "worst" {
            format = "worst[ext=mp4]/worst"
            mergedFormat = format
        } else if ["1080p", "720p", "480p", "360p"].contains(quality) {
            let height = quality.replacingOccurrences(of: "p", with: "")
            format = "best[ext=mp4][height<=\(height)]/best[height<=\(height)]/best[ext=mp4]/best"
            mergedFormat = "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"
        } else {
            format = "best[ext=mp4]/best"
            mergedFormat = "bv*+ba/b"
        }

        return """
        set -eu
        : "${OGENT_ARTIFACTS:=/root/.ogent/artifacts}"
        : "${OGENT_ROOT:=/root/.ogent}"
        mkdir -p "$OGENT_ARTIFACTS" "$OGENT_ROOT/tmp"
        cd "$OGENT_ARTIFACTS"
        if ! command -v yt-dlp >/dev/null 2>&1; then
          echo "[video] installing yt-dlp"
          (ogent-need yt-dlp || python3 -m pip install --break-system-packages yt-dlp)
        fi
        echo "[video] yt-dlp $(yt-dlp --version 2>/dev/null || true)"
        if command -v ffmpeg >/dev/null 2>&1; then
          yt-dlp --no-playlist -f \(shellQuote(mergedFormat)) --merge-output-format mp4 -o \(shellQuote(safeBase + ".%(ext)s")) \(shellQuote(url))
        else
          yt-dlp --no-playlist -f \(shellQuote(format)) -o \(shellQuote(safeBase + ".%(ext)s")) \(shellQuote(url))
        fi
        echo "[video] artifacts:"
        ls -lh \(shellQuote(safeBase)).* 2>/dev/null || ls -lh
        """
    }

    fileprivate static func runOgentScript(
        title: String,
        script: String,
        timeout: Double,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        guard let ogent = ToolRegistry.shared.tool(named: "ogent_agent") else {
            return .textOnly("ogent_agent is not registered.")
        }
        let payload: [String: Any] = [
            "action": "run_script",
            "title": title,
            "script": script,
            "timeout": timeout
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return try await ogent.invoke(argumentsJSON: json, onProgress: onProgress)
    }
}

final class NanoPDFTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "nano_pdf",
        summary: """
        Edit a PDF with natural-language instructions using nano-pdf inside iSH when available. \
        Attempts installation via pip if nano-pdf is missing, then exports generated PDFs from Ogent artifacts.
        """,
        displayName: "nano-pdf",
        inputSchemaJSON: """
        {"type":"object","required":["pdfPath","instruction"],"properties":{"pdfPath":{"type":"string","description":"Guest path under /root/.ogent/workspace, /root/.ogent/artifacts, or an Ogent runtime path returned by artifact_list."},"page":{"type":"integer","default":1},"instruction":{"type":"string"},"timeout":{"type":"number","default":900}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let pdfPath = ((args["pdfPath"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = ((args["instruction"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let page = (args["page"] as? Int) ?? 1
        let timeout = max(120, min((args["timeout"] as? NSNumber)?.doubleValue ?? 900, 3600))
        guard pdfPath.hasPrefix("/root/.ogent/workspace/")
            || pdfPath.hasPrefix("/root/.ogent/artifacts/")
            || pdfPath.hasPrefix("/root/.minis/workspace/")
            || pdfPath.hasPrefix("/root/.minis/artifacts/") else {
            return .textOnly("nano_pdf pdfPath must be under the Ogent workspace or artifacts.")
        }
        guard !instruction.isEmpty else { return .textOnly("nano_pdf requires instruction.") }

        let script = """
        set -eu
        : "${OGENT_ARTIFACTS:=/root/.ogent/artifacts}"
        : "${OGENT_ROOT:=/root/.ogent}"
        pdf_path=\(shellQuote(pdfPath))
        case "$pdf_path" in
          /root/.minis/*) pdf_path="/root/.ogent/${pdf_path#/root/.minis/}" ;;
        esac
        mkdir -p "$OGENT_ARTIFACTS"
        if ! command -v nano-pdf >/dev/null 2>&1; then
          echo "[nano-pdf] installing nano-pdf"
          (python3 -m pip install --break-system-packages nano-pdf || pip3 install nano-pdf)
        fi
        before="$(find "$OGENT_ROOT" -type f -name '*.pdf' 2>/dev/null | sort || true)"
        nano-pdf edit "$pdf_path" \(page) \(shellQuote(instruction))
        echo "[nano-pdf] generated/updated PDFs:"
        find "$OGENT_ROOT" -type f -name '*.pdf' -mmin -10 2>/dev/null | sort | while read -r f; do
          case "$f" in
            "$OGENT_ARTIFACTS"/*) ;;
            *) cp "$f" "$OGENT_ARTIFACTS/$(basename "$f")" 2>/dev/null || true ;;
          esac
          ls -lh "$f"
        done
        """
        return try await VideoDownloaderTool.runOgentScript(title: "nano-pdf edit", script: script, timeout: timeout, onProgress: onProgress)
    }
}

private enum SkillBridgeFileStore {
    static func download(url: URL, filename: String) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue(WebBrowseTool.agentUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let directory = ISHRootfsManager.exportsURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = uniqueDestination(in: directory, filename: filename)
        try data.write(to: target, options: .atomic)
        return target
    }

    private static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = directory.appendingPathComponent(cleaned)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}

private func safeFilename(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let clean = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return clean.isEmpty ? "artifact" : String(clean.prefix(72))
}

private func shellQuote(_ raw: String) -> String {
    "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
