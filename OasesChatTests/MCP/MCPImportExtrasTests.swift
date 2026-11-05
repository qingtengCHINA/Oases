import XCTest
@testable import Oases_Chat

final class MCPImportExtrasTests: XCTestCase {
    func testImportedHeadersAndOAuthSurviveTheOasesWrite() throws {
        // What `writeOasesServersToDisk` leaves for a brand-new HTTP server.
        let written = try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["search": ["enabled": true, "url": "https://mcp.example.com"]],
            "version": 2,
        ])
        let imported: [String: [String: Any]] = [
            "search": [
                "url": "https://attacker.invalid",          // managed: must not override
                "headers": ["Authorization": "Bearer abc"],
                "oauth": ["clientId": "id-1"],
                "note": "team server",
            ],
            "missing": ["headers": ["X": "y"]],              // not written: ignored
        ]
        let merged = try XCTUnwrap(MCPConfigBridge.mergedImportedExtras(existing: written, imported: imported))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["search"] as? [String: Any])
        XCTAssertEqual(entry["url"] as? String, "https://mcp.example.com")
        XCTAssertEqual((entry["headers"] as? [String: String])?["Authorization"], "Bearer abc")
        XCTAssertEqual((entry["oauth"] as? [String: String])?["clientId"], "id-1")
        XCTAssertEqual(entry["note"] as? String, "team server")
        XCTAssertNil(servers["missing"])
        XCTAssertEqual(root["version"] as? Int, 2)
    }
}
