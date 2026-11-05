import Foundation

/// Web search through the Oases gateway (`POST /v1/search/{provider}`).
///
/// The search providers' own keys live on the gateway; the app spends its
/// Oases key, and the gateway normalizes every provider into one result
/// shape. This is plain HTTPS from the app: no WebKit, no Linux runtime.
enum OasesWebSearch {
    struct Result: Decodable, Sendable, Equatable {
        let position: Int?
        let title: String?
        let url: String
        let snippet: String?
        let publishedAt: String?

        enum CodingKeys: String, CodingKey {
            case position, title, url, snippet
            case publishedAt = "published_at"
        }
    }

    struct Response: Decodable, Sendable {
        let provider: String?
        let query: String?
        let results: [Result]
    }

    enum SearchError: LocalizedError {
        case allProvidersFailed(String)

        var errorDescription: String? {
            switch self {
            case .allProvidersFailed(let detail):
                return "search_failed \(detail)" // i18n-ignore: tool diagnostic the model reads
            }
        }
    }

    /// The two providers turned on for this app's key on the gateway. Each
    /// search starts with one of them at random (spreads the daily quota) and
    /// falls over to the other.
    static let providers = ["brave", "exa"]
    static let freshnessValues: Set<String> = ["day", "week", "month", "year"]

    /// The gateway times out providers at 20 s; the docs ask clients for 35 s.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config)
        AIRequestGate.registerSession(session)
        return session
    }()

    /// Search with fail-over: a random one of Brave / Exa first, then the
    /// other; an empty answer moves on too.
    static func search(
        query: String,
        maxResults: Int = 5,
        freshness: String? = nil,
        language: String? = nil
    ) async throws -> Response {
        let order = providers.shuffled()

        var body: [String: Any] = [
            "query": String(query.prefix(500)),
            "max_results": max(1, min(maxResults, 10))
        ]
        if let freshness, freshnessValues.contains(freshness) { body["freshness"] = freshness }
        if let language, !language.isEmpty { body["language"] = language }
        let payload = try JSONSerialization.data(withJSONObject: body)

        let client = APIClient(session: session)
        var failures: [String] = []
        var emptyAnswer: Response?
        for provider in order {
            try Task.checkCancellation()
            do {
                let (data, _) = try await client.data(path: "search/\(provider)", body: payload)
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                if !decoded.results.isEmpty { return decoded }
                emptyAnswer = decoded
                failures.append("\(provider)=no_results")
            } catch let error as APIError {
                switch error {
                case .dataSharingConsentRequired:
                    throw error
                case .badStatus(let code, let snippet):
                    let body = snippet ?? ""
                    // The key itself can't search: another provider won't help.
                    if code == 401 { throw error }
                    if code == 403, !body.contains("provider_not_allowed") { throw error }
                    failures.append("\(provider)=HTTP \(code)")
                default:
                    failures.append("\(provider)=\(error.localizedDescription)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(provider)=\(error.localizedDescription)")
            }
        }
        if let emptyAnswer { return emptyAnswer }
        throw SearchError.allProvidersFailed(failures.joined(separator: "; "))
    }
}

// MARK: - Sources shown under a reply

/// A page the reply was grounded on, parsed back out of a search tool's
/// output so the chat can list it without storing a second copy.
struct WebSource: Identifiable, Equatable, Sendable {
    let title: String
    let url: URL

    var id: String { url.absoluteString }

    var host: String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Reads `n. Title` / `   URL: https://…` pairs, the shape both search
    /// paths render (see `WebSearchTool.renderSearchResults`).
    static func parse(searchOutput output: String) -> [WebSource] {
        var sources: [WebSource] = []
        var seen = Set<String>()
        var pendingTitle: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("URL: ") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   seen.insert(url.absoluteString).inserted {
                    let title = pendingTitle ?? (url.host(percentEncoded: false) ?? value)
                    sources.append(WebSource(title: title, url: url))
                }
                pendingTitle = nil
            } else if let dot = line.firstIndex(of: "."), dot != line.startIndex,
                      line[line.startIndex..<dot].allSatisfy(\.isNumber),
                      line.index(after: dot) < line.endIndex {
                let title = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                pendingTitle = title.isEmpty ? nil : title
            }
        }
        return sources
    }
}
