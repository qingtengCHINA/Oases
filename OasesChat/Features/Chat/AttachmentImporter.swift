import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Import pipeline for composer attachments (photos, camera captures, picked
/// files). Every function here is blocking and thread-agnostic — callers run
/// it off the main actor (`Task.detached`) so a 48 MP HEIC or an 80-page PDF
/// never stalls the UI.
enum AttachmentImporter {
    /// Longest edge, in pixels, of an image attachment sent to the model and
    /// stored with the message. A 48 MP original would otherwise become a
    /// ~27 MB base64 string in the request body and in SwiftData.
    static let maxImagePixelSize = 2048
    static let jpegQuality: CGFloat = 0.85
    /// Text kept per attachment. `composeWireContent` sends at most this many
    /// characters, so capping at import changes nothing on the wire — it only
    /// stops megabytes of unused text from being held and persisted.
    static let maxTextCharacters = 80_000
    /// Bytes read from a text file (UTF-8 is at most 4 bytes per character).
    static let maxTextBytes = maxTextCharacters * 4
    /// Pages read from a PDF.
    static let maxPDFPages = 80

    struct PreparedImage: Sendable, Equatable {
        let data: Data
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int

        var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    }

    // MARK: - Images

    /// Downsamples encoded image bytes of any ImageIO format (HEIC, PNG, WebP,
    /// JPEG, GIF…) to at most `maxPixelSize` on the long edge with the EXIF
    /// orientation applied, then re-encodes as JPEG so the declared MIME type
    /// always matches the bytes. The full-resolution bitmap is never decoded.
    static func prepareImage(data: Data, maxPixelSize: Int = maxImagePixelSize) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return prepareImage(source: source, maxPixelSize: maxPixelSize)
    }

    /// Same pipeline, reading the file lazily instead of loading it whole.
    static func prepareImage(fileURL: URL, maxPixelSize: Int = maxImagePixelSize) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        return prepareImage(source: source, maxPixelSize: maxPixelSize)
    }

    /// Same pipeline for an in-memory photo (camera capture). Drawing applies
    /// `imageOrientation`, so the output is upright.
    static func prepareImage(image: UIImage, maxPixelSize: Int = maxImagePixelSize) -> PreparedImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > 0 else { return nil }
        let ratio = min(1, CGFloat(maxPixelSize) / longEdge)
        let target = CGSize(
            width: max(1, (pixelWidth * ratio).rounded(.down)),
            height: max(1, (pixelHeight * ratio).rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return encodeJPEG(cgImage)
    }

    /// Image attachment ready for the composer, or nil when the bytes aren't
    /// a decodable image.
    static func makeImageAttachment(data: Data, name: String) -> Attachment? {
        prepareImage(data: data).map { imageAttachment($0, name: name) }
    }

    static func makeImageAttachment(image: UIImage, name: String) -> Attachment? {
        prepareImage(image: image).map { imageAttachment($0, name: name) }
    }

    /// The chip shows the file name; after re-encoding it should say `.jpg`.
    static func jpegFileName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" { return name }
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return "\(base.isEmpty ? "image" : base).jpg"
    }

    /// Decodes a data URL's image at most `maxPixelSize` on the long edge —
    /// used for 22–26 pt chips and the preview sheet, so neither has to hold
    /// the full bitmap.
    static func decodeImage(dataURL: String, maxPixelSize: Int) -> UIImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]),
                              options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions(maxPixelSize: maxPixelSize)
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func imageAttachment(_ prepared: PreparedImage, name: String) -> Attachment {
        Attachment(
            name: jpegFileName(for: name),
            mimeType: prepared.mimeType,
            kind: .image,
            dataUrl: prepared.dataURL
        )
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes the EXIF orientation into the pixels.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
    }

    private static func prepareImage(source: CGImageSource, maxPixelSize: Int) -> PreparedImage? {
        guard CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions(maxPixelSize: maxPixelSize)
              ) else { return nil }
        return encodeJPEG(cgImage)
    }

    private static func encodeJPEG(_ image: CGImage) -> PreparedImage? {
        let opaque = flattenedOnWhite(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            opaque,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(
            data: output as Data,
            mimeType: "image/jpeg",
            pixelWidth: opaque.width,
            pixelHeight: opaque.height
        )
    }

    /// JPEG has no alpha channel; ImageIO would turn transparent pixels
    /// (PNG screenshots, stickers) black. Composite them onto white instead.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    // MARK: - Files

    /// Turns a picked file into an attachment: images go through the image
    /// pipeline, PDFs / RTF / text-like files are extracted to capped text,
    /// anything else becomes a name + MIME chip. Handles the security scope
    /// itself.
    static func makeAttachment(fromFileAt url: URL) -> Attachment {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        if mime.hasPrefix("image/") {
            if let prepared = prepareImage(fileURL: url) {
                return imageAttachment(prepared, name: name)
            }
            return Attachment(name: name, mimeType: mime, kind: .file)
        }

        // PDFs: extract the text with PDFKit so the model receives the
        // document body, not a "[文件附件: foo.pdf]" sentinel it then
        // answers "我无法读取" to.
        if mime == "application/pdf" || ext == "pdf" {
            if let extracted = extractPDFText(from: url), !extracted.isEmpty {
                return Attachment(name: name, mimeType: mime, kind: .text, textContent: extracted)
            }
            // Image-only / encrypted PDFs fall through to a file chip.
        }

        // RTF — NSAttributedString ships an RTF parser on iOS. (.docx / .doc
        // are macOS-only and fall through to the binary path.)
        if ext == "rtf" {
            if let extracted = extractAttributedText(from: url, ext: ext), !extracted.isEmpty {
                return Attachment(name: name, mimeType: mime, kind: .text, textContent: extracted)
            }
        }

        if isTextLike(name: name, mime: mime), let text = readUTF8Prefix(of: url) {
            return Attachment(name: name, mimeType: mime, kind: .text, textContent: text)
        }

        return Attachment(name: name, mimeType: mime, kind: .file)
    }

    /// Extracts PDF text, up to `maxPDFPages` pages / `maxTextCharacters`.
    /// Returns nil if the document fails to open; empty when every page is
    /// image-only.
    static func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var buffer = ""
        var characters = 0
        for index in 0..<min(document.pageCount, maxPDFPages) {
            guard let text = document.page(at: index)?.string else { continue }
            if !buffer.isEmpty { buffer += "\n\n" }
            buffer += text
            characters += text.count + 2
            if characters >= maxTextCharacters { break }
        }
        return capped(buffer)
    }

    /// Plain text of an .rtf file via NSAttributedString, capped.
    static func extractAttributedText(from url: URL, ext: String) -> String? {
        let docType: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .plain
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: docType]
        guard let attributed = try? NSAttributedString(url: url, options: options, documentAttributes: nil) else {
            return nil
        }
        return capped(attributed.string)
    }

    static func isTextLike(name: String, mime: String) -> Bool {
        if mime.hasPrefix("text/") { return true }
        let textExts: Set<String> = ["md", "txt", "json", "csv", "ts", "tsx", "js", "jsx",
                                      "html", "css", "xml", "yaml", "yml", "swift", "py", "go", "rs"]
        let ext = (name as NSString).pathExtension.lowercased()
        return textExts.contains(ext)
    }

    /// Reads at most `maxTextBytes` of a UTF-8 file. Returns nil for data
    /// that isn't UTF-8 (the file then becomes a binary chip, as before).
    static func readUTF8Prefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxTextBytes) ?? Data()
        } catch {
            return nil
        }
        return decodeUTF8Prefix(data, truncated: data.count >= maxTextBytes).map(capped)
    }

    /// UTF-8 decode. When the read limit cut the file short, a multi-byte
    /// character split at the end is dropped (up to 3 trailing bytes)
    /// instead of failing the whole decode.
    static func decodeUTF8Prefix(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated, !data.isEmpty else { return nil }
        for trim in 1...min(3, data.count) {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    static func capped(_ text: String) -> String {
        text.count > maxTextCharacters ? String(text.prefix(maxTextCharacters)) : text
    }
}
