import CryptoKit
import Foundation

enum ArtifactValidationError: Error, LocalizedError, Equatable {
    case missingFile(URL)
    case notRegularFile(URL)
    case emptyFile(URL)
    case unsupportedFormat(URL)
    case kindMismatch(expected: ArtifactKind, actual: ArtifactKind)
    case malformedDocument(URL)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url): return "Artifact does not exist: \(url.lastPathComponent)"
        case .notRegularFile(let url): return "Artifact is not a regular file: \(url.lastPathComponent)"
        case .emptyFile(let url): return "Artifact is empty: \(url.lastPathComponent)"
        case .unsupportedFormat(let url): return "Artifact format is unsupported: \(url.lastPathComponent)"
        case .kindMismatch(let expected, let actual): return "Artifact kind mismatch: expected \(expected.rawValue), got \(actual.rawValue)."
        case .malformedDocument(let url): return "Artifact package is malformed: \(url.lastPathComponent)"
        }
    }
}

enum ArtifactValidator {
    static func validate(
        fileURL: URL,
        expectedKind: ArtifactKind? = nil
    ) throws -> ArtifactValidation {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ArtifactValidationError.missingFile(fileURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ArtifactValidationError.notRegularFile(fileURL)
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw ArtifactValidationError.emptyFile(fileURL) }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let kind = detectKind(for: fileURL, data: data)
        guard kind != .other else { throw ArtifactValidationError.unsupportedFormat(fileURL) }
        if let expectedKind, expectedKind != kind {
            throw ArtifactValidationError.kindMismatch(expected: expectedKind, actual: kind)
        }
        guard formatIsValid(kind: kind, data: data) else {
            throw ArtifactValidationError.malformedDocument(fileURL)
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .valid(kind: kind, byteCount: byteCount, sha256: digest)
    }

    private static func detectKind(for url: URL, data: Data) -> ArtifactKind {
        switch url.pathExtension.lowercased() {
        case "docx": return .docx
        case "pptx": return .pptx
        case "pdf": return .pdf
        case "mp4", "mov", "m4a", "mp3", "webm", "mkv": return .media
        case "zip", "tar", "gz", "tgz", "7z": return .download
        default:
            if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
            if data.starts(with: [0x50, 0x4B]) { return .download }
            return .other
        }
    }

    private static func formatIsValid(kind: ArtifactKind, data: Data) -> Bool {
        switch kind {
        case .docx:
            return isZip(data) && containsASCII("[Content_Types].xml", in: data) && containsASCII("word/document.xml", in: data)
        case .pptx:
            return isZip(data) && containsASCII("[Content_Types].xml", in: data) && containsASCII("ppt/presentation.xml", in: data)
        case .pdf:
            return data.starts(with: [0x25, 0x50, 0x44, 0x46]) && containsASCII("%%EOF", in: data)
        case .media, .download:
            return !data.isEmpty
        case .other:
            return false
        }
    }

    private static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(2).elementsEqual([0x50, 0x4B])
    }

    private static func containsASCII(_ string: String, in data: Data) -> Bool {
        data.range(of: Data(string.utf8)) != nil
    }
}
