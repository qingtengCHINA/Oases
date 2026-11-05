import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import Oases_Chat

@MainActor
final class ImageGenerationTests: XCTestCase {
    private let consent = AIDataSharingConsentFixture()

    override func setUp() {
        super.setUp()
        consent.acceptForTest()
    }

    override func tearDown() {
        consent.restore()
        super.tearDown()
    }

    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testImageGenerationPlanUsesOnlyProviderSupportedShapes() {
        let grokLandscape = ImageGenerationPlan.forRequest(
            model: "grok-imagine-image-2.0",
            prompt: "a cinematic city skyline, 16:9"
        )
        XCTAssertEqual(grokLandscape.aspect, .landscape)
        XCTAssertEqual(grokLandscape.requestAspectRatio, "16:9")
        XCTAssertEqual(grokLandscape.requestResolution, "1k")
        XCTAssertEqual(grokLandscape.expectedAspectRatio ?? -1, 16.0 / 9.0, accuracy: 0.0001)

        let grokAutomatic = ImageGenerationPlan.forRequest(
            model: "grok-imagine-image-2.0",
            prompt: "a quiet garden with no canvas instruction"
        )
        XCTAssertNil(grokAutomatic.aspect)
        XCTAssertEqual(grokAutomatic.requestAspectRatio, "auto")
        XCTAssertNil(grokAutomatic.expectedAspectRatio)

        let gptLandscape = ImageGenerationPlan.forRequest(
            model: "gpt-image-1",
            prompt: "a wide poster, 16:9"
        )
        XCTAssertEqual(gptLandscape.requestSize, "1536x1024")
        XCTAssertEqual(gptLandscape.aspect, .photoLandscape)
        XCTAssertEqual(gptLandscape.expectedAspectRatio ?? -1, 1.5, accuracy: 0.0001)

        let gptPortrait = ImageGenerationPlan.forRequest(
            model: "gpt-image-1",
            prompt: "a vertical poster, 9:16"
        )
        XCTAssertEqual(gptPortrait.requestSize, "1024x1536")
        XCTAssertEqual(gptPortrait.aspect, .photoPortrait)
        XCTAssertEqual(gptPortrait.expectedAspectRatio ?? -1, 2.0 / 3.0, accuracy: 0.0001)

        let unsupportedToken = ImageGenerationPlan.forRequest(
            model: "grok-imagine-image-2.0",
            prompt: "do not use an arbitrary 12:34 canvas"
        )
        XCTAssertNil(unsupportedToken.expectedAspectRatio)

        let gemini = ImageGenerationPlan.forRequest(
            model: "gemini-3.1-flash-image",
            prompt: "a portrait, 9:16"
        )
        XCTAssertEqual(gemini.control, .providerSelected)
        XCTAssertNil(gemini.expectedAspectRatio)
    }

    func testGeneratedImageLayoutUsesNaturalAspectWithPortraitHeightCap() {
        XCTAssertEqual(
            GeneratedImageLayout.widthCap(for: 9.0 / 16.0),
            292.5,
            accuracy: 0.01
        )
        XCTAssertEqual(
            GeneratedImageLayout.widthCap(for: 16.0 / 9.0),
            16.0 / 9.0 * 520.0,
            accuracy: 0.01
        )
    }

    func testRenderedWaitingAndCompletedImagesKeepRatioOnPhoneAndIPad() throws {
        let landscapePlan = ImageGenerationPlan.forRequest(
            model: Models.defaultImage,
            prompt: "a cinematic landscape, 16:9"
        )
        let portraitPlan = ImageGenerationPlan.forRequest(
            model: Models.defaultImage,
            prompt: "a vertical poster, 9:16"
        )
        let landscapeImage = fixtureImage(
            size: CGSize(width: 320, height: 180),
            color: .systemBlue
        )
        let portraitImage = fixtureImage(
            size: CGSize(width: 180, height: 320),
            color: .systemOrange
        )

        for width in [CGFloat(320), CGFloat(700)] {
            let waitingLandscape = try XCTUnwrap(
                renderWaiting(plan: landscapePlan, width: width)
            )
            let completedLandscape = try XCTUnwrap(
                renderCompleted(image: landscapeImage, width: width)
            )
            assertRenderedRatio(
                waitingLandscape,
                completedLandscape,
                expected: 16.0 / 9.0,
                label: "landscape width \(width)"
            )

            let waitingPortrait = try XCTUnwrap(
                renderWaiting(plan: portraitPlan, width: width)
            )
            let completedPortrait = try XCTUnwrap(
                renderCompleted(image: portraitImage, width: width)
            )
            assertRenderedRatio(
                waitingPortrait,
                completedPortrait,
                expected: 9.0 / 16.0,
                label: "portrait width \(width)"
            )
        }

        // Keep a deterministic preview for visual review without making a
        // real generation request. ImageRenderer does not run onAppear here,
        // so this fixture captures the initial waiting layout frame.
        if let preview = renderWaiting(plan: landscapePlan, width: 700),
           let data = preview.pngData() {
            try data.write(to: URL(fileURLWithPath: "/tmp/oases-image-waiting-preview.png"))
        } else {
            XCTFail("Could not write image waiting preview")
        }
    }

