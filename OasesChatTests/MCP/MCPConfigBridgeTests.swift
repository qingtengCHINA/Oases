import Foundation
import XCTest
@testable import Oases_Chat

/// `MCPConfigBridge` writes `servers.json` from the agent-tool model, which
/// knows nothing about headers / OAuth / note / startup timeout. Toggling,
/// deleting or importing a server used to rewrite the whole file with those
/// fields nil, wiping every HTTP server's auth. These pin the merge.
final class MCPConfigBridgeTests: XCTestCase {
    private let existingFile = """
    {
      "schemaVersion": 2,
      "mcpServers": {
        "notion": {
          "enabled": true,
          "createdAt": 1000,
          "url": "https://mcp.notion.example/mcp",
          "headers": { "Authorization": "Bearer secret-token", "X-Workspace": "w1" },
          "oauth": { "mode": "static", "clientId": "client-1", "authorizationEndpoint": "https://a.example/auth", "tokenEndpoint": "https://a.example/token" },
          "note": "team workspace",
          "futureKey": { "nested": true }
        },
        "local-tools": {
          "enabled": true,
          "command": "/bin/sh",
          "args": ["tools.sh"],
          "startupTimeoutSeconds": 120
        },
        "scratch": { "enabled": true, "command": "/bin/true" }
      }
    }
    """

    private func entries(_ data: Data?) throws -> [String: [String: Any]] {
        let data = try XCTUnwrap(data)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
    }

    /// Round trip: read → toggle one server → write keeps every unmanaged field.
    func testToggleRoundTripKeepsHeadersOAuthNoteAndUnknownKeys() throws {
        let original = Data(existingFile.utf8)
        var servers = try entries(original).map { name, raw -> OasesMCPServerConfig in
            OasesMCPServerConfig(
                name: name,
                transport: raw["url"] != nil ? .http : .stdio,
                isEnabled: raw["enabled"] as? Bool ?? true,
                command: raw["command"] as? String,
                arguments: raw["args"] as? [String] ?? [],
                urlString: raw["url"] as? String
            )
        }
        for index in servers.indices { servers[index].id = servers[index].name }
        let notion = try XCTUnwrap(servers.firstIndex { $0.name == "notion" })
        servers[notion].isEnabled = false

        let merged = MCPConfigBridge.mergedServersFileData(existing: original, servers: servers)
        let result = try entries(merged)

        let notionEntry = try XCTUnwrap(result["notion"])
        XCTAssertEqual(notionEntry["enabled"] as? Bool, false)
        XCTAssertEqual(notionEntry["url"] as? String, "https://mcp.notion.example/mcp")
        XCTAssertEqual(notionEntry["headers"] as? [String: String],
                       ["Authorization": "Bearer secret-token", "X-Workspace": "w1"])
        let oauth = try XCTUnwrap(notionEntry["oauth"] as? [String: Any])
        XCTAssertEqual(oauth["clientId"] as? String, "client-1")
        XCTAssertEqual(notionEntry["note"] as? String, "team workspace")
        XCTAssertNotNil(notionEntry["futureKey"])

        XCTAssertEqual(result["local-tools"]?["startupTimeoutSeconds"] as? Int, 120)

        // Top-level keys other than mcpServers survive too.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(merged)) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)

        // The decoded model the engineering UI reads keeps the OAuth config.
        let decodedOAuth = try JSONDecoder().decode(
            MCPOAuthConfig.self,
            from: JSONSerialization.data(withJSONObject: oauth)
        )
        XCTAssertEqual(decodedOAuth.tokenEndpoint, "https://a.example/token")
    }

