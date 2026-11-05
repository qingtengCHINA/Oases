import Foundation
import XCTest
@testable import Oases_Chat

final class OgentProductionAgentRuntimeTests: XCTestCase {
    func testContinuationPromptCarriesTheActualTask() {
        let prompt = OgentProductionAgentSession.continuationPrompt(for: "下载视频并在聊天里播放")
        XCTAssertTrue(prompt.contains("下载视频并在聊天里播放"), prompt)
        XCTAssertFalse(prompt.contains("(request)"), prompt)
    }

    func testProductionSessionHydratesToolProtocolHistoryFromPersistedEvents() async {
        let context = AgentRunContext(
            model: "test-model",
            effort: nil,
            surface: .project,
            messages: [ChatAPIMessage(role: "user", content: .text("继续任务"))],
            toolsJSON: nil,
            projectSessionID: nil,
            projectID: nil
        )
        let session = OgentProductionAgentSession(context: context)
        let callID = "resume-call"
        let transcript = [
            AgentEvent.text("先检查文件", role: "assistant", location: .remoteOases),
            AgentEvent.tool(
                name: "file_read",
                phase: .started,
                callID: callID,
                location: .ishLinux,
                metadata: ["arguments": "{\"path\":\"/root/.ogent/workspace/a.txt\"}"]
            ),
            AgentEvent.tool(
                name: "file_read",
                phase: .succeeded,
                callID: callID,
                summary: "file contents",
                location: .ishLinux
            )
        ]

        let configuration = await session.modelConfiguration(
            for: ModelTurnRequest(
                runID: UUID(),
                userRequest: "继续任务",
                iteration: 0,
                transcript: transcript
            )
        )

        XCTAssertEqual(configuration.history.count, 3)
        XCTAssertEqual(configuration.history[1].role, "assistant")
        XCTAssertEqual(configuration.history[1].toolCalls?.first?.id, callID)
        XCTAssertEqual(configuration.history[1].toolCalls?.first?.function.name, "file_read")
        XCTAssertEqual(configuration.history[2].role, "tool")
        XCTAssertEqual(configuration.history[2].toolCallId, callID)
        if let content = configuration.history[2].content, case .text(let value) = content {
            XCTAssertEqual(value, "file contents")
        } else {
            XCTFail("Expected a text tool result")
        }
    }

