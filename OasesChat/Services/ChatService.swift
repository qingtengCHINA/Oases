import Foundation
import AVFoundation

/// Chat + media client for OpenAI-compatible endpoints. Project mode can
/// route model inference directly to a user-configured provider while all
/// engineering tools and artifacts stay on the device-local Ogent runtime.
actor ChatService {
    private let client: APIClient
    /// Long-timeout client for image generation — higher-quality models can
    /// take well over the default 60s, so the request must not be cut off.
    private let imageClient: APIClient
    /// Streaming client with a long per-request timeout so long generations
    /// that pause between chunks (>60s) aren't killed mid-stream.
    private let streamClient: APIClient
    private let decoder: JSONDecoder

    init(client: APIClient = APIClient(),
         imageClient: APIClient = APIClient(session: APIClient.longTimeout),
         streamClient: APIClient = APIClient(session: APIClient.streaming)) {
        self.client = client
        self.imageClient = imageClient
        self.streamClient = streamClient
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = dec
    }

    // MARK: - Text chat (streaming)

    /// Streaming chat with full event fidelity — emits text deltas, tool
    /// call deltas, and the terminal finish-reason. The agent loop in
    /// `ChatViewModel` uses this directly so it can detect when the
    /// model asks for a tool, dispatch it, then re-stream with the
    /// tool result appended to the history. `toolsJSON` is the raw
    /// OpenAI `tools` array JSON (built by `ToolRegistry`); pass nil
    /// when the surface doesn't expose any tools.
    func streamEvents(
        messages: [ChatAPIMessage],
        model: String,
        effort: String? = nil,
        surface: AgentSurface? = nil,
        toolsJSON: String? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let category: Models.Category
        if surface == .project {
            category = .project
        } else if surface == .chat {
            category = .text
        } else {
            category = Models.category(for: model)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                // [Stage 2.3] A picked model may be a user-configured provider
                // entry ("entry:<instanceId>/<modelId>"). Resolve it to the
                // vendor model id + route before building the prompt/body so
                // the system prompt names the real model, not the internal id.
                let userRoute = await MainActor.run { ProviderChatRouting.route(for: model) }

                // [P1] Anthropic / Gemini entries can't ride the OpenAI-wire
                // path — hand them to AgentProviderChatBridge, which speaks
                // their format via the ported AgentProvider and adapts the
                // result back onto this same StreamEvent contract.
                if userRoute == nil,
                   let bridged = await MainActor.run(body: { Self.bridgedEntry(for: model) }) {
                    guard AIDataSharingConsent.isAccepted else {
                        continuation.finish(throwing: APIError.dataSharingConsentRequired)
                        return
                    }
                    do {
                        let prompt = ChatService.systemPrompt(for: bridged.model.id, surface: surface)
                        let assembled = [ChatAPIMessage(role: "system", content: .text(prompt))] + messages
                        let stream = try await Self.bridgedStream(
                            entry: bridged,
                            messages: assembled,
                            toolsJSON: toolsJSON
                        )
                        for try await event in stream {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        NSLog("[ChatService] bridged stream failed: \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // An `entry:` whose instance still exists but can't be routed
                // (credential missing/expired, unsupported vendor) must not be
                // silently served by the default Oases model — same rule as
                // `generateImage`. Only a stale id (instance deleted) falls back
                // to the built-in default instead of posting a synthetic model id.
                if userRoute == nil, ProviderChatRouting.isEntryId(model),
                   await MainActor.run(body: { ProviderChatRouting.resolve(modelId: model) != nil }) {
                    continuation.finish(throwing: APIError.server(String(localized: "所选提供商当前不可用（请检查登录状态或 API Key），或换用其他模型", comment: "Chat error: the selected provider cannot be used (check sign-in or API key) or pick another model")))
                    return
                }
                let promptModel = userRoute?.modelOverride
                    ?? (ProviderChatRouting.isEntryId(model)
                        ? Models.defaultModel(for: category)
                        : Models.sanitizedId(model, category: category))
                let systemPrompt = ChatService.systemPrompt(for: promptModel, surface: surface)
                let assembledMessages = [ChatAPIMessage(role: "system", content: .text(systemPrompt))] + messages

                var requestSummary = Self.streamRequestSummary(
                    messages: assembledMessages,
                    hasTools: toolsJSON != nil,
                    bodyBytes: 0
                )
                do {
                    let projectRoute = try await Self.resolveProjectRouteForStreaming(surface: surface)
                    let requestModel = projectRoute?.modelOverride ?? promptModel
                    if surface == .project, let projectRoute {
                        NSLog(
                            "[ChatService] project_route kind=%@ host=%@ model=%@",
                            projectRoute.kind.rawValue,
                            projectRoute.hostDescription,
                            requestModel
                        )
                    } else if let userRoute {
                        NSLog(
                            "[ChatService] provider_route kind=%@ host=%@ model=%@",
                            userRoute.kind.rawValue,
                            userRoute.hostDescription,
                            requestModel
                        )
                    }
                    let payload = ChatRequest(
                        model: requestModel,
                        messages: assembledMessages,
                        stream: true,
                        temperature: category == .project ? 0.35 : 0.6,
                        effort: effort,
                        reasoningEffort: effort,
                        streamOptions: StreamOptions(includeUsage: true)
                    )
                    let baseBody = try encoder.encode(payload)
                    // Inject `tools` and `tool_choice: "auto"` by patching
                    // the serialized JSON when present. We don't add a
                    // tools field to ChatRequest itself because the
                    // schema is already valid JSON.
                    let body: Data
                    if let toolsJSON {
                        body = try Self.injectTools(into: baseBody, toolsJSON: toolsJSON)
                    } else {
                        body = baseBody
                    }
                    requestSummary = Self.streamRequestSummary(
                        messages: assembledMessages,
                        hasTools: toolsJSON != nil,
                        bodyBytes: body.count
                    )
                    let activeStreamClient: APIClient
                    if surface == .project, let route = projectRoute {
                        activeStreamClient = APIClient(route: route, session: APIClient.streaming)
                    } else if let userRoute {
                        activeStreamClient = APIClient(route: userRoute, session: APIClient.streaming)
                    } else {
                        activeStreamClient = streamClient
                    }
                    let bytes = try await activeStreamClient.bytes(path: "chat/completions", body: body)
                    var toolIndexer = StreamToolCallIndexer()
                    var loggedUndecodableChunk = false
                    for try await raw in SSEDecoder.events(from: bytes) {
                        if Task.isCancelled { break }
                        guard let data = raw.data(using: .utf8) else { continue }
                        // One decode per chunk; the error payload is only
                        // parsed again when the chunk carries (or failed to
                        // decode around) an `error` key.
                        let chunk = try? decoder.decode(ChatStreamChunk.self, from: data)
                        if chunk == nil || chunk?.error != nil,
                           let streamError = Self.streamAPIError(from: data) {
                            continuation.finish(throwing: APIError.server(streamError))
                            return
                        }
                        guard let chunk else {
                            // Log the shape problem once per stream (no
                            // payload: it can carry the reply text).
                            if !loggedUndecodableChunk {
                                loggedUndecodableChunk = true
                                NSLog("[ChatService] skipped an undecodable stream chunk (\(data.count) bytes)")
                            }
                            continue
                        }
                        if let usage = chunk.usage {
                            let input = usage.promptTokens ?? 0
                            let output = usage.completionTokens ?? 0
                            if input > 0 || output > 0 {
                                UsageLedger.record(modelId: requestModel, input: input, output: output)
                                continuation.yield(.usage(input: input, output: output))
                            }
                        }
                        guard let choice = chunk.choices?.first else { continue }
                        if let text = choice.delta?.content, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        if let calls = choice.delta?.toolCalls {
                            for (offset, entry) in calls.enumerated() {
                                let index = toolIndexer.resolve(
                                    index: entry.index,
                                    id: entry.id,
                                    offsetInChunk: offset
                                )
                                continuation.yield(.toolCallDelta(
                                    index: index,
                                    id: entry.id,
                                    name: entry.function?.name,
                                    argumentsDelta: entry.function?.arguments
                                ))
                            }
                        }
                        if let reason = choice.finishReason {
                            continuation.yield(.finish(reason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    NSLog("[ChatService] streamEvents failed: \(error.localizedDescription); \(requestSummary)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Bridged (non-OpenAI-wire) vendors

    /// The picked entry when it belongs to a vendor that needs
    /// `AgentProviderChatBridge` (Anthropic / Gemini), else nil.
    @MainActor
    private static func bridgedEntry(for modelId: String) -> ModelEntry? {
        guard let (entry, instance) = ProviderChatRouting.resolve(modelId: modelId),
              AgentProviderChatBridge.requiresBridge(instance.providerType),
              instance.isEnabled, instance.hasAnyCredential else { return nil }
        return entry
    }

    private static func bridgedStream(
        entry: ModelEntry,
        messages: [ChatAPIMessage],
        toolsJSON: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let provider = try await LLMProviderFactory.makeAgentProvider(for: entry)
        let (systemPrompt, agentMessages) = AgentProviderChatBridge.translate(messages: messages)
        let tools = AgentProviderChatBridge.translateTools(fromOpenAIJSON: toolsJSON)
        let upstream = try await provider.streamAgentMessage(
            messages: agentMessages,
            systemPrompt: systemPrompt,
            tools: tools,
            maxTokens: provider.defaultMaxTokens
        )
        return AgentProviderChatBridge.streamEvents(from: upstream)
    }

    private static func resolveProjectRouteForStreaming(surface: AgentSurface?) async throws -> AIProviderRouting.Route? {
        guard surface == .project else { return nil }

        if let localRoute = OgentLocalModelSettingsStore.projectRoute {
            let readiness = await OgentLocalModelRuntime.prepareForProjectInference { line in
                NSLog("[ChatService] project_local_model %@", line.trimmingCharacters(in: .newlines))
            }
            guard readiness.isRealInferenceReady else {
                throw LocalModelRouteError.notReady(readiness.summary)
            }
            return localRoute
        }

        if let customRoute = AIProviderRouting.nonLocalProjectRoute {
            return customRoute
        }

        let automaticLocalRoute = await OgentLocalModelRuntime.automaticProjectRouteIfReady { line in
            NSLog("[ChatService] project_auto_local_model %@", line.trimmingCharacters(in: .newlines))
        }
        if let route = automaticLocalRoute.route {
            NSLog("[ChatService] %@", automaticLocalRoute.summary)
            return route
        }
        NSLog("[ChatService] %@", automaticLocalRoute.summary)
        return AIProviderRouting.effectiveProjectRoute
    }

    /// Splice the `tools` JSON array + `tool_choice: "auto"` into an
    /// already-serialized chat completions body. Pure string patching
    /// so we don't have to invent an Encodable shape for `tools`.
    private static func injectTools(into body: Data, toolsJSON: String) throws -> Data {
        guard var s = String(data: body, encoding: .utf8) else { return body }
        let injection = ",\"tools\":\(toolsJSON),\"tool_choice\":\"auto\""
        if let closeIdx = s.lastIndex(of: "}") {
            s.insert(contentsOf: injection, at: closeIdx)
        }
        return Data(s.utf8)
    }

    /// OpenAI-compatible SSE can emit `{"error":{"message":"..."}}` instead of
    /// a `choices` chunk. `try? decode(ChatStreamChunk)` used to swallow that.
    private static func streamAPIError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] else { return nil }
        if let dict = err as? [String: Any] {
            if let message = dict["message"] as? String, !message.isEmpty {
                return message
            }
            if let type = dict["type"] as? String, !type.isEmpty {
                return type
            }
        }
        if let message = err as? String, !message.isEmpty {
            return message
        }
        return String(localized: "流式响应错误", comment: "Generic error shown when a streaming reply fails without a message")
    }

    private static func streamRequestSummary(messages: [ChatAPIMessage], hasTools: Bool, bodyBytes: Int) -> String {
        let messageShape = messages.enumerated().map { index, message in
            let contentChars = contentLength(message.content)
            let toolCalls = message.toolCalls?.count ?? 0
            let toolResult = message.toolCallId == nil ? "" : " tool_result=true"
            return "#\(index):\(message.role) content_chars=\(contentChars) tool_calls=\(toolCalls)\(toolResult)"
        }.joined(separator: " | ")
        return "body_bytes=\(bodyBytes) has_tools=\(hasTools) messages=\(messages.count) \(messageShape)"
    }

    private static func contentLength(_ content: MessageContent?) -> Int {
        guard let content else { return 0 }
        switch content {
        case .text(let text):
            return text.count
        case .parts(let parts):
            return parts.reduce(0) { partial, part in
                partial + (part.text?.count ?? 0) + (part.imageUrl?.url.count ?? 0)
            }
        }
    }

    // MARK: - Image generation

    /// `POST images/generations` with the provider-supported image controls.
    /// Grok Imagine receives `aspect_ratio` + `resolution`; explicitly chosen
    /// gpt-image models receive one of their supported `size` values. Returns
    /// either a remote URL or a `data:image/png;base64,...` data URL — mirrors
    /// Web `sendImage` + `extractMediaUrl` (iOS only ships the non-reve models).
    ///
    /// `referenceImages` (data URLs) are forwarded as both `image` (first one)
    /// and `images[]` (array) — common image-to-image conventions across the
    /// OpenAI/Stable-Diffusion proxies behind `api.oases.dev`. Servers that
    /// don't understand the field will ignore it. The prompt is passed
    /// verbatim — no "（已附加 X 张参考图片）" wrapper is injected, so the
    /// model sees the user's intent untouched.
    func generateImage(prompt: String, model: String, effort: String? = nil,
                       referenceImages: [String] = [],
                       plan: ImageGenerationPlan? = nil) async throws -> String {
        guard AIDataSharingConsent.isAccepted else {
            throw APIError.dataSharingConsentRequired
        }
        let userRoute = await MainActor.run { ProviderChatRouting.route(for: model) }
        // A custom `entry:` selection without an OpenAI-compatible route
        // must not silently fall through to the default Oases image client.
        // That could send the request to a different provider/account than
        // the user selected (Gemini/unsupported entries need a dedicated
        // image bridge before they can be offered here).
        if ProviderChatRouting.isEntryId(model), userRoute == nil {
            throw APIError.server(String(localized: "所选提供商暂不支持此图像请求，请换用可用图像模型", comment: "Image generation error: selected provider does not support this request"))
        }
        let vendorModel = await MainActor.run { ProviderChatRouting.vendorModelId(for: model) }
        let requestModel = userRoute?.modelOverride
            ?? vendorModel
            ?? Models.sanitizedId(model, category: .image)
        let generationPlan = plan ?? ImageGenerationPlan.forRequest(model: requestModel, prompt: prompt)
        let activeClient = userRoute.map { APIClient(route: $0, session: APIClient.longTimeout) } ?? imageClient
        // api.oases.dev only accepts grok-imagine* and gpt-image* on
        // /images/generations. Gemini image and gpt-5.4-image-2 answer on
        // /chat/completions and return `message.images[].image_url.url`.
        if Self.usesImagesGenerationsEndpoint(requestModel) {
            return try await generateImageViaImagesAPI(
                prompt: prompt,
                model: requestModel,
                effort: effort,
                referenceImages: referenceImages,
                plan: generationPlan,
                client: activeClient
            )
        }
        return try await generateImageViaChat(
            prompt: prompt,
            model: requestModel,
            referenceImages: referenceImages,
            plan: generationPlan,
            client: activeClient
        )
    }

    /// Gateway allow-list for `/v1/images/generations`.
    private static func usesImagesGenerationsEndpoint(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.contains("grok-imagine") || id.contains("gpt-image")
    }

    private func generateImageViaImagesAPI(
        prompt: String,
        model: String,
        effort: String?,
        referenceImages: [String],
        plan: ImageGenerationPlan,
        client: APIClient
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
        ]
        switch plan.control {
        case .xAIAspectRatio:
            // These keys are forwarded by the Oases proxy and are the xAI
            // image-generation controls. `auto` is intentional when the
            // prompt did not establish a canvas; the UI then stays compact
            // until the returned image reveals its real ratio.
            body["aspect_ratio"] = plan.requestAspectRatio ?? "auto"
            body["resolution"] = plan.requestResolution ?? "1k"
            // A base64 response survives the provider's temporary URL
            // lifetime and is still accepted by the existing extractor.
            body["response_format"] = "b64_json"
        case .openAISize:
            body["size"] = plan.requestSize ?? "1024x1024"
        case .providerSelected:
            // Keep the legacy square fallback only for an endpoint that has
            // no explicit plan. The catalog currently routes these models
            // through chat/completions instead, so this is defensive.
            body["size"] = plan.requestSize ?? "1024x1024"
        }
        if let effort { body["effort"] = effort }
        if let first = referenceImages.first { body["image"] = first }
        if !referenceImages.isEmpty { body["images"] = referenceImages }
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, _) = try await client.data(path: "images/generations", body: data)
        UsageLedger.record(json: responseData, modelId: model)
        return try Self.extractImagesAPIURL(responseData)
    }

    private func generateImageViaChat(
        prompt: String,
        model: String,
        referenceImages: [String],
        plan _: ImageGenerationPlan,
        client: APIClient
    ) async throws -> String {
        let userContent: Any
        if referenceImages.isEmpty {
            userContent = prompt
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": prompt]]
            for url in referenceImages {
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            userContent = parts
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": userContent]],
            "stream": false,
        ]
        // OpenRouter-backed image chats default max_tokens to the model
        // ceiling (65536) and 402 when the account can't cover that. A few
        // thousand is enough for the image payload.
        if model.lowercased().contains("gpt") {
            body["max_tokens"] = 2048
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, _) = try await client.data(path: "chat/completions", body: data)
        UsageLedger.record(json: responseData, modelId: model)
        return try Self.extractChatImageURL(responseData)
    }

    private static func extractImagesAPIURL(_ responseData: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first else {
            throw APIError.decode(URLError(.cannotParseResponse))
        }
        if let url = first["url"] as? String, !url.isEmpty { return url }
        if let b64 = first["b64_json"] as? String, !b64.isEmpty {
            return b64.hasPrefix("data:") ? b64 : "data:image/png;base64,\(b64)"
        }
        throw APIError.decode(URLError(.cannotParseResponse))
    }

    private static func extractChatImageURL(_ responseData: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw APIError.decode(URLError(.cannotParseResponse))
        }
        if let images = message["images"] as? [[String: Any]] {
            for image in images {
                if let url = imageURLString(image["image_url"]) { return url }
                if let url = image["url"] as? String, !url.isEmpty { return url }
            }
        }
        if let content = message["content"] as? String, let url = firstImageURL(in: content) {
            return url
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if let url = imageURLString(part["image_url"]) { return url }
            }
        }
        throw APIError.decode(URLError(.cannotParseResponse))
    }

    private static func imageURLString(_ value: Any?) -> String? {
        if let url = value as? String, !url.isEmpty { return url }
        if let dict = value as? [String: Any], let url = dict["url"] as? String, !url.isEmpty {
            return url
        }
        return nil
    }

    private static func firstImageURL(in text: String) -> String? {
        if text.hasPrefix("data:image") { return text }
        if let range = text.range(of: "data:image") {
            let tail = text[range.lowerBound...]
            let end = tail.firstIndex(where: { $0.isWhitespace || $0 == ")" || $0 == "\"" }) ?? tail.endIndex
            return String(tail[..<end])
        }
        return nil
    }

    // MARK: - Text-to-speech (audio)

    /// `POST chat/completions` with the TTS model and the text-to-speak sent
    /// as an `assistant` message, `stream: false`. Extracts the synthesized
    /// audio from `choices[0].message.audio` — mirrors Web `sendTts` +
    /// `getAudioPayload`. Returns a data URL + MIME.
    func synthesizeSpeech(text: String, model: String) async throws -> (url: String, mime: String) {
        guard AIDataSharingConsent.isAccepted else {
            throw APIError.dataSharingConsentRequired
        }
        let userRoute = await MainActor.run { ProviderChatRouting.route(for: model) }
        let requestModel = userRoute?.modelOverride ?? Models.sanitizedId(model, category: .audio)
        let body: [String: Any] = [
            "model": requestModel,
            "messages": [["role": "assistant", "content": text]],
            "stream": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let activeClient = userRoute.map { APIClient(route: $0) } ?? client
        let (responseData, _) = try await activeClient.data(path: "chat/completions", body: data)
        UsageLedger.record(json: responseData, modelId: requestModel)

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw APIError.decode(URLError(.cannotParseResponse))
        }

        let audio = (message["audio"] as? [String: Any]) ?? (json["audio"] as? [String: Any]) ?? [:]

        if let url = audio["url"] as? String, !url.isEmpty {
            let mime = AudioMime.fromDataUrl(url) ?? "audio/mpeg"
            return (url, mime)
        }
        if let b64 = (audio["data"] as? String) ?? (json["data"] as? String), !b64.isEmpty {
            let mime = AudioMime.fromBase64(b64)
            let dataUrl = b64.hasPrefix("data:") ? b64 : "data:\(mime);base64,\(b64)"
            return (dataUrl, mime)
        }
        throw APIError.decode(URLError(.cannotParseResponse))
    }

    // MARK: - System prompt

    /// Mirrors Web `buildSystemPrompt`: the active agent profile's
    /// surface-specific system prompt (chat vs project) plus an
    /// identity line so the model answers "what model are you"
    /// correctly. Project mode uses the longer prompt that steers
    /// the model toward `shell_local` for code work.
    static func systemPrompt(for modelId: String, surface: AgentSurface? = nil) -> String {
        let meta = Models.option(for: modelId)
        let label = meta?.label ?? modelId
        let surfacePrompt: String
        switch surface {
        case .project:
            surfacePrompt = AgentCatalogue.project.systemPrompt
        default:
            surfacePrompt = AgentCatalogue.chat.systemPrompt
        }
        return [
            surfacePrompt,
            surface == .project ? AIProviderRouting.projectPromptNote : nil,
            "你当前通过 Oases Chat 以 \(label)（模型 ID: \(modelId)）身份提供回复。", // i18n-ignore: model-facing system prompt
            "如果历史消息里出现过其他模型、自我介绍或厂商身份，那是旧上下文，不代表当前模型身份。", // i18n-ignore: model-facing system prompt
            "如果用户询问“你是什么模型”或类似问题，请明确回答当前模型是 \(label)。", // i18n-ignore: model-facing system prompt
        ].compactMap { $0 }.joined(separator: "\n")
    }

    // i18n-ignore: model-facing system prompt
    static let defaultSystemPrompt = """
    你是简洁的技术专家，同时也是一个无所不知的 AI 助手。没有空洞，只有事实。但同时也不要丢掉幽默感，适当时候可以尖锐直率一些。

    工具使用规则（重要）：
    - 用户请求生成 / 绘制 / 画图 / 设计图像时，**必须调用 image_gen 工具**，不要尝试自己描述或返回 base64。image_gen 内部会自动切到 Oases 图像模型。
    - 用户请求朗读 / 合成语音时，调用 speech_synth 工具。
    - 需要查询当前网络信息（新闻、实时价格、近期事件）时，调用 web_search 工具。
    - 工具结果会自动嵌入到下一轮上下文，你只需基于结果继续对话。

    若用户的请求只是普通对话 / 知识问答，直接回答即可，**不要无脑调工具**。
    """
}

// MARK: - MIME inference for base64 audio

enum AudioMime {
    /// Mirrors Web `inferAudioMimeTypeFromBase64` — WAV magic `UklG`, MP3 ID3
    /// `SUQz` / `/+M` / `//uQ`, defaulting to `audio/mpeg`.
    static func fromBase64(_ b64: String) -> String {
        let s = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("UklG") { return "audio/wav" }
        if s.hasPrefix("SUQz") || s.hasPrefix("/+M") || s.hasPrefix("//uQ") { return "audio/mpeg" }
        return "audio/mpeg"
    }

    static func fromDataUrl(_ url: String) -> String? {
        guard url.hasPrefix("data:"), let semi = url.firstIndex(of: ";") else { return nil }
        return String(url[url.index(url.startIndex, offsetBy: 5)..<semi])
    }
}

private enum LocalModelRouteError: LocalizedError {
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let summary):
            return String(localized: "iSH 本机模型未达到真实推理就绪状态：\(summary)", comment: "Error: the local iSH model is not ready for inference; argument is a diagnostic summary")
        }
    }
}

// MARK: - Wire types

private struct StreamOptions: Encodable {
    let includeUsage: Bool
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatAPIMessage]
    let stream: Bool
    let temperature: Double
    let effort: String?
    let reasoningEffort: String?
    let streamOptions: StreamOptions
}

/// Decoding is deliberately lenient: some OpenAI-compatible gateways
/// (Gemini compat layers, a few proxies) omit `index` on tool-call deltas or
/// send a final `{"choices":[{"finish_reason":"stop"}]}` with no `delta`.
/// With strict fields the whole chunk failed to decode and was skipped, so
/// tool calls never assembled and the `finish` event was lost. Well-formed
/// chunks decode exactly as before.
private struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCallEntry]?

            private enum CodingKeys: String, CodingKey {
                case content, toolCalls
            }

            /// Absorbs one malformed array element so the loop can move past it.
            private struct SkippedElement: Decodable {
                init(from decoder: Decoder) throws {}
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = try? c.decodeIfPresent(String.self, forKey: .content)
                // Decode tool calls element by element: one odd entry used to
                // take the text delta in the same chunk down with it.
                if var list = try? c.nestedUnkeyedContainer(forKey: .toolCalls) {
                    var entries: [ToolCallEntry] = []
                    while !list.isAtEnd {
                        if let entry = try? list.decode(ToolCallEntry.self) {
                            entries.append(entry)
                        } else if (try? list.decode(SkippedElement.self)) == nil {
                            break
                        }
                    }
                    toolCalls = entries
                } else {
                    toolCalls = nil
                }
            }
        }
        struct ToolCallEntry: Decodable {
            /// Optional on the wire; `StreamToolCallIndexer` fills it in.
            let index: Int?
            let id: String?
            let type: String?
            let function: FunctionDelta?
        }
        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
        let delta: Delta?
        let finishReason: String?
    }
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
    }
    /// Presence marker for an `{"error": …}` payload (object or string);
    /// the message itself is read by `streamAPIError(from:)`.
    struct ErrorMarker: Decodable {
        init(from decoder: Decoder) throws {}
    }
    let choices: [Choice]?
    let usage: Usage?
    let error: ErrorMarker?
}

