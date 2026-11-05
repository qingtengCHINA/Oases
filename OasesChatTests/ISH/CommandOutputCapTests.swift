import XCTest
@testable import Oases_Chat

/// Captured command output keeps its start and end; the middle of a huge one is dropped.
final class CommandOutputCapTests: XCTestCase {
    func testShortOutputIsUntouched() {
        var buffer = ""
        CommandOutputCap.append("line 1\n", to: &buffer)
        CommandOutputCap.append("line 2\n", to: &buffer)
        XCTAssertEqual(buffer, "line 1\nline 2\n")
    }

    func testHugeOutputKeepsHeadAndTailWithOneMarker() {
        var buffer = ""
        CommandOutputCap.append("FIRST LINE\n", to: &buffer)
        let line = String(repeating: "y", count: 1023) + "\n"
        for _ in 0..<4_000 { CommandOutputCap.append(line, to: &buffer) }  // ~4 MB
        CommandOutputCap.append("LAST LINE\n", to: &buffer)
        CommandOutputCap.trim(&buffer)

        XCTAssertTrue(buffer.hasPrefix("FIRST LINE\n"))
        XCTAssertTrue(buffer.hasSuffix("LAST LINE\n"))
        XCTAssertEqual(buffer.components(separatedBy: CommandOutputCap.marker).count, 2, "exactly one marker")
        XCTAssertLessThanOrEqual(buffer.utf8.count, CommandOutputCap.keepBytes * 2 + CommandOutputCap.marker.utf8.count)
    }

    /// Cuts fall on scalar boundaries: multi-byte text stays valid.
    func testCJKOutputStaysValidText() {
        var buffer = ""
        let line = String(repeating: "中文输出", count: 200) + "\n"
        for _ in 0..<1_500 { CommandOutputCap.append(line, to: &buffer) }
        CommandOutputCap.trim(&buffer)
        XCTAssertNotNil(buffer.data(using: .utf8))
        XCTAssertFalse(buffer.contains("\u{FFFD}"))
        XCTAssertTrue(buffer.contains(CommandOutputCap.marker))
    }
}
