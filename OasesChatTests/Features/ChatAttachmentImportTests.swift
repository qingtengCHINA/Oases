import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Oases_Chat

/// Composer attachment import: images are downsampled and re-encoded so the
/// MIME type matches the bytes; text extraction is capped.
final class ChatAttachmentImportTests: XCTestCase {
    func testLargeImageIsDownsampledToTheLongEdgeBound() throws {
        let png = try encode(makeImage(width: 4000, height: 3000, alpha: false), as: .png)

        let prepared = try XCTUnwrap(AttachmentImporter.prepareImage(data: png))

        XCTAssertEqual(max(prepared.pixelWidth, prepared.pixelHeight), AttachmentImporter.maxImagePixelSize)
        XCTAssertEqual(prepared.pixelWidth, 2048)
        XCTAssertEqual(prepared.pixelHeight, 1536)
        let decoded = try decodedSize(prepared.data)
        XCTAssertEqual(decoded.width, 2048)
        XCTAssertEqual(decoded.height, 1536)
    }

    func testSmallImageIsNotUpscaled() throws {
        let png = try encode(makeImage(width: 300, height: 200, alpha: false), as: .png)
        let prepared = try XCTUnwrap(AttachmentImporter.prepareImage(data: png))
        XCTAssertEqual(prepared.pixelWidth, 300)
        XCTAssertEqual(prepared.pixelHeight, 200)
    }

    func testHEICIsReencodedAsJPEGWithMatchingMIME() throws {
        let heic: Data
        do {
            heic = try encode(makeImage(width: 640, height: 480, alpha: false), as: .heic)
        } catch {
            throw XCTSkip("HEIC encoding is not available on this simulator")
        }

        let attachment = try XCTUnwrap(AttachmentImporter.makeImageAttachment(data: heic, name: "IMG_0001.HEIC"))

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.name, "IMG_0001.jpg")
        let dataURL = try XCTUnwrap(attachment.dataUrl)
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
        let bytes = try XCTUnwrap(Data(base64Encoded: String(dataURL.dropFirst("data:image/jpeg;base64,".count))))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF], "payload must be JPEG, as its MIME says")
    }

    func testTransparentPNGBecomesOpaqueJPEG() throws {
        let png = try encode(makeImage(width: 64, height: 64, alpha: true), as: .png)
        let prepared = try XCTUnwrap(AttachmentImporter.prepareImage(data: png))
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(Array(prepared.data.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testEXIFOrientationIsApplied() throws {
        // 400×200 pixels tagged "rotate 90° CW" (EXIF 6) displays as 200×400.
        let jpeg = try encode(
            makeImage(width: 400, height: 200, alpha: false),
            as: .jpeg,
            properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue]
        )
        let prepared = try XCTUnwrap(AttachmentImporter.prepareImage(data: jpeg))
        XCTAssertEqual(prepared.pixelWidth, 200)
        XCTAssertEqual(prepared.pixelHeight, 400)
    }

    func testCameraImageGoesThroughTheSamePipeline() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 4000), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        }
        let attachment = try XCTUnwrap(AttachmentImporter.makeImageAttachment(image: photo, name: "image-1.jpg"))
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.name, "image-1.jpg")
        let chip = try XCTUnwrap(AttachmentImageCache.thumbnail(for: attachment))
        XCTAssertLessThanOrEqual(max(chip.size.width, chip.size.height), CGFloat(AttachmentImageCache.thumbnailPixelSize))
        AttachmentImageCache.evict(attachment.id)
    }

    func testUndecodableBytesAreRejected() {
        XCTAssertNil(AttachmentImporter.makeImageAttachment(data: Data("not an image".utf8), name: "x.png"))
    }

    func testTextFileIsCappedAndSurvivesASplitMultibyteCharacter() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkgc-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        // Three-byte characters, so the byte limit lands mid-character.
        let text = String(repeating: "汉", count: AttachmentImporter.maxTextBytes / 3 + 10) + "x"
        try Data(text.utf8).write(to: url)

        let attachment = AttachmentImporter.makeAttachment(fromFileAt: url)

        XCTAssertEqual(attachment.kind, .text)
        let content = try XCTUnwrap(attachment.textContent)
        XCTAssertEqual(content.count, AttachmentImporter.maxTextCharacters)
        XCTAssertTrue(content.allSatisfy { $0 == "汉" })
    }

    func testNonUTF8TextFileFallsBackToFileChip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkgc-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0xC3]).write(to: url)

        let attachment = AttachmentImporter.makeAttachment(fromFileAt: url)

        XCTAssertEqual(attachment.kind, .file)
        XCTAssertNil(attachment.textContent)
    }

    // MARK: - Helpers

    private func makeImage(width: Int, height: Int, alpha: Bool) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    private func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.featureUnsupported) }
        return output as Data
    }

    private func decodedSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }
}

