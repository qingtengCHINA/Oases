import Foundation

/// The machine-readable result of an agent run. A final chat message is not a
/// substitute for this record: callers can use it to render, resume, export,
/// or audit a run without parsing prose.
struct AgentDelivery: Codable, Sendable, Equatable {
    enum Outcome: String, Codable, Sendable, Equatable {
        case succeeded
        case partial
        case failed
        case cancelled
    }

    var outcome: Outcome
    var summary: String
    var artifactIDs: [UUID]
    var sourceLinks: [URL]
    var completedSteps: [String]
    var remainingSteps: [String]
    var warnings: [String]

    init(
        outcome: Outcome,
        summary: String,
        artifactIDs: [UUID] = [],
        sourceLinks: [URL] = [],
        completedSteps: [String] = [],
        remainingSteps: [String] = [],
        warnings: [String] = []
    ) {
        self.outcome = outcome
        self.summary = summary
        self.artifactIDs = artifactIDs
        self.sourceLinks = sourceLinks
        self.completedSteps = completedSteps
        self.remainingSteps = remainingSteps
        self.warnings = warnings
    }
}
