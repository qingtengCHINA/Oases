import XCTest
@testable import Oases_Chat

/// The console rail's "what did this run produce" bookkeeping.
final class OgentDeliverableLedgerTests: XCTestCase {

    // MARK: - Fixtures

    private func user(_ text: String = "go", queued: Bool = false) -> ChatMessage {
        ChatMessage(role: .user, content: text, isQueued: queued)
    }

    private func assistant(_ blocks: [AssistantBlock], error: String? = nil) -> ChatMessage {
        let message = ChatMessage(role: .assistant, content: "", blocks: blocks)
        message.error = error
        return message
    }

    private func shell(output: String, status: ToolBlockStatus = .success) -> AssistantBlock {
        AssistantBlock(kind: .shellTool(command: "ffmpeg -f lavfi -i testsrc out.mp4"), content: output, toolStatus: status)
    }

    private func shell(produced urls: [String], status: ToolBlockStatus = .success) -> AssistantBlock {
        let block = AssistantBlock(kind: .shellTool(command: "make"), content: "done", toolStatus: status)
        block.producedMinisURLs = urls
        return block
    }

    private func toolOutput(listing urls: [String], trailer: String = "") -> String {
        "frame=  90 fps=0.0 q=-1.0 Lsize=      61kB\n\n[minis] New/modified files:"
            + urls.map { "\n  \($0)" }.joined()
            + trailer
    }

    // MARK: - Parsing the shell tool's [minis] section

    func testParsesNewOrModifiedSectionFromShellOutput() {
        let output = toolOutput(listing: ["minis://workspace/out.mp4", "minis://attachments/a%20b.png"])
        XCTAssertEqual(
            OgentDeliverableLedger.minisURLs(inToolOutput: output),
            ["minis://workspace/out.mp4", "minis://attachments/a%20b.png"]
        )
    }

    func testSectionEndsAtFirstLineThatIsNotAnEntry() {
        let output = toolOutput(
            listing: ["minis://workspace/report.pdf"],
            trailer: "\n\n[browser_downloads] saved minis://workspace/other.zip\n  minis://workspace/not-an-entry.txt"
        )
        XCTAssertEqual(OgentDeliverableLedger.minisURLs(inToolOutput: output), ["minis://workspace/report.pdf"])
    }

    func testOutputWithoutSectionHasNoFiles() {
        XCTAssertEqual(OgentDeliverableLedger.minisURLs(inToolOutput: "hello\nworld"), [])
        XCTAssertEqual(OgentDeliverableLedger.minisURLs(inToolOutput: ""), [])
    }

    func testOnlyTheLastSectionCounts() {
        // A command that cats an earlier tool result echoes the header; the
        // real section is the one appended after the command's own output.
        let output = "[minis] New/modified files:\n  minis://workspace/old.txt\nmore output"
            + "\n\n[minis] New/modified files:\n  minis://workspace/new.mp4"
        XCTAssertEqual(OgentDeliverableLedger.minisURLs(inToolOutput: output), ["minis://workspace/new.mp4"])
    }

    // MARK: - What counts as a deliverable

    func testExcludesOffloadsBrowserAndInternalNamespaces() {
        let excluded = [
            "minis://offloads/tool_output_123.txt",
            "minis://browser/screenshot_1700000000.jpg",
            "minis://memory/notes.md",
            "minis://skills/demo/SKILL.md",
            "minis://mcp-servers/fs/config.json",
            "minis://attachments/uploads/photo.jpg",
        ]
        for url in excluded {
            XCTAssertFalse(OgentDeliverableLedger.isDeliverable(minisURL: url), url)
        }
        let included = [
            "minis://workspace/out.mp4",
            "minis://attachments/console_demo.mp4",
            "minis://shared/report.pdf",
            "minis://workspace/site/index.html",
            "minis://mounts/Documents/summary.md",
        ]
        for url in included {
            XCTAssertTrue(OgentDeliverableLedger.isDeliverable(minisURL: url), url)
        }
    }

    func testExcludesBuildAndCacheNoise() {
        let noise = [
            "minis://workspace/app/node_modules/left-pad/index.js",
            "minis://workspace/.env",
            "minis://workspace/pkg/__pycache__/mod.cpython-312.pyc",
            "minis://workspace/tool.pyc",
            "minis://workspace/.git/HEAD",
            "minis://workspace/download.part",
        ]
        for url in noise {
            XCTAssertFalse(OgentDeliverableLedger.isDeliverable(minisURL: url), url)
        }
    }

