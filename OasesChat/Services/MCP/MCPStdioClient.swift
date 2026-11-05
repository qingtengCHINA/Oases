import Foundation
import Network

protocol MCPStdioTransport: Sendable {
    func start() async throws
    func write(_ data: Data) async throws
    func read() async throws -> Data?
    func stop() async
}

protocol MCPRequestingClient: Sendable {
    func start() async throws
    func stop() async
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPTransportResponse
    func notify(_ notification: MCPJSONRPCNotification) async throws
}

actor MCPStdioClient: MCPRequestingClient {
    let configuration: MCPConfiguration
    private let transport: any MCPStdioTransport
    private var framer: MCPMessageFramer
    private(set) var isRunning = false

    init(configuration: MCPConfiguration, transport: any MCPStdioTransport, framingMode: MCPMessageFramer.Mode = .auto) {
        self.configuration = configuration
        self.transport = transport
        self.framer = MCPMessageFramer(mode: framingMode)
    }

    func start() async throws {
        guard configuration.command?.isEmpty == false else { throw MCPConfigurationError.missingCommand }
        try await transport.start()
        isRunning = true
    }

    func stop() async {
        await transport.stop()
        isRunning = false
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPTransportResponse {
        guard let id = request.id else { throw MCPProtocolError.invalidRequestID }
        guard isRunning else { throw MCPStdioClientError.notRunning }
        try await transport.write(try MCPMessageFramer.encode(.request(request)))
        var notifications: [MCPJSONRPCNotification] = []
        while true {
            try Task.checkCancellation()
            guard let chunk = try await transport.read() else { throw MCPStdioClientError.eof }
            for message in try framer.append(chunk) {
                switch message {
                case .request(let notification) where notification.id == nil:
                    notifications.append(notification)
                case .response(let response) where response.id == id:
                    if let error = response.error { throw MCPProtocolError.responseError(error) }
                    return MCPTransportResponse(response: response, notifications: notifications, statusCode: 200, sessionID: nil)
                case .response:
                    // A late reply to an earlier cancelled/timed-out request;
                    // the session itself is fine, keep waiting for ours.
                    continue
                case .request(let serverRequest):
                    // Server→client request (ping, roots/list, sampling…).
                    // Answer it so the server doesn't block waiting on us.
                    try await transport.write(try MCPMessageFramer.encode(.response(.reply(to: serverRequest))))
                }
            }
        }
    }

    func notify(_ notification: MCPJSONRPCNotification) async throws {
        guard isRunning else { throw MCPStdioClientError.notRunning }
        try await transport.write(try MCPMessageFramer.encode(.request(notification)))
    }
}

extension MCPJSONRPCResponse {
    /// Reply for a server→client request: `ping` succeeds, everything else is
    /// "method not found" since this client advertises no capabilities.
    static func reply(to request: MCPJSONRPCRequest) -> MCPJSONRPCResponse {
        if request.method == "ping" {
            return MCPJSONRPCResponse(id: request.id, result: .object([:]))
        }
        return MCPJSONRPCResponse(
            id: request.id,
            error: MCPJSONRPCError(code: -32601, message: "Method not found: \(request.method)")
        )
    }
}

enum MCPStdioClientError: LocalizedError, Equatable, Sendable {
    case notRunning
    case eof

    var errorDescription: String? {
        switch self {
        case .notRunning: return "MCP STDIO client is not running."
        case .eof: return "MCP STDIO transport closed before the response arrived."
        }
    }
}

