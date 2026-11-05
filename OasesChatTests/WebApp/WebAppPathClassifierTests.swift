import XCTest
@testable import Oases_Chat

/// The classifier's scope roots were the main thing that changed when porting
/// `WebApp/` — OpenMinis reads them off `AIChatViewModel` statics over its
/// `Library/MinisChat/minis/<sid>/` tree, OasesChat off `OasesFsRouter` and the
/// App Group. A wrong root silently produces a pinned tile that can never
/// resolve, so these pin the mapping.
@MainActor
final class WebAppPathClassifierTests: XCTestCase {

    private var sessionsBase: URL { OasesFsRouter.shared.sessionsBaseURL }

    func testSessionAttachmentIsClassifiedWithSessionId() {
        let url = sessionsBase
            .appendingPathComponent("sid-1/attachments/docs/index.html")
        let result = WebAppPathClassifier.classify(hostURL: url)
        XCTAssertEqual(result?.scope, .sessionAttachment)
        XCTAssertEqual(result?.scopeContext, "sid-1")
        XCTAssertEqual(result?.htmlPath, "docs/index.html")
    }

    func testSessionWorkspaceIsClassifiedWithSessionId() {
        let url = sessionsBase
            .appendingPathComponent("sid-2/workspace/report.html")
        let result = WebAppPathClassifier.classify(hostURL: url)
        XCTAssertEqual(result?.scope, .sessionWorkspace)
        XCTAssertEqual(result?.scopeContext, "sid-2")
        XCTAssertEqual(result?.htmlPath, "report.html")
    }

    /// `offloads/` and `browser/` are real session buckets but aren't exposed
    /// as WebApp scopes — refusing to classify gives the user a clean error
    /// instead of a tile that half-works.
    func testUnsupportedSessionBucketIsRejected() {
        let url = sessionsBase
            .appendingPathComponent("sid-3/offloads/thing.html")
        XCTAssertNil(WebAppPathClassifier.classify(hostURL: url))
    }

    func testSharedScopeUsesAppGroupFileProviderRoot() {
        let url = AppGroup.fileProviderShared.appendingPathComponent("notes/a.html")
        let result = WebAppPathClassifier.classify(hostURL: url)
        XCTAssertEqual(result?.scope, .shared)
        XCTAssertNil(result?.scopeContext)
        XCTAssertEqual(result?.htmlPath, "notes/a.html")
    }

    func testPathOutsideEveryScopeIsRejected() {
        let url = URL(fileURLWithPath: "/tmp/somewhere/else.html")
        XCTAssertNil(WebAppPathClassifier.classify(hostURL: url))
    }
}

/// `WebAppShortcut` rows moved from OpenMinis' ChatStore SQLite table to a JSON
/// file (`WebAppShortcutStore`), so round-tripping is worth pinning.
final class WebAppShortcutStoreTests: XCTestCase {

    func testShortcutRoundTripsThroughTheStore() async {
        let store = WebAppShortcutStore.shared
        let id = "test-\(UUID().uuidString)"
        let shortcut = WebAppShortcut(
            id: id,
            htmlPath: "docs/index.html",
            pathScope: .sessionWorkspace,
            scopeContext: "sid-1",
            title: "Report",
            iconRef: .preset("doc"),
            iconCachePath: nil
        )

        await store.save(shortcut)
        let loaded = await store.shortcut(id: id)
        XCTAssertEqual(loaded?.htmlPath, "docs/index.html")
        XCTAssertEqual(loaded?.pathScope, .sessionWorkspace)
        XCTAssertEqual(loaded?.scopeContext, "sid-1")

        await store.delete(id: id)
        let afterDelete = await store.shortcut(id: id)
        XCTAssertNil(afterDelete)
    }
}
