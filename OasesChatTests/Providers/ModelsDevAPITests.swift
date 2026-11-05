import XCTest
@testable import Oases_Chat

final class ModelsDevAPITests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-dev-\(UUID().uuidString)", isDirectory: true)
        ModelsDevAPI.diskCacheURLOverride = cacheDir.appendingPathComponent("api.json")
        // The test bundle has no models-dev-api.json, just like the app.
        ModelsDevAPI.fallbackBundle = Bundle(for: Self.self)
        ModelsDevAPI.allowsNetworkRefresh = false
        ModelsDevAPI.resetInMemoryCache()
    }

    override func tearDown() {
        ModelsDevAPI.diskCacheURLOverride = nil
        ModelsDevAPI.fallbackBundle = .main
        ModelsDevAPI.allowsNetworkRefresh = true
        ModelsDevAPI.resetInMemoryCache()
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    /// First launch: no downloaded copy and nothing bundled. This used to hit
    /// an `assertionFailure` (EXC_BREAKPOINT in DEBUG) when a provider's
    /// model list was fetched.
    func testEnrichmentWithoutAnyRegistryLeavesModelsUnchanged() {
        let model = LLMModel(id: "some-model", displayName: "Some Model", provider: "OpenAI")

        let enriched = ModelsDevAPI.enrichModels([model])
        XCTAssertEqual(enriched.map(\.id), ["some-model"])
        XCTAssertNil(enriched.first?.contextWindow)
        XCTAssertNil(ModelsDevAPI.enrichModel(model).contextWindow)
    }

    func testDownloadedCopyEnrichesModels() throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let json = #"{"acme":{"id":"acme","models":{"acme-large":{"id":"acme-large","limit":{"context":123456,"output":4096}}}}}"#
        try Data(json.utf8).write(to: cacheDir.appendingPathComponent("api.json"))

        let enriched = ModelsDevAPI.enrichModel(LLMModel(id: "acme-large", displayName: "Acme Large", provider: "Acme"))
        XCTAssertEqual(enriched.contextWindow, 123456)
        XCTAssertEqual(enriched.maxOutputTokens, 4096)
    }
}
