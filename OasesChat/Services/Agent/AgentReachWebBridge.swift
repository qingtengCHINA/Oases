import Foundation

/// Shared network fallback for Agent Reach and the native browser.
///
/// WebKit remains the primary path for page reads because it owns cookies and
/// user approval. This reader is deliberately a fallback, so a page that
/// needs a login is never silently downgraded to a stateless request.
enum AgentReachWebBridge {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 OasesOgent/1.0"

    static func read(url: URL, timeout: TimeInterval = 45) async throws -> String {
        guard let readerURL = URL(string: "https://r.jina.ai/\(url.absoluteString)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: readerURL, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, text/markdown, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await AIRequestGate.data(URLSession.shared, for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return """
        ## Agent Reach Reader

        URL: \(url.absoluteString)
        source=https://r.jina.ai/
        strategy=agentReachReader

        \(body)
        """
    }
}
