import Foundation
import XCTest
@testable import Oases_Chat

/// Code-review remediation (package F): error classification, base URL
/// validation, per-request body patching, persistence ordering, id_token
/// claims, system ASR watchdog.
final class ProviderRequestTests: XCTestCase {

    // MARK: - Anthropic mapError

    func testAnthropicClassificationUsesStatusAndErrorType() {
        XCTAssertEqual(AnthropicProvider.classifyError(status: 401, errorType: nil), .authentication)
        XCTAssertEqual(AnthropicProvider.classifyError(status: 429, errorType: nil), .rateLimited)
        XCTAssertEqual(AnthropicProvider.classifyError(status: 500, errorType: nil), .transient)
        XCTAssertEqual(AnthropicProvider.classifyError(status: 529, errorType: "overloaded_error"), .transient)
        XCTAssertEqual(AnthropicProvider.classifyError(status: 400, errorType: "invalid_request_error"), .other)
        XCTAssertEqual(AnthropicProvider.classifyError(status: 403, errorType: "permission_error"), .other)
        // No status (e.g. an in-stream error): the structured type decides.
        XCTAssertEqual(AnthropicProvider.classifyError(status: nil, errorType: "overloaded_error"), .transient)
        XCTAssertEqual(AnthropicProvider.classifyError(status: nil, errorType: "rate_limit_error"), .rateLimited)
        XCTAssertEqual(AnthropicProvider.classifyError(status: nil, errorType: nil), .other)
    }

