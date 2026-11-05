import XCTest
@testable import Oases_Chat

/// Hostile terminal input (`cat` of a binary, crafted escape sequences) must
/// neither trap on Int overflow nor spin the main thread.
@MainActor
final class TerminalHardeningTests: XCTestCase {

    private func csiParams(_ bytes: String) -> [[Int]] {
        var captured: [[Int]] = []
        ANSIParser().feed(Data(bytes.utf8)) { action in
            if case .csiDispatch(let params, _, _) = action { captured.append(params) }
        }
        return captured
    }

    func testHugeCSIParameterIsClampedInsteadOfOverflowing() {
        let digits = String(repeating: "9", count: 400)
        let params = csiParams("\u{1B}[\(digits);5H")
        XCTAssertEqual(params, [[ANSIParser.maxParamValue, 5]])
    }

    func testParameterListIsCapped() {
        let many = Array(repeating: "1", count: 10_000).joined(separator: ";")
        let params = csiParams("\u{1B}[\(many)m")
        XCTAssertEqual(params.first?.count, ANSIParser.maxParamCount)
    }

    func testHugeOSCCommandAndPayloadAreBounded() {
        var dispatched: (Int, String)?
        let payload = String(repeating: "A", count: ANSIParser.maxOSCPayloadBytes * 2)
        let digits = String(repeating: "7", count: 300)
        ANSIParser().feed(Data("\u{1B}]\(digits);\(payload)\u{07}".utf8)) { action in
            if case .oscDispatch(let command, let text) = action { dispatched = (command, text) }
        }
        XCTAssertEqual(dispatched?.0, ANSIParser.maxParamValue)
        XCTAssertEqual(dispatched?.1.utf8.count, ANSIParser.maxOSCPayloadBytes)
    }

    func testScrollUpWithHugeCountClearsScreenQuickly() {
        let emulator = TerminalEmulator()
        emulator.resize(cols: 10, rows: 4)
        emulator.feed(Data("a\r\nb\r\nc".utf8))
        let start = Date()
        emulator.feed(Data("\u{1B}[999999999S\u{1B}[999999999T".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        for row in 0..<4 {
            XCTAssertTrue(emulator.activeBuffer.grid[row].allSatisfy { $0.character == " " })
        }
    }

    func testCursorHorizontalTabWithHugeCountStopsAtLastColumn() {
        let emulator = TerminalEmulator()
        emulator.resize(cols: 20, rows: 3)
        emulator.feed(Data("\u{1B}[999999999I".utf8))
        XCTAssertEqual(emulator.activeBuffer.cursorCol, 19)
    }

    func testBinaryGarbageDoesNotCrash() {
        let emulator = TerminalEmulator()
        emulator.resize(cols: 40, rows: 10)
        // Deterministic pseudo-random bytes (LCG) so a failure reproduces.
        var state: UInt32 = 0x1234_5678
        var bytes = [UInt8]()
        for _ in 0..<60_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        // Sprinkle escape introducers so the CSI/OSC paths get exercised.
        for i in stride(from: 0, to: bytes.count, by: 97) { bytes[i] = 0x1B }
        emulator.feed(Data(bytes))
        XCTAssertEqual(emulator.activeBuffer.grid.count, 10)
    }
}
