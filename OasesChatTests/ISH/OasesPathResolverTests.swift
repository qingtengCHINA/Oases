import XCTest
@testable import Oases_Chat

final class OasesPathResolverTests: XCTestCase {
    func testNormalizeAbsoluteOasesPath() {
        XCTAssertEqual(
            OasesPathResolver.normalizeGuestPath("/var/oases/workspace/a.py"),
            "/var/oases/workspace/a.py"
        )
    }

    func testNormalizeMinisAlias() {
        XCTAssertEqual(
            OasesPathResolver.normalizeGuestPath("/var/minis/workspace/x.md"),
            "/var/oases/workspace/x.md"
        )
    }

    func testNormalizeRelativeToWorkspace() {
        XCTAssertEqual(
            OasesPathResolver.normalizeGuestPath("notes/todo.md"),
            "/var/oases/workspace/notes/todo.md"
        )
    }

    func testRejectTraversal() {
        XCTAssertNil(OasesPathResolver.normalizeGuestPath("../etc/passwd"))
        XCTAssertNil(OasesPathResolver.normalizeGuestPath("/var/oases/../etc/passwd"))
    }

    func testOasesURL() {
        let url = OasesPathResolver.oasesURL(forGuest: "/var/oases/workspace/hi.txt")
        XCTAssertEqual(url, "oases://workspace/hi.txt")
    }

    func testHostURLUnderDataTree() {
        let host = OasesPathResolver.hostURL(forGuest: "/var/oases/workspace/a.txt")
        XCTAssertNotNil(host)
        XCTAssertTrue(host!.path.contains("var/oases/workspace/a.txt")
            || host!.path.hasSuffix("var/oases/workspace/a.txt"))
    }
}
