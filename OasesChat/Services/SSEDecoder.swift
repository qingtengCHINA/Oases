import Foundation

/// OpenAI-compatible Server-Sent Events decoder.
/// Yields the `data` payload of each event; the `data: [DONE]` event ends the
/// stream. Parsing follows the WHATWG `text/event-stream` rules (see
/// `SSEEventParser`) on the raw bytes — `AsyncBytes.lines` can't be used
/// because the blank lines that separate events are significant.
enum SSEDecoder {
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = SSEEventParser()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        for payload in parser.consume(byte: byte) {
                            if SSEEventParser.isDone(payload) {
                                continuation.finish()
                                return
                            }
                            continuation.yield(payload)
                        }
                    }
                    for payload in parser.finish() {
                        if SSEEventParser.isDone(payload) { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Incremental `text/event-stream` parser:
/// - lines end in LF, CRLF or CR;
/// - a blank line dispatches the event; its `data` lines are joined with LF;
/// - `data:` drops one optional space after the colon; `:` lines are
///   comments; `event:` / `id:` / `retry:` are accepted and ignored (chat
///   completion streams don't use them);
/// - an event still open at end of stream is delivered rather than dropped.
///
/// Tolerance for proxies that omit the blank line between events: a `data:`
/// line starting with `{` (or `[DONE]`) right after buffered data ending in
/// `}` can't continue the same JSON value, so it starts a new event; and a
/// lone `data: [DONE]` is delivered immediately.
struct SSEEventParser {
    private var lineBuffer: [UInt8] = []
    private var lastByteWasCR = false
    private var dataLines: [String] = []

    static func isDone(_ payload: String) -> Bool {
        payload.trimmingCharacters(in: .whitespaces) == "[DONE]"
    }

    /// Feeds raw bytes; returns the payloads of the events they complete.
    mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var payloads: [String] = []
        for byte in bytes {
            payloads.append(contentsOf: consume(byte: byte))
        }
        return payloads
    }

    mutating func consume(byte: UInt8) -> [String] {
        switch byte {
        case 0x0A: // LF — the second half of a CRLF was already handled by CR.
            if lastByteWasCR {
                lastByteWasCR = false
                return []
            }
            return endLine()
        case 0x0D: // CR
            lastByteWasCR = true
            return endLine()
        default:
            lastByteWasCR = false
            lineBuffer.append(byte)
            return []
        }
    }

    /// End of stream: delivers a trailing unterminated line / open event.
    mutating func finish() -> [String] {
        var payloads: [String] = []
        if !lineBuffer.isEmpty {
            payloads.append(contentsOf: endLine())
        }
        payloads.append(contentsOf: dispatch())
        return payloads
    }

    /// Processes one complete line (without its terminator).
    mutating func consume(line: String) -> [String] {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return [] }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        guard field == "data" else { return [] }

        var payloads: [String] = []
        if startsNewJSONEvent(value) {
            payloads = dispatch()
        }
        // The terminator is never part of a multi-line event; deliver it at
        // once instead of waiting for a blank line that may not come.
        if dataLines.isEmpty, Self.isDone(String(value)) {
            payloads.append(String(value))
            return payloads
        }
        dataLines.append(String(value))
        return payloads
    }

    private mutating func endLine() -> [String] {
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        return consume(line: line)
    }

    private mutating func dispatch() -> [String] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return [payload]
    }

    private func startsNewJSONEvent(_ value: Substring) -> Bool {
        guard let last = dataLines.last,
              last.trimmingCharacters(in: .whitespaces).hasSuffix("}") else { return false }
        let next = value.trimmingCharacters(in: .whitespaces)
        return next.hasPrefix("{") || next == "[DONE]"
    }
}
