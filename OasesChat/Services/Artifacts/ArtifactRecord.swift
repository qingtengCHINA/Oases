import Foundation

enum ArtifactKind: String, Codable, Sendable, Equatable, Hashable {
    case docx
    case pptx
    case pdf
    case media
    case download
    case other
}

struct ArtifactValidation: Codable, Sendable, Equatable {
    let isValid: Bool
    let reason: String?
    let detectedKind: ArtifactKind
    let byteCount: Int64
    let sha256: String?

    static func valid(
        kind: ArtifactKind,
        byteCount: Int64,
        sha256: String
    ) -> ArtifactValidation {
        ArtifactValidation(
            isValid: true,
            reason: nil,
            detectedKind: kind,
            byteCount: byteCount,
            sha256: sha256
        )
    }

    static func invalid(
        reason: String,
        kind: ArtifactKind = .other,
        byteCount: Int64 = 0
    ) -> ArtifactValidation {
        ArtifactValidation(
            isValid: false,
            reason: reason,
            detectedKind: kind,
            byteCount: byteCount,
            sha256: nil
        )
    }
}

struct ArtifactRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let kind: ArtifactKind
    let fileURL: URL
    let sha256: String
    let byteCount: Int64
    let createdAt: Date
    let validation: ArtifactValidation

    init(
        id: UUID = UUID(),
        runID: UUID,
        kind: ArtifactKind,
        fileURL: URL,
        sha256: String,
        byteCount: Int64,
        createdAt: Date = Date(),
        validation: ArtifactValidation
    ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.fileURL = fileURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.validation = validation
    }
}
