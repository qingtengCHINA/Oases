import Foundation

/// Debug-only integration hooks live outside the App initializer so normal
/// startup only performs registration and runtime bootstrap. Each self-test
/// remains opt-in through an environment variable for simulator/device runs.
enum IntegrationTestBootstrap {
    #if DEBUG
    static func runPlanningSelfTestsIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let requested = environment["OASES_TOOL_ROUTER_SELFTEST"] == "1"
            || environment["OASES_ISH_SELFTEST"] == "1"
            || environment["OASES_HOST_PREFLIGHT_SELFTEST"] == "1"
            || environment["OASES_LOCAL_MODEL_SELFTEST"] == "1"
            || environment["OASES_SUBAGENT_SELFTEST"] == "1"
            || environment["OASES_MEMORY_SELFTEST"] == "1"
            || environment["OASES_COMPACTION_MEMORY_SELFTEST"] == "1"
        guard requested else { return }

        let projectToolRouting = ProjectToolRoutingSelfTest.run()
        NSLog("[ISHSelfTest] project_tool_routing_result %@", projectToolRouting)
        for line in projectToolRouting.split(separator: "\n") {
            let text = String(line)
            if text.contains("project_tool_router_")
                || text.contains("schema_budget_guard=")
                || text.contains("dynamic_skill_router=")
                || text.contains("dynamic_mcp_router=")
                || text.contains("dynamic_mcp_12306_router=")
                || text.contains("builtin_12306_mcp_config=")
                || text.contains("builtin_12306_live_selftest_schema=")
                || text.contains("builtin_12306_ticket_wrapper_schema=")
                || text.contains("local_model_router=")
                || text.contains("oilprice_schema_subset=") {
                NSLog("[ISHSelfTest] project_tool_routing_marker %@", text)
            }
        }

        let projectExecution = ProjectAgentExecutionSelfTest.run()
        NSLog("[ISHSelfTest] project_agent_execution_result %@", projectExecution)
        let recovery = ProjectToolFailureRecoverySelfTest.run()
        NSLog("[ISHSelfTest] project_tool_failure_recovery_result %@", recovery)
        for line in recovery.split(separator: "\n") {
            let text = String(line)
            if text.contains("project_tool_failure_recovery_")
                || text.contains("web_fallback=")
                || text.contains("mcp_12306_fallback=")
                || text.contains("retry_policy=")
                || text.contains("repeat_guard_signature=") {
                NSLog("[ISHSelfTest] project_tool_failure_recovery_marker %@", text)
            }
        }

        let compactor = ProjectAgentContextCompactorSelfTest.run()
        NSLog("[ISHSelfTest] project_context_compactor_result %@", compactor)
        let memoryPolicy = OgentProjectMemoryPolicy.runSelfTest()
        NSLog("[ISHSelfTest] project_memory_policy_result %@", memoryPolicy)
    }
    #else
    static func runPlanningSelfTestsIfRequested(environment: [String: String] = [:]) {}
    #endif
}
