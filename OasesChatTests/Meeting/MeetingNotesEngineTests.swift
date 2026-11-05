import XCTest
@testable import Oases_Chat

final class MeetingNotesEngineTests: XCTestCase {
    private let times: [Double] = [0, 12, 30, 61, 95]

    func testParseKeepsOnlyEvidenceThatPointsAtRealLines() throws {
        let raw = """
        Here you go:
        {"title": "“发布计划”", "summary": "讨论了发布时间。",
         "topics": [{"start": 10, "title": "时间", "summary": "定在周五",
                     "points": [{"text": "周五发布", "evidence": ["L2", "L99"]}, "直接写的要点"],
                     "evidence": ["L1"], "fishbone": {"question": "为什么延期", "branches": [{"label": "测试", "detail": "没测完", "evidence": ["L3"]}]}}],
         "conclusions": [{"text": "周五发布", "evidence": ["L2", "L4"]}],
         "todos": [{"text": "写公告", "owner": "", "evidence": ["L0"]}],
         "terms": [{"name": "Oases", "note": "产品", "heard": ["欧亚斯", "Oases"]}]}
        trailing text
        """
        let notes = try XCTUnwrap(MeetingNotesEngine.parse(raw, times: times, startedAt: 0))
        XCTAssertEqual(notes.title, "发布计划")
        XCTAssertEqual(notes.topics.count, 1)
        XCTAssertEqual(notes.topics[0].points, ["周五发布", "直接写的要点"])
        // L2 → 12 s; L99 is out of range and ignored.
        XCTAssertEqual(notes.topics[0].pointTime(0), 12)
        XCTAssertNil(notes.topics[0].pointTime(1))
        // A fishbone needs at least two branches.
        XCTAssertNil(notes.topics[0].fishbone)
        XCTAssertEqual(notes.conclusions.first?.support, 2)
        XCTAssertEqual(notes.conclusions.first?.t, 12)
        XCTAssertEqual(notes.todos.first?.support, 0)
        XCTAssertNil(notes.todos.first?.owner)
        // The correct spelling is never listed as a mishearing.
        XCTAssertEqual(notes.terms.first?.heard, ["欧亚斯"])
    }

    func testEmptyOrBrokenRepliesAreRejected() {
        XCTAssertNil(MeetingNotesEngine.parse("not json", times: times, startedAt: 0))
        XCTAssertNil(MeetingNotesEngine.parse(#"{"summary": "", "topics": []}"#, times: times, startedAt: 0))
    }

    func testLanguageCheck() {
        var zh = MeetingNotes()
        zh.summary = "讨论了 Oases 的发布时间和 iOS 版本。"
        XCTAssertTrue(MeetingNotesEngine.written(zh, in: "Simplified Chinese"))
        XCTAssertFalse(MeetingNotesEngine.written(zh, in: "English"))
        var en = MeetingNotes()
        en.summary = "We agreed to ship on Friday."
        XCTAssertTrue(MeetingNotesEngine.written(en, in: "English"))
        XCTAssertFalse(MeetingNotesEngine.written(en, in: "Japanese"))
    }

    func testLongTranscriptsAreSplitIntoWindowsThatCoverEveryLine() {
        let line = String(repeating: "字", count: 1000)
        let lines = (0..<60).map { MeetingLine(id: "\($0)", t: Double($0) * 10, text: line) }
        let windows = MeetingNotesEngine.windows(lines)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, lines.count)
        for (a, b) in zip(windows, windows.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
        XCTAssertEqual(MeetingNotesEngine.windows(Array(lines.prefix(3))), [0..<3])
    }

    func testTimesCarryOverToRepeatedPoints() {
        var old = MeetingNotes()
        old.topics = [NoteTopic(start: 0, title: "A", summary: "", points: ["p"], fishbone: nil, pointTimes: [5])]
        var new = MeetingNotes()
        new.topics = [NoteTopic(start: 0, title: "A", summary: "", points: ["p", "q"], fishbone: nil, pointTimes: [40, nil])]
        MeetingNotesEngine.carryTimes(from: old, into: &new)
        XCTAssertEqual(new.topics[0].pointTime(0), 5)
        XCTAssertNil(new.topics[0].pointTime(1))
    }

    func testSRTAndClock() {
        var m = Meeting(id: "x", startedAt: Date(timeIntervalSince1970: 0), language: "zh-CN", engine: "on-device")
        m.lines = [MeetingLine(id: "1", t: 1.5, text: "你好"), MeetingLine(id: "2", t: 3725, text: "再见")]
        let srt = MeetingExport.srt(m)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:01,500 --> 00:00:09,500\n你好\n"))
        XCTAssertTrue(srt.contains("2\n01:02:05,000 --> 01:02:09,000\n再见\n"))
        XCTAssertEqual(MeetingExport.clock(65), "01:05")
        XCTAssertEqual(MeetingExport.clock(3725), "1:02:05")
    }

    func testHeardTextCleansRecognitionNoise() {
        XCTAssertEqual(HeardText.clean("., , that is ..... fine"), "that is… fine")
        XCTAssertEqual(HeardText.clean("，，我们开始吧 。"), "我们开始吧。")
    }
}
