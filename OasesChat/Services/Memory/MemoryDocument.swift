import Foundation

enum MemorySensitivity: String, Codable, Equatable, Hashable, Sendable {
    case normal
    case health
    case contacts
    case photos
    case location
    case cookies
    case apiKeys
    case rawTranscript
}

struct MemoryProvenance: Codable, Equatable, Hashable, Sendable {
    let source: String
    let sourceRunID: UUID?

    init(source: String, sourceRunID: UUID? = nil) {
        self.source = source
        self.sourceRunID = sourceRunID
    }
}

struct MemoryDocument: Codable, Sendable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    let id: UUID
    var title: String
    var body: String
    var tags: Set<String>
    var sourceRunID: UUID?
    var provenance: MemoryProvenance
    var sensitivity: MemorySensitivity
    var createdAt: Date
    var updatedAt: Date
    let schemaVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        tags: Set<String> = [],
        sourceRunID: UUID? = nil,
        provenance: MemoryProvenance = MemoryProvenance(source: "oases.project"),
        sensitivity: MemorySensitivity = .normal,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = MemoryDocument.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.sourceRunID = sourceRunID
        self.provenance = provenance
        self.sensitivity = sensitivity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    var normalizedTopic: String {
        title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum MemoryPolicyViolation: String, Codable, Equatable, Sendable {
    case health
    case contacts
    case photos
    case location
    case cookies
    case apiKeys
    case rawTranscript
}

enum MemoryRepositoryError: LocalizedError, Equatable, Sendable {
    case rejectedByPolicy(MemoryPolicyViolation)
    case invalidTopic
    case unsupportedSchema(Int)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .rejectedByPolicy(let violation):
            return "Memory document rejected by privacy policy: \(violation.rawValue)."
        case .invalidTopic:
            return "Memory topic must contain at least one letter, number, or CJK character."
        case .unsupportedSchema(let version):
            return "Memory store schema version \(version) is newer than this app supports."
        case .persistence(let detail):
            return "Memory store persistence failed: \(detail)."
        }
    }
}
