import Foundation

/// [P1] Lets vendors that are **not** OpenAI-wire-compatible (Anthropic,
/// Gemini) serve the existing `ChatService.streamEvents` contract.
///
/// `ProviderChatRouting` handles the OpenAI-compatible vendors by pointing
/// `APIClient` at a different base URL — the request/response shape is
/// unchanged, so no translation is needed. Anthropic and Gemini speak their
/// own wire formats, and their ported `AgentProvider` implementations already
/// know how to do that. This bridge is the adapter between the two worlds:
///
///   ChatAPIMessage + OpenAI tools JSON  →  AgentMessage + AgentToolDefinition
///   AgentStreamEvent                    →  StreamEvent
///
/// Deliberately NOT a rewrite of the agent loop. The loop keeps consuming
/// `StreamEvent`; richer signals `AgentProvider` can emit (thinking deltas,
/// reasoning echo, usage) are dropped here because `StreamEvent` has no case
/// for them. Migrating the loop to consume `AgentStreamEvent` natively is
/// separate work — this bridge is what makes Anthropic/Gemini reachable from
/// chat *at all* in the meantime.
enum AgentProviderChatBridge {

    // MARK: - Vendor eligibility

    /// Vendors that need this bridge (i.e. everything `ProviderChatRouting`
    /// can't serve by base-URL swap alone).
    static func requiresBridge(_ type: ProviderType) -> Bool {
        switch type {
        case .anthropic, .gemini, .antigravity:
            return true
        case .openAI, .openAIResponses, .openRouter, .xAI, .kimiCode, .unsupported:
            return false
        }
    }

    // MARK: - Request translation

