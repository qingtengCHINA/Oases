import Foundation
import XCTest
@testable import Oases_Chat

final class MCPClientTests: XCTestCase {
    func testFramerHandlesPartialNewlineMessagesAndNotifications() throws {
        let notification = MCPJSONRPCNotification(method: "notifications/progress", params: .object(["value": .number(1)]))
        let response = MCPJSONRPCResponse(id: .integer(4), result: .object(["ok": .bool(true)]))
        let first = try MCPMessageFramer.encode(.request(notification))
        let second = try MCPMessageFramer.encode(.response(response))
        var framer = MCPMessageFramer(mode: .newlineDelimited)
        XCTAssertEqual(try framer.append(Data(first.dropLast())), [])
        let messages = try framer.append(Data(first.suffix(1)) + second)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].request?.method, "notifications/progress")
        XCTAssertEqual(messages[1].response?.id, .integer(4))
    }

    func testFramerHandlesContentLengthHeaders() throws {
        let response = MCPJSONRPCResponse(id: .string("abc"), result: .string("done"))
        var framer = MCPMessageFramer(mode: .auto)
        let encoded = try MCPMessageFramer.encode(.response(response), mode: .contentLength)
        let messages = try framer.append(encoded)
        XCTAssertEqual(messages.first?.response?.result, .string("done"))
    }

    func testSecretMigrationStoresOnlySensitiveEnvironmentKeys() throws {
        let keychain = MemoryKeychain()
        let store = MCPSecretStore(keychain: keychain, referencePrefix: "test.secret.")
        let migrated = try store.migrate([
            MCPEnvironmentBinding(key: "API_KEY", source: .literal("secret")),
            MCPEnvironmentBinding(key: "REGION", source: .literal("cn")),
            MCPEnvironmentBinding(key: "SESSION_COOKIE", source: .literal("cookie"))
        ])
        XCTAssertEqual(migrated[1].source, .literal("cn"))
        XCTAssertEqual(try store.resolve(migrated[0]), "secret")
        XCTAssertEqual(try store.resolve(migrated[2]), "cookie")
        XCTAssertTrue(MCPSecretStore.isSensitiveKey("Authorization"))
        XCTAssertFalse(MCPSecretStore.isSensitiveKey("REGION"))
    }

    func testHTTPClientSendsJSONAndMappedHeaders() async throws {
        let recorder = HTTPRecorder()
        let session = URLSession(configuration: HTTPRecorder.protocolSession(protocolClass: HTTPRecorder.self))
        let store = MCPSecretStore(keychain: MemoryKeychain())
        let config = MCPConfiguration(
            name: "mock",
            transport: .http,
            url: URL(string: "https://example.invalid/mcp"),
            environment: [
                MCPEnvironmentBinding(key: "Authorization", source: .literal("Bearer test")),
                MCPEnvironmentBinding(key: "HEADER_X_API_KEY", source: .literal("key"))
            ]
        )
        recorder.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-KEY"), "key")
            let response = MCPJSONRPCResponse(id: .integer(1), result: .object(["ok": .bool(true)]))
            return (200, ["Content-Type": "application/json"], try JSONEncoder().encode(response))
        }
        let client = MCPHTTPClient(configuration: config, session: session, secretStore: store)
        let result = try await client.send(MCPJSONRPCRequest(id: .integer(1), method: "tools/list"))
        let resultValue = try XCTUnwrap(result.response.result)
        let resultObject = try XCTUnwrap(resultValue.objectValue)
        XCTAssertEqual(resultObject["ok"], MCPJSONValue.bool(true))
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testHTTPClientParsesSingleSSEEventAndRejectsAuthFailures() async throws {
        let recorder = HTTPRecorder()
        let session = URLSession(configuration: HTTPRecorder.protocolSession(protocolClass: HTTPRecorder.self))
        let config = MCPConfiguration(name: "mock", transport: .http, url: URL(string: "https://example.invalid/mcp"))
        let client = MCPHTTPClient(configuration: config, session: session)
        recorder.handler = { _ in
            let response = MCPJSONRPCResponse(id: .integer(2), result: .string("sse"))
            let data = try JSONEncoder().encode(response)
            return (200, ["Content-Type": "text/event-stream"], Data("event: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n".utf8))
        }
        let result = try await client.send(MCPJSONRPCRequest(id: .integer(2), method: "tools/call"))
        XCTAssertEqual(result.response.result, MCPJSONValue.string("sse"))

        recorder.handler = { _ in (401, [:], Data()) }
        do {
            _ = try await client.send(MCPJSONRPCRequest(id: .integer(3), method: "tools/list"))
            XCTFail("Expected unauthorized")
        } catch let error as MCPHTTPClientError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testStdioClientKeepsInjectedTransportAliveAcrossRequests() async throws {
        let transport = ScriptedStdioTransport()
        let config = MCPConfiguration(name: "stdio", transport: .stdio, command: "/bin/mock")
        let client = MCPStdioClient(configuration: config, transport: transport, framingMode: .newlineDelimited)
        try await transport.enqueue(response: MCPJSONRPCResponse(id: .integer(1), result: .object(["initialized": .bool(true)])))
        try await transport.enqueue(response: MCPJSONRPCResponse(id: .integer(2), result: .object(["tools": .array([])])))
        try await client.start()
        _ = try await client.send(MCPJSONRPCRequest(id: .integer(1), method: "initialize"))
        _ = try await client.send(MCPJSONRPCRequest(id: .integer(2), method: "tools/list"))
        let startCount = await transport.startCount
        let writeCount = await transport.writeCount
        let isRunning = await client.isRunning
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(writeCount, 2)
        XCTAssertTrue(isRunning)
        await client.stop()
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testManagerCachesSessionAndRunsToolsListAndCall() async throws {
        let transport = ScriptedStdioTransport()
        try await transport.enqueue(response: MCPJSONRPCResponse(id: .integer(1), result: .object([
            "protocolVersion": .string("2025-06-18"),
            "serverInfo": .object(["name": .string("fixture-mcp"), "version": .string("1.2.3")])
        ])))
        try await transport.enqueue(response: MCPJSONRPCResponse(id: .integer(2), result: .object(["tools": .array([])])))
        try await transport.enqueue(response: MCPJSONRPCResponse(id: .integer(3), result: .object(["content": .array([])])))
        let configuration = MCPConfiguration(id: "cached", name: "stdio", transport: .stdio, command: "/bin/mock")
        let manager = MCPClientManager(stdioFactory: { _ in transport })

        let list = try await manager.toolsList(server: configuration)
        let call = try await manager.toolsCall(server: configuration, toolName: "fixture")
        let listObject = try XCTUnwrap(list.objectValue)
        let callObject = try XCTUnwrap(call.objectValue)
        let cachedCount = await manager.cachedSessionCount()
        let sessionInfo = await manager.sessionInfo(serverID: configuration.id)
        let startCount = await transport.startCount
        let writeCount = await transport.writeCount
        XCTAssertEqual(listObject["tools"], MCPJSONValue.array([]))
        XCTAssertEqual(callObject["content"], MCPJSONValue.array([]))
        XCTAssertEqual(cachedCount, 1)
        XCTAssertEqual(sessionInfo?.serverName, "fixture-mcp")
        XCTAssertEqual(sessionInfo?.serverVersion, "1.2.3")
        XCTAssertTrue(sessionInfo?.initialized == true)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(writeCount, 4)
    }

    func testISHStdioTransportRejectsMissingCommandBeforeRuntimeStart() async throws {
        let configuration = MCPConfiguration(
            id: "missing-command",
            name: "fixture",
            transport: .stdio,
            command: nil
        )
        let transport = ISHMCPStdioTransport(configuration: configuration)

        do {
            try await transport.start()
            XCTFail("Expected missing command")
        } catch let error as ISHMCPStdioTransportError {
            XCTAssertEqual(error, .missingCommand)
        }
    }

    func testISHStdioTransportReportsPersistentProcessFailure() {
        XCTAssertTrue(ISHMCPStdioTransportError.processExited.localizedDescription.contains("exited"))
    }
}

private final class MemoryKeychain: MCPKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(reference: String) throws -> String? { lock.withLock { values[reference] } }
    func write(_ value: String, reference: String) throws { lock.withLock { values[reference] = value } }
    func delete(reference: String) throws { _ = lock.withLock { values.removeValue(forKey: reference) } }
}