/// Search result highlighting must index the string it searched.
final class SearchSnippetTests: XCTestCase {
    func testHighlightAfterLengthChangingLowercaseCharacters() throws {
        // "İ".lowercased() is two scalars; the old code used a range from the
        // lowercased copy to index the original and crashed / misaligned.
        let text = "İİİİ İstanbul Kelvin \u{212A} hello World"
        let parts = try XCTUnwrap(SearchSnippet.split(text, query: "hello world"))
        XCTAssertEqual(parts.match, "hello World")
        XCTAssertEqual(parts.before, "İİİİ İstanbul Kelvin \u{212A} ")
        XCTAssertEqual(parts.after, "")
    }

    func testCaseInsensitiveMatchOnSpecialCharacter() throws {
        let parts = try XCTUnwrap(SearchSnippet.split("前缀 İstanbul 后缀", query: "istanbul"))
        XCTAssertEqual(parts.match, "İstanbul")
        XCTAssertEqual(parts.before, "前缀 ")
        XCTAssertEqual(parts.after, " 后缀")
    }

    func testContextIsTrimmedAndMissesReturnNil() throws {
        let text = String(repeating: "a", count: 50) + "NEEDLE" + String(repeating: "b", count: 100)
        let parts = try XCTUnwrap(SearchSnippet.split(text, query: "needle"))
        XCTAssertEqual(parts.before.count, 30)
        XCTAssertEqual(parts.match, "NEEDLE")
        XCTAssertEqual(parts.after.count, 60)
        XCTAssertNil(SearchSnippet.split(text, query: "absent"))
        XCTAssertNil(SearchSnippet.split(text, query: ""))
    }
}

/// Share card bounds: image count and output bitmap size.
@MainActor
final class ShareCardLimitsTests: XCTestCase {
    func testBuilderKeepsOnlyTheNewestImages() {
        let messages = (0..<10).map { index in
            ChatUIMessage(
                id: "m\(index)",
                role: .user,
                content: "",
                thinking: nil,
                createdAt: .now,
                imageUrl: nil,
                audioUrl: nil,
                audioMimeType: nil,
                attachments: [Attachment(
                    name: "\(index).jpg",
                    mimeType: "image/jpeg",
                    kind: .image,
                    dataUrl: "data:image/jpeg;base64,source\(index)"
                )]
            )
        }

        let model = ShareCardBuilder.make(messages: messages, conversationTitle: nil, generatedAt: .now)

        XCTAssertEqual(model.mediaItems.count, ShareCardBuilder.maxImages)
        XCTAssertEqual(model.messages.map(\.id), (2..<10).map { "m\($0)" })
        XCTAssertEqual(model.omittedMessageCount, 2)
    }

    func testRenderScaleStaysWithinThePixelBudget() {
        XCTAssertEqual(ShareCardRenderer.renderScale(for: CGSize(width: 420, height: 1_000), screenScale: 3), 3)
        let tall = ShareCardRenderer.renderScale(for: CGSize(width: 420, height: 12_000), screenScale: 3)
        XCTAssertLessThan(tall, 3)
        XCTAssertLessThanOrEqual(420 * 12_000 * tall * tall, 16_000_001)
        XCTAssertEqual(ShareCardRenderer.renderScale(for: CGSize(width: 420, height: 1_000_000), screenScale: 3), 1)
    }
}
