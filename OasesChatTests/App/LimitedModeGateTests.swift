import Foundation
import SwiftData
import XCTest
@testable import Oases_Chat

/// Limited mode (AI data sharing declined): every path that would send user
/// content to an AI service refuses, without consuming input or creating
/// sessions; local paths and loopback model servers keep working.
@MainActor
final class LimitedModeGateTests: XCTestCase {
    private let consent = AIDataSharingConsentFixture()

    override func setUp() {
        super.setUp()
        consent.declineForTest()
    }

    override func tearDown() {
        consent.restore()
        super.tearDown()
    }

    // MARK: - LLMProviderFactory (choke point)

    private func instance(
        _ type: ProviderType,
        credential: ProviderCredential = .apiKey,
        base: String?
    ) -> ProviderInstance {
        ProviderInstance(label: "test", providerType: type, credentialType: credential, customBaseURL: base)
    }

    func testFactoryRefusesCloudAndUnknownTargetsWithoutConsent() {
        let refused: [ProviderInstance?] = [
            nil,                                                         // stale entry
            instance(.openAI, base: nil),                                // vendor default host
            instance(.openAI, base: "https://api.example.com/v1"),
            instance(.openRouter, base: "http://127.0.0.1.nip.io/v1"),   // lookalike host
            instance(.anthropic, credential: .oauth, base: "http://127.0.0.1:8080"),
            instance(.antigravity, base: "http://127.0.0.1:8080"),
        ]
        for target in refused {
            XCTAssertThrowsError(try LLMProviderFactory.requireDataSharingConsent(for: target), "\(String(describing: target))") { error in
                XCTAssertTrue(AIDataSharingConsent.isConsentError(error))
            }
        }
    }

    func testFactoryAllowsLoopbackModelServersWithoutConsent() {
        for target in [
            instance(.openAI, base: "http://127.0.0.1:11434/v1"),
            instance(.openRouter, base: "http://localhost:8080"),
            instance(.gemini, base: "http://[::1]:9000"),
        ] {
            XCTAssertNoThrow(try LLMProviderFactory.requireDataSharingConsent(for: target))
        }
    }

    func testFactoryAllowsEverythingWithConsent() {
        consent.acceptForTest()
        XCTAssertNoThrow(try LLMProviderFactory.requireDataSharingConsent(for: instance(.openAI, base: nil)))
    }

    /// The gate runs before the instance lookup in both builders: a missing
    /// instance reports the consent error, not "no instance".
    func testMakeProviderAndMakeAgentProviderAreGated() async {
        let entry = ModelEntry(
            providerInstanceId: "limited-mode-test-\(UUID().uuidString)",
            model: LLMModel(id: "m", displayName: "M", provider: "test")
        )
        do {
            _ = try await LLMProviderFactory.makeProvider(for: entry)
            XCTFail("makeProvider must refuse in limited mode")
        } catch {
            XCTAssertTrue(AIDataSharingConsent.isConsentError(error), "\(error)")
        }
        do {
            _ = try await LLMProviderFactory.makeAgentProvider(for: entry)
            XCTFail("makeAgentProvider must refuse in limited mode")
        } catch {
            XCTAssertTrue(AIDataSharingConsent.isConsentError(error), "\(error)")
        }
        do {
            _ = try await AIChatViewModel.makeAgentProvider(for: entry)
            XCTFail("AIChatViewModel.makeAgentProvider must refuse in limited mode")
        } catch {
            XCTAssertTrue(AIDataSharingConsent.isConsentError(error), "\(error)")
        }

        consent.acceptForTest()
        do {
            _ = try await LLMProviderFactory.makeProvider(for: entry)
            XCTFail("unknown instance")
        } catch {
            XCTAssertFalse(AIDataSharingConsent.isConsentError(error), "with consent the lookup decides: \(error)")
        }
    }

    // MARK: - APIClient

