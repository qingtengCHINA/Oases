import Foundation

struct AgentRunMemoryWriteResult: Sendable, Equatable {
    let documentTopic: String
    let wikiTopic: String
    let persisted: Bool
    let detail: String
}

/// The journal contains only the already-redacted memory projection. It is
/// safe to leave on disk during a crash and makes native memory/wiki writes
/// recoverable without retaining a transcript or provider credentials.
struct AgentRunMemoryWikiWrite: Codable, Sendable, Equatable {
    let topic: String
    let title: String
    let body: String
    let tags: [String]
    let relatedTopics: [String]
    let sourceRunID: UUID?
    let provenance: MemoryProvenance
    let updatedAt: Date
}

struct AgentRunMemoryJournal: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let document: MemoryDocument
    let wiki: AgentRunMemoryWikiWrite

    static let currentSchemaVersion = 1
}

/// The durable memory boundary for the production engineering agent.
///
/// Memory is deliberately selected before a model turn and summarized after a
/// terminal run. The service never stores a raw transcript, cookies, API keys,
/// or full tool output. The iOS repositories are authoritative; the iSH wiki
/// mirror remains an execution-facing projection rather than the recovery
/// source of truth.
actor AgentRunMemoryService {
    static let shared = AgentRunMemoryService(
        repository: .shared,
        wikiRepository: .shared
    )

    private let repository: MemoryRepository
    private let retriever: MemoryRetriever
    private let wikiRepository: MemoryWikiRepository
    private let journalURL: URL
    private var didRecoverJournal = false
    private var recoveryDetail = ""

    init(
        repository: MemoryRepository,
        wikiRepository: MemoryWikiRepository,
        journalURL: URL? = nil
    ) {
        self.repository = repository
        self.retriever = MemoryRetriever(repository: repository)
        self.wikiRepository = wikiRepository
        self.journalURL = journalURL ?? Self.defaultJournalURL()
    }

    /// Return a compact, query-specific memory block. A caller should add this
    /// only once to a run's model history; no complete memory index is exposed.
    func relevantContext(query: String, limit: Int = 4) async -> String? {
        await recoverPendingJournalIfNeeded()
        let cleanQuery = Self.compact(query)
        guard cleanQuery.count >= 2 else { return nil }

        var sections: [String] = []
        if let results = try? await retriever.search(cleanQuery, limit: limit), !results.isEmpty {
            var lines = ["-- native memory --"]
            for result in results.prefix(limit) {
                lines.append("[\(result.document.title)] \(Self.compact(result.document.body, limit: 600))")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if let results = try? await wikiRepository.search(cleanQuery, limit: limit), !results.isEmpty {
            var lines = ["-- living wiki --"]
            for result in results.prefix(limit) {
                lines.append("[\(result.page.topic) rev=\(result.page.revision)] \(Self.compact(result.page.body, limit: 600))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        // i18n-ignore: model-facing system prompt (selected run memory block)
        return """
        [Ogent selected run memory]
        这是针对当前任务从本机 Memory/Wiki 检索出的少量相关记录。它不是完整上下文；如果与当前目标冲突，以当前目标和实时工具结果为准。
        query=\(Self.compact(cleanQuery, limit: 500))
        \(sections.joined(separator: "\n"))
        [/Ogent selected run memory]
        """
    }

    /// Persist a terminal engineering run as an auditable document and update
    /// one stable wiki topic. The stable topic makes future runs improve the
    /// same project memory page while the per-run document preserves provenance.
    func record(run: AgentRun, artifacts: [ArtifactRecord]) async -> AgentRunMemoryWriteResult {
        guard run.context?.surface == .project, let delivery = run.delivery else {
            return AgentRunMemoryWriteResult(
                documentTopic: "",
                wikiTopic: "",
                persisted: false,
                detail: "not a terminal project run"
            )
        }

        let runTopic = "agent-run-\(run.id.uuidString.lowercased())"
        let wikiTopic = Self.stableWikiTopic(for: run)
        let body = Self.runBody(run: run, delivery: delivery, artifacts: artifacts)
        let title = "工程任务 \(String(run.id.uuidString.prefix(8)))" // i18n-ignore: persisted memory-wiki page title, model-facing memory data
        let tags = [
            "agent-run",
            "project",
            delivery.outcome.rawValue,
            run.state.rawValue
        ]

        let document = MemoryDocument(
            title: runTopic,
            body: body,
            tags: Set(tags),
            sourceRunID: run.id,
            provenance: MemoryProvenance(source: "oases.agent.run", sourceRunID: run.id)
        )
        let wikiWrite = AgentRunMemoryWikiWrite(
            topic: wikiTopic,
            title: title,
            body: body,
            tags: tags,
            relatedTopics: [runTopic],
            sourceRunID: run.id,
            provenance: MemoryProvenance(source: "oases.agent.wiki", sourceRunID: run.id),
            updatedAt: Date()
        )

        do {
            await recoverPendingJournalIfNeeded()
            guard recoveryDetail.isEmpty else {
                return AgentRunMemoryWriteResult(
                    documentTopic: runTopic,
                    wikiTopic: wikiTopic,
                    persisted: false,
                    detail: "pending_memory_recovery_failed \(recoveryDetail)"
                )
            }
            try persistJournal(AgentRunMemoryJournal(
                schemaVersion: AgentRunMemoryJournal.currentSchemaVersion,
                document: document,
                wiki: wikiWrite
            ))
            _ = try await repository.save(document)
            _ = try await wikiRepository.upsert(
                topic: wikiWrite.topic,
                title: wikiWrite.title,
                body: wikiWrite.body,
                tags: wikiWrite.tags,
                relatedTopics: wikiWrite.relatedTopics,
                sourceRunID: wikiWrite.sourceRunID,
                provenance: wikiWrite.provenance,
                updatedAt: wikiWrite.updatedAt
            )
            clearJournal()
            return AgentRunMemoryWriteResult(
                documentTopic: runTopic,
                wikiTopic: wikiTopic,
                persisted: true,
                detail: "native_memory_and_wiki_updated"
            )
        } catch {
            NSLog("[OgentMemory] terminal run write failed: %@", error.localizedDescription)
            return AgentRunMemoryWriteResult(
                documentTopic: runTopic,
                wikiTopic: wikiTopic,
                persisted: false,
                detail: error.localizedDescription
            )
        }
    }

    /// Replay one interrupted native-memory transaction. Repositories are
    /// actor-isolated, so the replay is serialized with normal reads/writes;
    /// the repository-level idempotency checks make this safe after any crash
    /// point between the two commits.
    private func recoverPendingJournalIfNeeded() async {
        guard !didRecoverJournal else { return }
        didRecoverJournal = true
        guard let data = try? Data(contentsOf: journalURL) else { return }
        do {
            let journal = try Self.decoder.decode(AgentRunMemoryJournal.self, from: data)
            guard journal.schemaVersion <= AgentRunMemoryJournal.currentSchemaVersion else {
                throw MemoryRepositoryError.unsupportedSchema(journal.schemaVersion)
            }
            _ = try await repository.save(journal.document)
            _ = try await wikiRepository.upsert(
                topic: journal.wiki.topic,
                title: journal.wiki.title,
                body: journal.wiki.body,
                tags: journal.wiki.tags,
                relatedTopics: journal.wiki.relatedTopics,
                sourceRunID: journal.wiki.sourceRunID,
                provenance: journal.wiki.provenance,
                updatedAt: journal.wiki.updatedAt
            )
            clearJournal()
        } catch {
            recoveryDetail = error.localizedDescription
            NSLog("[OgentMemory] pending journal recovery failed: %@", error.localizedDescription)
        }
    }

    private func persistJournal(_ journal: AgentRunMemoryJournal) throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(journal)
        try data.write(to: journalURL, options: [.atomic])
    }

    private func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    private static func runBody(
        run: AgentRun,
        delivery: AgentDelivery,
        artifacts: [ArtifactRecord]
    ) -> String {
        let context = run.context
        var lines: [String] = [
            "## 工程 Agent 运行摘要", // i18n-ignore: persisted memory document body, model-facing memory data
            "- run_id: \(run.id.uuidString)",
            "- state: \(run.state.rawValue)",
            "- outcome: \(delivery.outcome.rawValue)",
            "- model: \(redact(context?.model ?? "unknown"))"
        ]

        if let projectID = context?.projectID, !projectID.isEmpty {
            lines.append("- project_id: \(redact(projectID))")
        }
        if let sessionID = context?.projectSessionID, !sessionID.isEmpty {
            lines.append("- session_id: \(redact(sessionID))")
        }
        if let request = run.request, !request.isEmpty {
            lines.append("- user_goal: \(redact(request, limit: 700))")
        }

        lines.append("")
        lines.append("### Delivery")
        lines.append(redact(delivery.summary, limit: 1_400))
        if !delivery.completedSteps.isEmpty {
            lines.append("completed_steps: \(delivery.completedSteps.map { redact($0, limit: 180) }.joined(separator: " | "))")
        }
        if !delivery.remainingSteps.isEmpty {
            lines.append("remaining_steps: \(delivery.remainingSteps.map { redact($0, limit: 180) }.joined(separator: " | "))")
        }
        if !delivery.warnings.isEmpty {
            lines.append("warnings: \(delivery.warnings.map { redact($0, limit: 220) }.joined(separator: " | "))")
        }
        if !delivery.sourceLinks.isEmpty {
            let links = delivery.sourceLinks.prefix(8).compactMap(Self.safeURL).joined(separator: " | ")
            if !links.isEmpty { lines.append("source_links: \(links)") }
        }
        if !artifacts.isEmpty {
            lines.append("")
            lines.append("### Verified artifacts")
            for artifact in artifacts where artifact.validation.isValid {
                lines.append("- \(artifact.kind.rawValue): \(artifact.fileURL.lastPathComponent) (\(artifact.byteCount) bytes, sha256=\(artifact.sha256.prefix(12)))")
            }
        }
        return redact(lines.joined(separator: "\n"), limit: 6_000)
    }

    private static func stableWikiTopic(for run: AgentRun) -> String {
        let raw = run.context?.projectID
            ?? run.context?.projectSessionID
            ?? "run-\(run.id.uuidString)"
        let normalized = raw.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(String(scalar))
            }
            return "-"
        }
        let value = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "agent-project-\(value.isEmpty ? run.id.uuidString.lowercased() : value)"
    }

    private static func safeURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    private static func redact(_ value: String, limit: Int = 1_000) -> String {
        var result = compact(value, limit: limit)
        result = result.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)sk-[A-Za-z0-9._\-]+"#,
            with: "[redacted]",
            options: .regularExpression
        )
        return result
    }

    private static func compact(_ value: String, limit: Int? = nil) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let limit, normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func defaultJournalURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("OasesChat", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("pending-agent-run.json")
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
