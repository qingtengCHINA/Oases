import Foundation

struct AgentCompletionContract: Equatable, Sendable {
    let requiresArtifact: Bool
    let requiredArtifactKinds: Set<ArtifactKind>
    let minimumCompletedSteps: Int

    init(
        requiresArtifact: Bool,
        requiredArtifactKinds: Set<ArtifactKind> = [],
        minimumCompletedSteps: Int = 0
    ) {
        self.requiresArtifact = requiresArtifact
        self.requiredArtifactKinds = requiredArtifactKinds
        self.minimumCompletedSteps = minimumCompletedSteps
    }
}

struct AgentFinalizationResult: Equatable, Sendable {
    let delivery: AgentDelivery
    let validatedArtifacts: [ArtifactRecord]
}

enum AgentFinalizer {
    static func validatedArtifacts(_ artifacts: [ArtifactRecord]) -> [ArtifactRecord] {
        artifacts.filter { record in
            guard record.validation.isValid else { return false }
            guard FileManager.default.fileExists(atPath: record.fileURL.path) else { return false }
            return (try? ArtifactValidator.validate(fileURL: record.fileURL, expectedKind: record.kind))?.isValid == true
        }
    }

    static func finalize(
        contract: AgentCompletionContract,
        artifacts: [ArtifactRecord],
        completedSteps: [String],
        sourceLinks: [URL] = []
    ) -> AgentFinalizationResult {
        let validatedArtifacts = Self.validatedArtifacts(artifacts)

        let missingKinds = contract.requiredArtifactKinds.subtracting(Set(validatedArtifacts.map(\.kind)))
        let hasRequiredArtifacts = !contract.requiresArtifact || (!validatedArtifacts.isEmpty && missingKinds.isEmpty)
        let hasMinimumSteps = completedSteps.count >= contract.minimumCompletedSteps

        guard hasRequiredArtifacts, hasMinimumSteps else {
            let missing = missingKinds.map(\.rawValue).sorted().joined(separator: ", ")
            var remaining = [String]()
            if !hasRequiredArtifacts { remaining.append(missing.isEmpty ? "required artifact" : "artifact: \(missing)") }
            if !hasMinimumSteps { remaining.append("completed steps \(completedSteps.count)/\(contract.minimumCompletedSteps)") }
            let outcome: AgentDelivery.Outcome = completedSteps.isEmpty ? .failed : .partial
            let delivery = AgentDelivery(
                outcome: outcome,
                summary: String(localized: "工程任务未形成可验证的最终交付。", comment: "Engineering agent delivery summary: the task produced no verifiable final delivery"),
                artifactIDs: validatedArtifacts.map(\.id),
                sourceLinks: sourceLinks,
                completedSteps: completedSteps,
                remainingSteps: remaining,
                warnings: [String(localized: "工具结果不能替代真实产物校验。", comment: "Engineering agent delivery warning: tool output text cannot stand in for validating a real artifact file")]
            )
            return AgentFinalizationResult(delivery: delivery, validatedArtifacts: validatedArtifacts)
        }

        let delivery = AgentDelivery(
            outcome: .succeeded,
            summary: String(localized: "工程任务已完成并通过最终交付校验。", comment: "Engineering agent delivery summary: the task finished and passed final delivery validation"),
            artifactIDs: validatedArtifacts.map(\.id),
            sourceLinks: sourceLinks,
            completedSteps: completedSteps
        )
        return AgentFinalizationResult(delivery: delivery, validatedArtifacts: validatedArtifacts)
    }
}