    func testDeleteDropsOnlyTheRemovedServer() throws {
        let original = Data(existingFile.utf8)
        let kept = OasesMCPServerConfig(
            name: "notion", transport: .http, isEnabled: true,
            urlString: "https://mcp.notion.example/mcp"
        )
        let merged = MCPConfigBridge.mergedServersFileData(existing: original, servers: [kept])
        let result = try entries(merged)
        XCTAssertEqual(Set(result.keys), ["notion"])
        XCTAssertEqual(result["notion"]?["headers"] as? [String: String],
                       ["Authorization": "Bearer secret-token", "X-Workspace": "w1"])
    }

    func testRenameInheritsFieldsFromPreviousKey() throws {
        var renamed = OasesMCPServerConfig(
            name: "notion-work", transport: .http, isEnabled: true,
            urlString: "https://mcp.notion.example/mcp"
        )
        renamed.id = "notion"  // ids are the on-disk key the entry was read from
        let merged = MCPConfigBridge.mergedServersFileData(existing: Data(existingFile.utf8), servers: [renamed])
        let result = try entries(merged)
        XCTAssertNil(result["notion"])
        XCTAssertEqual(result["notion-work"]?["note"] as? String, "team workspace")
    }

    func testTransportSwitchRemovesStaleTransportKeys() throws {
        var switched = OasesMCPServerConfig(
            name: "local-tools", transport: .http, isEnabled: true,
            urlString: "https://tools.example/mcp"
        )
        switched.id = "local-tools"
        let merged = MCPConfigBridge.mergedServersFileData(existing: Data(existingFile.utf8), servers: [switched])
        let entry = try XCTUnwrap(try entries(merged)["local-tools"])
        XCTAssertEqual(entry["url"] as? String, "https://tools.example/mcp")
        XCTAssertNil(entry["command"])
        XCTAssertNil(entry["args"])
    }

    func testWritesFreshFileWhenNothingExists() throws {
        let server = OasesMCPServerConfig(name: "new", transport: .stdio, command: "/bin/echo", arguments: ["hi"])
        let result = try entries(MCPConfigBridge.mergedServersFileData(existing: nil, servers: [server]))
        XCTAssertEqual(result["new"]?["command"] as? String, "/bin/echo")
        XCTAssertEqual(result["new"]?["args"] as? [String], ["hi"])
    }
}

/// Transport-level hardening for the MCP clients.
final class MCPTransportHardeningTests: XCTestCase {
    func testSSEIsDecidedByContentTypeOnly() {
        XCTAssertTrue(MCPHTTPClient.isEventStream(contentType: "text/event-stream"))
        XCTAssertTrue(MCPHTTPClient.isEventStream(contentType: "Text/Event-Stream; charset=utf-8"))
        XCTAssertFalse(MCPHTTPClient.isEventStream(contentType: "application/json"))
        XCTAssertFalse(MCPHTTPClient.isEventStream(contentType: nil))
    }

    /// A JSON reply whose payload merely contains "data:" (a data: URI) must be
    /// parsed as JSON, not as an SSE stream.
    func testJSONBodyContainingDataPrefixIsParsedAsJSON() async throws {
        let session = URLSession(configuration: StubProtocol.configuration)
        let config = MCPConfiguration(name: "json", transport: .http, url: URL(string: "https://example.invalid/mcp"))
        let client = MCPHTTPClient(configuration: config, session: session)
        let reply = MCPJSONRPCResponse(id: .integer(7), result: .object([
            "image": .string("data:image/png;base64,AAAA"),
            "metadata:": .string("x")
        ]))
        StubProtocol.response = (200, ["Content-Type": "application/json"], try JSONEncoder().encode(reply))
        let result = try await client.send(MCPJSONRPCRequest(id: .integer(7), method: "tools/call"))
        XCTAssertEqual(result.response.result?.objectValue?["image"], .string("data:image/png;base64,AAAA"))
    }

    func testJSONRPCErrorsDoNotCountAsTransportFailures() {
        XCTAssertFalse(MCPClientManager.isTransportFailure(
            MCPProtocolError.responseError(MCPJSONRPCError(code: -32602, message: "bad args"))
        ))
        XCTAssertFalse(MCPClientManager.isTransportFailure(CancellationError()))
        XCTAssertTrue(MCPClientManager.isTransportFailure(MCPStdioClientError.eof))
        XCTAssertTrue(MCPClientManager.isTransportFailure(MCPHTTPClientError.httpStatus(502)))
    }

