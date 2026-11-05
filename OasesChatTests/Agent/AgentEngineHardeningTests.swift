import SwiftData
import XCTest
@testable import Oases_Chat

/// Regression coverage for the track-M engine fixes from the 2026-09-29 code
/// review (in-loop compaction, msgIdx re-resolution, fallback provider
/// switch, request image budget, session-load image inlining, fork media,
/// context estimate cache, concurrency slot key).
@MainActor
final class AgentEngineHardeningTests: XCTestCase {

    // MARK: - In-loop compaction keeps isProcessing

    /// Two-message session whose latest marker already covers everything, so
    /// compactBefore passes its guards, takes ownership of `isProcessing`, and
    /// returns through the "already compacted" exit (no LLM call).
    private func makeAlreadyCompactedVM() -> (AIChatViewModel, UUID) {
        let vm = AIChatViewModel()
        vm.sessionId = "engine-hardening-\(UUID().uuidString)"
        let user = ChatMessage(role: .user, content: "hello there")
        let assistant = ChatMessage(role: .assistant, content: "", blocks: [])
        vm.messages = [user, assistant]
        var userEntry = AgentMessage(role: .user, parts: [.text("hello there")])
        userEntry.dbMessageId = "db-user"
        var assistantEntry = AgentMessage(role: .assistant, parts: [.text("hi")])
        assistantEntry.dbMessageId = "db-assistant"
        vm.agentHistory = [userEntry, assistantEntry]
        vm.cachedLatestMarker = CompactMarker(
            id: UUID().uuidString, sessionId: vm.sessionId!, summary: "earlier",
            firstKeptSortOrder: 0, compactedCount: 2, createdAt: Date(),
            uiBoundarySortOrder: nil, boundaryMessageId: nil, firstKeptMessageId: nil,
            lastCompactedMessageId: "db-assistant", version: 2
        )
        return (vm, assistant.id)
    }

    func testInLoopCompactionLeavesProcessingToTheLoop() async {
        let (vm, anchor) = makeAlreadyCompactedVM()
        vm.isProcessing = true
        defer { vm.isProcessing = false }

        await vm.compactBefore(anchor, allowDuringProcessing: true)

        XCTAssertTrue(vm.isProcessing, "compaction inside a running loop must not clear the loop's isProcessing")
        XCTAssertFalse(vm.isCompacting)
    }

    func testStandaloneCompactionStillResetsProcessing() async {
        let (vm, anchor) = makeAlreadyCompactedVM()
        XCTAssertFalse(vm.isProcessing)

        await vm.compactBefore(anchor)

        XCTAssertFalse(vm.isProcessing)
        XCTAssertFalse(vm.isCompacting)
    }

    func testClearChatRefusedWhileProcessing() {
        let vm = AIChatViewModel()
        vm.messages = [ChatMessage(role: .user, content: "keep me")]
        vm.agentHistory = [AgentMessage(role: .user, parts: [.text("keep me")])]
        vm.isProcessing = true
        defer { vm.isProcessing = false }

        vm.clearChat()

        XCTAssertEqual(vm.messages.first?.content, "keep me")
        XCTAssertEqual(vm.agentHistory.count, 1)
    }

    // MARK: - msgIdx re-resolution

