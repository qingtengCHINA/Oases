import Foundation

struct MCPClientSessionInfo: Equatable, Sendable {
    let serverID: String
    let initialized: Bool
    let protocolVersion: String?
    let serverName: String?
    let serverVersion: String?
}

actor MCPClientManager {
    typealias StdioTransportFactory = @Sendable (MCPConfiguration) async throws -> any MCPStdioTransport

    private struct SessionState {
        var client: (any MCPRequestingClient)?
        var initialized = false
        var protocolVersion: String?
        var serverName: String?
        var serverVersion: String?
        var failureCount = 0
        var retryAfter: Date?
    }

    private var sessions: [String: SessionState] = [:]
    private let secretStore: MCPSecretStore
    private let urlSession: URLSession
    private let stdioFactory: StdioTransportFactory
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let baseBackoffNanoseconds: UInt64
    private let maximumBackoffNanoseconds: UInt64

    init(
        secretStore: MCPSecretStore = MCPSecretStore(),
        urlSession: URLSession = .shared,
        stdioFactory: @escaping StdioTransportFactory = { configuration in
            ISHMCPStdioTransport(configuration: configuration)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        baseBackoffNanoseconds: UInt64 = 100_000_000,
        maximumBackoffNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.secretStore = secretStore
        self.urlSession = urlSession
        self.stdioFactory = stdioFactory
        self.now = now
        self.sleep = sleep
        self.baseBackoffNanoseconds = baseBackoffNanoseconds
        self.maximumBackoffNanoseconds = maximumBackoffNanoseconds
    }

    func toolsList(server: MCPConfiguration) async throws -> MCPJSONValue {
        let response = try await call(server: server, method: "tools/list")
        return response.result ?? .object([:])
    }

    func toolsList(server: OasesMCPServerConfig) async throws -> MCPJSONValue {
        try await toolsList(server: MCPConfiguration(server: server))
    }

    func toolsCall(server: MCPConfiguration, toolName: String, arguments: MCPJSONValue = .object([:])) async throws -> MCPJSONValue {
        let params: MCPJSONValue = .object(["name": .string(toolName), "arguments": arguments])
        let response = try await call(server: server, method: "tools/call", params: params)
        return response.result ?? .null
    }

    func toolsCall(server: OasesMCPServerConfig, toolName: String, arguments: MCPJSONValue = .object([:])) async throws -> MCPJSONValue {
        try await toolsCall(server: MCPConfiguration(server: server), toolName: toolName, arguments: arguments)
    }

    func call(server: MCPConfiguration, method: String, params: MCPJSONValue? = nil) async throws -> MCPJSONRPCResponse {
        let client = try await client(for: server)
        do {
            try await ensureInitialized(server: server, client: client)
            let request = MCPJSONRPCRequest(id: nextRequestID(for: server.id), method: method, params: params)
            return try await client.send(request).response
        } catch {
            if Self.isTransportFailure(error) {
                await recordFailure(serverID: server.id, client: client)
            }
            throw error
        }
    }

    /// A JSON-RPC `error` reply (bad arguments, unknown tool…) or a caller
    /// cancellation means the session is still healthy, so it must not tear
    /// down the server process and trigger restart backoff. Everything else
    /// (EOF, framing, HTTP/transport errors) does.
    static func isTransportFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case MCPProtocolError.responseError = error { return false }
        return true
    }

    func restart(serverID: String) async {
        if let client = sessions[serverID]?.client { await client.stop() }
        sessions.removeValue(forKey: serverID)
    }

    func shutdown() async {
        for state in sessions.values { await state.client?.stop() }
        sessions.removeAll()
    }

    func cachedSessionCount() -> Int { sessions.count }

    func sessionInfo(serverID: String) -> MCPClientSessionInfo? {
        guard let state = sessions[serverID] else { return nil }
        return MCPClientSessionInfo(
            serverID: serverID,
            initialized: state.initialized,
            protocolVersion: state.protocolVersion,
            serverName: state.serverName,
            serverVersion: state.serverVersion
        )
    }

    private var requestCounter = 0

    private func nextRequestID(for _: String) -> MCPRequestID {
        requestCounter += 1
        return .integer(requestCounter)
    }

    private func client(for configuration: MCPConfiguration) async throws -> any MCPRequestingClient {
        if let client = sessions[configuration.id]?.client { return client }
        var state = sessions[configuration.id] ?? SessionState()
        if let retryAfter = state.retryAfter, retryAfter > now() {
            try await sleep(UInt64(retryAfter.timeIntervalSince(now()) * 1_000_000_000))
        }
        let client: any MCPRequestingClient
        switch configuration.transport {
        case .http:
            client = MCPHTTPClient(configuration: configuration, session: urlSession, secretStore: secretStore)
        case .stdio:
            let transport = try await stdioFactory(configuration)
            client = MCPStdioClient(configuration: configuration, transport: transport)
        }
        do {
            try await client.start()
        } catch {
            state.failureCount += 1
            state.retryAfter = now().addingTimeInterval(backoff(for: state.failureCount))
            sessions[configuration.id] = state
            throw error
        }
        state.client = client
        state.retryAfter = nil
        sessions[configuration.id] = state
        return client
    }

    private func ensureInitialized(server: MCPConfiguration, client: any MCPRequestingClient) async throws {
        guard sessions[server.id]?.initialized != true else { return }
        let params: MCPJSONValue = .object([
            "protocolVersion": .string(server.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(server.clientName),
                "version": .string(server.clientVersion)
            ])
        ])
        let response = try await client.send(MCPJSONRPCRequest(id: nextRequestID(for: server.id), method: "initialize", params: params))
        let negotiated = response.response.result?.objectValue?["protocolVersion"]?.stringValue ?? server.protocolVersion
        let serverInfo = response.response.result?.objectValue?["serverInfo"]?.objectValue
        try await client.notify(MCPJSONRPCNotification(method: "notifications/initialized"))
        sessions[server.id]?.initialized = true
        sessions[server.id]?.protocolVersion = negotiated
        sessions[server.id]?.serverName = serverInfo?["name"]?.stringValue
        sessions[server.id]?.serverVersion = serverInfo?["version"]?.stringValue
    }

    private func recordFailure(serverID: String, client: any MCPRequestingClient) async {
        await client.stop()
        var state = sessions[serverID] ?? SessionState()
        state.client = nil
        state.initialized = false
        state.failureCount += 1
        state.retryAfter = now().addingTimeInterval(backoff(for: state.failureCount))
        sessions[serverID] = state
    }

    private func backoff(for failureCount: Int) -> TimeInterval {
        let multiplier = min(max(failureCount - 1, 0), 6)
        let nanos = min(baseBackoffNanoseconds << UInt64(multiplier), maximumBackoffNanoseconds)
        return TimeInterval(nanos) / 1_000_000_000
    }
}

enum MCPManagerError: LocalizedError, Equatable, Sendable {
    case stdioTransportUnavailable

    var errorDescription: String? { "No STDIO transport was provided for MCP." }
}

private extension MCPJSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}