    func testGeneratedImageLoaderDecodesDataAndFileSourcesAndCaches() async throws {
        let dataURL = "data:image/png;base64,\(onePixelPNG.base64EncodedString())"
        let image = try await GeneratedImageLoader.load(source: dataURL)
        XCTAssertEqual(image.size.width, 1, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 1, accuracy: 0.01)
        XCTAssertNotNil(GeneratedImageLoader.cached(source: dataURL))

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-image-\(UUID().uuidString).png")
        try onePixelPNG.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileImage = try await GeneratedImageLoader.load(source: fileURL.absoluteString)
        XCTAssertEqual(fileImage.size.width, 1, accuracy: 0.01)
        XCTAssertEqual(fileImage.size.height, 1, accuracy: 0.01)
    }

    func testGeneratedImageLoaderValidatesMockHTTPStatusAndCachesSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageLoaderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let successURL = "https://image-loader.test/\(UUID().uuidString).png"

        ImageLoaderURLProtocol.statusCode = 200
        ImageLoaderURLProtocol.responseData = onePixelPNG
        let loaded = try await GeneratedImageLoader.load(source: successURL, session: session)
        XCTAssertEqual(loaded.size.width, 1, accuracy: 0.01)
        XCTAssertNotNil(GeneratedImageLoader.cached(source: successURL))

        ImageLoaderURLProtocol.statusCode = 404
        let failureURL = "https://image-loader.test/\(UUID().uuidString).png"
        do {
            _ = try await GeneratedImageLoader.load(source: failureURL, session: session)
            XCTFail("Expected an HTTP status error")
        } catch let error as GeneratedImageLoaderError {
            XCTAssertEqual(error, .httpStatus(404))
        }
    }

    func testChatServiceSendsGrokControlsAndReturnsMockURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ImageRequestURLProtocol.lastBody = nil

        let client = APIClient(
            baseURL: URL(string: "https://image-request.test/v1")!,
            apiKey: "unit-test-key",
            session: session
        )
        let service = ChatService(imageClient: client)
        let returnedURL = try await service.generateImage(
            prompt: "a cinematic city skyline, 16:9",
            model: Models.defaultImage
        )

        XCTAssertEqual(returnedURL, "https://cdn.image-request.test/generated.png")
        let body = try XCTUnwrap(ImageRequestURLProtocol.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, Models.defaultImage)
        XCTAssertEqual(json["aspect_ratio"] as? String, "16:9")
        XCTAssertEqual(json["resolution"] as? String, "1k")
        XCTAssertEqual(json["response_format"] as? String, "b64_json")
        XCTAssertNil(json["size"], "Grok requests must not use the old size field")
    }

    private func renderWaiting(plan: ImageGenerationPlan, width: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(
            content: GridRevealView(image: nil, plan: plan, caption: nil)
                .frame(width: width, alignment: .leading)
        )
        renderer.scale = 1
        return renderer.uiImage
    }

    private func renderCompleted(image: UIImage, width: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(
            content: FittedGeneratedImage(image: image)
                .frame(width: width, alignment: .leading)
        )
        renderer.scale = 1
        return renderer.uiImage
    }

    private func assertRenderedRatio(
        _ waiting: UIImage,
        _ completed: UIImage,
        expected: CGFloat,
        label: String
    ) {
        guard let waitingBounds = visibleBounds(of: waiting),
              let completedBounds = visibleBounds(of: completed) else {
            XCTFail("No visible pixels for \(label)")
            return
        }
        let waitingRatio = waitingBounds.width / max(waitingBounds.height, 1)
        let completedRatio = completedBounds.width / max(completedBounds.height, 1)
        XCTAssertEqual(waitingRatio, expected, accuracy: 0.12, label)
        XCTAssertEqual(completedRatio, expected, accuracy: 0.12, label)
        XCTAssertEqual(waitingRatio, completedRatio, accuracy: 0.12, label)
        XCTAssertEqual(waitingBounds.width, completedBounds.width, accuracy: 2, label)
        XCTAssertEqual(waitingBounds.height, completedBounds.height, accuracy: 2, label)
        XCTAssertGreaterThan(waitingBounds.width, 1, label)
        XCTAssertGreaterThan(waitingBounds.height, 1, label)
        XCTAssertGreaterThan(completedBounds.width, 1, label)
        XCTAssertGreaterThan(completedBounds.height, 1, label)
    }

    private func fixtureImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func visibleBounds(of image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
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
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                guard alpha > 8 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}

private final class ImageLoaderURLProtocol: URLProtocol {
    static var statusCode = 200
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if (200...299).contains(Self.statusCode) {
            client?.urlProtocol(self, didLoad: Self.responseData)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ImageRequestURLProtocol: URLProtocol {
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody = Self.bodyData(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ),
              let data = "{\"data\":[{\"url\":\"https://cdn.image-request.test/generated.png\"}]}"
                .data(using: .utf8) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return stream.read(baseAddress, maxLength: buffer.count)
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.isEmpty ? nil : data
    }
}