    /// Convert the OpenAI-shaped conversation into provider-agnostic
    /// `AgentMessage`s. The leading `system` message is pulled out — every
    /// `AgentProvider` takes the system prompt as a separate argument.
    ///
    /// Tool-call and tool-result messages are mapped onto `.toolUse` /
    /// `.toolResult` parts so multi-turn tool conversations survive the trip.
    static func translate(
        messages: [ChatAPIMessage]
    ) -> (systemPrompt: String?, agentMessages: [AgentMessage]) {
        var systemPrompt: String?
        var result: [AgentMessage] = []

        for message in messages {
            switch message.role {
            case "system":
                if case .text(let text) = message.content {
                    // Later system messages append rather than overwrite —
                    // ChatService only emits one today, but a caller adding a
                    // second shouldn't silently lose the first.
                    systemPrompt = systemPrompt.map { $0 + "\n\n" + text } ?? text
                }

            case "tool":
                // OpenAI models tool results as their own role; the agent
                // format nests them as a part of a user message.
                guard let id = message.toolCallId else { continue }
                let text: String
                if case .text(let t) = message.content { text = t } else { text = "" }
                result.append(AgentMessage(
                    role: .user,
                    parts: [.toolResult(id: id, name: "", content: text, isError: false)]
                ))

            case "assistant":
                var parts: [AgentContentPart] = []
                if case .text(let text) = message.content, !text.isEmpty {
                    parts.append(.text(text))
                }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(
                        with: Data(call.function.arguments.utf8)
                    )) as? [String: Any] ?? [:]
                    parts.append(.toolUse(id: call.id, name: call.function.name, input: input))
                }
                guard !parts.isEmpty else { continue }
                result.append(AgentMessage(role: .assistant, parts: parts))

            default:
                let parts = userParts(from: message.content)
                guard !parts.isEmpty else { continue }
                result.append(AgentMessage(role: .user, parts: parts))
            }
        }

        return (systemPrompt, result)
    }

    /// Map an OpenAI content payload onto agent parts, decoding inline
    /// `data:` image URLs so vision requests survive the translation.
    private static func userParts(from content: MessageContent?) -> [AgentContentPart] {
        switch content {
        case .text(let text):
            return text.isEmpty ? [] : [.text(text)]

        case .parts(let parts):
            return parts.compactMap { part in
                if let text = part.text, !text.isEmpty {
                    return .text(text)
                }
                guard let url = part.imageUrl?.url,
                      let (data, mime) = decodeDataURL(url) else { return nil }
                return .imageData(data: data, mimeType: mime)
            }

        case nil:
            return []
        }
    }

    /// `data:image/png;base64,<payload>` → (bytes, mime). Remote URLs return
    /// nil: fetching them here would turn a translation step into a network
    /// call, and the OpenAI path doesn't do that either.
    private static func decodeDataURL(_ url: String) -> (Data, String)? {
        guard url.hasPrefix("data:"),
              let comma = url.firstIndex(of: ","),
              let semi = url.firstIndex(of: ";"),
              semi < comma else { return nil }
        let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<semi])
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return (data, mime)
    }

    /// Parse `ToolRegistry.openAIToolsJSON` back into `AgentToolDefinition`s.
    ///
    /// `AgentToolParam` only models string/integer/boolean, so richer JSON
    /// Schema types (arrays, objects, enums-of-object) collapse to `.string`.
    /// That matches how the tools are actually invoked — every handler parses
    /// its arguments out of a JSON string anyway.
    static func translateTools(fromOpenAIJSON json: String?) -> [AgentToolDefinition] {
        guard let json,
              let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let array = raw as? [[String: Any]] else { return [] }

        return array.compactMap { entry in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let description = function["description"] as? String ?? ""
            let schema = function["parameters"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = schema["required"] as? [String] ?? []

            var params: [String: AgentToolParam] = [:]
            for (key, value) in properties {
                let spec = value as? [String: Any] ?? [:]
                params[key] = AgentToolParam(
                    type: paramType(spec["type"] as? String),
                    description: spec["description"] as? String ?? "",
                    enumValues: spec["enum"] as? [String]
                )
            }

            return AgentToolDefinition(
                name: name,
                description: description,
                parameters: params,
                required: required
            )
        }
    }

    private static func paramType(_ raw: String?) -> AgentParamType {
        switch raw {
        case "integer", "number": return .integer
        case "boolean": return .boolean
        default: return .string
        }
    }

    // MARK: - Response translation

    /// Adapt an `AgentProvider` stream into the `StreamEvent` stream the chat
    /// loop consumes.
    ///
    /// Tool calls arrive from `AgentProvider` already assembled
    /// (`.toolCallComplete`), whereas `StreamEvent.toolCallDelta` is
    /// incremental. We emit one delta carrying the whole call — the loop
    /// accumulates by index, so a single complete chunk lands correctly.
    static func streamEvents(
        from upstream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var toolIndex = 0
                do {
                    for try await event in upstream {
                        if Task.isCancelled { break }
                        switch event {
                        case .textDelta(let text):
                            continuation.yield(.textDelta(text))

                        case .toolCallComplete(let id, let name, let args, _):
                            let argumentsJSON: String
                            if let data = try? JSONSerialization.data(withJSONObject: args),
                               let string = String(data: data, encoding: .utf8) {
                                argumentsJSON = string
                            } else {
                                argumentsJSON = "{}"
                            }
                            continuation.yield(.toolCallDelta(
                                index: toolIndex,
                                id: id,
                                name: name,
                                argumentsDelta: argumentsJSON
                            ))
                            toolIndex += 1

                        case .done(let stopReason):
                            continuation.yield(.finish(reason: finishReason(stopReason)))

                        case .contentBlockStart, .toolInputDelta, .usage,
                             .thinkingDelta, .reasoningContent, .reasoningEcho:
                            // No `StreamEvent` representation. Thinking and
                            // usage are surfaced natively only once the loop
                            // consumes AgentStreamEvent directly.
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map onto the OpenAI `finish_reason` strings the loop already branches on.
    private static func finishReason(_ reason: AgentStopReason) -> String {
        switch reason {
        case .toolUse: return "tool_calls"
        case .maxTokens: return "length"
        case .refusal: return "content_filter"
        case .endTurn: return "stop"
        }
    }
}