    func testAnthropicMapErrorIgnoresMisleadingSubstrings() {
        let provider = AnthropicProvider(apiKey: "test-key")
        _ = LastAPIErrorBody.shared.take()
        // "generate"/"accurate" contain "rate"; "5000"/"1500" contain "500".
        let misleading = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "max_tokens: 5000 is too large; generate an accurate 1500-word summary instead",
        ])
        guard case .providerError = provider.mapError(misleading) else {
            return XCTFail("substring match must not classify this as rate-limited / transient")
        }

        LastAPIErrorBody.shared.set(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        guard case .transientError(let message) = provider.mapError(NSError(domain: "Test", code: 2)) else {
            return XCTFail("overloaded_error body should be transient")
        }
        XCTAssertTrue(message.contains("Overloaded"), message)

        LastAPIErrorBody.shared.set(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        guard case .invalidAPIKey = provider.mapError(NSError(domain: "Test", code: 3)) else {
            return XCTFail("authentication_error body should map to invalidAPIKey")
        }

        guard case .rateLimited = provider.mapError(LLMError.rateLimited) else {
            return XCTFail("an already-classified LLMError passes through")
        }
    }

    // MARK: - Base URL validation

    func testBaseURLValidation() {
        XCTAssertNil(URLBuilding.baseURLValidationError(""))
        XCTAssertNil(URLBuilding.baseURLValidationError("   "))
        XCTAssertNil(URLBuilding.baseURLValidationError("https://api.openai.com/v1"))
        XCTAssertNil(URLBuilding.baseURLValidationError("http://192.168.1.2:8080"))
        XCTAssertNil(URLBuilding.baseURLValidationError("https://x.openai.azure.com/openai?api-version=2024-10-21"))
        XCTAssertNil(URLBuilding.baseURLValidationError("  https://proxy.example.com/anthropic  "))

        XCTAssertNotNil(URLBuilding.baseURLValidationError("api.openai.com"))
        XCTAssertNotNil(URLBuilding.baseURLValidationError("ftp://files.example.com"))
        XCTAssertNotNil(URLBuilding.baseURLValidationError("localhost:8080"))
        XCTAssertNotNil(URLBuilding.baseURLValidationError("https://"))
        XCTAssertNotNil(URLBuilding.baseURLValidationError("https://exa mple.com"))
    }

    func testAnthropicSDKBaseIsSanitized() {
        XCTAssertNil(LLMProviderFactory.sdkSafeBaseURL(nil))
        XCTAssertEqual(LLMProviderFactory.sdkSafeBaseURL("https://api.anthropic.com"), "https://api.anthropic.com")
        XCTAssertEqual(LLMProviderFactory.sdkSafeBaseURL("not a url"), "https://invalid-base-url.invalid")
    }

    // MARK: - RequestBodyPatcher per-request isolation

    func testPatchContextIsDeliveredOnlyToItsOwnRequestUnderConcurrency() async throws {
        let adaptive: RequestPatchContext = {
            var c = RequestPatchContext()
            c.thinkingEffort = "high"
            return c
        }()
        let disabled: RequestPatchContext = {
            var c = RequestPatchContext()
            c.thinkingDisabled = true
            c.toolResultImages = ["tool_1": (data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")]
            return c
        }()

        // Many concurrent agent requests and unbound (warmup-like) requests at once.
        let results = try await withThrowingTaskGroup(of: PatchOutcome.self) { group in
            for i in 0..<40 {
                let kind = ["adaptive", "disabled", "none"][i % 3]
                group.addTask {
                    let request = Self.makeRequest()
                    let id: String?
                    switch kind {
                    case "adaptive": id = RequestBodyPatcher.$current.withValue(adaptive) { RequestBodyPatcher.registerCurrentContext() }
                    case "disabled": id = RequestBodyPatcher.$current.withValue(disabled) { RequestBodyPatcher.registerCurrentContext() }
                    default: id = RequestBodyPatcher.registerCurrentContext()
                    }
                    if let id { request.setValue(id, forHTTPHeaderField: RequestBodyPatcher.patchIdHeader) }
                    try await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000))
                    let context = RequestBodyPatcher.takeContext(from: request)
                    let headerStripped = request.value(forHTTPHeaderField: RequestBodyPatcher.patchIdHeader) == nil
                    RequestBodyPatcher.patchToolResultsWithImages(into: request, context: context)
                    RequestBodyPatcher.injectThinkingConfig(into: request, context: context)
                    let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
                    let toolResult = ((json["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first
                    return PatchOutcome(
                        kind: kind,
                        headerStripped: headerStripped,
                        thinkingType: (json["thinking"] as? [String: Any])?["type"] as? String,
                        effort: (json["output_config"] as? [String: Any])?["effort"] as? String,
                        toolResultHasImage: toolResult?["content"] is [[String: Any]]
                    )
                }
            }
            var all: [PatchOutcome] = []
            for try await r in group { all.append(r) }
            return all
        }

        XCTAssertEqual(results.count, 40)
        for r in results {
            XCTAssertTrue(r.headerStripped, "tag header must never reach the network")
            switch r.kind {
            case "adaptive":
                XCTAssertEqual(r.thinkingType, "adaptive")
                XCTAssertEqual(r.effort, "high")
                XCTAssertFalse(r.toolResultHasImage, "no images for this request")
            case "disabled":
                XCTAssertEqual(r.thinkingType, "disabled")
                XCTAssertNil(r.effort)
                XCTAssertTrue(r.toolResultHasImage, "this request's own images are patched in")
            default:
                XCTAssertNil(r.thinkingType, "an unbound request (e.g. a warmup) gets no thinking patch")
                XCTAssertNil(r.effort)
                XCTAssertFalse(r.toolResultHasImage)
            }
        }
    }

    private struct PatchOutcome: Sendable {
        let kind: String
        let headerStripped: Bool
        let thinkingType: String?
        let effort: String?
        let toolResultHasImage: Bool
    }

    func testPatchContextIsClaimedOnlyOnce() {
        let id = RequestBodyPatcher.$current.withValue(RequestPatchContext()) {
            RequestBodyPatcher.registerCurrentContext()
        }
        XCTAssertNotNil(id)
        XCTAssertNotNil(RequestBodyPatcher.claimContext(id: id!))
        XCTAssertNil(RequestBodyPatcher.claimContext(id: id!))
        XCTAssertNil(RequestBodyPatcher.registerCurrentContext(), "nothing bound outside withValue")
    }

    private static func makeRequest() -> NSMutableURLRequest {
        let request = NSMutableURLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tool_1", "content": "screenshot"]]],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: - Persistence ordering

    func testPersistQueueRunsInOrderAndSkipsSupersededSnapshots() async {
        let queue = ProviderPersistQueue()
        let log = OrderLog()
        for i in 0..<20 {
            let revision = queue.nextRevision()
            queue.enqueue {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0...1_000_000))
                await log.append(i, wrote: queue.isLatest(revision))
            }
        }
        await queue.drain()
        let entries = await log.entries
        XCTAssertEqual(entries.map(\.index), Array(0..<20), "writes must land in enqueue order")
        XCTAssertEqual(entries.filter(\.wrote).map(\.index), [19], "only the newest full snapshot needs writing")

        // JSON mirror: an older queued write never overwrites a newer synchronous one.
        let older = queue.nextJSONRevision()
        var written: [String] = []
        queue.writeJSONNow { written.append("save") }
        queue.writeJSONIfLatest(older) { written.append("stale merge") }
        let newer = queue.nextJSONRevision()
        queue.writeJSONIfLatest(newer) { written.append("merge") }
        XCTAssertEqual(written, ["save", "merge"])
    }

    // MARK: - Codex id_token claims

    func testCodexAccountInfoReadsNamespacedClaimWithTopLevelFallback() {
        let namespaced = Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-ns", "chatgpt_plan_type": "plus"]])
        let info = CodexOAuthManager.chatGPTAccountInfo(fromIDToken: namespaced)
        XCTAssertEqual(info.accountId, "acct-ns")
        XCTAssertEqual(info.planType, "plus")

        let topLevel = Self.jwt(["chatgpt_account_id": "acct-top", "chatgpt_plan_type": "pro"])
        let fallback = CodexOAuthManager.chatGPTAccountInfo(fromIDToken: topLevel)
        XCTAssertEqual(fallback.accountId, "acct-top")
        XCTAssertEqual(fallback.planType, "pro")

        XCTAssertNil(CodexOAuthManager.chatGPTAccountInfo(fromIDToken: "not-a-jwt").accountId)
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"none"}"#.utf8))
        let payload = b64url((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
        return "\(header).\(payload).sig"
    }

    // MARK: - System ASR watchdog

    func testRecognitionWatchdogScalesWithClipDuration() {
        XCTAssertEqual(SystemVoiceProvider.wavDurationSeconds(Self.wav(seconds: 30, sampleRate: 16_000)) ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(SystemVoiceProvider.recognitionWatchdogSeconds(forWAV: Self.wav(seconds: 1, sampleRate: 48_000)), 9, accuracy: 0.01)
        XCTAssertEqual(SystemVoiceProvider.recognitionWatchdogSeconds(forWAV: Self.wav(seconds: 60, sampleRate: 16_000)), 68, accuracy: 0.01)
        XCTAssertEqual(SystemVoiceProvider.recognitionWatchdogSeconds(forWAV: Self.wav(seconds: 300, sampleRate: 8_000)), 120, accuracy: 0.01)
        XCTAssertEqual(SystemVoiceProvider.recognitionWatchdogSeconds(forWAV: Data("garbage".utf8)), 8)
    }

    /// Canonical 16-bit mono PCM WAV of silence.
    private static func wav(seconds: Double, sampleRate: Int) -> Data {
        let dataSize = UInt32(Double(sampleRate) * seconds) * 2
        var wav = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        wav.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2); le16(2); le16(16)
        wav.append(contentsOf: Array("data".utf8)); le32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }
}

private actor OrderLog {
    struct Entry { let index: Int; let wrote: Bool }
    private(set) var entries: [Entry] = []
    func append(_ index: Int, wrote: Bool) { entries.append(Entry(index: index, wrote: wrote)) }
}
