import XCTest
@testable import Oases_Chat

final class ShellExecuteAliasTests: XCTestCase {
    func testShellExecuteRegisteredWithShellLocalAlias() {
        // Ensure registration matches production boot.
        ToolRegistry.shared.register(ShellTool(), aliases: ["shell_local"])

        let primary = ToolRegistry.shared.tool(named: "shell_execute")
        let alias = ToolRegistry.shared.tool(named: "shell_local")
        XCTAssertNotNil(primary)
        XCTAssertNotNil(alias)
        XCTAssertEqual(primary?.descriptor.name, "shell_execute")
        // Alias resolves to the same underlying tool instance behavior.
        XCTAssertEqual(ToolRegistry.shared.canonicalName(for: "shell_local"), "shell_execute")
        XCTAssertEqual(ToolRegistry.shared.canonicalName(for: "shell_execute"), "shell_execute")
    }

    func testPlannerEmitsShellExecuteNotOnlyShellLocal() {
        let plan = ProjectAgentPlanner.plan(
            for: "写一个 python 脚本统计 csv 并运行它",
            iteration: 1,
            executedToolCalls: 0
        )
        XCTAssertTrue(plan.toolNames.contains("shell_execute"), "\(plan.toolNames)")
        XCTAssertTrue(plan.toolNames.contains("file_write") || plan.toolNames.contains("file_edit") || plan.toolNames.contains("file_read"), "\(plan.toolNames)")
    }

    func testGreetingStillExposesNoTools() {
        let plan = ProjectAgentPlanner.plan(for: "你好", iteration: 1, executedToolCalls: 0)
        XCTAssertFalse(plan.exposesTools)
        XCTAssertTrue(plan.toolNames.isEmpty)
    }
}