    func testAPIClientGatesContentEndpointsByHost() throws {
        let cloud = APIClient(baseURL: URL(string: "https://api.example.test/v1")!, apiKey: "k")
        XCTAssertThrowsError(try cloud.makeRequest(path: "chat/completions")) { error in
            XCTAssertTrue(AIDataSharingConsent.isConsentError(error))
        }
        XCTAssertThrowsError(try cloud.makeRequest(path: "images/generations"))
        // Model lists carry no user content.
        XCTAssertNoThrow(try cloud.makeRequest(path: "models", method: "GET"))

        let local = APIClient(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, apiKey: nil)
        XCTAssertNoThrow(try local.makeRequest(path: "chat/completions"))
    }

    /// The "local model" setting accepts any http(s) URL; only a loopback
    /// one is actually on the device.
    func testLocalModelRouteToARemoteHostIsStillGated() {
        let remote = APIClient(route: .init(
            baseURL: URL(string: "http://192.168.1.20:11434/v1")!,
            apiKey: nil,
            kind: .localISHModel
        ))
        XCTAssertThrowsError(try remote.makeRequest(path: "chat/completions"))

        let local = APIClient(route: .init(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: nil,
            kind: .localISHModel
        ))
        XCTAssertNoThrow(try local.makeRequest(path: "chat/completions"))
    }

