import Foundation
import NaturalLanguage

enum MemoryRetrievalMode: String, Codable, Sendable {
    case hybrid
}

struct MemorySearchResult: Sendable, Equatable {
    let document: MemoryDocument
    let score: Double
    let matchedTerms: [String]
}

actor MemoryRetriever {
    static let retrievalMode: MemoryRetrievalMode = .hybrid

    private let repository: MemoryRepository
    private var index: [MemoryIndexEntry] = []
    private var semanticVectors: [UUID: (updatedAt: Date, vector: [Double])] = [:]

    init(repository: MemoryRepository) {
        self.repository = repository
    }

    func rebuildIndex() async throws {
        index = MemoryIndexer.build(from: try await repository.all())
    }

    func search(_ query: String, limit: Int = 8) async throws -> [MemorySearchResult] {
        guard limit > 0 else { return [] }
        let documents = try await repository.all()
        // Rebuild on every query so writes from another actor or a resumed
        // run cannot leave the in-memory index stale.
        index = MemoryIndexer.build(from: documents)
        let queryTokens = MemoryIndexer.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        semanticVectors = semanticVectors.filter { byID[$0.key]?.updatedAt == $0.value.updatedAt }
        let queryNGrams = MemoryIndexer.characterNGrams(query)
        let queryVector = MemorySemanticEmbedding.vector(for: query)
        let documentCount = max(1, index.count)
        let documentFrequency = index.reduce(into: [String: Int]()) { result, entry in
            for token in entry.tokens where queryTokens.contains(token) {
                result[token, default: 0] += 1
            }
        }

        return index.compactMap { entry -> MemorySearchResult? in
            guard let document = byID[entry.documentID] else { return nil }
            let matched = queryTokens.filter(entry.tokens.contains).sorted()
            let lexicalScore = matched.reduce(0.0) { partial, token in
                let frequency = Double(entry.tokenFrequencies[token, default: 0])
                let termFrequency = frequency > 0 ? 1 + log(frequency) : 0
                let inverseDocumentFrequency = log(
                    1 + Double(documentCount + 1) / Double(documentFrequency[token, default: 0] + 1)
                )
                return partial + termFrequency * inverseDocumentFrequency
            }
            let nGramOverlap = queryNGrams.isEmpty
                ? 0
                : Double(queryNGrams.intersection(entry.characterNGrams).count) / Double(queryNGrams.count)
            let fuzzyScore = nGramOverlap * 2.25
            let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let searchableText = "\(document.title) \(document.body) \(document.tags.joined(separator: " "))".lowercased()
            let phraseBonus = searchableText.contains(normalizedQuery) ? 2.5 : 0
            let matchedSet = Set(matched)
            let titleBonus = !matchedSet.intersection(entry.titleTokens).isEmpty ? 1.25 : 0
            let tagBonus = !matchedSet.intersection(entry.tagTokens).isEmpty ? 0.75 : 0
            let semanticScore = queryVector.map { queryVector in
                let documentVector: [Double]
                if let cached = semanticVectors[document.id], cached.updatedAt == document.updatedAt {
                    documentVector = cached.vector
                } else if let generated = MemorySemanticEmbedding.vector(for: searchableText) {
                    semanticVectors[document.id] = (document.updatedAt, generated)
                    documentVector = generated
                } else {
                    return 0.0
                }
                return MemorySemanticEmbedding.cosineSimilarity(queryVector, documentVector)
            } ?? 0.0
            let semanticBonus = semanticScore * 4.0
            let score = lexicalScore + fuzzyScore + phraseBonus + titleBonus + tagBonus + semanticBonus
            guard score > 0.35,
                  !matched.isEmpty || nGramOverlap >= 0.12 || semanticScore >= 0.55 else { return nil }
            return MemorySearchResult(document: document, score: score, matchedTerms: matched)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.updatedAt > $1.document.updatedAt
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

/// Optional on-device semantic layer backed by Apple's contextual NaturalLanguage
/// models. The store remains usable when system assets are unavailable; callers
/// then keep the deterministic lexical and character n-gram scores.
enum MemorySemanticEmbedding {
    static let providerIdentifier = "apple-natural-language-contextual-embedding"
    private static let availabilityCache = MemorySemanticEmbeddingAvailabilityCache()

    static func vector(for text: String) -> [Double]? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        for language in candidateLanguages(for: normalized) {
            guard !availabilityCache.isUnavailable(language) else { continue }
            guard let embedding = NLContextualEmbedding(language: language) else {
                availabilityCache.markUnavailable(language)
                continue
            }
            guard embedding.hasAvailableAssets else {
                availabilityCache.markUnavailable(language)
                continue
            }
            do {
                try embedding.load()
                let result = try embedding.embeddingResult(for: normalized, language: language)
                var pooled: [Double] = []
                var tokenCount = 0
                result.enumerateTokenVectors(in: normalized.startIndex..<normalized.endIndex) { vector, _ in
                    if pooled.isEmpty {
                        pooled = Array(repeating: 0, count: vector.count)
                    }
                    guard pooled.count == vector.count else { return true }
                    for index in vector.indices {
                        pooled[index] += vector[index]
                    }
                    tokenCount += 1
                    return false
                }
                guard tokenCount > 0 else { continue }
                return pooled.map { $0 / Double(tokenCount) }
            } catch {
                // Some simulator runtimes report assets as available but cannot
                // write NaturalLanguage's system model cache. Remember that
                // result for this process and use the deterministic fallback.
                availabilityCache.markUnavailable(language)
                continue
            }
        }
        return nil
    }

    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return max(0, dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude)))
    }

    private static func candidateLanguages(for text: String) -> [NLLanguage] {
        let supported: Set<NLLanguage> = [
            NLLanguage.simplifiedChinese,
            NLLanguage.traditionalChinese,
            NLLanguage.english
        ]
        var candidates: [NLLanguage] = []
        if let dominant = NLLanguageRecognizer.dominantLanguage(for: text), supported.contains(dominant) {
            candidates.append(dominant)
        }
        candidates.append(contentsOf: supported)

        var seen = Set<NLLanguage>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

private final class MemorySemanticEmbeddingAvailabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var unavailableLanguages: Set<NLLanguage> = []

    func isUnavailable(_ language: NLLanguage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unavailableLanguages.contains(language)
    }

    func markUnavailable(_ language: NLLanguage) {
        lock.lock()
        unavailableLanguages.insert(language)
        lock.unlock()
    }
}
