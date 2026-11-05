import Foundation

/// Where an agent event was produced. This is deliberately part of the
/// persisted event rather than inferred later from a log line.
enum ExecutionLocation: String, Codable, Sendable, Equatable {
    case iosHost
    case ishLinux
    case remoteOases
    case remoteCustomProvider
    case localModelEndpoint
}

/// A typed event emitted by an AgentRun. The payload is intentionally small;
/// large tool output should live in an artifact or an external event log and
/// be referenced from the metadata field.
struct AgentEvent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, Equatable {
        case status
        case tool
        case text
        case diagnostic
    }

    struct Status: Codable, Sendable, Equatable {
        let from: AgentRunState
        let to: AgentRunState
    }

    enum ToolPhase: String, Codable, Sendable, Equatable {
        case started
        case progress
        case succeeded
        case failed
        case cancelled
    }

    struct Tool: Codable, Sendable, Equatable {
        let name: String
        let phase: ToolPhase
        let callID: String?
        let summary: String?
    }

    struct Text: Codable, Sendable, Equatable {
        let text: String
        let role: String?
    }

    enum DiagnosticLevel: String, Codable, Sendable, Equatable {
        case info
        case warning
        case error
    }

    struct Diagnostic: Codable, Sendable, Equatable {
        let level: DiagnosticLevel
        let message: String
        let code: String?
    }

    enum Payload: Codable, Sendable, Equatable {
        case status(Status)
        case tool(Tool)
        case text(Text)
        case diagnostic(Diagnostic)

        var kind: Kind {
            switch self {
            case .status: return .status
            case .tool: return .tool
            case .text: return .text
            case .diagnostic: return .diagnostic
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)
            switch kind {
            case .status:
                self = .status(try container.decode(Status.self, forKey: .value))
            case .tool:
                self = .tool(try container.decode(Tool.self, forKey: .value))
            case .text:
                self = .text(try container.decode(Text.self, forKey: .value))
            case .diagnostic:
                self = .diagnostic(try container.decode(Diagnostic.self, forKey: .value))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            switch self {
            case .status(let value): try container.encode(value, forKey: .value)
            case .tool(let value): try container.encode(value, forKey: .value)
            case .text(let value): try container.encode(value, forKey: .value)
            case .diagnostic(let value): try container.encode(value, forKey: .value)
            }
        }
    }

    let id: UUID
    let timestamp: Date
    let location: ExecutionLocation
    let payload: Payload
    let metadata: [String: String]

    var kind: Kind { payload.kind }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        location: ExecutionLocation,
        payload: Payload,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.location = location
        self.payload = payload
        self.metadata = metadata
    }

    static func status(
        from: AgentRunState,
        to: AgentRunState,
        location: ExecutionLocation = .iosHost,
        timestamp: Date = Date()
    ) -> AgentEvent {
        AgentEvent(
            timestamp: timestamp,
            location: location,
            payload: .status(Status(from: from, to: to))
        )
    }

    static func tool(
        name: String,
        phase: ToolPhase,
        callID: String? = nil,
        summary: String? = nil,
        location: ExecutionLocation,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) -> AgentEvent {
        AgentEvent(
            timestamp: timestamp,
            location: location,
            payload: .tool(Tool(name: name, phase: phase, callID: callID, summary: summary)),
            metadata: metadata
        )
    }

    static func text(
        _ text: String,
        role: String? = nil,
        location: ExecutionLocation,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) -> AgentEvent {
        AgentEvent(
            timestamp: timestamp,
            location: location,
            payload: .text(Text(text: text, role: role)),
            metadata: metadata
        )
    }

    static func diagnostic(
        _ message: String,
        level: DiagnosticLevel = .info,
        code: String? = nil,
        location: ExecutionLocation = .iosHost,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) -> AgentEvent {
        AgentEvent(
            timestamp: timestamp,
            location: location,
            payload: .diagnostic(Diagnostic(level: level, message: message, code: code)),
            metadata: metadata
        )
    }
}
