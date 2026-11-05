import Foundation

final class ArtifactStore: @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ogent Artifacts", isDirectory: true)
    }

    func record(
        fileURL: URL,
        runID: UUID,
        expectedKind: ArtifactKind? = nil
    ) throws -> ArtifactRecord {
        let validation = try ArtifactValidator.validate(fileURL: fileURL, expectedKind: expectedKind)
        return ArtifactRecord(
            runID: runID,
            kind: validation.detectedKind,
            fileURL: fileURL,
            sha256: validation.sha256 ?? "",
            byteCount: validation.byteCount,
            validation: validation
        )
    }

    func record(
        data: Data,
        filename: String,
        runID: UUID,
        expectedKind: ArtifactKind? = nil
    ) throws -> ArtifactRecord {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return try record(fileURL: fileURL, runID: runID, expectedKind: expectedKind)
    }
}