    // MARK: - View-model send entry points

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ConversationModel.self, MessageModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }

    func testChatSendKeepsInputAndCreatesNothing() async throws {
        let vm = ChatViewModel()
        vm.bind(context: try makeContext())
        vm.input = "hello"

        await vm.send()

        XCTAssertEqual(vm.input, "hello")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.conversation)
        XCTAssertFalse(vm.isStreaming)
    }

    func testRetryDoesNotTruncateTheTranscript() throws {
        let vm = ChatViewModel()
        vm.bind(context: try makeContext())
        let first = ChatUIMessage.user("first")
        vm.messages = [first, .user("second")]

        vm.retryFromMessage(first.id)

        XCTAssertEqual(vm.messages.map(\.content), ["first", "second"])
        XCTAssertFalse(vm.isStreaming)
    }

    func testInterruptedRunIsNotResumedInLimitedMode() async throws {
        let vm = ChatViewModel()
        vm.bind(context: try makeContext())

        await vm.resumeLatestInterruptedProjectRunIfNeeded()

        XCTAssertFalse(vm.didAttemptInterruptedProjectRecovery, "the one-shot attempt must not be spent in limited mode")
        XCTAssertTrue(vm.messages.isEmpty)
    }

    // MARK: - App Intents

    private func conversationCount() throws -> Int {
        try ModelContext(ConversationContainer.shared).fetchCount(FetchDescriptor<ConversationModel>())
    }

    private func assertRefused(_ name: String, _ perform: () async throws -> Void) async {
        do {
            try await perform()
            XCTFail("\(name) must refuse in limited mode")
        } catch {
            guard case .dataSharingConsentRequired? = error as? SessionIntentError else {
                return XCTFail("\(name): unexpected \(error)")
            }
        }
    }

    func testSendingIntentsRefuseBeforeCreatingASession() async throws {
        let before = try conversationCount()

        var send = SendPromptIntent()
        send.prompt = "hello"
        await assertRefused("SendPromptIntent") { _ = try await send.perform() }

        var ask = AskOasesIntent()
        ask.prompt = "hello"
        await assertRefused("AskOasesIntent") { _ = try await ask.perform() }

        // Parameters left unset on purpose: the gate is the first statement,
        // so `perform()` never reads them.
        await assertRefused("QuickTaskIntent") { _ = try await QuickTaskIntent().perform() }
        await assertRefused("FollowUpSessionIntent") { _ = try await FollowUpSessionIntent().perform() }
        await assertRefused("RetryRunIntent") { _ = try await RetryRunIntent().perform() }

        XCTAssertEqual(try conversationCount(), before, "no session may be created in limited mode")
    }

    func testIntentErrorIsLocalized() {
        let resource = SessionIntentError.dataSharingConsentRequired.localizedStringResource
        XCTAssertFalse(String(localized: resource).isEmpty)
    }

    func testGuestSessionsBridgeRefusesWithoutCreatingASession() throws {
        let before = try conversationCount()
        // Off the main thread like the guest bridge: a missing gate would
        // block on the semaphore instead of failing the expectation.
        let done = expectation(description: "bridge returned")
        let results = BridgeResults()
        DispatchQueue.global().async {
            results.send = SessionsOffloadBridge.sendPrompt(
                sessionId: nil, prompt: "hello", attachmentPaths: [], modelEntryId: nil, source: "test"
            )
            results.retry = SessionsOffloadBridge.retryMessage(sessionId: UUID().uuidString, messageId: nil, attachmentPaths: [])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(results.send?["ok"] as? Bool, false)
        XCTAssertEqual(results.send?["error"] as? String, "ai_data_sharing_consent_required")
        XCTAssertEqual(results.retry?["error"] as? String, "ai_data_sharing_consent_required")
        XCTAssertEqual(try conversationCount(), before)
    }

    // MARK: - Voice

    func testCloudVoiceRefusesWithItsOwnError() async {
        let cloud = VoiceProvider(providerId: "test", baseURL: "https://voice.example.test", apiKey: "k")
        do {
            _ = try await cloud.transcribe(VoiceInputRequest(audioData: Data([0, 1, 2])))
            XCTFail("cloud ASR must refuse in limited mode")
        } catch {
            guard case .dataSharingConsentRequired? = error as? VoiceProviderError else {
                return XCTFail("unexpected \(error)")
            }
        }
        do {
            _ = try await cloud.synthesize(VoiceOutputRequest(input: "hi"))
            XCTFail("cloud TTS must refuse in limited mode")
        } catch {
            XCTAssertTrue(AIDataSharingConsent.isConsentError(error), "\(error)")
        }
    }

    func testResolverKeepsOnlySystemAndLoopbackVoices() {
        let system = ProviderInstance(
            id: SystemVoiceProvider.builtinProviderId, label: "System",
            providerType: .openAI, credentialType: .apiKey
        )
        let cloudInstance = instance(.openAI, base: "https://voice.example.test")
        let cloud = VoiceProvider(providerId: cloudInstance.id, baseURL: "https://voice.example.test")
        let loopback = VoiceProvider(providerId: "local", baseURL: "http://127.0.0.1:8000")

        XCTAssertTrue(VoiceProviderResolver.consentAllows(system, provider: SystemVoiceProvider.shared))
        XCTAssertFalse(VoiceProviderResolver.consentAllows(cloudInstance, provider: cloud))
        XCTAssertTrue(VoiceProviderResolver.consentAllows(cloudInstance, provider: loopback))

        consent.acceptForTest()
        XCTAssertTrue(VoiceProviderResolver.consentAllows(cloudInstance, provider: cloud))
    }

    // MARK: - Error copy

    func testConsentErrorsGetTheirOwnBannerCopy() {
        let generic = ChatErrorCopy.message(for: NSError(domain: "x", code: 1))
        for error: Error in [APIError.dataSharingConsentRequired, VoiceProviderError.dataSharingConsentRequired] {
            let copy = ChatErrorCopy.message(for: error)
            XCTAssertNotEqual(copy, generic)
            XCTAssertEqual(copy, String(localized: "需要先同意 AI 数据共享，才能发送给 AI。"))
        }
    }

    // MARK: - Automations

    func testWithdrawingConsentCancelsPendingRefreshAndAgreeingResumes() {
        var resumed = 0
        var cancelled = 0
        var voided = 0

        AIConsentAutomationLifecycle.consentDidChange(
            isAccepted: false, resume: { resumed += 1 }, cancelPending: { cancelled += 1 }, voidRequests: { voided += 1 }
        )
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(resumed, 0)
        XCTAssertEqual(voided, 1, "withdrawing stops the AI requests under way (`AIRequestGate`)")

        AIConsentAutomationLifecycle.consentDidChange(
            isAccepted: true, resume: { resumed += 1 }, cancelPending: { cancelled += 1 }, voidRequests: { voided += 1 }
        )
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(voided, 1, "agreeing voids nothing")
    }

    func testScheduledAutomationRunReChecksConsent() async {
        let summary = await OgentAutomationScheduler.runDueForSelfTest(reason: "limited_mode_test")
        XCTAssertTrue(summary.contains("consent_required=1"), summary)
    }
}

/// Written on a background queue, read after the expectation is fulfilled.
private final class BridgeResults: @unchecked Sendable {
    var send: NSDictionary?
    var retry: NSDictionary?
}
