import Foundation
import Network

struct MCPTransportResponse: Sendable, Equatable {
    let response: MCPJSONRPCResponse
    let notifications: [MCPJSONRPCNotification]
    let statusCode: Int
    let sessionID: String?
}

actor MCPHTTPClient: MCPRequestingClient {
    let configuration: MCPConfiguration
    private let session: URLSession
    private let secretStore: MCPSecretStore
    private(set) var sessionID: String?

    init(
        configuration: MCPConfiguration,
        session: URLSession = .shared,
        secretStore: MCPSecretStore = MCPSecretStore()
    ) {
        self.configuration = configuration
        self.session = session
        self.secretStore = secretStore
    }

    func start() async throws {
        guard configuration.url != nil else { throw MCPConfigurationError.invalidURL("") }
    }

    func stop() async {
        sessionID = nil
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPTransportResponse {
        let data = try JSONEncoder().encode(request)
        return try await execute(data: data, expectsResponse: true, expectedID: request.id)
    }

    func notify(_ notification: MCPJSONRPCNotification) async throws {
        let data = try JSONEncoder().encode(notification)
        _ = try await execute(data: data, expectsResponse: false, expectedID: nil)
    }

    private func execute(
        data: Data,
        expectsResponse: Bool,
        expectedID: MCPRequestID?
    ) async throws -> MCPTransportResponse {
        guard let url = configuration.url else { throw MCPConfigurationError.invalidURL("") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in try secretStore.resolve(configuration.environment) where Self.isHeaderKey(key) {
            request.setValue(value, forHTTPHeaderField: Self.headerName(for: key))
        }

        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await AIRequestGate.data(session, for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else { throw MCPHTTPClientError.invalidResponse }
        if let returnedSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = returnedSessionID
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw MCPHTTPClientError.unauthorized
            case 403: throw MCPHTTPClientError.forbidden
            default: throw MCPHTTPClientError.httpStatus(http.statusCode)
            }
        }
        guard expectsResponse else {
            return MCPTransportResponse(response: MCPJSONRPCResponse(id: nil), notifications: [], statusCode: http.statusCode, sessionID: sessionID)
        }
        let parsed = try Self.parse(body: body, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        let responses = parsed.compactMap(\.response)
        guard !responses.isEmpty else {
            throw MCPHTTPClientError.missingResponse
        }
        // An SSE stream may carry replies to other requests; only ours counts.
        guard let response = responses.first(where: { $0.id == expectedID }) else {
            throw MCPProtocolError.responseIDMismatch(expected: expectedID ?? .string("nil"), actual: responses.first?.id)
        }
        if let error = response.error { throw MCPProtocolError.responseError(error) }
        return MCPTransportResponse(response: response, notifications: parsed.compactMap { $0.notification }, statusCode: http.statusCode, sessionID: sessionID)
    }

    /// SSE vs plain JSON is decided by Content-Type only: a JSON body that
    /// merely contains "data:" (a data: URI, "metadata:" text…) is not SSE.
    static func isEventStream(contentType: String?) -> Bool {
        contentType?.lowercased().contains("text/event-stream") == true
    }

    private static func parse(body: Data, contentType: String?) throws -> [ParsedHTTPMessage] {
        if isEventStream(contentType: contentType) {
            let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            let eventBlocks = text.components(separatedBy: "\n\n")
            var messages: [ParsedHTTPMessage] = []
            for block in eventBlocks {
                let lines = block.split(whereSeparator: \.isNewline)
                let dataLines = lines.compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                guard !dataLines.isEmpty else { continue }
                messages.append(contentsOf: try parseJSON(Data(dataLines.joined(separator: "\n").utf8)))
            }
            guard !messages.isEmpty else { throw MCPHTTPClientError.malformedResponse }
            return messages
        }
        return try parseJSON(body)
    }

    private static func parseJSON(_ data: Data) throws -> [ParsedHTTPMessage] {
        do {
            let message = try JSONDecoder().decode(MCPJSONRPCMessage.self, from: data)
            switch message {
            case .request(let request):
                // Server→client requests (ping, roots/list…) can ride along in
                // the stream; this client has no capabilities to answer them
                // and the reply we need is already in the same body, so skip.
                guard request.id == nil else { return [] }
                return [.notification(request)]
            case .response(let response): return [.response(response)]
            }
        } catch let error as MCPHTTPClientError {
            throw error
        } catch let error as MCPProtocolError {
            throw error
        } catch {
            throw MCPHTTPClientError.malformedResponse
        }
    }

    private static func isHeaderKey(_ key: String) -> Bool {
        key.caseInsensitiveCompare("Authorization") == .orderedSame || key.uppercased().hasPrefix("HEADER_")
    }

    private static func headerName(for key: String) -> String {
        key.uppercased().hasPrefix("HEADER_")
            ? String(key.dropFirst("HEADER_".count)).replacingOccurrences(of: "_", with: "-")
            : key
    }
}

private enum ParsedHTTPMessage: Sendable {
    case response(MCPJSONRPCResponse)
    case notification(MCPJSONRPCNotification)

    var response: MCPJSONRPCResponse? { if case .response(let value) = self { return value }; return nil }
    var notification: MCPJSONRPCNotification? { if case .notification(let value) = self { return value }; return nil }
}

enum MCPHTTPClientError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case forbidden
    case httpStatus(Int)
    case malformedResponse
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "MCP HTTP response is not an HTTP response."
        case .unauthorized: return "MCP HTTP server rejected authentication."
        case .forbidden: return "MCP HTTP server rejected authorization."
        case .httpStatus(let status): return "MCP HTTP server returned status \(status)."
        case .malformedResponse: return "MCP HTTP response is malformed."
        case .missingResponse: return "MCP HTTP response did not contain a JSON-RPC response."
        }
    }
}
