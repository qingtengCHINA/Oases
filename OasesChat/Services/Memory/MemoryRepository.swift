import Foundation

actor MemoryRepository {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var documents: [MemoryDocument]
    }

    static let shared = MemoryRepository(fileURL: MemoryRepository.defaultFileURL())

    private let fileURL: URL
    private var documents: [UUID: MemoryDocument] = [:]
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func save(_ document: MemoryDocument) throws -> MemoryDocument {
        try loadIfNeeded()
        try MemoryPrivacyPolicy.validate(document)

        var saved = document
        if let existing = documents.values.first(where: { $0.normalizedTopic == document.normalizedTopic }),
           !document.normalizedTopic.isEmpty {
            // Journal replay is deliberately idempotent. A process may crash
            // after this repository commits but before the wiki commit; do
            // not create a new timestamped memory when the exact document is
            // replayed on the next launch.
            if existing.title == document.title,
               existing.body == document.body,
               existing.tags == document.tags,
               existing.sourceRunID == document.sourceRunID,
               existing.provenance == document.provenance,
               existing.sensitivity == document.sensitivity {
                return existing
            }
            saved = MemoryDocument(
                id: existing.id,
                title: document.title,
                body: document.body,
                tags: document.tags,
                sourceRunID: document.sourceRunID,
                provenance: document.provenance,
                sensitivity: document.sensitivity,
                createdAt: existing.createdAt,
                updatedAt: document.updatedAt,
                schemaVersion: MemoryDocument.currentSchemaVersion
            )
        } else if document.schemaVersion != MemoryDocument.currentSchemaVersion {
            saved = MemoryDocument(
                id: document.id,
                title: document.title,
                body: document.body,
                tags: document.tags,
                sourceRunID: document.sourceRunID,
                provenance: document.provenance,
                sensitivity: document.sensitivity,
                createdAt: document.createdAt,
                updatedAt: document.updatedAt,
                schemaVersion: MemoryDocument.currentSchemaVersion
            )
        }

        documents[saved.id] = saved
        try persist()
        return saved
    }

    func all() throws -> [MemoryDocument] {
        try loadIfNeeded()
        return sorted(Array(documents.values))
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        try loadIfNeeded()
        guard documents.removeValue(forKey: id) != nil else { return false }
        try persist()
        return true
    }

    @discardableResult
    func delete(sourceRunID: UUID) throws -> Int {
        try loadIfNeeded()
        let matching = documents.values.filter { $0.sourceRunID == sourceRunID }.map(\.id)
        guard !matching.isEmpty else { return 0 }
        matching.forEach { documents.removeValue(forKey: $0) }
        try persist()
        return matching.count
    }

    func export() throws -> Data {
        try loadIfNeeded()
        let envelope = Envelope(schemaVersion: MemoryDocument.currentSchemaVersion, documents: sorted(Array(documents.values)))
        return try Self.encoder.encode(envelope)
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        didLoad = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion <= MemoryDocument.currentSchemaVersion else {
                throw MemoryRepositoryError.unsupportedSchema(envelope.schemaVersion)
            }
            documents = Dictionary(uniqueKeysWithValues: envelope.documents.map { document in
                let migrated = document.schemaVersion == MemoryDocument.currentSchemaVersion
                    ? document
                    : MemoryDocument(
                        id: document.id,
                        title: document.title,
                        body: document.body,
                        tags: document.tags,
                        sourceRunID: document.sourceRunID,
                        provenance: document.provenance,
                        sensitivity: document.sensitivity,
                        createdAt: document.createdAt,
                        updatedAt: document.updatedAt,
                        schemaVersion: MemoryDocument.currentSchemaVersion
                    )
                return (migrated.id, migrated)
            })
            if envelope.schemaVersion != MemoryDocument.currentSchemaVersion {
                try persist()
            }
        } catch let error as MemoryRepositoryError {
            throw error
        } catch {
            // Preserve a recoverable copy before replacing a corrupt store.
            // A malformed memory file must never prevent the agent from
            // starting or silently destroy the only copy of local knowledge.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            documents = [:]
            try persist()
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let envelope = Envelope(schemaVersion: MemoryDocument.currentSchemaVersion, documents: sorted(Array(documents.values)))
            try Self.encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        } catch {
            throw MemoryRepositoryError.persistence(error.localizedDescription)
        }
    }

    private func sorted(_ values: [MemoryDocument]) -> [MemoryDocument] {
        values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("OasesChat", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("memories.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum MemoryPrivacyPolicy {
    static func validate(_ document: MemoryDocument) throws {
        switch document.sensitivity {
        case .normal:
            break
        case .health: throw MemoryRepositoryError.rejectedByPolicy(.health)
        case .contacts: throw MemoryRepositoryError.rejectedByPolicy(.contacts)
        case .photos: throw MemoryRepositoryError.rejectedByPolicy(.photos)
        case .location: throw MemoryRepositoryError.rejectedByPolicy(.location)
        case .cookies: throw MemoryRepositoryError.rejectedByPolicy(.cookies)
        case .apiKeys: throw MemoryRepositoryError.rejectedByPolicy(.apiKeys)
        case .rawTranscript: throw MemoryRepositoryError.rejectedByPolicy(.rawTranscript)
        }

        let text = "\(document.title)\n\(document.body)".lowercased()
        let rules: [(MemoryPolicyViolation, [String])] = [
            (.health, ["heart rate", "blood pressure", "healthkit", "健康数据", "心率"]), // i18n-ignore: privacy-filter keyword data
            (.contacts, ["联系人", "contact list", "address book"]), // i18n-ignore: privacy-filter keyword data
            (.photos, ["照片相册", "photo library", "phlibrary"]), // i18n-ignore: privacy-filter keyword data
            (.location, ["gps latitude", "latitude and longitude", "当前定位", "经纬度"]), // i18n-ignore: privacy-filter keyword data
            (.cookies, ["set-cookie", "cookie=", "browser cookies"]),
            (.apiKeys, ["api_key=", "api key", "sk-test-", "authorization: bearer", "password="]),
            (.rawTranscript, ["full conversation transcript", "conversation transcript", "完整对话记录"]) // i18n-ignore: privacy-filter keyword data
        ]
        if let (violation, _) = rules.first(where: { _, needles in needles.contains(where: text.contains) }) {
            throw MemoryRepositoryError.rejectedByPolicy(violation)
        }
    }
}