    func testResolvedMessageIndexFollowsMessageAcrossMutations() {
        let user = ChatMessage(role: .user, content: "q")
        let assistant = ChatMessage(role: .assistant, content: "", blocks: [])
        var messages = [user, assistant]
        XCTAssertEqual(AIChatViewModel.resolvedMessageIndex(of: assistant.id, in: messages, hint: 1), 1)

        // An in-loop compaction inserts its divider above the running message.
        messages.insert(ChatMessage(role: .compactDivider, content: "1 messages compacted"), at: 1)
        XCTAssertEqual(AIChatViewModel.resolvedMessageIndex(of: assistant.id, in: messages, hint: 1), 2)

        // A delete shrank the array: the stale hint is past the end.
        XCTAssertEqual(AIChatViewModel.resolvedMessageIndex(of: assistant.id, in: [assistant], hint: 5), 0)

        // A reload rebuilds the list with fresh ChatMessage instances.
        let reloaded = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "", blocks: [])]
        XCTAssertNil(AIChatViewModel.resolvedMessageIndex(of: assistant.id, in: reloaded, hint: 1))
    }

    // MARK: - Fallback provider switch

    private struct StubProvider: AgentProvider {
        let name: String
        var model: LLMModel { LLMModel(id: "stub-\(name)", displayName: name, provider: "stub") }
        var defaultMaxTokens: Int { 1024 }
        func streamAgentMessageClamped(
            messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition],
            maxTokens: Int, thinkingLevel: ThinkingLevel
        ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testFallbackSlotRebuildsProviderWhenActiveEntryAdvances() async throws {
        var slot = AIChatViewModel.FallbackProviderSlot(
            provider: StubProvider(name: "primary"), systemPrompt: "primary prompt", entryId: "entry-a"
        )
        var builds: [String] = []
        let build: (String) async throws -> (provider: any AgentProvider, systemPrompt: String?)? = { id in
            builds.append(id)
            guard id != "missing" else { return nil }
            return (StubProvider(name: "p-\(id)"), "prompt-\(id)")
        }

        let unchanged = try await slot.follow("entry-a", build: build)
        XCTAssertFalse(unchanged)
        XCTAssertEqual(slot.provider.name, "primary")
        XCTAssertTrue(builds.isEmpty)

        let advanced = try await slot.follow("entry-b", build: build)
        XCTAssertTrue(advanced)
        XCTAssertEqual(slot.provider.name, "p-entry-b", "the next request must go to the advanced entry's provider")
        XCTAssertEqual(slot.systemPrompt, "prompt-entry-b")
        XCTAssertEqual(slot.entryId, "entry-b")

        let again = try await slot.follow("entry-b", build: build)
        XCTAssertFalse(again)
        XCTAssertEqual(builds, ["entry-b"])

        let unknown = try await slot.follow("missing", build: build)
        XCTAssertFalse(unknown)
        XCTAssertEqual(slot.provider.name, "p-entry-b")
    }

    // MARK: - Request image budget

    func testImageBudgetPlanUsesStablePositions() {
        let bytes = Data(repeating: 7, count: 10)
        // Identical bytes: pointer identity of bridged Data used to be the key.
        let images = (0..<3).map { _ in
            AIChatViewModel.BudgetImage(data: bytes, linuxPath: nil, mimeType: "image/png")
        }
        let plan = AIChatViewModel.planRequestBudget(images, maxBytes: 25)
        XCTAssertEqual(plan.droppedIndices, [0], "oldest image is dropped first")
        XCTAssertEqual(plan.keptBytes, 20)
        XCTAssertEqual(AIChatViewModel.planRequestBudget(images, maxBytes: 25).droppedIndices, plan.droppedIndices)
    }

    func testRequestImageBudgetElidesOldestImagesOverTwentyFiveMegabytes() {
        let vm = AIChatViewModel()
        vm.sessionId = "engine-hardening-\(UUID().uuidString)"
        // Six images at the 5 MB per-image cap = 30 MB > 25 MB budget.
        let image = Data(count: 6 * 1024 * 1024)
        let history = (0..<6).map { i in
            AgentMessage(role: .user, parts: [
                .imageData(data: image, mimeType: "image/jpeg", linuxPath: "/var/minis/attachments/uploads/img\(i).jpg")
            ])
        }

        let budgeted = vm.applyRequestImageBudget(history)

        guard case .text(let placeholder) = budgeted[0].parts[0] else {
            return XCTFail("oldest image should be replaced by a placeholder")
        }
        XCTAssertTrue(placeholder.contains("/var/minis/attachments/uploads/img0.jpg"))
        for message in budgeted.dropFirst() {
            guard case .imageData = message.parts[0] else {
                return XCTFail("the five most recent images fit the budget and must stay inline")
            }
        }
    }

    // MARK: - Session load inlines only recent images

    func testSessionLoadInlinesOnlyMostRecentImages() throws {
        let sessionId = "engine-hardening-\(UUID().uuidString)"
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEngineHardeningTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let resolver: (MediaRef) -> URL = { base.appendingPathComponent($0.relativePath) }

        let limit = RawMessage.recentInlineImageMessageLimit
        let total = limit + 2
        var raws: [RawMessage] = []
        for i in 0..<total {
            let ref = MediaRef(
                id: "img\(i)", relativePath: "\(sessionId)/attachments/img\(i).jpg",
                mimeType: "image/jpeg", originalFileName: nil, linuxPath: nil
            )
            let file = resolver(ref)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF, UInt8(i)]).write(to: file)
            raws.append(RawMessage(
                id: "msg\(i)", sessionId: sessionId, role: .user, parts: [.mediaRef(ref)],
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + i)),
                tokenUsage: nil, reasoningContent: nil
            ))
        }

        let inlineIds = RawMessage.idsWithRecentImages(in: raws)
        let history = raws.map {
            AIChatViewModel.restoredAgentMessage(
                $0, inlineImages: inlineIds.contains($0.id), mediaResolver: resolver, sessionId: sessionId
            )
        }

        for (i, message) in history.enumerated() {
            if i >= total - limit {
                guard case .imageData = message.parts.first else {
                    return XCTFail("message \(i) is among the \(limit) most recent and must keep its bytes")
                }
            } else {
                guard case .text(let placeholder) = message.parts.first else {
                    return XCTFail("message \(i) is older and must be a placeholder")
                }
                // Legacy ref without linuxPath: point at the session file.
                XCTAssertTrue(placeholder.contains("/var/minis/attachments/img\(i).jpg"), placeholder)
            }
        }
    }

    func testUnloadedToolResultImageGetsSessionPath() {
        let sessionId = "sid-1"
        let ref = MediaRef(id: "s", relativePath: "\(sessionId)/browser/shot.jpg", mimeType: "image/jpeg", originalFileName: nil)
        let raw = RawMessage(
            id: "tr", sessionId: sessionId, role: .user,
            parts: [.toolResult(ChatMessageToolResult(
                toolUseId: "tu1", output: "clicked", success: true, mediaRef: ref,
                snapshot: nil, pageURL: nil, status: "success"
            ))],
            createdAt: Date(), tokenUsage: nil, reasoningContent: nil
        )
        let message = AIChatViewModel.restoredAgentMessage(
            raw, inlineImages: false, mediaResolver: { _ in URL(fileURLWithPath: "/nonexistent") }, sessionId: sessionId
        )
        guard case .toolResult(_, _, let content, _, let imageData, _, _, let linuxPath) = message.parts[0] else {
            return XCTFail("expected tool result")
        }
        XCTAssertNil(imageData)
        XCTAssertEqual(linuxPath, "/var/minis/browser/shot.jpg")
        XCTAssertTrue(content.hasPrefix("clicked\n"))
        XCTAssertTrue(content.contains("/var/minis/browser/shot.jpg"))
        XCTAssertNil(AIChatViewModel.linuxPathForStoredMedia(relativePath: "other/browser/shot.jpg", sessionId: sessionId))
        XCTAssertNil(AIChatViewModel.linuxPathForStoredMedia(relativePath: "\(sessionId)/images/x.jpg", sessionId: sessionId))
    }

    // MARK: - Split compaction keeps the previous summary

    func testSplitCompactionMergeCarriesPreviousSummary() {
        let merged = AIChatViewModel.splitSummaryMergeInput(previousSummary: "OLD-SUMMARY", part1: "P1", part2: "P2")
        XCTAssertTrue(merged.contains("OLD-SUMMARY"))
        XCTAssertLessThan(merged.range(of: "OLD-SUMMARY")!.lowerBound, merged.range(of: "Part 1:")!.lowerBound)
        XCTAssertFalse(AIChatViewModel.splitSummaryMergeInput(previousSummary: nil, part1: "P1", part2: "P2")
            .contains("Earlier context summary"))
    }

    // MARK: - Context estimate cache

    func testContextEstimateIsCachedUntilHistoryOrMarkerChanges() {
        let vm = AIChatViewModel()
        vm.agentHistory = [AgentMessage(role: .user, parts: [.text(String(repeating: "a", count: 350))])]
        XCTAssertEqual(vm.estimateContextTokens(), 100)
        let revision = vm.contextRevision
        XCTAssertEqual(vm.estimateContextTokens(), 100)
        XCTAssertEqual(vm.contextTokenEstimateCache?.revision, revision)

        vm.agentHistory.append(AgentMessage(role: .assistant, parts: [.text(String(repeating: "b", count: 350))]))
        XCTAssertEqual(vm.estimateContextTokens(), 200)

        let afterAppend = vm.contextRevision
        vm.agentHistory[0].dbMessageId = "db-0"
        XCTAssertGreaterThan(vm.contextRevision, afterAppend, "in-place element edits must bump the revision too")
        let beforeMarker = vm.contextRevision
        vm.cachedLatestMarker = nil
        XCTAssertGreaterThan(vm.contextRevision, beforeMarker)
    }

    // MARK: - Concurrency slot key

    func testDraftSessionsGetDistinctConcurrencyKeys() {
        let first = AIChatViewModel()
        first.draftId = "__new__A"
        let second = AIChatViewModel()
        second.draftId = "__new__B"
        XCTAssertEqual(first.concurrencySlotKey, "__new__A")
        XCTAssertNotEqual(first.concurrencySlotKey, second.concurrencySlotKey)

        let bare = AIChatViewModel()
        XCTAssertTrue(bare.concurrencySlotKey.hasPrefix("vm-"))
        bare.sessionId = "real-session"
        XCTAssertEqual(bare.concurrencySlotKey, "real-session")
    }

    // MARK: - Cancel hand-over wait

    func testWaitForCompletionReturnsWhenTaskFinishesOrTimesOut() async {
        let quick = Task<Void, Never> { }
        await AIChatViewModel.waitForCompletion(of: quick, timeout: 5)

        let stuck = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        let start = Date()
        await AIChatViewModel.waitForCompletion(of: stuck, timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        stuck.cancel()
    }

    // MARK: - Auto-learned skills

    func testLearnedSkillsAreDedupedAndCapped() {
        func skill(_ name: String, source: SkillImportSource = .session) -> Skill {
            Skill(
                id: SkillStore.slugify(name), name: name, description: "", version: "1",
                importSource: source, isEnabled: true, installedAt: Date(), updatedAt: Date(), body: ""
            )
        }
        let existing = [skill("Learned convert the video"), skill("Hand written", source: .file)]
        XCTAssertFalse(AIChatViewModel.shouldImportLearnedSkill(named: "Learned convert the video", existing: existing))
        XCTAssertTrue(AIChatViewModel.shouldImportLearnedSkill(named: "Learned resize photos", existing: existing))

        let full = (0..<3).map { skill("Learned task \($0)") }
        XCTAssertFalse(AIChatViewModel.shouldImportLearnedSkill(named: "Learned another", existing: full, cap: 3))
    }

    // MARK: - Fork / duplicate media

    func testForkCopiesMediaAndRebasesRefs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEngineHardeningTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = "src-session"
        let target = "dst-session"
        let uploads = base.appendingPathComponent("\(source)/attachments/uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: base.appendingPathComponent("\(source)/attachments/a.jpg"))
        try Data("upload".utf8).write(to: uploads.appendingPathComponent("doc.pdf"))
        let browser = base.appendingPathComponent("\(source)/browser", isDirectory: true)
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        try Data("shot".utf8).write(to: browser.appendingPathComponent("s.jpg"))

        let copied = SessionForkManager.copySessionMediaFiles(from: source, to: target, baseURL: base)
        XCTAssertEqual(copied, ["attachments/a.jpg", "attachments/uploads/doc.pdf", "browser/s.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("\(target)/attachments/uploads/doc.pdf").path))

        let image = MediaRef(id: "a", relativePath: "\(source)/attachments/a.jpg", mimeType: "image/jpeg", originalFileName: nil)
        let shot = MediaRef(id: "s", relativePath: "\(source)/browser/s.jpg", mimeType: "image/jpeg", originalFileName: nil)
        let missing = MediaRef(id: "m", relativePath: "\(source)/attachments/gone.jpg", mimeType: "image/jpeg", originalFileName: nil)
        let parts: [ContentPart] = [
            .mediaRef(image),
            .mediaRef(missing),
            .toolResult(ChatMessageToolResult(
                toolUseId: "tu", output: "ok", success: true, mediaRef: shot,
                snapshot: ToolSnapshot(type: .image, text: nil, mediaRef: shot, duration: 1),
                pageURL: nil, status: "success"
            )),
        ]
        let rebased = SessionForkManager.rebasedParts(parts, from: source, to: target, copied: copied)

        guard case .mediaRef(let newImage) = rebased[0], case .mediaRef(let untouched) = rebased[1],
              case .toolResult(let result) = rebased[2] else {
            return XCTFail("part kinds must be preserved")
        }
        XCTAssertEqual(newImage.relativePath, "\(target)/attachments/a.jpg")
        XCTAssertEqual(untouched.relativePath, missing.relativePath, "refs to files that weren't copied keep the original")
        XCTAssertEqual(result.mediaRef?.relativePath, "\(target)/browser/s.jpg")
        XCTAssertEqual(result.snapshot?.mediaRef?.relativePath, "\(target)/browser/s.jpg")
        XCTAssertEqual(result.output, "ok")
    }

    // MARK: - SessionReadFacade.userMessages(since:)

    func testUserMessagesSinceReturnsOnlyNewerMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEngineHardeningTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatStore(baseURL: directory)
        let container = try ModelContainer(
            for: ConversationModel.self, MessageModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let facade = SessionReadFacade(chatStore: store, nativeEngine: SessionsQueryEngine(modelContainer: container))

        let session = await store.createSession(modelId: "m", title: "t")
        for (id, time) in [("00000000-0000-0000-0000-000000000101", 1_000.0), ("00000000-0000-0000-0000-000000000102", 3_000.0)] {
            await store.appendMessage(RawMessage(
                id: id, sessionId: session.id, role: .user, parts: [.text("text \(Int(time))")],
                createdAt: Date(timeIntervalSince1970: time), tokenUsage: nil, reasoningContent: nil
            ))
        }

        let recent = await facade.userMessages(since: 2_000)
        XCTAssertEqual(recent.map(\.text), ["text 3000"])
        let all = await facade.userMessages(since: 0)
        XCTAssertEqual(all.map(\.text), ["text 1000", "text 3000"])
    }
}
