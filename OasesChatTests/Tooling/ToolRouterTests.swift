import XCTest
@testable import Oases_Chat

final class ToolRouterTests: XCTestCase {
    private var registeredNames: [String] = []
    private var registry = ToolRegistry()

    override func setUp() {
        super.setUp()
        let fixtures = [
            fixture("fixture_ppt_artifact", summary: "Create PPTX presentation artifacts", schemaSize: 80),
            fixture("fixture_web_browse", summary: "Browse web pages", schemaSize: 80),
            fixture("fixture_web_search", summary: "Search the web", schemaSize: 80),
            fixture("fixture_12306_ticket", summary: "Query 12306 train tickets", schemaSize: 80),
            fixture("fixture_unrelated_health", summary: "Read health data", schemaSize: 80),
            fixture("fixture_artifact_bridge", summary: "Write final artifacts", schemaSize: 80),
            fixture("fixture_optional_ppt", summary: "Optional PPT helper", schemaSize: 1_800)
        ]
        fixtures.forEach { tool in
            registry.register(tool)
            registeredNames.append(tool.descriptor.name)
        }
    }

    override func tearDown() {
        registeredNames.forEach { registry.unregister(name: $0) }
        registeredNames.removeAll()
        super.tearDown()
    }

    func testGreetingDoesNotExposeToolsOrSchemas() {
        let route = ToolRouter(registry: registry).route(prompt: "你好", schemaBudgetBytes: 10_000)

        XCTAssertTrue(route.candidates.isEmpty)
        XCTAssertTrue(route.allowlist.isEmpty)
        XCTAssertNil(route.schemaJSON)
        XCTAssertEqual(route.schemaByteCount, 0)
    }

    func testPPTPromptSelectsArtifactCapabilityOnly() {
        let route = ToolRouter(registry: registry).route(prompt: "请制作一个 PPT 演示文稿")

        XCTAssertTrue(route.candidates.contains { $0.capability == .artifacts })
        XCTAssertTrue(route.allowlist.contains("fixture_ppt_artifact"))
        XCTAssertTrue(route.allowlist.contains("fixture_artifact_bridge"))
        XCTAssertFalse(route.allowlist.contains("fixture_web_browse"))
        XCTAssertFalse(route.allowlist.contains("fixture_12306_ticket"))
        XCTAssertFalse(route.allowlist.contains("fixture_unrelated_health"))
    }

    func testWebPromptSelectsWebCapabilityOnly() {
        let route = ToolRouter(registry: registry).route(prompt: "浏览网页并搜索最新新闻")

        XCTAssertTrue(route.candidates.contains { $0.capability == .web })
        XCTAssertTrue(route.allowlist.contains("fixture_web_browse"))
        XCTAssertTrue(route.allowlist.contains("fixture_web_search"))
        XCTAssertFalse(route.allowlist.contains("fixture_12306_ticket"))
        XCTAssertFalse(route.allowlist.contains("fixture_unrelated_health"))
    }

    func test12306PromptSelectsTrainCapabilityOnly() {
        let route = ToolRouter(registry: registry).route(prompt: "查询明天北京到上海的 12306 高铁余票")

        XCTAssertTrue(route.candidates.contains { $0.capability == .trainTickets })
        XCTAssertTrue(route.allowlist.contains("fixture_12306_ticket"))
        XCTAssertFalse(route.allowlist.contains("fixture_web_browse"))
        XCTAssertFalse(route.allowlist.contains("fixture_unrelated_health"))
    }

    func testBudgetPruningKeepsCoreToolAndNeverExceedsBudget() {
        let coreOnlyJSON = registry.openAIToolsJSON(
            for: .project,
            allowedNames: Set(["fixture_artifact_bridge"])
        ) ?? ""
        let budget = coreOnlyJSON.utf8.count + 20

        let route = ToolRouter(registry: registry).route(
            prompt: "制作 PPT 演示文稿",
            schemaBudgetBytes: budget
        )

        XCTAssertTrue(route.didFitBudget)
        XCTAssertTrue(route.protectedToolNames.contains("fixture_artifact_bridge"))
        XCTAssertTrue(route.selectedToolNames.contains("fixture_artifact_bridge"))
        XCTAssertFalse(route.selectedToolNames.contains("fixture_optional_ppt"))
        XCTAssertNotNil(route.schemaJSON)
        XCTAssertLessThanOrEqual(route.schemaByteCount, budget)
    }

    func testPreferredPlannerNamesAreValidatedByLiveRegistry() {
        let route = ToolRouter(registry: registry).route(
            prompt: "制作 PPT 演示文稿",
            preferredToolNames: Set([
                "fixture_ppt_artifact",
                "fixture_artifact_bridge",
                "not_registered"
            ])
        )

        XCTAssertTrue(route.selectedToolNames.contains("fixture_ppt_artifact"))
        XCTAssertTrue(route.selectedToolNames.contains("fixture_artifact_bridge"))
        XCTAssertFalse(route.selectedToolNames.contains("not_registered"))
        XCTAssertFalse(route.schemaJSON?.contains("not_registered") ?? false)
    }

    private func fixture(
        _ name: String,
        summary: String,
        schemaSize: Int
    ) -> FixtureTool {
        let padding = String(repeating: "x", count: schemaSize)
        return FixtureTool(
            descriptor: ToolDescriptor(
                name: name,
                summary: "\(summary) \(padding)",
                surfaces: [.project]
            )
        )
    }
}

private final class FixtureTool: AgentTool, @unchecked Sendable {
    let descriptor: ToolDescriptor

    init(descriptor: ToolDescriptor) {
        self.descriptor = descriptor
    }

    func invoke(
        argumentsJSON: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        .textOnly("fixture")
    }
}
