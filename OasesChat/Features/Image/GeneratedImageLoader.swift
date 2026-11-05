import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum GeneratedImageLoaderError: Error, LocalizedError, Equatable, Sendable {
    case invalidSource
    case unsupportedScheme(String)
    case httpStatus(Int)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidSource: return String(localized: "图片地址无效")
        case .unsupportedScheme(let scheme): return String(localized: "不支持的图片地址类型：\(scheme)")
        case .httpStatus(let status): return String(localized: "图片服务器返回错误（\(status)）")
        case .invalidImage: return String(localized: "图片数据无效")
        }
    }
}

/// One image source implementation shared by the chat bubble, full-screen
/// viewer and conversation exports. The cache
/// lives on the main actor because UIKit images are UI values; fetching,
/// base64 decoding and bitmap decoding run off the main actor.
@MainActor
enum GeneratedImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func cached(source: String) -> UIImage? {
        guard !source.isEmpty else { return nil }
        return cache.object(forKey: source as NSString)
    }

    static func load(source: String) async throws -> UIImage {
        try await load(source: source, session: URLSession.shared)
    }

    /// Transport-injectable overload used by unit tests. The app-facing
    /// contract above remains the single-argument method.
    static func load(source: String, session: URLSession) async throws -> UIImage {
        guard !source.isEmpty else { throw GeneratedImageLoaderError.invalidSource }
        if let image = cached(source: source) { return image }

        let data = try await data(for: source, session: session)
        try Task.checkCancellation()
        guard let image = await decodedImage(from: data) else {
            throw GeneratedImageLoaderError.invalidImage
        }
        try Task.checkCancellation()
        let decodedCost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(image, forKey: source as NSString, cost: decodedCost)
        return image
    }

    /// Converts a valid image source into a durable data URL. Provider image
    /// URLs can expire shortly after generation; callers can retain the
    /// original URL when this method returns nil and expose a retry affordance
    /// instead of replacing a successfully generated result with an error.
    static func materializedDataURL(source: String) async -> String? {
        if source.lowercased().hasPrefix("data:") {
            return (try? await load(source: source)) == nil ? nil : source
        }
        // Keep the provider's original bytes (PNG / JPEG / WebP) instead of
        // decoding and re-encoding to PNG, which bloated the stored message
        // 3–6× and ran on the main actor.
        guard let data = try? await data(for: source, session: URLSession.shared) else {
            return nil
        }
        return await dataURL(forImageData: data)
    }

    /// Decodes and pre-renders the bitmap off the main actor, so neither the
    /// base64 payload nor the first draw decodes a large image on the UI
    /// thread.
    nonisolated private static func decodedImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image.preparingForDisplay() ?? image
        }.value
    }

    /// `data:<mime>;base64,…` for bytes that ImageIO recognises as an image
    /// with real dimensions; nil otherwise.
    nonisolated private static func dataURL(forImageData data: Data) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let typeIdentifier = CGImageSourceGetType(source) as String?,
                  let mime = UTType(typeIdentifier)?.preferredMIMEType,
                  mime.hasPrefix("image/"),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
                return nil
            }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }.value
    }

    nonisolated private static func data(for source: String, session: URLSession) async throws -> Data {
        if source.lowercased().hasPrefix("data:") {
            return try decodeDataURL(source)
        }

        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            throw GeneratedImageLoaderError.invalidSource
        }
        switch scheme {
        case "file":
            do {
                return try Data(contentsOf: url)
            } catch {
                throw GeneratedImageLoaderError.invalidSource
            }
        case "http", "https":
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw GeneratedImageLoaderError.httpStatus(http.statusCode)
            }
            return data
        default:
            throw GeneratedImageLoaderError.unsupportedScheme(scheme)
        }
    }

    nonisolated private static func decodeDataURL(_ source: String) throws -> Data {
        guard let comma = source.firstIndex(of: ",") else {
            throw GeneratedImageLoaderError.invalidSource
        }
        let header = String(source[..<comma]).lowercased()
        let rawPayload = String(source[source.index(after: comma)...])
        if header.contains(";base64") {
            let payload = rawPayload
                .removingPercentEncoding?
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "") ?? rawPayload
            guard let data = Data(base64Encoded: payload) else {
                throw GeneratedImageLoaderError.invalidSource
            }
            return data
        }
        guard let decoded = rawPayload.removingPercentEncoding,
              let data = decoded.data(using: .utf8) else {
            throw GeneratedImageLoaderError.invalidSource
        }
        return data
    }
}
