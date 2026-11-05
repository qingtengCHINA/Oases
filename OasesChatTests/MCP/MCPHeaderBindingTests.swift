import XCTest
@testable import Oases_Chat

/// "Custom Headers" saved in the MCP form reach the app's own HTTP client.
final class MCPHeaderBindingTests: XCTestCase {
    private func key(_ binding: MCPEnvironmentBinding) -> String { binding.key }

    func testHeadersBecomeHeaderBindings() throws {
        var server = OasesMCPServerConfig(name: "notes", transport: .http, urlString: "https://mcp.example.com/mcp")
        server.headers = ["Authorization": "Bearer t0ken", "X-Api-Key": "k"]
        let configuration = try MCPConfiguration(server: server)
        let byKey = Dictionary(uniqueKeysWithValues: configuration.environment.map { ($0.key, $0.source) })
        XCTAssertEqual(byKey["Authorization"], .literal("Bearer t0ken"))
        XCTAssertEqual(byKey["HEADER_X_Api_Key"], .literal("k"))
    }

    /// A value the environment already sets wins; stdio servers get no header bindings.
    func testEnvironmentWinsAndStdioIsUntouched() throws {
        var http = OasesMCPServerConfig(name: "a", transport: .http, urlString: "https://mcp.example.com",
                                        environment: [MCPEnvironmentVariable(key: "Authorization", value: "Bearer env")])
        http.headers = ["authorization": "Bearer header"]
        let configuration = try MCPConfiguration(server: http)
        XCTAssertEqual(configuration.environment.filter { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }.count, 1)
        XCTAssertEqual(configuration.environment.first?.source, .literal("Bearer env"))

        var stdio = OasesMCPServerConfig(name: "b", transport: .stdio, command: "/bin/true")
        stdio.headers = ["Authorization": "x"]
        XCTAssertTrue(try MCPConfiguration(server: stdio).environment.isEmpty)
    }

    /// The bridge keeps an HTTP server's headers when it maps servers.json to the agent model.
    func testBridgeCarriesHeaders() {
        let server = MCPServerConfig(
            id: "notes", note: nil, enabled: true, createdAt: nil, updatedAt: nil,
            url: "https://mcp.example.com/mcp", headers: ["Authorization": "Bearer t"], oauth: nil,
            command: nil, args: nil, env: nil, startupTimeoutSeconds: nil
        )
        XCTAssertEqual(MCPConfigBridge.toOases(server).headers, ["Authorization": "Bearer t"])
    }
}
