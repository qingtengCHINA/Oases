import XCTest
@testable import Oases_Chat

final class ProjectAgentPlannerTests: XCTestCase {
    func testGreetingExposesNoTools() {
        let plan = ProjectAgentPlanner.plan(for: "你好", iteration: 1, executedToolCalls: 0)

        XCTAssertFalse(plan.exposesTools)
        XCTAssertEqual(plan.contextPolicy, .none)
    }

    func testWebDocumentTaskRoutesOnlyRelevantTools() {
        let plan = ProjectAgentPlanner.plan(
            for: "抓取 oilprice.com 最近三天新闻并写入 Word",
            iteration: 1,
            executedToolCalls: 0
        )

        XCTAssertTrue(plan.toolNames.isSuperset(of: ["web_search", "web_browse", "artifact_bridge"]))
        XCTAssertFalse(plan.toolNames.contains("contact_search"))
    }

    func testMediaTaskSelectsMediaSkillWithoutSystemData() {
        let plan = ProjectAgentPlanner.plan(
            for: "下载这个 YouTube 视频并保存到文件",
            iteration: 1,
            executedToolCalls: 0
        )

        XCTAssertTrue(plan.toolNames.contains("youtube_downloader"))
        XCTAssertFalse(plan.toolNames.contains("calendar_read"))
    }
}
