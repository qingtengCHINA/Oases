import XCTest
@testable import Oases_Chat

final class ArtifactValidatorTests: XCTestCase {
    func testDocxRequiresOpenXMLEntriesAndProducesDigest() throws {
        let url = temporaryURL("result.docx")
        let bytes = Data("PK\\u{03}\\u{04}[Content_Types].xml word/document.xml".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ArtifactValidator.validate(fileURL: url, expectedKind: .docx)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedKind, .docx)
        XCTAssertEqual(result.byteCount, Int64(bytes.count))
        XCTAssertEqual(result.sha256?.count, 64)
    }

    func testArtifactStoreRejectsEmptyFiles() throws {
        let url = temporaryURL("empty.pdf")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ArtifactValidator.validate(fileURL: url, expectedKind: .pdf)) { error in
            XCTAssertEqual(error as? ArtifactValidationError, .emptyFile(url))
        }
    }

    private func temporaryURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oases-\(UUID().uuidString)-\(filename)")
    }
}
