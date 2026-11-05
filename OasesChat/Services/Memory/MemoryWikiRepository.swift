import Foundation

struct MemoryWikiPage: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    let topic: String
    var title: String
    var body: String
    var tags: [String]
    var relatedTopics: [String]
    var sourceRunID: UUID?
    var provenance: MemoryProvenance
    var revision: Int
    let createdAt: Date
    var updatedAt: Date
    let schemaVersion: Int
}

struct MemoryWikiRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let pageID: UUID
    let topic: String
    let title: String
    let body: String
    let tags: [String]
    let relatedTopics: [String]
    let sourceRunID: UUID?
    let provenance: MemoryProvenance
    let revision: Int
    let updatedAt: Date
}

struct MemoryWikiSearchResult: Equatable, Sendable {
    let page: MemoryWikiPage
    let score: Double
}

/// Versioned, privacy-filtered native wiki storage for project memory.
///
/// The iSH wiki mirror remains useful for guest-side tools, but this repository
/// is the authoritative iOS index used to bootstrap and resume agent runs.
actor MemoryWikiRepository {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var pages: [MemoryWikiPage]
        var revisions: [MemoryWikiRevision]
    }

    static let shared = MemoryWikiRepository(fileURL: MemoryWikiRepository.defaultFileURL())

    private let fileURL: URL
    private var pagesByTopic: [String: MemoryWikiPage] = [:]
    private var revisionsByTopic: [String: [MemoryWikiRevision]] = [:]
    private var didLoad = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    func upsert(
        topic: String,
        title: String,
        body: String,
        tags: [String] = [],
        relatedTopics: [String] = [],
        sourceRunID: UUID? = nil,
        provenance: MemoryProvenance = MemoryProvenance(source: "oases.project.wiki"),
        sensitivity: MemorySensitivity = .normal,
        updatedAt: Date = Date()
    ) throws -> MemoryWikiPage {
        try loadIfNeeded()

        let normalizedTopic = Self.normalizeTopic(topic)
        guard !normalizedTopic.isEmpty else {
            throw MemoryRepositoryError.invalidTopic
        }

        let normalizedTitle = Self.compact(title).isEmpty ? normalizedTopic : Self.compact(title)
        let normalizedBody = Self.compact(body)
        let normalizedTags = Self.unique(Self.compactTags(tags))
        let normalizedRelatedTopics = Self.unique(
            relatedTopics.map(Self.normalizeTopic).filter { !$0.isEmpty && $0 != normalizedTopic }
        )

        let policyDocument = MemoryDocument(
            title: normalizedTitle,
            body: normalizedBody,
            tags: Set(normalizedTags),
            sourceRunID: sourceRunID,
            provenance: provenance,
            sensitivity: sensitivity,
            updatedAt: updatedAt
        )
        try MemoryPrivacyPolicy.validate(policyDocument)

        let existing = pagesByTopic[normalizedTopic]
        // A pending-memory journal can be replayed after either repository
        // has already committed. Treat the same content/provenance as a
        // no-op so recovery never fabricates an extra wiki revision.
        if let existing,
           existing.title == normalizedTitle,
           existing.body == normalizedBody,
           existing.tags == normalizedTags,
           existing.relatedTopics == normalizedRelatedTopics,
           existing.sourceRunID == sourceRunID,
           existing.provenance == provenance {
            return existing
        }
        if let existing {
            revisionsByTopic[normalizedTopic, default: []].append(
                MemoryWikiRevision(
                    id: UUID(),
                    pageID: existing.id,
                    topic: existing.topic,
                    title: existing.title,
                    body: existing.body,
                    tags: existing.tags,
                    relatedTopics: existing.relatedTopics,
                    sourceRunID: existing.sourceRunID,
                    provenance: existing.provenance,
                    revision: existing.revision,
                    updatedAt: existing.updatedAt
                )
            )
            revisionsByTopic[normalizedTopic] = Array(
                revisionsByTopic[normalizedTopic, default: []].suffix(Self.maxRevisionHistory)
            )
        }

        let page = MemoryWikiPage(
            id: existing?.id ?? UUID(),
            topic: normalizedTopic,
            title: normalizedTitle,
            body: normalizedBody,
            tags: normalizedTags,
            relatedTopics: normalizedRelatedTopics,
            sourceRunID: sourceRunID,
            provenance: provenance,
            revision: (existing?.revision ?? 0) + 1,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt,
            schemaVersion: MemoryWikiPage.currentSchemaVersion
        )
        pagesByTopic[normalizedTopic] = page
        try persist()
        return page
    }

    func page(topic: String) throws -> MemoryWikiPage? {
        try loadIfNeeded()
        return pagesByTopic[Self.normalizeTopic(topic)]
    }

    func all() throws -> [MemoryWikiPage] {
        try loadIfNeeded()
        return Self.sorted(Array(pagesByTopic.values))
    }

    func history(topic: String) throws -> [MemoryWikiRevision] {
        try loadIfNeeded()
        return revisionsByTopic[Self.normalizeTopic(topic), default: []]
            .sorted { $0.revision > $1.revision }
    }

    @discardableResult
    func delete(topic: String) throws -> Bool {
        try loadIfNeeded()
        let normalizedTopic = Self.normalizeTopic(topic)
        guard pagesByTopic.removeValue(forKey: normalizedTopic) != nil else { return false }
        revisionsByTopic.removeValue(forKey: normalizedTopic)
        try persist()
        return true
    }

    func search(_ query: String, limit: Int = 8) throws -> [MemoryWikiSearchResult] {
        try loadIfNeeded()
        guard limit > 0 else { return [] }

        let queryText = Self.compact(query).lowercased()
        let queryTokens = MemoryIndexer.tokenize(queryText)
        let queryNGrams = MemoryIndexer.characterNGrams(queryText)
        let queryVector = MemorySemanticEmbedding.vector(for: queryText)
        guard !queryTokens.isEmpty else {
            return Self.sorted(Array(pagesByTopic.values))
                .prefix(limit)
                .map { MemoryWikiSearchResult(page: $0, score: 0) }
        }

        return pagesByTopic.values.compactMap { page in
            let pageText = "\(page.topic) \(page.title) \(page.body) \(page.tags.joined(separator: " "))"
            let pageTokens = MemoryIndexer.tokenize(pageText)
            let overlap = queryTokens.intersection(pageTokens).count
            let pageNGrams = MemoryIndexer.characterNGrams(pageText)
            let nGramOverlap = queryNGrams.isEmpty
                ? 0
                : Double(queryNGrams.intersection(pageNGrams).count) / Double(queryNGrams.count)
            let phraseBonus = pageText.lowercased().contains(queryText) ? 3 : 0
            let topicBonus = page.topic.contains(Self.normalizeTopic(query)) ? 4 : 0
            let titleBonus = page.title.lowercased().contains(queryText) ? 2 : 0
            let fuzzyBonus = nGramOverlap >= 0.12 ? Int((nGramOverlap * 8).rounded()) : 0
            let semanticBonus: Double
            if let queryVector,
               let pageVector = MemorySemanticEmbedding.vector(for: pageText) {
                semanticBonus = MemorySemanticEmbedding.cosineSimilarity(queryVector, pageVector) * 8.0
            } else {
                semanticBonus = 0
            }
            let score = Double(overlap * 2 + phraseBonus + topicBonus + titleBonus + fuzzyBonus) + semanticBonus
            guard score > 0 else { return nil }
            return MemoryWikiSearchResult(page: page, score: score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.page.updatedAt != $1.page.updatedAt { return $0.page.updatedAt > $1.page.updatedAt }
            return $0.page.topic < $1.page.topic
        }
        .prefix(limit)
        .map { $0 }
    }

    func export() throws -> Data {
        try loadIfNeeded()
        let envelope = Envelope(
            schemaVersion: MemoryWikiPage.currentSchemaVersion,
            pages: Self.sorted(Array(pagesByTopic.values)),
            revisions: revisionsByTopic.values.flatMap { $0 }.sorted { $0.updatedAt < $1.updatedAt }
        )
        return try Self.encoder.encode(envelope)
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        didLoad = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion <= MemoryWikiPage.currentSchemaVersion else {
                throw MemoryRepositoryError.unsupportedSchema(envelope.schemaVersion)
            }
            pagesByTopic = Dictionary(uniqueKeysWithValues: envelope.pages.map { ($0.topic, $0) })
            revisionsByTopic = Dictionary(grouping: envelope.revisions, by: \.topic)
            if envelope.schemaVersion != MemoryWikiPage.currentSchemaVersion {
                try persist()
            }
        } catch let error as MemoryRepositoryError {
            throw error
        } catch {
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            pagesByTopic = [:]
            revisionsByTopic = [:]
            try persist()
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let envelope = Envelope(
                schemaVersion: MemoryWikiPage.currentSchemaVersion,
                pages: Self.sorted(Array(pagesByTopic.values)),
                revisions: revisionsByTopic.values.flatMap { $0 }.sorted { $0.updatedAt < $1.updatedAt }
            )
            try Self.encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        } catch {
            throw MemoryRepositoryError.persistence(error.localizedDescription)
        }
    }

    private static func normalizeTopic(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || isCJK(scalar)
                || scalar == "_"
                || scalar == "-"
                || scalar == "."
            if isAllowed {
                if pendingSeparator && !result.isEmpty && !result.hasSuffix("-") {
                    result.append("-")
                }
                result.append(String(scalar))
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private static func compact(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactTags(_ tags: [String]) -> [String] {
        tags.map(compact).filter { !$0.isEmpty }
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func sorted(_ pages: [MemoryWikiPage]) -> [MemoryWikiPage] {
        pages.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.topic < $1.topic
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
    }

    private static let maxRevisionHistory = 20

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("OasesChat", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("wiki.json")
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