private actor ScriptedStdioTransport: MCPStdioTransport {
    private var responses: [Data] = []
    private(set) var startCount = 0
    private(set) var writeCount = 0
    private(set) var stopCount = 0

    func start() async throws { startCount += 1 }
    func write(_ data: Data) async throws { writeCount += 1 }
    func read() async throws -> Data? { responses.isEmpty ? nil : responses.removeFirst() }
    func stop() async { stopCount += 1 }
    func enqueue(response: MCPJSONRPCResponse) throws { responses.append(try MCPMessageFramer.encode(.response(response))) }
}

private final class HTTPRecorder: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private static let state = HTTPRecorderState()

    var handler: Handler? {
        get { Self.state.lock.withLock { Self.state.currentHandler } }
        set { Self.state.lock.withLock { Self.state.currentHandler = newValue } }
    }
    var requestCount: Int { Self.state.lock.withLock { Self.state.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.lock.withLock { Self.state.count += 1; return Self.state.currentHandler }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    static func protocolSession(protocolClass: AnyClass) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        Self.state.lock.withLock { Self.state.count = 0; Self.state.currentHandler = nil }
        return configuration
    }
}

private final class HTTPRecorderState: @unchecked Sendable {
    let lock = NSLock()
    var currentHandler: HTTPRecorder.Handler?
    var count = 0
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
