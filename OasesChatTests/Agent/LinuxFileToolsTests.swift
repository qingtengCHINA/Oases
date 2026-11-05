import XCTest
@testable import Oases_Chat

final class LinuxFileToolsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Host-side layout only. materializeGuestLayout() hops iSH guest
        // mkdir onto ISHRuntimeQueue when the kernel is warm — safe for
        // unit tests that intentionally skip full Alpine bootstrap.
        _ = OasesPathResolver.materializeGuestLayout()
    }

    func testWriteReadEditRoundTrip() async throws {
        let write = LinuxFileWriteTool()
        let read = LinuxFileReadTool()
        let edit = LinuxFileEditTool()

        let path = "/var/oases/workspace/oases_file_tools_selftest_\(UUID().uuidString.prefix(8)).txt"
        let writeJSON = """
        {"path":"\(path)","content":"hello world\\nline2\\n","tool_title":"Write selftest file"}
        """
        let writeResult = try await write.invoke(argumentsJSON: writeJSON, onProgress: { _ in })
        XCTAssertTrue(writeResult.text?.contains("Wrote") == true || writeResult.text?.contains("✓") == true, writeResult.text ?? "")
        XCTAssertTrue(writeResult.text?.contains(path) == true)

        let readJSON = """
        {"path":"\(path)","tool_title":"Read selftest file"}
        """
        let readResult = try await read.invoke(argumentsJSON: readJSON, onProgress: { _ in })
        XCTAssertTrue(readResult.text?.contains("hello world") == true, readResult.text ?? "")

        let editJSON = """
        {"path":"\(path)","old_string":"hello world","new_string":"hello oases","tool_title":"Edit selftest file"}
        """
        let editResult = try await edit.invoke(argumentsJSON: editJSON, onProgress: { _ in })
        XCTAssertTrue(editResult.text?.contains("Edited") == true || editResult.text?.contains("✓") == true, editResult.text ?? "")

        let read2 = try await read.invoke(argumentsJSON: readJSON, onProgress: { _ in })
        XCTAssertTrue(read2.text?.contains("hello oases") == true, read2.text ?? "")
        XCTAssertFalse(read2.text?.contains("hello world") == true)
    }

    func testRelativePathResolvesToWorkspace() async throws {
        let write = LinuxFileWriteTool()
        let name = "rel_\(UUID().uuidString.prefix(6)).txt"
        let result = try await write.invoke(
            argumentsJSON: "{\"path\":\"\(name)\",\"content\":\"rel-ok\"}",
            onProgress: { _ in }
        )
        XCTAssertTrue(result.text?.contains("/var/oases/workspace/\(name)") == true, result.text ?? "")
    }

    func testEditMissingOldStringFails() async throws {
        let write = LinuxFileWriteTool()
        let edit = LinuxFileEditTool()
        let path = "/var/oases/workspace/edit_miss_\(UUID().uuidString.prefix(6)).txt"
        _ = try await write.invoke(
            argumentsJSON: "{\"path\":\"\(path)\",\"content\":\"abc\\n\"}",
            onProgress: { _ in }
        )
        let result = try await edit.invoke(
            argumentsJSON: "{\"path\":\"\(path)\",\"old_string\":\"zzz\",\"new_string\":\"yyy\"}",
            onProgress: { _ in }
        )
        XCTAssertTrue(result.text?.contains("old_string not found") == true, result.text ?? "")
    }
}
