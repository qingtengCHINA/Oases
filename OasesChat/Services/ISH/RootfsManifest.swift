import CryptoKit
import Foundation

struct RootfsManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let alpineVersion: String
    let architecture: String
    let files: [String: String]
    let runtimeOverlayVersion: Int
    /// Bumped by `scripts/rootfs/build_alpine_fakefs.sh` whenever the bundled
    /// package set changes; absent (v1) on the original base-only rootfs.
    var rootfsVersion: Int? = nil
    /// The bundled `/etc/apk/world`.
    var packages: [String]? = nil

    var effectiveRootfsVersion: Int { rootfsVersion ?? 1 }

    static func load(from rootURL: URL) -> RootfsManifest? {
        let url = rootURL.appendingPathComponent("rootfs-manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RootfsManifest.self, from: data)
    }

    enum VerificationError: LocalizedError, Equatable {
        case invalidSchema
        case unsupportedArchitecture(String)
        case invalidPath(String)
        case missingFile(String)
        case symlinkNotAllowed(String)
        case hashMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidSchema: return String(localized: "Rootfs manifest schema 无效", comment: "Linux rootfs verification error: the manifest file has an invalid schema")
            case .unsupportedArchitecture(let value): return String(localized: "Rootfs architecture 不支持：\(value)", comment: "Linux rootfs verification error: CPU architecture not supported; value is the architecture name")
            case .invalidPath(let path): return String(localized: "Rootfs manifest 路径无效：\(path)", comment: "Linux rootfs verification error: a path listed in the manifest is invalid")
            case .missingFile(let path): return String(localized: "Rootfs manifest 文件缺失：\(path)", comment: "Linux rootfs verification error: a file listed in the manifest is missing")
            case .symlinkNotAllowed(let path): return String(localized: "Rootfs manifest 禁止符号链接：\(path)", comment: "Linux rootfs verification error: a manifest entry is a symbolic link, which is not allowed")
            case .hashMismatch(let path): return String(localized: "Rootfs manifest hash 不匹配：\(path)", comment: "Linux rootfs verification error: a file's hash does not match the manifest")
            }
        }
    }

    func verify(bundleRoot: URL, fileManager: FileManager = .default) throws {
        guard schemaVersion >= 1, !alpineVersion.isEmpty, !files.isEmpty else {
            throw VerificationError.invalidSchema
        }
        guard architecture == "aarch64" else {
            throw VerificationError.unsupportedArchitecture(architecture)
        }

        for (relativePath, expectedHash) in files {
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw VerificationError.invalidPath(relativePath)
            }
            let fileURL = bundleRoot.appendingPathComponent(relativePath).standardizedFileURL
            let rootPath = bundleRoot.standardizedFileURL.path
            guard fileURL.path == rootPath || fileURL.path.hasPrefix(rootPath + "/") else {
                throw VerificationError.invalidPath(relativePath)
            }
            var directory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &directory), !directory.boolValue else {
                throw VerificationError.missingFile(relativePath)
            }
            guard (try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) == nil else {
                throw VerificationError.symlinkNotAllowed(relativePath)
            }
            let actualHash = try Self.sha256(fileURL)
            guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw VerificationError.hashMismatch(relativePath)
            }
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
