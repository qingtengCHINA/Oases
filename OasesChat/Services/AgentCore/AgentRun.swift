import Foundation

enum AgentRunState: String, Codable, Sendable, Equatable {
    case queued
    case planning
    case awaitingApproval
    case runningTool
    case waitingExternal
    case finalizing
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .partiallySucceeded, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// The transition table is kept in one place so an executor and a
    /// resumer cannot silently disagree about which lifecycle edges exist.
    func canTransition(to next: AgentRunState) -> Bool {
        switch self {
        case .queued:
            return [.planning, .cancelled, .failed].contains(next)
        case .planning:
            return [.awaitingApproval, .runningTool, .waitingExternal, .finalizing, .failed, .cancelled].contains(next)
        case .awaitingApproval:
            return [.planning, .runningTool, .cancelled, .failed].contains(next)
        case .runningTool:
            return [.planning, .awaitingApproval, .waitingExternal, .finalizing, .failed, .cancelled].contains(next)
        case .waitingExternal:
            return [.planning, .runningTool, .finalizing, .failed, .cancelled].contains(next)
        case .finalizing:
            return [.succeeded, .partiallySucceeded, .failed, .cancelled].contains(next)
        case .succeeded, .partiallySucceeded, .failed, .cancelled:
            return false
        }
    }
}

enum AgentRunError: Error, LocalizedError, Equatable {
    case invalidTransition(from: AgentRunState, to: AgentRunState)
    case missingDelivery(for: AgentRunState)
    case deliveryOutcomeMismatch(state: AgentRunState, outcome: AgentDelivery.Outcome)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return String(localized: "Invalid agent run transition: \(from.rawValue) -> \(to.rawValue).", comment: "Internal engineering agent error (can surface as the run error message); arguments are run state identifiers")
        case .missingDelivery(let state):
            return String(localized: "Agent run cannot enter \(state.rawValue) without a delivery record.", comment: "Internal engineering agent error (can surface as the run error message); the argument is a run state identifier")
        case .deliveryOutcomeMismatch(let state, let outcome):
            return String(localized: "Delivery outcome \(outcome.rawValue) does not match terminal state \(state.rawValue).", comment: "Internal engineering agent error (can surface as the run error message); arguments are an outcome identifier and a run state identifier")
        }
    }
}

/// Everything needed to reconstruct the model side of a run after a process
/// restart. Tool processes and iSH remain outside this value; they are rebuilt
/// by the runtime adapter from the persisted request and session identifiers.
struct AgentRunContext: Codable, Sendable, Equatable {
    let model: String
    let effort: String?
    let surface: AgentSurface
    let messages: [ChatAPIMessage]
    let toolsJSON: String?
    let projectSessionID: String?
    let projectID: String?
}

struct AgentRun: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: AgentRunState
    var events: [AgentEvent]
    var delivery: AgentDelivery?
    var request: String?
    var context: AgentRunContext?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        state: AgentRunState = .queued,
        events: [AgentEvent] = [],
        delivery: AgentDelivery? = nil,
        request: String? = nil,
        context: AgentRunContext? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.state = state
        self.events = events
        self.delivery = delivery
        self.request = request
        self.context = context
    }

    mutating func transition(
        to next: AgentRunState,
        at date: Date = Date(),
        location: ExecutionLocation = .iosHost
    ) throws {
        guard state.canTransition(to: next) else {
            throw AgentRunError.invalidTransition(from: state, to: next)
        }

        if next == .succeeded || next == .partiallySucceeded {
            guard let delivery else {
                throw AgentRunError.missingDelivery(for: next)
            }
            let expected: AgentDelivery.Outcome = next == .succeeded ? .succeeded : .partial
            guard delivery.outcome == expected else {
                throw AgentRunError.deliveryOutcomeMismatch(state: next, outcome: delivery.outcome)
            }
        } else if next == .failed || next == .cancelled {
            // Failure and cancellation can happen before a finalizer runs.
            // Materialize a typed minimal delivery so no terminal run is
            // persisted without an explicit outcome.
            let expected: AgentDelivery.Outcome = next == .failed ? .failed : .cancelled
            if let delivery {
                guard delivery.outcome == expected else {
                    throw AgentRunError.deliveryOutcomeMismatch(state: next, outcome: delivery.outcome)
                }
            } else {
                delivery = AgentDelivery(
                    outcome: expected,
                    summary: next == .failed
                        ? String(localized: "Agent run failed before final delivery.", comment: "Engineering agent run summary shown in chat when the run failed before producing a delivery")
                        : String(localized: "Agent run was cancelled.", comment: "Engineering agent run summary shown in chat when the run was cancelled")
                )
            }
        }

        events.append(.status(from: state, to: next, location: location, timestamp: date))
        state = next
        updatedAt = date
    }
}

struct AgentRunEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let run: AgentRun

    init(run: AgentRun, schemaVersion: Int = AgentRunEnvelope.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.run = run
    }
}