    func testProductionCompositionRunsToolThenFinalResponseThroughPersistedRun() async throws {
        let registry = ToolRegistry()
        let tool = RuntimeTestTool()
        registry.register(tool)

        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-agent-runtime-\(UUID().uuidString)", isDirectory: true)
        let store = AgentRunStore(directoryURL: storeDirectory)
        let context = AgentRunContext(
            model: "test-model",
            effort: nil,
            surface: .project,
            messages: [ChatAPIMessage(role: "user", content: .text("run the test tool"))],
            toolsJSON: nil,
            projectSessionID: nil,
            projectID: nil
        )
        let service = ScriptedOgentChatService(responses: [
            [.toolCallDelta(index: 0, id: "call-1", name: "runtime_test_tool", argumentsDelta: "{}"), .finish(reason: "tool_calls")],
            [.textDelta("最终交付：工具结果已处理。"), .finish(reason: "stop")]
        ])
        let runtime = OgentProductionAgentRuntime(
            context: context,
            completionContract: AgentCompletionContract(requiresArtifact: false),
            service: service,
            store: store,
            registry: registry
        )

        let handle = try await runtime.start()
        for await _ in handle.events { }

        let storedRun = try await runtime.load(runID: handle.runID)
        let run = try XCTUnwrap(storedRun)
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.delivery?.outcome, .succeeded)
        XCTAssertEqual(run.delivery?.summary, "最终交付：工具结果已处理。")
        XCTAssertTrue(run.events.contains { event in
            if case .tool(let toolEvent) = event.payload {
                return toolEvent.name == "runtime_test_tool" && toolEvent.phase == .succeeded
            }
            return false
        })
        XCTAssertEqual(run.context, context)
    }

    func testProductionRuntimeCanRebuildAndResumePersistedRun() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-agent-resume-(UUID().uuidString)", isDirectory: true)
        let store = AgentRunStore(directoryURL: storeDirectory)
        let context = AgentRunContext(
            model: "test-model",
            effort: nil,
            surface: .project,
            messages: [ChatAPIMessage(role: "user", content: .text("继续已中断任务"))],
            toolsJSON: nil,
            projectSessionID: "session-resume",
            projectID: "project-resume"
        )
        let runID = UUID()
        var persisted = AgentRun(
            id: runID,
            state: .planning,
            events: [
                AgentEvent.tool(
                    name: "file_read",
                    phase: .started,
                    callID: "old-call",
                    location: .ishLinux,
                    metadata: ["arguments": "{\"path\":\"/root/.ogent/workspace/report.txt\"}"]
                ),
                AgentEvent.tool(
                    name: "file_read",
                    phase: .succeeded,
                    callID: "old-call",
                    summary: "old tool result",
                    location: .ishLinux
                )
            ],
            request: "继续已中断任务",
            context: context
        )
        try await store.save(persisted)

        let service = ScriptedOgentChatService(responses: [
            [.textDelta("恢复后已完成最终交付。"), .finish(reason: "stop")]
        ])
        let (runtime, handle) = try await OgentProductionAgentRuntime.resumePersistedRun(
            runID: runID,
            service: service,
            store: store
        )
        for await _ in handle.events { }

        let resumedRun = try await runtime.load(runID: runID)
        persisted = try XCTUnwrap(resumedRun)
        XCTAssertEqual(persisted.state, .succeeded)
        XCTAssertEqual(persisted.delivery?.summary, "恢复后已完成最终交付。")
        XCTAssertTrue(persisted.events.contains { event in
            if case .status(let status) = event.payload {
                return status.to == .succeeded
            }
            return false
        })
    }

    func testLatestInterruptedProjectRunIgnoresTerminalAndNonProjectRuns() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-agent-recovery-(UUID().uuidString)", isDirectory: true)
        let store = AgentRunStore(directoryURL: storeDirectory)
        let projectContext = AgentRunContext(
            model: "test-model",
            effort: nil,
            surface: .project,
            messages: [ChatAPIMessage(role: "user", content: .text("恢复工程任务"))],
            toolsJSON: nil,
            projectSessionID: "session-recovery",
            projectID: "project-recovery"
        )
        let chatContext = AgentRunContext(
            model: "test-model",
            effort: nil,
            surface: .chat,
            messages: [ChatAPIMessage(role: "user", content: .text("普通聊天"))],
            toolsJSON: nil,
            projectSessionID: nil,
            projectID: nil
        )
        let terminal = AgentRun(
            id: UUID(),
            state: .failed,
            delivery: AgentDelivery(outcome: .failed, summary: "已失败"),
            request: "旧工程任务",
            context: projectContext
        )
        let chatRun = AgentRun(
            id: UUID(),
            state: .planning,
            request: "普通聊天",
            context: chatContext
        )
        let interrupted = AgentRun(
            id: UUID(),
            state: .planning,
            request: "恢复工程任务",
            context: projectContext
        )
        try await store.save(terminal)
        try await store.save(chatRun)
        try await store.save(interrupted)

        let candidate = try await OgentProductionAgentRuntime.latestInterruptedProjectRun(store: store)
        XCTAssertEqual(candidate?.id, interrupted.id)
        XCTAssertEqual(candidate?.context?.surface, .project)
    }
}

private final class RuntimeTestTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "runtime_test_tool",
        summary: "A deterministic production adapter test tool.",
        surfaces: [.project]
    )

    func invoke(
        argumentsJSON: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        onProgress("tool-progress\n")
        return .textOnly("tool-result")
    }
}

private actor ScriptedOgentChatService: OgentChatStreaming {
    private var responses: [[StreamEvent]]

    init(responses: [[StreamEvent]]) {
        self.responses = responses
    }

    func streamEvents(
        messages: [ChatAPIMessage],
        model: String,
        effort: String?,
        surface: AgentSurface?,
        toolsJSON: String?
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        let response = responses.isEmpty ? [.finish(reason: "stop")] : responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in response {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