    func testKindFromExtension() {
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "clip.MP4"), .video)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "chart.png"), .image)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "voice.mp3"), .audio)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "index.html"), .html)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "report.pdf"), .pdf)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "main.py"), .code)
        XCTAssertEqual(OgentDeliverableLedger.kind(forFileName: "archive.zip"), .other)
    }

    func testMinisURLRoundTripsThroughGuestPath() throws {
        let url = try XCTUnwrap(OgentDeliverableLedger.minisURL(forPath: "/var/minis/workspace/My Clip.mp4"))
        XCTAssertEqual(url, "minis://workspace/My%20Clip.mp4")
        XCTAssertEqual(OgentDeliverableLedger.linuxPath(forMinisURL: url), "/var/minis/workspace/My Clip.mp4")
        let item = try XCTUnwrap(OgentDeliverableLedger.makeDeliverable(minisURL: url, producedAt: Date(), runIndex: 1))
        XCTAssertEqual(item.fileName, "My Clip.mp4")
        XCTAssertEqual(item.kind, .video)
        XCTAssertNil(OgentDeliverableLedger.minisURL(forPath: "/root/out.mp4"))
        XCTAssertEqual(OgentDeliverableLedger.minisURL(forPath: "minis://shared/a.txt"), "minis://shared/a.txt")
    }

    // MARK: - Collecting from the message list

    func testCollectDedupesKeepingTheLatestProduction() {
        let messages = [
            user("make a video"),
            assistant([shell(produced: ["minis://workspace/a.mp4", "minis://workspace/b.png"])]),
            user("make it longer"),
            // Reloaded block: the list comes from the persisted output.
            assistant([shell(output: toolOutput(listing: ["minis://workspace/a.mp4"]))]),
        ]
        let items = OgentDeliverableLedger.collect(from: messages)
        XCTAssertEqual(items.map(\.minisURL), ["minis://workspace/b.png", "minis://workspace/a.mp4"])
        XCTAssertEqual(items.map(\.runIndex), [1, 2])
    }

    func testCollectDropsExcludedFilesAndUnfinishedOrFailedTools() {
        let running = shell(output: toolOutput(listing: ["minis://workspace/partial.mp4"]), status: .running)
        let failedWrite = AssistantBlock(kind: .fileWriteTool(path: "/var/minis/workspace/broken.py"), content: "Error", toolStatus: .failed(message: "Error"))
        let goodWrite = AssistantBlock(kind: .fileWriteTool(path: "/var/minis/workspace/app.py"), content: "Wrote", toolStatus: .success)
        let edit = AssistantBlock(kind: .fileEditTool(path: "/var/minis/shared/notes.md"), content: "Edited", toolStatus: .success)
        let outsideMinis = AssistantBlock(kind: .fileWriteTool(path: "/root/scratch.txt"), content: "Wrote", toolStatus: .success)
        let screenshots = shell(produced: ["minis://browser/screenshot_1.jpg", "minis://offloads/out.txt", "minis://workspace/final.mp4"])
        let messages = [
            user(),
            assistant([running, failedWrite, goodWrite, edit, outsideMinis, screenshots]),
        ]
        let items = OgentDeliverableLedger.collect(from: messages)
        XCTAssertEqual(items.map(\.fileName), ["app.py", "notes.md", "final.mp4"])
    }

    func testThisRunMeansAfterTheLastUserMessage() {
        let messages = [
            user("first"),
            assistant([shell(produced: ["minis://workspace/one.png"])]),
            user("second"),
            assistant([shell(produced: ["minis://workspace/two.png", "minis://workspace/three.mp4"])]),
            // Typed while the run was going: queued, not a new run yet.
            user("third", queued: true),
        ]
        let all = OgentDeliverableLedger.collect(from: messages)
        XCTAssertEqual(OgentDeliverableLedger.currentRunIndex(in: messages), 2)
        // Newest first.
        XCTAssertEqual(
            OgentDeliverableLedger.thisRunDeliverables(all, messages: messages).map(\.fileName),
            ["three.mp4", "two.png"]
        )

        // A new user message starts a run that has produced nothing yet.
        let next = messages.dropLast() + [user("fourth")]
        XCTAssertEqual(OgentDeliverableLedger.thisRunDeliverables(all, messages: Array(next)), [])
    }

    func testReloadedShellOutputIsParsedOnceAndMemoized() {
        let block = shell(output: toolOutput(listing: ["minis://workspace/out.mp4"]))
        XCTAssertNil(block.producedMinisURLs)
        _ = OgentDeliverableLedger.collect(from: [user(), assistant([block])])
        XCTAssertEqual(block.producedMinisURLs, ["minis://workspace/out.mp4"])
    }

    // MARK: - Which run the rail describes

    func testLatestRunFollowsTheCurrentRunWhileProcessing() throws {
        let earlier = shell(produced: [])
        let messages = [user("a"), assistant([earlier]), user("b")]

        // Processing, no tool yet in the new run: the rail shows the new run.
        let active = try XCTUnwrap(OgentDeliverableLedger.latestRun(in: messages, isProcessing: true))
        XCTAssertEqual(active.runIndex, 2)
        XCTAssertTrue(active.steps.isEmpty)
        XCTAssertEqual(OgentDeliverableLedger.outcome(of: active, isProcessing: true), .active)

        // Idle after a text-only reply: keep describing the last tool run.
        let idle = try XCTUnwrap(OgentDeliverableLedger.latestRun(in: messages + [assistant([])], isProcessing: false))
        XCTAssertEqual(idle.runIndex, 1)
        XCTAssertEqual(idle.steps.map(\.id), [earlier.id])
        XCTAssertFalse(idle.isLatest)
    }

    func testSessionsWithoutToolsShowTheRailOnlyWhileWorking() throws {
        let messages = [user(), assistant([AssistantBlock(kind: .text, content: "hi")])]
        XCTAssertNil(OgentDeliverableLedger.latestRun(in: messages, isProcessing: false))
        // While a run is in flight the rail shows it (empty), so the thinking mind has a home.
        let working = try XCTUnwrap(OgentDeliverableLedger.latestRun(in: messages + [user()], isProcessing: true))
        XCTAssertTrue(working.steps.isEmpty)
        XCTAssertTrue(working.isLatest)
        XCTAssertEqual(OgentDeliverableLedger.outcome(of: working, isProcessing: true), .active)
    }

    func testRunOutcome() throws {
        let failed = try XCTUnwrap(OgentDeliverableLedger.latestRun(
            in: [user(), assistant([shell(produced: [])], error: "rate limited")], isProcessing: false))
        XCTAssertEqual(OgentDeliverableLedger.outcome(of: failed, isProcessing: false), .failed)

        let stopped = try XCTUnwrap(OgentDeliverableLedger.latestRun(
            in: [user(), assistant([shell(produced: [], status: .cancelled)])], isProcessing: false))
        XCTAssertEqual(OgentDeliverableLedger.outcome(of: stopped, isProcessing: false), .cancelled)

        let done = try XCTUnwrap(OgentDeliverableLedger.latestRun(
            in: [user(), assistant([shell(produced: [], status: .failed(message: "x")), shell(produced: [])])], isProcessing: false))
        XCTAssertEqual(OgentDeliverableLedger.outcome(of: done, isProcessing: false), .success)
    }

    func testDurationUnionsParallelStepsAndFallsBackToRecordedDurations() {
        let start = Date(timeIntervalSince1970: 1_000)
        let a = shell(produced: [])
        a.toolStartTime = start
        a.toolDuration = 10
        let b = shell(produced: [])
        b.toolStartTime = start.addingTimeInterval(5)
        b.toolDuration = 10
        let c = shell(produced: [])
        c.toolStartTime = start.addingTimeInterval(30)
        c.toolDuration = 2
        // [0,10] ∪ [5,15] ∪ [30,32] = 15 + 2
        XCTAssertEqual(OgentDeliverableLedger.duration(of: [a, b, c]), 17, accuracy: 0.001)

        // Reloaded steps have durations but no start times: sum them.
        let r1 = shell(produced: [])
        r1.toolDuration = 4
        let r2 = shell(produced: [])
        r2.toolDuration = 6
        XCTAssertEqual(OgentDeliverableLedger.duration(of: [r1, r2]), 10, accuracy: 0.001)
    }

    // MARK: - Session file snapshot (routed /var/minis namespaces)

    func testSnapshotMapsHostFilesToGuestPathsAndSeesNewFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ogent-snap-\(UUID().uuidString)", isDirectory: true)
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: attachments.appendingPathComponent("uploads"), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("a".utf8).write(to: attachments.appendingPathComponent("uploads/photo.jpg"))
        try Data("h".utf8).write(to: workspace.appendingPathComponent(".hidden"))
        let roots: [(namespace: String, url: URL)] = [("attachments", attachments), ("workspace", workspace)]

        let before = AIChatViewModel.snapshotFiles(in: roots)
        XCTAssertEqual(Set(before.keys), ["/var/minis/attachments/uploads/photo.jpg"])

        try Data("mp4".utf8).write(to: attachments.appendingPathComponent("console_demo.mp4"))
        try fm.createDirectory(at: workspace.appendingPathComponent("site"), withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: workspace.appendingPathComponent("site/index.html"))
        let after = AIChatViewModel.snapshotFiles(in: roots)
        let produced = after.filter { key, date in before[key].map { $0 < date } ?? true }
        XCTAssertEqual(Set(produced.keys), [
            "/var/minis/attachments/console_demo.mp4",
            "/var/minis/workspace/site/index.html",
        ])
        XCTAssertEqual(AIChatViewModel.snapshotFiles(in: roots, limit: 1).count, 1)
    }

    // MARK: - Live tail

    func testLastMeaningfulLineStripsANSIAndKeepsLatestProgressSegment() {
        let output = "Executing...\n\u{1B}[32mInput #0, lavfi\u{1B}[0m\nframe=   10 fps=0\rframe=   90 fps=45 \n\n"
        XCTAssertEqual(OgentConsoleText.lastMeaningfulLine(of: output), "frame=   90 fps=45")
        XCTAssertNil(OgentConsoleText.lastMeaningfulLine(of: "Executing..."))
        XCTAssertEqual(OgentConsoleText.stripANSI("\u{1B}]0;title\u{07}ok\tdone"), "ok done")
    }
}
