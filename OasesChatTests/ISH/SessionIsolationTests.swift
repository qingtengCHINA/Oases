import XCTest
@testable import Oases_Chat

final class SessionIsolationTests: XCTestCase {
    func testTwoSessionsHaveDistinctWorkspaceTrees() throws {
        let sidA = "session-a-\(UUID().uuidString.prefix(8))"
        let sidB = "session-b-\(UUID().uuidString.prefix(8))"
        let path = "/var/oases/workspace/isolation.txt"

        let hostA = OasesFsRouter.shared.hostURL(forGuest: path, sessionId: sidA)
        let hostB = OasesFsRouter.shared.hostURL(forGuest: path, sessionId: sidB)
        XCTAssertNotNil(hostA)
        XCTAssertNotNil(hostB)
        XCTAssertNotEqual(hostA!.path, hostB!.path)
        XCTAssertTrue(hostA!.path.contains(sidA))
        XCTAssertTrue(hostB!.path.contains(sidB))
    }

    func testFileToolsWritePerSessionWithoutCrossTalk() async throws {
        let sidA = "iso-a-\(UUID().uuidString.prefix(6))"
        let sidB = "iso-b-\(UUID().uuidString.prefix(6))"
        let path = "/var/oases/workspace/note.txt"
        let write = LinuxFileWriteTool()
        let read = LinuxFileReadTool()

        try await OasesPathResolver.ActiveSession.$id.withValue(sidA) {
            _ = try await write.invoke(
                argumentsJSON: "{\"path\":\"\(path)\",\"content\":\"alpha-only\"}",
                onProgress: { _ in }
            )
        }
        try await OasesPathResolver.ActiveSession.$id.withValue(sidB) {
            _ = try await write.invoke(
                argumentsJSON: "{\"path\":\"\(path)\",\"content\":\"beta-only\"}",
                onProgress: { _ in }
            )
        }

        let readA = try await OasesPathResolver.ActiveSession.$id.withValue(sidA) {
            try await read.invoke(argumentsJSON: "{\"path\":\"\(path)\"}", onProgress: { _ in })
        }
        let readB = try await OasesPathResolver.ActiveSession.$id.withValue(sidB) {
            try await read.invoke(argumentsJSON: "{\"path\":\"\(path)\"}", onProgress: { _ in })
        }

        XCTAssertTrue(readA.text?.contains("alpha-only") == true, readA.text ?? "")
        XCTAssertFalse(readA.text?.contains("beta-only") == true, readA.text ?? "")
        XCTAssertTrue(readB.text?.contains("beta-only") == true, readB.text ?? "")
        XCTAssertFalse(readB.text?.contains("alpha-only") == true, readB.text ?? "")
    }

    func testFsContextTokensStablePerSession() {
        let sid = "ctx-\(UUID().uuidString.prefix(6))"
        let a = OasesFsRouter.shared.context(for: sid)
        let b = OasesFsRouter.shared.context(for: sid)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, 0)
        XCTAssertEqual(OasesFsRouter.shared.sessionId(for: a), sid)
    }
}
