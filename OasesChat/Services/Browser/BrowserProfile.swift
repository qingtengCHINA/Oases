import CryptoKit
import Foundation

/// A stable browser data boundary for one workspace. The identifier is not a
/// secret; it only scopes WebKit website data on this device.
struct BrowserProfile: Codable, Hashable, Sendable, Identifiable {
    let workspaceID: String
    let id: String
    let displayName: String
    let storageIdentifier: UUID

    init(workspaceID: String) {
        let normalized = workspaceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let value = normalized.isEmpty ? "project" : String(normalized.prefix(48))
        self.workspaceID = value
        self.id = "dev.oases.chat.browser.\(value)"
        self.displayName = "Ogent \(value)"
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        self.storageIdentifier = UUID(uuidString: "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-4\(digest.dropFirst(13).prefix(3))-8\(digest.dropFirst(16).prefix(3))-\(digest.dropFirst(19).prefix(12))") ?? UUID()
    }
}