    /// A tool-level JSON-RPC error must leave the cached session (and its
    /// process) alone instead of restarting it with backoff.
    func testManagerKeepsSessionAfterJSONRPCError() async throws {
        let transport = QueueTransport()
        await transport.enqueue(.response(MCPJSONRPCResponse(id: .integer(1), result: .object([:]))))
        await transport.enqueue(.response(MCPJSONRPCResponse(id: .integer(2), error: MCPJSONRPCError(code: -32601, message: "no such tool"))))
        await transport.enqueue(.response(MCPJSONRPCResponse(id: .integer(3), result: .object(["tools": .array([])]))))
        let manager = MCPClientManager(stdioFactory: { _ in transport })
        let config = MCPConfiguration(id: "keep", name: "stdio", transport: .stdio, command: "/bin/mock")

        do {
            _ = try await manager.toolsCall(server: config, toolName: "missing")
            XCTFail("Expected JSON-RPC error")
        } catch MCPProtocolError.responseError(let error) {
            XCTAssertEqual(error.code, -32601)
        }
        _ = try await manager.toolsList(server: config)
        let starts = await transport.startCount
        let stops = await transport.stopCount
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
    }

    /// Late replies to other ids, server→client requests and notifications are
    /// tolerated while waiting for our reply; server requests get answered.
    func testStdioClientSkipsStaleRepliesAndAnswersServerRequests() async throws {
        let transport = QueueTransport()
        await transport.enqueue(.response(MCPJSONRPCResponse(id: .integer(99), result: .string("stale"))))
        await transport.enqueue(.request(MCPJSONRPCRequest(id: .string("srv-1"), method: "ping")))
        await transport.enqueue(.request(MCPJSONRPCNotification(method: "notifications/progress")))
        await transport.enqueue(.response(MCPJSONRPCResponse(id: .integer(5), result: .string("ours"))))
        let client = MCPStdioClient(
            configuration: MCPConfiguration(name: "stdio", transport: .stdio, command: "/bin/mock"),
            transport: transport,
            framingMode: .newlineDelimited
        )
        try await client.start()
        let result = try await client.send(MCPJSONRPCRequest(id: .integer(5), method: "tools/list"))
        XCTAssertEqual(result.response.result, .string("ours"))
        XCTAssertEqual(result.notifications.map(\.method), ["notifications/progress"])

        let written = await transport.written
        XCTAssertEqual(written.count, 2)  // our request + the ping reply
        var framer = MCPMessageFramer(mode: .newlineDelimited)
        let pingReply = try XCTUnwrap(framer.append(written[1]).first?.response)
        XCTAssertEqual(pingReply.id, .string("srv-1"))
        XCTAssertNotNil(pingReply.result)
    }

    func testReplyToUnknownServerRequestIsMethodNotFound() {
        let reply = MCPJSONRPCResponse.reply(to: MCPJSONRPCRequest(id: .integer(3), method: "sampling/createMessage"))
        XCTAssertEqual(reply.id, .integer(3))
        XCTAssertEqual(reply.error?.code, -32601)
    }
}

private actor QueueTransport: MCPStdioTransport {
    private var queue: [Data] = []
    private(set) var written: [Data] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func enqueue(_ message: MCPJSONRPCMessage) {
        if let data = try? MCPMessageFramer.encode(message) { queue.append(data) }
    }

    func start() async throws { startCount += 1 }
    func write(_ data: Data) async throws { written.append(data) }
    func read() async throws -> Data? { queue.isEmpty ? nil : queue.removeFirst() }
    func stop() async { stopCount += 1 }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, [String: String], Data) = (200, [:], Data())

    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
