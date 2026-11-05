import Foundation
import XCTest
@testable import Oases_Chat

/// `text/event-stream` parsing used by the chat stream (`SSEDecoder`).
final class SSEEventParserTests: XCTestCase {
    private func parse(_ stream: String, chunkSize: Int = .max) -> [String] {
        var parser = SSEEventParser()
        var payloads: [String] = []
        let bytes = Array(stream.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + chunkSize)
            payloads += parser.consume(bytes[index..<end])
            index = end
        }
        return payloads + parser.finish()
    }

    func testBlankLineSeparatesEvents() {
        XCTAssertEqual(parse("data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testMultiLineDataIsJoinedWithNewline() {
        XCTAssertEqual(parse("data: {\"a\":\ndata: 1}\n\n"), ["{\"a\":\n1}"])
    }

    func testCRLFAndCRLineEndings() {
        XCTAssertEqual(parse("data: one\r\n\r\ndata: two\r\rdata: three\n\n"), ["one", "two", "three"])
    }

    func testOnlyOneLeadingSpaceIsRemoved() {
        XCTAssertEqual(parse("data:  two spaces\n\ndata:none\n\n"), [" two spaces", "none"])
    }

    func testCommentsAndOtherFieldsAreIgnored() {
        let stream = ": keep-alive\nevent: message\nid: 7\nretry: 1000\ndata: payload\n\n"
        XCTAssertEqual(parse(stream), ["payload"])
    }

    func testEventWithoutDataIsNotDispatched() {
        XCTAssertEqual(parse("event: ping\n\n: comment\n\ndata: x\n\n"), ["x"])
    }

    func testEventsSplitAcrossChunksAtEveryByte() {
        let stream = "data: {\"text\":\"你好\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        XCTAssertEqual(parse(stream, chunkSize: 1), ["{\"text\":\"你好\"}", "[DONE]"])
    }

    func testDoneIsDeliveredWithoutTrailingBlankLine() {
        var parser = SSEEventParser()
        XCTAssertEqual(parser.consume(Array("data: {\"a\":1}\n\n".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(parser.consume(Array("data: [DONE]\n".utf8)), ["[DONE]"])
        XCTAssertTrue(SSEEventParser.isDone("[DONE]"))
    }

    func testUnterminatedFinalEventIsDeliveredAtEndOfStream() {
        XCTAssertEqual(parse("data: {\"a\":1}\n\ndata: {\"b\":2}"), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testJSONLinesWithoutBlankSeparatorAreSplit() {
        // Some proxies omit the blank line; `}` followed by `{` can't be one
        // JSON value, so each line is its own event.
        let stream = "data: {\"a\":1}\ndata: {\"b\":2}\ndata: [DONE]\n"
        XCTAssertEqual(parse(stream), ["{\"a\":1}", "{\"b\":2}", "[DONE]"])
    }

    func testEmptyDataPayloadIsSkipped() {
        XCTAssertEqual(parse("data:\n\ndata: x\n\n"), ["x"])
    }
}
