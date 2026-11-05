import Foundation

enum AgentRunStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidRunFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return String(localized: "Unsupported AgentRun schema version: \(version).", comment: "Error shown when a saved engineering agent run uses an unknown schema version; the argument is the version number")
        case .invalidRunFile(let path):
            return String(localized: "Invalid AgentRun file: \(path).", comment: "Error shown when a saved engineering agent run file is unreadable; the argument is the file path")
        }
    }
}

/// File-backed run persistence used until the run metadata has a stable
/// SwiftData schema. Each run is a separate envelope, which keeps recovery of
/// one corrupt run from making the whole run history unreadable.
actor AgentRunStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
    }

    func save(_ run: AgentRun) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(AgentRunEnvelope(run: run))

        // Data.write(.atomic) writes a sibling temporary file and replaces
        // the destination, so readers never observe a half-written envelope.
        try data.write(to: fileURL(for: run.id), options: [.atomic])
    }

    func load(id: UUID) throws -> AgentRun? {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(AgentRunEnvelope.self, from: data)
            guard envelope.schemaVersion == AgentRunEnvelope.currentSchemaVersion else {
                throw AgentRunStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return envelope.run
        } catch let error as AgentRunStoreError {
            throw error
        } catch {
            throw AgentRunStoreError.invalidRunFile(url.path)
        }
    }

    func list() throws -> [AgentRun] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        return try urls.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw AgentRunStoreError.invalidRunFile(url.path)
            }
            return try load(id: id)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent("OasesChat/AgentRuns", isDirectory: true)
    }
}