/// Assigns a stable slot to tool-call deltas that arrive without `index`.
/// A wire `index` always wins (that is the well-formed path); otherwise a
/// known `id` maps back to its slot, a new `id` opens the next slot, and an
/// id-less fragment continues the most recent call (or, before any call has
/// been seen, takes its position in the chunk).
private struct StreamToolCallIndexer {
    private var slotForId: [String: Int] = [:]
    private var lastSlot: Int?
    private var nextFreeSlot = 0

    mutating func resolve(index: Int?, id: String?, offsetInChunk: Int) -> Int {
        let slot: Int
        if let index {
            slot = index
        } else if let id, !id.isEmpty, let known = slotForId[id] {
            slot = known
        } else if let id, !id.isEmpty {
            slot = nextFreeSlot
        } else if let lastSlot {
            slot = lastSlot
        } else {
            slot = offsetInChunk
        }
        if let id, !id.isEmpty { slotForId[id] = slot }
        lastSlot = slot
        nextFreeSlot = max(nextFreeSlot, slot + 1)
        return slot
    }
}

/// Output of `ChatService.streamEvents` — the agent loop pattern-matches
/// on it to either accumulate text into the current bubble or build up a
/// pending `ToolCall` set across multiple `toolCallDelta` events.
enum StreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String?)
    case finish(reason: String?)
    case usage(input: Int, output: Int)
}

protocol OgentChatStreaming: Sendable {
    func streamEvents(
        messages: [ChatAPIMessage],
        model: String,
        effort: String?,
        surface: AgentSurface?,
        toolsJSON: String?
    ) async -> AsyncThrowingStream<StreamEvent, Error>
}

extension ChatService: OgentChatStreaming {}
