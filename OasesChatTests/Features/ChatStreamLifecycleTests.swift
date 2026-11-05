import Foundation
import SwiftData
import XCTest
@testable import Oases_Chat

/// Track O (plain chat) stream lifecycle: Stop halts the tool batch, a
/// cancelled post-tool stream is not finished as a success, and a stale
/// task's cleanup can't end the stream that replaced it.
@MainActor
final class ChatStreamLifecycleTests: XCTestCase {
    private let toolA = "pkgc_stop_probe_a"
    private let toolB = "pkgc_stop_probe_b"
    private let consent = AIDataSharingConsentFixture()

    override func setUp() {
        super.setUp()
        consent.acceptForTest()
    }

    override func tearDown() {
        consent.restore()
        super.tearDown()
    }

    private func cleanUp() {
        ToolRegistry.shared.unregister(name: toolA)
        ToolRegistry.shared.unregister(name: toolB)
        ChatStreamStubProtocol.reset()
    }

    // MARK: - Generation token

    func testStaleFinishAndFailDoNotEndTheNewerStream() {
        let vm = ChatViewModel()
        let stale = vm.makeAssistantPlaceholder()
        XCTAssertTrue(vm.ownsStream(stale))

        // Session switch / Stop abandons the turn; a new turn starts.
        vm.reset()
        XCTAssertFalse(vm.isStreaming)
        let current = vm.makeAssistantPlaceholder()
        let currentTask = Task<Void, Never> {}
        vm.currentTask = currentTask

        XCTAssertFalse(vm.finishStreaming(assistantId: stale, success: true))
        vm.failStreaming(assistantId: stale, error: URLError(.timedOut))
        XCTAssertTrue(vm.isStreaming, "stale cleanup must not end the new stream")
        XCTAssertNotNil(vm.currentTask)
        XCTAssertNil(vm.errorMessage, "stale failure must not surface a banner")
        XCTAssertTrue(vm.ownsStream(current))

        XCTAssertTrue(vm.finishStreaming(assistantId: current, success: false))
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.currentTask)
        XCTAssertNil(vm.activeStreamID)
    }

    // MARK: - Tool batch cancellation

    func testStopDuringToolBatchSkipsRemainingToolsAndNextRequest() async throws {
        defer { cleanUp() }
        let vm = makeViewModel()
        let probe = ToolProbe()
        ToolRegistry.shared.register(ProbeTool(name: toolA, probe: probe) { @MainActor in
            // The user taps Stop while the first tool runs.
            vm.stop()
        })
        ToolRegistry.shared.register(ProbeTool(name: toolB, probe: probe, onInvoke: nil))
        ChatStreamStubProtocol.responses = [.sse(Self.toolCallsSSE(names: [toolA, toolB]))]

        vm.messages.append(.user("run both tools"))
        let assistantId = vm.makeAssistantPlaceholder()
        await vm.sendChat(userWireContent: .text("run both tools"), assistantId: assistantId, routingPrompt: "run both tools")
        let task = try XCTUnwrap(vm.currentTask)
        await task.value

        let invoked = await probe.invoked
        XCTAssertEqual(invoked, [toolA], "tools after Stop must not start")
        XCTAssertEqual(ChatStreamStubProtocol.requestCount, 1, "no follow-up request after Stop")
        XCTAssertFalse(vm.isStreaming)
    }

    // MARK: - Cancellation after tools is not a success

    func testCancelledPostToolStreamIsNotPersistedAsSuccess() async throws {
        defer { cleanUp() }
        let container = try ModelContainer(
            for: ConversationModel.self, MessageModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let conversation = ConversationModel(mode: .chat)
        context.insert(conversation)

        let vm = makeViewModel()
        vm.bind(context: context)
        vm.setConversation(conversation)
        let probe = ToolProbe()
        ToolRegistry.shared.register(ProbeTool(name: toolA, probe: probe, onInvoke: nil))
        ChatStreamStubProtocol.responses = [.sse(Self.toolCallsSSE(names: [toolA])), .hang]

        vm.messages.append(.user("use the tool"))
        let assistantId = vm.makeAssistantPlaceholder()
        let hanging = expectation(description: "post-tool request started")
        ChatStreamStubProtocol.onHangingRequest = { hanging.fulfill() }
        await vm.sendChat(userWireContent: .text("use the tool"), assistantId: assistantId, routingPrompt: "use the tool")
        let task = try XCTUnwrap(vm.currentTask)
        await fulfillment(of: [hanging], timeout: 10)

        // What the watchdog does on timeout: cancel the turn and fail it.
        vm.currentTask?.cancel()
        vm.failStreaming(
            assistantId: assistantId,
            error: NSError(domain: "Chat", code: -1, userInfo: [NSLocalizedDescriptionKey: "响应超时，请重试"])
        )
        await task.value

        let invoked = await probe.invoked
        XCTAssertEqual(invoked, [toolA])
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNotNil(vm.errorMessage)
        let assistantRows = try context.fetch(FetchDescriptor<MessageModel>())
            .filter { $0.roleRaw == "assistant" }
        XCTAssertTrue(assistantRows.isEmpty, "a cancelled turn must not be persisted as a finished reply")
        let bubble = try XCTUnwrap(vm.messages.first { $0.id == assistantId })
        XCTAssertTrue(bubble.toolCalls.allSatisfy { $0.status != .pending && $0.status != .running })
    }

    // MARK: - Helpers

    private func makeViewModel() -> ChatViewModel {
        let vm = ChatViewModel(service: makeService())
        vm.activeMode = .chat
        vm.currentModel = Models.defaultChat
        return vm
    }

    private func makeService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStreamStubProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://chat-stream.test/v1")!,
            apiKey: "unit-test-key",
            session: URLSession(configuration: configuration)
        )
        return ChatService(streamClient: client)
    }

    private static func toolCallsSSE(names: [String]) -> String {
        var events = names.enumerated().map { index, name in
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":\#(index),"id":"call_\#(index)","type":"function","function":{"name":"\#(name)","arguments":"{}"}}]}}]}"#
        }
        events.append(#"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        events.append("data: [DONE]")
        return events.joined(separator: "\n\n") + "\n\n"
    }
}

private actor ToolProbe {
    private(set) var invoked: [String] = []
    func record(_ name: String) { invoked.append(name) }
}

private final class ProbeTool: AgentTool, @unchecked Sendable {
    let name: String
    let probe: ToolProbe
    let onInvoke: (@MainActor @Sendable () -> Void)?

    init(name: String, probe: ToolProbe, onInvoke: (@MainActor @Sendable () -> Void)?) {
        self.name = name
        self.probe = probe
        self.onInvoke = onInvoke
    }

    var descriptor: ToolDescriptor {
        ToolDescriptor(name: name, summary: "test probe", surfaces: [.chat])
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        await probe.record(name)
        if let onInvoke { await onInvoke() }
        return .textOnly("ok")
    }
}

/// Serves scripted responses to consecutive chat/completions requests.
private final class ChatStreamStubProtocol: URLProtocol {
    enum Response {
        case sse(String)
        /// Sends headers and then nothing, until the request is cancelled.
        case hang
    }

    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var onHangingRequest: (@Sendable () -> Void)?
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = []
            requestCount = 0
            onHangingRequest = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: Response = Self.lock.withLock {
            let index = Self.requestCount
            Self.requestCount += 1
            return index < Self.responses.count ? Self.responses[index] : .hang
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        switch response {
        case .sse(let body):
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            Self.onHangingRequest?()
        }
    }

    override func stopLoading() {}
}
