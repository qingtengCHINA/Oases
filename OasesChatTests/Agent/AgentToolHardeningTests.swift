import XCTest
@testable import Oases_Chat

/// Regression tests for the shell / tool hardening in review package A2:
/// retry semantics, 12306 cleanup scope, URL building from model input,
/// skill-manifest argument binding, bounded file reads, guest-script guards.
final class AgentToolHardeningTests: XCTestCase {

    // MARK: - ShellTool retry semantics

    func testOnlySpawnFailuresAreRetried() {
        XCTAssertTrue(ShellTool.isRetryableSpawnFailure(errorCode: ISHShellExecutorError.processCreationFailed.rawValue))
        for error: ISHShellExecutorError in [.timeout, .cancelled, .execFailed, .none] {
            XCTAssertFalse(ShellTool.isRetryableSpawnFailure(errorCode: error.rawValue), "\(error)")
        }
    }

    // MARK: - 12306 MCP cleanup

    func testOnlyTheSeededBuiltin12306ServerIsRemovable() {
        XCTAssertTrue(MCPSettingsStore.isBuiltin12306MCP(MCPSettingsStore.builtin12306MCP))

        let userNamed = OasesMCPServerConfig(
            name: "my-12306-helper", transport: .stdio, command: "npx", arguments: ["-y", "12306-mcp@0.3.9"])
        XCTAssertFalse(MCPSettingsStore.isBuiltin12306MCP(userNamed))

        let sameNameOwnCommand = OasesMCPServerConfig(
            name: "12306-mcp", transport: .stdio, command: "node", arguments: ["/root/my-12306.mjs"])
        XCTAssertFalse(MCPSettingsStore.isBuiltin12306MCP(sameNameOwnCommand))
    }

    // MARK: - SVG logo URLs

    func testSVGAssetURLRejectsPathSteering() {
        let base = "https://cdn.jsdelivr.net/gh/glincker/thesvg@main/public/icons"
        XCTAssertEqual(
            SVGLogoFetcherTool.assetURL(base: base, segments: ["github", "default.svg"])?.absoluteString,
            base + "/github/default.svg")
        XCTAssertEqual(
            SVGLogoFetcherTool.assetURL(base: base, segments: ["a b", "v?#.svg"])?.absoluteString,
            base + "/a%20b/v%3F%23.svg")
        for segments in [["..", "x.svg"], ["github", "../../x.svg"], ["", "x.svg"], ["a\\b", "x.svg"], [".", "x.svg"]] {
            XCTAssertNil(SVGLogoFetcherTool.assetURL(base: base, segments: segments), "\(segments)")
        }
    }

    // MARK: - Skill manifest arguments

    func testManifestArgumentsAreBoundAsShellData() {
        let resolved = ManifestBackedTool.resolvedCommand(
            template: "./run.sh \"$query\"",
            arguments: ["query": "x; rm -rf ~ $(id) it's"])
        XCTAssertEqual(resolved, "query='x; rm -rf ~ $(id) it'\"'\"'s'\n./run.sh \"$query\"")
    }

    func testOnlyReferencedNonReservedArgumentsAreBound() {
        let resolved = ManifestBackedTool.resolvedCommand(
            template: "echo ${limit} $query $PATH $queryX",
            arguments: ["query": "q", "limit": 5, "PATH": "/tmp", "LD_PRELOAD": "/tmp/x.so", "unused": "u", "bad-name": "b"])
        XCTAssertEqual(resolved, "limit='5'\nquery='q'\necho ${limit} $query $PATH $queryX")
        XCTAssertEqual(ManifestBackedTool.resolvedCommand(template: "ls", arguments: ["x": "y"]), "ls")
    }

    // MARK: - Bounded file reads

    func testSmallFileReadKeepsExactLineSemantics() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-small-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\nc".write(to: url, atomically: true, encoding: .utf8)

        let head = try BoundedFileReader.read(url, offset: 2, maxLines: 1, maxLength: 100, tail: false)
        XCTAssertEqual(head.content, "b")
        XCTAssertEqual(head.totalLines, 3)
        XCTAssertEqual(head.displayStart, 2)
        XCTAssertEqual(head.displayEnd, 2)

