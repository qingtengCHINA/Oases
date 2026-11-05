import Foundation
import Observation
import UIKit

/// The profile shown on the Profile page and the Settings card: a nickname and an avatar the
/// user picks. Both stay on this device (Application Support and user defaults); nothing is
/// uploaded and the account system is not involved.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    private static let nicknameKey = "profile.nickname"
    /// Longest nickname kept.
    static let nicknameLimit = 24
    /// Side of the stored avatar, in pixels.
    static let avatarSide: CGFloat = 512

    /// Saved as typed; the editor keeps it within `nicknameLimit`.
    var nickname: String {
        didSet { UserDefaults.standard.set(String(nickname.prefix(Self.nicknameLimit)), forKey: Self.nicknameKey) }
    }

    private(set) var avatar: UIImage?

    private init() {
        nickname = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""
        avatar = Self.avatarURL.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// Crops `image` to a centred square, scales it to 512 px and saves it.
    func setAvatar(_ image: UIImage) {
        let square = Self.squared(image, side: Self.avatarSide)
        guard let url = Self.avatarURL, let data = square.jpegData(compressionQuality: 0.88) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            avatar = square
        } catch {
            AppLogger(category: "Profile").error("avatar save failed: \(error.localizedDescription)")
        }
    }

    /// Goes back to the generated avatar.
    func removeAvatar() {
        if let url = Self.avatarURL { try? FileManager.default.removeItem(at: url) }
        avatar = nil
    }

    /// The name to show: the nickname, else a generic one.
    var displayName: String {
        let t = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? String(localized: "Oases 用户", comment: "Profile: name shown before the user sets a nickname") : t
    }

    private static var avatarURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Profile/avatar.jpg")
    }

    private static func squared(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        let edge = min(size.width, size.height)
        let crop = CGRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let target = min(side, edge * image.scale)
        return UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let k = target / edge
            image.draw(in: CGRect(x: -crop.minX * k, y: -crop.minY * k, width: size.width * k, height: size.height * k))
        }
    }
}
