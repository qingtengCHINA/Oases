import XCTest
@testable import Oases_Chat

/// Coverage for the ported ANSI emulator (`Features/Terminal/`).
///
/// The emulator, buffer and parser came over from OpenMinis as ~3300 lines with
/// no tests. "It compiles" says nothing about whether the escape sequences are
/// interpreted correctly, so these exercise the paths a real shell session hits
/// on the first screenful: plain text, cursor addressing, erase, SGR, autowrap,
/// CJK double-width cells, alternate screen, and the DSR reply.
@MainActor
final class TerminalEmulatorTests: XCTestCase {

    private func makeEmulator(cols: Int = 20, rows: Int = 5) -> TerminalEmulator {
        let emulator = TerminalEmulator()
        emulator.resize(cols: cols, rows: rows)
        return emulator
    }

    private func line(_ emulator: TerminalEmulator, _ row: Int) -> String {
        let cells = emulator.activeBuffer.grid[row]
        return String(cells.map(\.character)).trimmingCharacters(in: .whitespaces)
    }

    func testPlainTextLandsOnFirstRow() {
        let emulator = makeEmulator()
        emulator.feed(Data("hello".utf8))
        XCTAssertEqual(line(emulator, 0), "hello")
        XCTAssertEqual(emulator.activeBuffer.cursorCol, 5)
    }

    func testCarriageReturnAndLineFeedAdvanceRow() {
        let emulator = makeEmulator()
        emulator.feed(Data("ab\r\ncd".utf8))
        XCTAssertEqual(line(emulator, 0), "ab")
        XCTAssertEqual(line(emulator, 1), "cd")
        XCTAssertEqual(emulator.activeBuffer.cursorRow, 1)
    }

    /// CUP — `ESC[<row>;<col>H` is 1-based on the wire, 0-based in the buffer.
    func testCursorPositionIsOneBasedOnTheWire() {
        let emulator = makeEmulator()
        emulator.feed(Data("\u{1B}[3;5HX".utf8))
        XCTAssertEqual(emulator.activeBuffer.grid[2][4].character, "X")
    }

    /// ED — `ESC[2J` clears the screen without moving the cursor.
    func testEraseDisplayClearsAllRows() {
        let emulator = makeEmulator()
        emulator.feed(Data("dirty\r\nrows".utf8))
        emulator.feed(Data("\u{1B}[2J".utf8))
        XCTAssertEqual(line(emulator, 0), "")
        XCTAssertEqual(line(emulator, 1), "")
    }

    /// SGR — bold + red foreground, then reset.
    func testSGRAppliesAndResetsStyle() {
        let emulator = makeEmulator()
        emulator.feed(Data("\u{1B}[1;31mR\u{1B}[0mP".utf8))

        let styled = emulator.activeBuffer.grid[0][0]
        XCTAssertEqual(styled.character, "R")
        XCTAssertTrue(styled.attributes.contains(.bold))
        XCTAssertNotEqual(styled.foreground, .default)

        let plain = emulator.activeBuffer.grid[0][1]
        XCTAssertEqual(plain.character, "P")
        XCTAssertFalse(plain.attributes.contains(.bold))
        XCTAssertEqual(plain.foreground, .default)
    }

    func testTextWiderThanTheScreenWrapsToNextRow() {
        let emulator = makeEmulator(cols: 4, rows: 3)
        emulator.feed(Data("abcdef".utf8))
        XCTAssertEqual(line(emulator, 0), "abcd")
        XCTAssertEqual(line(emulator, 1), "ef")
    }

    /// CJK glyphs occupy two cells — getting this wrong misaligns every TUI.
    func testFullwidthCharacterOccupiesTwoCells() {
        let emulator = makeEmulator()
        emulator.feed(Data("中a".utf8))
        XCTAssertEqual(emulator.activeBuffer.grid[0][0].character, "中")
        XCTAssertEqual(emulator.activeBuffer.grid[0][0].width, 2)
        XCTAssertEqual(emulator.activeBuffer.grid[0][2].character, "a")
    }

    /// `ESC[?1049h` / `l` — vim and htop swap to the alternate screen and the
    /// primary contents must survive untouched.
    func testAlternateScreenPreservesPrimaryBuffer() {
        let emulator = makeEmulator()
        emulator.feed(Data("primary".utf8))

        emulator.feed(Data("\u{1B}[?1049h".utf8))
        XCTAssertTrue(emulator.isAlternateActive)
        emulator.feed(Data("alt".utf8))
        XCTAssertEqual(line(emulator, 0), "alt")

        emulator.feed(Data("\u{1B}[?1049l".utf8))
        XCTAssertFalse(emulator.isAlternateActive)
        XCTAssertEqual(line(emulator, 0), "primary")
    }

    /// DSR — `ESC[6n` must be answered with `ESC[<row>;<col>R`, or programs
    /// that query cursor position hang waiting for a reply.
    func testDeviceStatusReportRepliesWithCursorPosition() {
        let emulator = makeEmulator()
        var replies: [Data] = []
        emulator.onResponse = { replies.append($0) }

        emulator.feed(Data("\u{1B}[2;3H".utf8))
        emulator.feed(Data("\u{1B}[6n".utf8))

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first.map { String(decoding: $0, as: UTF8.self) }, "\u{1B}[2;3R")
    }

    /// A CSI split across two reads must still parse — TTY output arrives in
    /// arbitrarily small chunks.
    func testEscapeSequenceSplitAcrossFeedsStillParses() {
        let emulator = makeEmulator()
        emulator.feed(Data("\u{1B}[3".utf8))
        emulator.feed(Data(";5HX".utf8))
        XCTAssertEqual(emulator.activeBuffer.grid[2][4].character, "X")
    }
}
