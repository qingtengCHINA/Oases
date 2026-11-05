import XCTest
import UIKit
import SwiftUI
@testable import Oases_Chat

@MainActor
final class ShareCardImageTests: XCTestCase {
    func testBuilderKeepsMediaOnlyMessagesAndAttachmentOrder() {
        let first = fixtureSource(width: 320, height: 160, color: UIColor(red: 0.08, green: 0.38, blue: 0.90, alpha: 1))
        let second = fixtureSource(width: 160, height: 320, color: UIColor(red: 0.95, green: 0.35, blue: 0.08, alpha: 1))
        let attachmentA = Attachment(name: "first.png", mimeType: "image/png", kind: .image, dataUrl: first)
        let attachmentB = Attachment(name: "second.png", mimeType: "image/png", kind: .image, dataUrl: second)
        let user = ChatUIMessage(
            id: "user-images",
            role: .user,
            content: "",
            thinking: nil,
            createdAt: .now,
            imageUrl: nil,
            audioUrl: nil,
            audioMimeType: nil,
            attachments: [attachmentA, attachmentB]
        )
        let assistant = ChatUIMessage(
            id: "assistant-image",
            role: .assistant,
            content: "",
            thinking: nil,
            createdAt: .now,
            imageUrl: second,
            audioUrl: nil,
            audioMimeType: nil,
            attachments: nil
        )

        let model = ShareCardBuilder.make(
            messages: [user, assistant],
            conversationTitle: nil,
            generatedAt: .now
        )

        XCTAssertEqual(model.messages.map(\.id), ["user-images", "assistant-image"])
        XCTAssertEqual(model.messages[0].media.map(\.source), [first, second])
        XCTAssertEqual(model.messages[1].media.map(\.source), [second])
        XCTAssertTrue(model.messages.allSatisfy { $0.text.isEmpty })
    }

    func testStreamingPendingMessageIsFilteredButCompletedMediaOnlyMessageIsShareable() {
        var pending = ChatUIMessage.assistantPlaceholder(content: "正在生成图片…")
        pending.isStreaming = true
        let completed = ChatUIMessage(
            id: "completed-media",
            role: .assistant,
            content: "",
            thinking: nil,
            createdAt: .now,
            imageUrl: fixtureSource(width: 64, height: 64, color: .purple),
            audioUrl: nil,
            audioMimeType: nil,
            attachments: nil
        )

        let model = ShareCardBuilder.make(
            messages: [pending, completed],
            conversationTitle: nil,
            generatedAt: .now
        )

        XCTAssertEqual(model.messages.map(\.id), ["completed-media"])
    }

    func testRendererContainsLandscapeAndPortraitFixturePixelsAndWritesPreview() async throws {
        let blue = UIColor(red: 0.08, green: 0.38, blue: 0.90, alpha: 1)
        let orange = UIColor(red: 0.95, green: 0.35, blue: 0.08, alpha: 1)
        let landscapeSource = fixtureSource(width: 320, height: 160, color: blue)
        let portraitSource = fixtureSource(width: 160, height: 320, color: orange)
        let model = ShareCardModel(
            brandName: "Oases",
            conversationTitle: "图片分享测试",
            generatedAt: .now,
            omittedMessageCount: 0,
            messages: [
                ShareCardMessage(
                    id: "landscape",
                    role: .assistant,
                    text: "横向图片",
                    media: [ShareCardMedia(id: "landscape-image", source: landscapeSource, caption: nil)]
                ),
                ShareCardMessage(
                    id: "portrait",
                    role: .user,
                    text: "竖向图片",
                    media: [ShareCardMedia(id: "portrait-image", source: portraitSource, caption: nil)]
                )
            ]
        )
        let blueImage = try await GeneratedImageLoader.load(source: landscapeSource)
        let orangeImage = try await GeneratedImageLoader.load(source: portraitSource)

        guard let rendered = ShareCardRenderer.render(
            model: model,
            resolvedImages: [landscapeSource: blueImage, portraitSource: orangeImage]
        ) else {
            XCTFail("Share card did not render")
            return
        }

        XCTAssertTrue(containsColor(blue, in: rendered), "Rendered card does not contain the landscape fixture")
        XCTAssertTrue(containsColor(orange, in: rendered), "Rendered card does not contain the portrait fixture")
        let previewURL = URL(fileURLWithPath: "/tmp/oases-share-image-preview.png")
        try XCTUnwrap(rendered.pngData()).write(to: previewURL)
    }

    func testRendererRefusesUnresolvedMedia() {
        let source = fixtureSource(width: 64, height: 64, color: .systemPink)
        let model = ShareCardModel(
            brandName: "Oases",
            conversationTitle: nil,
            generatedAt: .now,
            omittedMessageCount: 0,
            messages: [
                ShareCardMessage(
                    id: "missing",
                    role: .assistant,
                    text: "图片",
                    media: [ShareCardMedia(id: "missing-image", source: source, caption: "missing.png")]
                )
            ]
        )

        XCTAssertNil(ShareCardRenderer.render(model: model))
    }

    func testImageResolutionFailureIsExplicitAndDoesNotExposeSource() async {
        let source = "data:image/png;base64,not-a-real-image"
        let model = ShareCardModel(
            brandName: "Oases",
            conversationTitle: nil,
            generatedAt: .now,
            omittedMessageCount: 0,
            messages: [
                ShareCardMessage(
                    id: "bad",
                    role: .assistant,
                    text: "图片",
                    media: [ShareCardMedia(id: "bad-image", source: source, caption: "bad.png")]
                )
            ]
        )

        do {
            _ = try await ShareCardImageResolver.resolve(model: model)
            XCTFail("Invalid image source should fail before export")
        } catch let error as ShareCardImageResolutionError {
            let caption = "bad.png"
            XCTAssertEqual(error.errorDescription, String(localized: "图片“\(caption)”未能加载，请检查网络后重试"))
            XCTAssertFalse(error.localizedDescription.contains(source))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func fixtureSource(width: CGFloat, height: CGFloat, color: UIColor) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        return "data:image/png;base64,\(image.pngData()!.base64EncodedString())"
    }

    private func containsColor(_ color: UIColor, in image: UIImage) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              let cgImage = image.cgImage else { return false }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let expected = SIMD3<Float>(Float(red), Float(green), Float(blue))
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let actual = SIMD3<Float>(
                Float(pixels[index]) / 255,
                Float(pixels[index + 1]) / 255,
                Float(pixels[index + 2]) / 255
            )
            if abs(actual.x - expected.x) < 0.04,
               abs(actual.y - expected.y) < 0.04,
               abs(actual.z - expected.z) < 0.04 {
                return true
            }
        }
        return false
    }
}
