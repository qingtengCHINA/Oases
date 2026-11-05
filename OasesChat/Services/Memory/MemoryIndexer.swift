import Foundation

struct MemoryIndexEntry: Sendable, Equatable {
    let documentID: UUID
    let tokens: Set<String>
    let tokenFrequencies: [String: Int]
    let characterNGrams: Set<String>
    let titleTokens: Set<String>
    let tagTokens: Set<String>
}

struct MemoryIndexer: Sendable {
    static func build(from documents: [MemoryDocument]) -> [MemoryIndexEntry] {
        documents.map { document in
            let titleTokens = tokenize(document.title)
            let tagTokens = tokenize(document.tags.joined(separator: " "))
            let searchableText = "\(document.title) \(document.body) \(document.tags.joined(separator: " "))"
            return MemoryIndexEntry(
                documentID: document.id,
                tokens: tokenize(searchableText),
                tokenFrequencies: frequencies(searchableText),
                characterNGrams: characterNGrams(searchableText),
                titleTokens: titleTokens,
                tagTokens: tagTokens
            )
        }
    }

    static func tokenize(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        var latin = ""
        let scalars = Array(text.lowercased().unicodeScalars)

        func flushLatin() {
            guard !latin.isEmpty else { return }
            tokens.insert(latin)
            latin = ""
        }

        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                latin.unicodeScalars.append(scalar)
                continue
            }
            flushLatin()
            if isCJK(scalar) {
                tokens.insert(String(scalar))
            }
        }
        flushLatin()

        // Keep contiguous CJK n-grams so a query such as "京都" ranks a
        // document containing the phrase above documents matching only one
        // character.
        let cjk = scalars.filter(isCJK).map(String.init)
        if cjk.count > 1 {
            for size in 2...min(4, cjk.count) {
                for index in 0...(cjk.count - size) {
                    tokens.insert(cjk[index..<(index + size)].joined())
                }
            }
        }
        return tokens
    }

    static func frequencies(_ text: String) -> [String: Int] {
        tokenizeInOrder(text).reduce(into: [:]) { result, token in
            result[token, default: 0] += 1
        }
    }

    /// Character n-grams provide a small, deterministic fuzzy layer for
    /// inflections, partial Latin words, and mixed Chinese/Latin queries.
    /// This is deliberately not presented as semantic embeddings.
    static func characterNGrams(_ text: String) -> Set<String> {
        var result = Set<String>()
        var run: [String] = []

        func flushRun() {
            guard run.count >= 2 else {
                run.removeAll(keepingCapacity: true)
                return
            }
            for size in 2...min(4, run.count) {
                for index in 0...(run.count - size) {
                    result.insert(run[index..<(index + size)].joined())
                }
            }
            run.removeAll(keepingCapacity: true)
        }

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar) {
                run.append(String(scalar))
            } else {
                flushRun()
            }
        }
        flushRun()
        return result
    }

    private static func tokenizeInOrder(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        let scalars = Array(text.lowercased().unicodeScalars)

        func flushLatin() {
            guard !latin.isEmpty else { return }
            tokens.append(latin)
            latin = ""
        }

        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                latin.unicodeScalars.append(scalar)
                continue
            }
            flushLatin()
            if isCJK(scalar) {
                tokens.append(String(scalar))
            }
        }
        flushLatin()
        return tokens
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
    }
}
