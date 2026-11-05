import Foundation

// MARK: - JSON-RPC values

enum MCPJSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

enum MCPRequestID: Codable, Equatable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

struct MCPJSONRPCError: Codable, Equatable, Sendable {
    let code: Int
    let message: String
    let data: MCPJSONValue?

    init(code: Int, message: String, data: MCPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: MCPRequestID?
    let method: String
    let params: MCPJSONValue?

    init(id: MCPRequestID, method: String, params: MCPJSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    init(method: String, params: MCPJSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = nil
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        self.id = try container.decodeIfPresent(MCPRequestID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(MCPJSONValue.self, forKey: .params)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(method, forKey: .method)
        if let params { try container.encode(params, forKey: .params) }
    }
}

typealias MCPJSONRPCNotification = MCPJSONRPCRequest

struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: MCPRequestID?
    let result: MCPJSONValue?
    let error: MCPJSONRPCError?

    init(id: MCPRequestID?, result: MCPJSONValue? = nil, error: MCPJSONRPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    var isError: Bool { error != nil }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        self.id = try container.decodeIfPresent(MCPRequestID.self, forKey: .id)
        self.result = container.contains(.result) ? try container.decode(MCPJSONValue.self, forKey: .result) : nil
        self.error = container.contains(.error) ? try container.decode(MCPJSONRPCError.self, forKey: .error) : nil
        guard (result != nil) != (error != nil) else { throw MCPProtocolError.invalidMessage }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) }
        if let result { try container.encode(result, forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
    }
}

enum MCPJSONRPCMessage: Codable, Equatable, Sendable {
    case request(MCPJSONRPCRequest)
    case response(MCPJSONRPCResponse)

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: DynamicCodingKey.self)
        if keys.contains(DynamicCodingKey("method")) {
            self = .request(try MCPJSONRPCRequest(from: decoder))
        } else if keys.contains(DynamicCodingKey("result")) || keys.contains(DynamicCodingKey("error")) {
            self = .response(try MCPJSONRPCResponse(from: decoder))
        } else {
            throw MCPProtocolError.invalidMessage
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request): try request.encode(to: encoder)
        case .response(let response): try response.encode(to: encoder)
        }
    }

    var response: MCPJSONRPCResponse? {
        guard case .response(let value) = self else { return nil }
        return value
    }

    var request: MCPJSONRPCRequest? {
        guard case .request(let value) = self else { return nil }
        return value
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

// MARK: - Configuration

struct MCPEnvironmentBinding: Codable, Equatable, Hashable, Sendable {
    let key: String
    let source: Source

    enum Source: Codable, Equatable, Hashable, Sendable {
        case literal(String)
        case keychain(reference: String)
    }

    init(key: String, source: Source) {
        self.key = key
        self.source = source
    }
}

struct MCPConfiguration: Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let transport: MCPTransport
    let command: String?
    let arguments: [String]
    let url: URL?
    let environment: [MCPEnvironmentBinding]
    let protocolVersion: String
    let clientName: String
    let clientVersion: String

    init(
        id: String = UUID().uuidString,
        name: String,
        transport: MCPTransport,
        command: String? = nil,
        arguments: [String] = [],
        url: URL? = nil,
        environment: [MCPEnvironmentBinding] = [],
        protocolVersion: String = "2025-06-18",
        clientName: String = "OasesChat",
        clientVersion: String = "0.1.0"
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environment = environment
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    init(server: OasesMCPServerConfig, environment: [MCPEnvironmentBinding]? = nil) throws {
        let url = server.urlString.flatMap(URL.init(string:))
        if server.transport == .http, url == nil {
            throw MCPConfigurationError.invalidURL(server.urlString ?? "")
        }
        var bindings = environment ?? server.environment.map {
            MCPEnvironmentBinding(key: $0.key, source: .literal($0.value))
        }
        if server.transport == .http {
            bindings += Self.headerBindings(server.headers, existing: bindings)
        }
        self.init(
            id: server.id,
            name: server.name,
            transport: server.transport,
            command: server.command,
            arguments: server.arguments,
            url: url,
            environment: bindings
        )
    }

    /// An HTTP server's custom headers in the environment form `MCPHTTPClient` sends
    /// (`Authorization`, or `HEADER_<NAME>` with `-` written `_`). A header the environment
    /// already sets keeps the environment's value.
    static func headerBindings(_ headers: [String: String]?, existing: [MCPEnvironmentBinding]) -> [MCPEnvironmentBinding] {
        guard let headers, !headers.isEmpty else { return [] }
        let taken = Set(existing.map { $0.key.uppercased() })
        return headers.sorted { $0.key < $1.key }.compactMap { name, value in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.caseInsensitiveCompare("Authorization") == .orderedSame
                ? "Authorization"
                : "HEADER_" + trimmed.replacingOccurrences(of: "-", with: "_")
            guard !taken.contains(key.uppercased()) else { return nil }
            return MCPEnvironmentBinding(key: key, source: .literal(value))
        }
    }

    func resolvedEnvironment(using secretStore: MCPSecretStore) throws -> [String: String] {
        try secretStore.resolve(environment)
    }
}

enum MCPProtocolError: LocalizedError, Equatable, Sendable {
    case invalidMessage
    case invalidJSON
    case invalidRequestID
    case responseError(MCPJSONRPCError)
    case responseIDMismatch(expected: MCPRequestID, actual: MCPRequestID?)
    case notificationResponse

    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "Invalid MCP JSON-RPC message."
        case .invalidJSON: return "Invalid MCP JSON-RPC JSON."
        case .invalidRequestID: return "MCP request is missing an ID."
        case .responseError(let error): return "MCP error \(error.code): \(error.message)"
        case .responseIDMismatch: return "MCP response ID does not match the request."
        case .notificationResponse: return "MCP notification unexpectedly returned a response."
        }
    }
}

enum MCPConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case missingCommand
    case unsupportedTransport

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid MCP URL: \(value)"
        case .missingCommand: return "STDIO MCP configuration has no command."
        case .unsupportedTransport: return "Unsupported MCP transport."
        }
    }
}
