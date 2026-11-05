import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Processes NSExtensionItems from the share sheet, saves files to the shared
/// container, and writes a PendingShare for the main app to consume.
final class ShareViewModel {
    private var pendingItems: [PendingShare.Item] = []
    private let inlineTextLimit = 1000
    /// Longest edge of shared images. Share extensions run under a ~120 MB
    /// memory limit, and a 48 MP photo decoded at full size alone is ~190 MB.
    private static let maxImagePixelSize = 2048
    private static let jpegQuality: CGFloat = 0.85
    /// Per-item cap on `NSItemProvider.loadItem`. A provider that never calls
    /// back must not leave the share sheet spinning forever.
    private static let loadItemTimeout: TimeInterval = 20

    /// Process all extension items from the share context.
    func processExtensionItems(_ extensionItems: [NSExtensionItem]) async {
        pendingItems.removeAll()

        let fm = FileManager.default
        if let dir = SharedContainerStore.sharedFileDirectory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for extensionItem in extensionItems {
            guard let attachments = extensionItem.attachments else { continue }

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    await processURL(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    await processText(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    await processImage(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    await processVideo(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    await processFile(provider)
                }
            }
        }
    }

    /// Save pending share and return true on success.
    /// [T-share-buffer-merge] MERGE with any unconsumed previous share instead
    /// of overwriting it. Rapid consecutive shares (user shares screenshot A,
    /// then B a few seconds later, before the main app ran
    /// processPendingShare) used to silently lose A: this save() replaced the
    /// App Group record wholesale. Attachment file names are UUID-suffixed so
    /// the merged item lists never collide on disk. The 300s window matches
    /// checkForPendingShare's staleness cutoff; anything older is abandoned
    /// content whose files the main app will clean up.
    func save() -> Bool {
        guard !pendingItems.isEmpty else { return false }
        var items = pendingItems
        if let existing = SharedContainerStore.loadPendingShare(),
           Date().timeIntervalSince(existing.timestamp) < 300 {
            NSLog("[ShareExt] save: merging %d existing unconsumed items with %d new",
                  existing.items.count, pendingItems.count)
            items = existing.items + items
        }
        let share = PendingShare(items: items, timestamp: Date())
        SharedContainerStore.savePendingShare(share)
        return true
    }

    // MARK: - Processors

    private func processURL(_ provider: NSItemProvider) async {
        guard let item = await loadItem(provider, type: UTType.url),
              let url = item as? URL else { return }

        // file:// URLs are local files — treat as file attachment, not inline text
        if url.isFileURL {
            await copyFileToShared(from: url)
            return
        }

        pendingItems.append(.init(kind: .inlineText, value: url.absoluteString))
    }

    /// Copy a local file URL to the shared container as an attachment.
    private func copyFileToShared(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // If it's an image, process through image pipeline for JPEG conversion
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext),
           let source = CGImageSourceCreateWithURL(url as CFURL, Self.imageSourceOptions),
           let jpegData = Self.downsampledJPEG(from: source) {
            saveSharedImage(jpegData)
            return
        }

        // General file copy
        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            pendingItems.append(.init(kind: .attachment, value: fileName))
        }
    }

    private func processText(_ provider: NSItemProvider) async {
        guard let item = await loadItem(provider, type: UTType.plainText),
              let text = item as? String else { return }

        if text.count <= inlineTextLimit {
            pendingItems.append(.init(kind: .inlineText, value: text))
        } else {
            let fileName = "shared-text-\(UUID().uuidString.prefix(8)).txt"
            if let dir = SharedContainerStore.sharedFileDirectory {
                let fileURL = dir.appendingPathComponent(fileName)
                try? text.write(to: fileURL, atomically: true, encoding: .utf8)
                pendingItems.append(.init(kind: .attachment, value: fileName))
            }
        }
    }

    private func processImage(_ provider: NSItemProvider) async {
        guard let item = await loadItem(provider, type: UTType.image) else { return }
        // Downsample from the encoded bytes / file with ImageIO wherever
        // possible instead of decoding the full-size bitmap.
        let jpegData: Data?
        if let uiImage = item as? UIImage {
            jpegData = Self.downsampledJPEG(from: uiImage)
        } else if let imageData = item as? Data,
                  let source = CGImageSourceCreateWithData(imageData as CFData, Self.imageSourceOptions) {
            jpegData = Self.downsampledJPEG(from: source)
        } else if let url = item as? URL {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            jpegData = CGImageSourceCreateWithURL(url as CFURL, Self.imageSourceOptions)
                .flatMap { Self.downsampledJPEG(from: $0) }
        } else {
            jpegData = nil
        }
        if let jpegData { saveSharedImage(jpegData) }
    }

    private func saveSharedImage(_ jpegData: Data) {
        let fileName = "shared-image-\(UUID().uuidString.prefix(8)).jpg"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let fileURL = dir.appendingPathComponent(fileName)
            try? jpegData.write(to: fileURL)
            pendingItems.append(.init(kind: .attachment, value: fileName))
        }
    }

    private func processVideo(_ provider: NSItemProvider) async {
        guard let item = await loadItem(provider, type: UTType.movie),
              let url = item as? URL else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let suffix = ext.isEmpty ? "mov" : ext
        let fileName = "shared-video-\(UUID().uuidString.prefix(8)).\(suffix)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            pendingItems.append(.init(kind: .attachment, value: fileName))
        }
    }

    private func processFile(_ provider: NSItemProvider) async {
        guard let item = await loadItem(provider, type: UTType.item),
              let url = item as? URL else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            pendingItems.append(.init(kind: .attachment, value: fileName))
        }
    }

    // MARK: - Helpers

    /// `loadItem` with a timeout. Returns nil on error or when the provider
    /// hasn't called back within `loadItemTimeout`.
    private func loadItem(_ provider: NSItemProvider, type: UTType) async -> NSSecureCoding? {
        let box: LoadedItem = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { NSLog("[ShareExt] loadItem(%@) failed: %@", type.identifier, error.localizedDescription) }
                if once.claim() { continuation.resume(returning: LoadedItem(value: item)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.loadItemTimeout) {
                if once.claim() {
                    NSLog("[ShareExt] loadItem(%@) timed out after %.0fs — skipping", type.identifier, Self.loadItemTimeout)
                    continuation.resume(returning: LoadedItem(value: nil))
                }
            }
        }
        return box.value
    }

    private static var imageSourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    /// Longest edge ≤ `maxImagePixelSize`, EXIF orientation applied, JPEG.
    private static func downsampledJPEG(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// For providers that hand over an already-decoded `UIImage`.
    private static func downsampledJPEG(from image: UIImage) -> Data? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > CGFloat(maxImagePixelSize) else {
            return image.jpegData(compressionQuality: jpegQuality)
        }
        let ratio = CGFloat(maxImagePixelSize) / longest
        let target = CGSize(width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}

/// Carries a loaded item across the completion-handler → async boundary.
private struct LoadedItem: @unchecked Sendable {
    let value: NSSecureCoding?
}

/// First caller wins — the provider callback or the timeout, never both.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
