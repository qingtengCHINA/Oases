import Foundation

/// Extended message types that the agent loop can attach to an
/// assistant turn. Mirrors AionUI's chatLib message taxonomy so we
/// can render the same UX vocabulary: plan cards, thinking blocks,
/// tool-call pills, permission gates.
///
/// These are NOT separate `ChatUIMessage` entries — they are
/// auxiliary blocks attached to an assistant message. The chat
/// surface renders them between the assistant header and its
/// final text.
struct AgentAnnotation: Identifiable, Equatable {
    let id: String
    let kind: Kind
    var payload: Payload

    init(id: String = UUID().uuidString, kind: Kind, payload: Payload) {
        self.id = id; self.kind = kind; self.payload = payload
    }

    enum Kind: String, Codable {
        case plan
        case thinking
        case toolCall
        case permission
        case agentStatus
    }

    enum Payload: Equatable {
        /// Multi-step plan the agent intends to follow.
        case plan(steps: [PlanStep])
        /// Free-form reasoning chunk — collapsible in the UI.
        case thinking(text: String)
        /// A single tool invocation in any of the five states.
        case toolCall(call: ToolCall)
        /// Permission request awaiting user accept / deny.
        case permission(prompt: String, toolName: String, allowOptions: [String])
        /// "Reading the file…", "Thinking…", etc. — short status line.
        case status(text: String)
    }
}

/// One row inside a plan annotation.
struct PlanStep: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var status: Status

    enum Status: String, Codable, Equatable {
        case pending, inProgress, completed, skipped, failed
    }

    init(id: String = UUID().uuidString, title: String, status: Status = .pending) {
        self.id = id; self.title = title; self.status = status
    }
}

/// Convenience constructors so call sites stay readable.
extension AgentAnnotation {
    static func plan(_ steps: [PlanStep]) -> AgentAnnotation {
        AgentAnnotation(kind: .plan, payload: .plan(steps: steps))
    }

    static func thinking(_ text: String) -> AgentAnnotation {
        AgentAnnotation(kind: .thinking, payload: .thinking(text: text))
    }

    static func toolCall(_ call: ToolCall) -> AgentAnnotation {
        AgentAnnotation(kind: .toolCall, payload: .toolCall(call: call))
    }

    static func status(_ text: String) -> AgentAnnotation {
        AgentAnnotation(kind: .agentStatus, payload: .status(text: text))
    }
}
