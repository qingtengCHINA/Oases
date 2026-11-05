import Foundation

struct MCPMessageFramer: Sendable {
    enum Mode: Sendable, Equatable {
        case newlineDelimited
        case contentLength
        case auto
    }

    private(set) var mode: Mode
    private let maximumMessageBytes: Int
    private var buffer = Data()

    init(mode: Mode = .auto, maximumMessageBytes: Int = 4 * 1024 * 1024) {
        self.mode = mode
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ data: Data) throws -> [MCPJSONRPCMessage] {
        buffer.append(data)
        var messages: [MCPJSONRPCMessage] = []
        while let payload = try nextPayload() {
            let message: MCPJSONRPCMessage
            do {
                message = try JSONDecoder().decode(MCPJSONRPCMessage.self, from: payload)
            } catch {
                throw MCPProtocolError.invalidJSON
            }
            messages.append(message)
        }
        return messages
    }

    static func encode(_ message: MCPJSONRPCMessage, mode: Mode = .newlineDelimited) throws -> Data {
        let data = try JSONEncoder.mcp.encode(message)
        switch mode {
        case .newlineDelimited, .auto:
            return data + Data([0x0A])
        case .contentLength:
            let header = "Content-Length: \(data.count)\r\n\r\n"
            return Data(header.utf8) + data
        }
    }

    private mutating func nextPayload() throws -> Data? {
        if mode == .auto, let firstLineEnd = buffer.firstIndex(of: 0x0A) {
            let firstLine = buffer[..<firstLineEnd]
            if String(decoding: firstLine, as: UTF8.self).lowercased().hasPrefix("content-length:") {
                mode = .contentLength
            } else {
                mode = .newlineDelimited
            }
        }

        switch mode {
        case .newlineDelimited, .auto:
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                try enforceLimit()
                return nil
            }
            let payload = buffer[..<newline]
            buffer.removeSubrange(...newline)
            let trimmed = payload.drop(while: { $0 == 0x20 || $0 == 0x0D || $0 == 0x0A })
            guard !trimmed.isEmpty else { return try nextPayload() }
            return Data(trimmed)

        case .contentLength:
            guard let headerEnd = findHeaderEnd() else {
                try enforceLimit()
                return nil
            }
            let header = String(decoding: buffer[..<headerEnd], as: UTF8.self)
            guard let lengthLine = header.split(whereSeparator: \.isNewline).first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }), let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) else {
                throw MCPProtocolError.invalidMessage
            }
            guard length >= 0, length <= maximumMessageBytes else { throw MCPFramerError.messageTooLarge }
            let bodyStart = headerEnd + (buffer[headerEnd] == 0x0D ? 4 : 2)
            guard buffer.count >= bodyStart + length else { return nil }
            let payload = buffer[bodyStart..<(bodyStart + length)]
            buffer.removeSubrange(..<(bodyStart + length))
            return Data(payload)
        }
    }

    private func findHeaderEnd() -> Data.Index? {
        if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) { return range.lowerBound }
        if let range = buffer.range(of: Data([0x0A, 0x0A])) { return range.lowerBound }
        return nil
    }

    private func enforceLimit() throws {
        if buffer.count > maximumMessageBytes { throw MCPFramerError.messageTooLarge }
    }
}

enum MCPFramerError: LocalizedError, Equatable, Sendable {
    case messageTooLarge

    var errorDescription: String? { "MCP message exceeds the configured limit." }
}

private extension JSONEncoder {
    static var mcp: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