        let tail = try BoundedFileReader.read(url, offset: 1, maxLines: 2, maxLength: 1, tail: true)
        XCTAssertEqual(tail.content, "b")
        XCTAssertTrue(tail.truncated)
    }

    func testLargeFilesAreReadThroughAWindow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-large-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let lineCount = 700_000
        var text = ""
        text.reserveCapacity(lineCount * 13)
        for i in 1...lineCount { text += String(format: "line-%07d\n", i) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(BoundedFileReader.fileSize(url) ?? 0, BoundedFileReader.wholeFileLimit)

        let head = try BoundedFileReader.read(url, offset: 1, maxLines: 3, maxLength: 1_000, tail: false)
        XCTAssertEqual(head.content, "line-0000001\nline-0000002\nline-0000003")
        XCTAssertNil(head.totalLines)
        XCTAssertEqual(head.displayStart, 1)
        XCTAssertEqual(head.displayEnd, 3)

        let middle = try BoundedFileReader.read(url, offset: 500_000, maxLines: 2, maxLength: 1_000, tail: false)
        XCTAssertEqual(middle.content, "line-0500000\nline-0500001")
        XCTAssertEqual(middle.displayStart, 500_000)

        let tail = try BoundedFileReader.read(url, offset: 1, maxLines: 3, maxLength: 1_000, tail: true)
        XCTAssertEqual(tail.content, "line-0699999\nline-0700000\n")
        XCTAssertNil(tail.displayStart)

        let unlimited = try BoundedFileReader.read(url, offset: 1, maxLines: nil, maxLength: 80_000, tail: false)
        XCTAssertEqual(unlimited.content.count, 80_000)
        XCTAssertTrue(unlimited.truncated)

        let pastEnd = try BoundedFileReader.read(url, offset: 900_000, maxLines: 5, maxLength: 1_000, tail: false)
        XCTAssertEqual(pastEnd.content, "")
    }

    func testLargeBinaryFileIsDetectedFromItsHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-bin-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("GGUF".utf8)
        data.append(Data(count: BoundedFileReader.wholeFileLimit + 1024))
        try data.write(to: url)

        let selection = try BoundedFileReader.read(url, offset: 1, maxLines: nil, maxLength: 1_000, tail: false)
        XCTAssertEqual(selection.fileSize, data.count)
        XCTAssertTrue(selection.binaryHexPreview?.hasPrefix("47 47 55 46") == true)
        XCTAssertFalse(selection.isText)
    }

    // MARK: - Guest runtime script guards

    private func shellFunction(_ name: String) -> String? {
        let script = ISHOgentAgentRuntime.scriptContents
        guard let start = script.range(of: "\n\(name)() {\n"),
              let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex) else { return nil }
        return String(script[start.upperBound..<end.lowerBound])
    }

    func testJSONEscapeHandlesBackslashAndControlCharacters() throws {
        let body = try XCTUnwrap(shellFunction("json_escape_text"))
        XCTAssertTrue(body.contains(#"sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'"#), body)
        XCTAssertTrue(body.contains(#"tr -d '\001-\010\013\014\016-\037'"#), body)
        XCTAssertTrue(body.contains(#"gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); if (NR>1) printf "\\n""#), body)
    }

    func testRunnerInstallRequiresSHA256() throws {
        let body = try XCTUnwrap(shellFunction("model_install_runner"))
        let guardRange = try XCTUnwrap(body.range(of: "missing_or_invalid_sha256"))
        let downloadRange = try XCTUnwrap(body.range(of: "curl -L --fail"))
        XCTAssertLessThan(guardRange.lowerBound, downloadRange.lowerBound, "sha256 must be checked before downloading")
    }

    func testCheckpointRestoreChecksMembersBeforeExtracting() throws {
        let body = try XCTUnwrap(shellFunction("checkpoint_restore"))
        let listRange = try XCTUnwrap(body.range(of: "tar -tzf \"$file\""))
        let refuseRange = try XCTUnwrap(body.range(of: "/*|..|../*|*/..|*/../*)"))
        let extractRange = try XCTUnwrap(body.range(of: "tar -xzf \"$file\" -C \"$ROOT\""))
        XCTAssertLessThan(listRange.lowerBound, extractRange.lowerBound)
        XCTAssertLessThan(refuseRange.lowerBound, extractRange.lowerBound)
    }

    func test12306PackageOverrideMustBePinned() {
        let script = ISHOgentAgentRuntime.scriptContents
        XCTAssertFalse(script.contains("${OASES_12306_MCP_PACKAGE:-$UPSTREAM_12306_PACKAGE}"))
        XCTAssertTrue(script.contains("UPSTREAM_12306_PACKAGE=\"\(ISHOgentAgentRuntime.upstream12306Package)\""))
        XCTAssertTrue(ISHOgentAgentRuntime.upstream12306Package.hasSuffix("@\(ISHOgentAgentRuntime.upstream12306Version)"))
    }
}
