import Foundation
import SwiftUI
import UIKit

/// Display form of a conversation/session title. New conversations are stored
/// with the literal title "新对话" (compared as-is in ChatViewModel and
/// ShareCardView), so the stored default and missing titles are shown in the
/// UI language instead.
enum ConversationTitleDisplay {
    /// The persisted default title. Never localize: it is compared literally.
    static let storedDefault = "新对话" // i18n-ignore: persisted default-title sentinel

    static func text(_ stored: String?) -> String {
        guard let stored,
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              stored != storedDefault else {
            return String(localized: "新对话", comment: "Fallback title for an untitled conversation")
        }
        return stored
    }
}

/// A pending or sent attachment. Mirrors Web's `UploadedAttachment`:
///   - images → `dataUrl` (base64 data URL) for thumbnail display + vision send
///   - text-like files → `textContent` inlined into the prompt
///   - other binaries → name + mime only (body not parsed)
struct Attachment: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable { case image, text, file }
    let id: String
    let name: String
    let mimeType: String
    let kind: Kind
    var dataUrl: String?
    var textContent: String?

    init(id: String = UUID().uuidString, name: String, mimeType: String,
         kind: Kind, dataUrl: String? = nil, textContent: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType
        self.kind = kind; self.dataUrl = dataUrl; self.textContent = textContent
    }
}

/// Cached decode of `Attachment.dataUrl` → `UIImage`. The original code
/// decoded base64 on every view body evaluation, which caused the typing
/// lag the user reported (every keystroke re-rendered the ComposerBar,
/// which re-decoded every attached image). Keyed by attachment id.
///
/// Chips get a small downsampled thumbnail; only the preview sheet decodes a
/// large image, and only the last few of those are kept. Both caches are
/// `NSCache`s (thread-safe, purged under memory pressure) — the previous
/// dictionary held a full-resolution bitmap per attachment forever.
enum AttachmentImageCache {
    /// Long edge for 22–26 pt chips at @3x.
    static let thumbnailPixelSize = 96
    /// Long edge for the preview sheet (imports are already capped here).
    static let previewPixelSize = AttachmentImporter.maxImagePixelSize

    nonisolated(unsafe) private static let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
    nonisolated(unsafe) private static let previews: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 3
        return cache
    }()

    /// Chip-sized image for an image attachment.
    static func thumbnail(for attachment: Attachment) -> UIImage? {
        decode(attachment, in: thumbnails, maxPixelSize: thumbnailPixelSize)
    }

    /// Preview-sized image for an image attachment.
    static func image(for attachment: Attachment) -> UIImage? {
        decode(attachment, in: previews, maxPixelSize: previewPixelSize)
    }

    static func evict(_ id: String) {
        thumbnails.removeObject(forKey: id as NSString)
        previews.removeObject(forKey: id as NSString)
    }

    private static func decode(_ attachment: Attachment,
                               in cache: NSCache<NSString, UIImage>,
                               maxPixelSize: Int) -> UIImage? {
        guard attachment.kind == .image, let dataUrl = attachment.dataUrl else { return nil }
        let key = attachment.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = AttachmentImporter.decodeImage(dataURL: dataUrl, maxPixelSize: maxPixelSize) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The part of an image request that can be known before the provider starts
/// rendering. Providers that expose a ratio (currently Grok Imagine) get a
/// matching waiting surface; providers that choose the output canvas
/// themselves leave `aspect` nil so the UI uses a compact progress surface
/// instead of promising the wrong image shape.
struct ImageGenerationPlan: Equatable, Sendable {
    enum Aspect: String, CaseIterable, Equatable, Sendable {
        case square = "1:1"
        case landscape = "16:9"
        case portrait = "9:16"
        case classicLandscape = "4:3"
        case classicPortrait = "3:4"
        case photoLandscape = "3:2"
        case photoPortrait = "2:3"

        var numericRatio: Double {
            let parts = rawValue.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return 1 }
            return parts[0] / parts[1]
        }
    }

    enum Control: String, Equatable, Sendable {
        /// xAI's image endpoint accepts `aspect_ratio` and `resolution`.
        case xAIAspectRatio
        /// OpenAI-compatible image endpoints accept the established `size`
        /// values. This is kept for explicitly selected gpt-image models.
        case openAISize
        /// Chat-completions image models may select their own output canvas.
        case providerSelected
    }

    let model: String
    let control: Control
    let aspect: Aspect?
    let requestAspectRatio: String?
    let requestResolution: String?
    let requestSize: String?

    var expectedAspectRatio: Double? { aspect?.numericRatio }
    var isKnownBeforeGeneration: Bool { expectedAspectRatio != nil }

    /// Builds a request plan without probing or calling a provider. Prompt
    /// hints are intentionally conservative: only explicit aspect tokens and
    /// common unambiguous canvas words are mapped to a ratio. All other
    /// prompts use the provider's automatic canvas selection.
    static func forRequest(model: String, prompt: String) -> ImageGenerationPlan {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "－", with: "-")

        let aspect = inferredAspect(from: normalized)
        let id = model.lowercased()
        if id.contains("grok-imagine") {
            return ImageGenerationPlan(
                model: model,
                control: .xAIAspectRatio,
                aspect: aspect,
                requestAspectRatio: aspect?.rawValue ?? "auto",
                requestResolution: "1k",
                requestSize: nil
            )
        }
        if id.contains("gpt-image") {
            // The OpenAI image endpoint accepts three concrete sizes. A
            // broad landscape/portrait hint is therefore normalized to the
            // provider's actual 3:2 canvas; the placeholder must describe
            // that request, rather than claim an unsupported 16:9/4:3 size.
            let selected: Aspect
            switch aspect {
            case .portrait, .classicPortrait, .photoPortrait:
                selected = .photoPortrait
            case .landscape, .classicLandscape, .photoLandscape:
                selected = .photoLandscape
            case .square, .none:
                selected = .square
            }
            return ImageGenerationPlan(
                model: model,
                control: .openAISize,
                aspect: selected,
                requestAspectRatio: nil,
                requestResolution: nil,
                requestSize: openAISize(for: selected)
            )
        }
        return ImageGenerationPlan(
            model: model,
            control: .providerSelected,
            aspect: nil,
            requestAspectRatio: nil,
            requestResolution: nil,
            requestSize: nil
        )
    }

    private static func openAISize(for aspect: Aspect) -> String {
        switch aspect {
        case .square: return "1024x1024"
        case .landscape, .classicLandscape, .photoLandscape: return "1536x1024"
        case .portrait, .classicPortrait, .photoPortrait: return "1024x1536"
        }
    }

    private static func inferredAspect(from prompt: String) -> Aspect? {
        // Check explicit ratios first so a prompt such as "4:3 横构图"
        // remains faithful to the user's exact request.
        let explicit: [(String, Aspect)] = [
            ("16:9", .landscape), ("16/9", .landscape),
            ("9:16", .portrait), ("9/16", .portrait),
            ("4:3", .classicLandscape), ("4/3", .classicLandscape),
            ("3:4", .classicPortrait), ("3/4", .classicPortrait),
            ("3:2", .photoLandscape), ("3/2", .photoLandscape),
            ("2:3", .photoPortrait), ("2/3", .photoPortrait),
            ("1:1", .square), ("1/1", .square)
        ]
        if let match = explicit.first(where: { containsAspectToken($0.0, in: prompt) }) {
            return match.1
        }

        // Prompt-matching keywords (user input in any language), never shown in the UI.
        let landscapeWords = [
            "landscape", "wide", "widescreen", "cinematic", "横屏", "横向", // i18n-ignore: prompt-matching keywords
            "宽屏", "横构图", "风景照" // i18n-ignore: prompt-matching keywords
        ]
        if landscapeWords.contains(where: { containsHint($0, in: prompt) }) { return .landscape }

        let portraitWords = [
            "portrait", "vertical", "tall", "手机壁纸", "竖屏", "纵向", "竖构图" // i18n-ignore: prompt-matching keywords
        ]
        if portraitWords.contains(where: { containsHint($0, in: prompt) }) { return .portrait }

        // i18n-ignore: prompt-matching keywords
        if ["square", "正方形", "方形", "方构图"].contains(where: { containsHint($0, in: prompt) }) {
            return .square
        }
        return nil
    }

    private static func containsAspectToken(_ token: String, in prompt: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return prompt.range(of: "(^|[^0-9])\(escaped)([^0-9]|$)",
                            options: .regularExpression) != nil
    }

    private static func containsHint(_ hint: String, in prompt: String) -> Bool {
        let isASCIIWord = hint.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil
        if isASCIIWord {
            let escaped = NSRegularExpression.escapedPattern(for: hint)
            return prompt.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
        }
        return prompt.contains(hint)
    }
}

/// UI-facing chat message model used by ChatViewModel / ChatView.
struct ChatUIMessage: Identifiable, Equatable {
    enum Role: String, Codable, Equatable { case user, assistant, system }
    let id: String
    let role: Role
    var content: String
    var thinking: String?
    var createdAt: Date
    /// Populated for image-mode assistant messages (Web `message.imageUrl`).
    var imageUrl: String?
    /// Populated for audio-mode assistant messages (Web `message.audioUrl`).
    var audioUrl: String?
    var audioMimeType: String?
    /// Attachments shown under a user message.
    var attachments: [Attachment]?
    /// True while the assistant message is actively receiving SSE chunks.
    /// The bubble uses a lightweight plain-text renderer in this state,
    /// then swaps to the full Markdown view once the stream completes —
    /// MarkdownMessageView re-parses the entire text on every keystroke,
    /// which made long streams feel sluggish (the original perf bug).
    var isStreaming: Bool = false
    /// Tool invocations the agent loop dispatched as part of producing
    /// this assistant turn. Rendered as status pills above the assistant
    /// text. Empty for pure text replies.
    var toolCalls: [ToolCall] = []
    /// Ephemeral request metadata used to keep the image placeholder's
    /// canvas aligned with the eventual provider output. Completed messages
    /// derive their natural size from the decoded image itself, and old
    /// SwiftData rows need no migration.
    var imageGenerationPlan: ImageGenerationPlan?

    static func user(_ text: String, attachments: [Attachment]? = nil) -> ChatUIMessage {
        .init(id: UUID().uuidString, role: .user, content: text,
              thinking: nil, createdAt: .now, attachments: attachments)
    }

    static func assistantPlaceholder(content: String = "") -> ChatUIMessage {
        .init(id: UUID().uuidString, role: .assistant, content: content, thinking: nil, createdAt: .now)
    }
}

/// Wire format aligned with OpenAI-compatible upstream (api.oases.dev/v1).
/// `content` is either a plain string or a multipart array of text + image_url
/// parts — the latter is used when image attachments are sent to a
/// vision-capable model (OpenAI `image_url` content-part format).
///
/// `toolCalls` is set on assistant messages that produced tool calls; the
/// corresponding tool result message uses `role: "tool"` + `toolCallId`
/// and carries the result as plain string `content`. Both fields are
/// optional to keep the wire payload minimal for plain text turns.
struct ChatAPIMessage: Codable, Equatable, Sendable {
    let role: String
    var content: MessageContent?
    var toolCalls: [WireToolCall]?
    var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    /// Skip nil fields entirely — same reason we did this for APIContentPart:
    /// strict proxies reject `"tool_calls": null`. Custom encoding keeps
    /// the wire body minimal.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let content { try c.encode(content, forKey: .content) }
        if let toolCalls, !toolCalls.isEmpty { try c.encode(toolCalls, forKey: .toolCalls) }
        if let toolCallId { try c.encode(toolCallId, forKey: .toolCallId) }
    }

    init(role: String,
         content: MessageContent? = nil,
         toolCalls: [WireToolCall]? = nil,
         toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

/// OpenAI `tool_calls` array entry — `function` block carries the tool
/// name + JSON arguments string.
struct WireToolCall: Codable, Equatable, Sendable {
    let id: String
    let type: String  // always "function" for OpenAI
    let function: Function

    struct Function: Codable, Equatable, Sendable {
        let name: String
        /// Stringified JSON object (OpenAI accumulates this across chunks).
        let arguments: String
    }
}

enum MessageContent: Codable, Equatable, Sendable {
    case text(String)
    case parts([APIContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([APIContentPart].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }
}

/// One part of a multipart message content array.
struct APIContentPart: Codable, Equatable, Sendable {
    let type: String
    let text: String?
    let imageUrl: ImageURLBody?

    struct ImageURLBody: Codable, Equatable, Sendable {
        let url: String

        enum CodingKeys: String, CodingKey { case url }
        // Encode as `image_url: { "url": "..." }` — the snake_case `image_url`
        // is what the OpenAI-compatible upstream expects.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url, forKey: .url)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, imageUrl = "image_url"
    }

    // Custom encoding — skip nil fields entirely so the wire JSON never
    // contains `"image_url": null` or `"text": null`. Many OpenAI-compatible
    // proxies validate the multipart content schema strictly and reject any
    // part that carries a null field; that was the source of vision messages
    // arriving at the model as plain text with no images attached.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let text { try c.encode(text, forKey: .text) }
        if let imageUrl { try c.encode(imageUrl, forKey: .imageUrl) }
    }

    static func text(_ s: String) -> APIContentPart { APIContentPart(type: "text", text: s, imageUrl: nil) }
    static func image(url: String) -> APIContentPart {
        APIContentPart(type: "image_url", text: nil, imageUrl: ImageURLBody(url: url))
    }
}

extension ChatUIMessage {
    /// Plain-text wire view of a message — used for history (assistant +
    /// earlier user turns). The current user turn is composed separately so
    /// it can carry image parts.
    var api: ChatAPIMessage {
        var text = content
        if role == .user {
            // An earlier turn's attached documents stay in the history. The bubble shows only
            // the prompt, so their text is added here in the form the turn first sent them
            // (`composeWireContent`); a message that already carries it (an older row saved
            // with the text inline) is left as is.
            for block in Self.attachmentTextBlocks(attachments) where !text.contains(block.header) {
                text += text.isEmpty ? block.text : "\n\n" + block.text
            }
        }
        if role == .assistant, !toolCalls.isEmpty {
            let trail = toolCalls.map { call -> String in
                let status = call.status.rawValue
                let args = call.inputJSON ?? "{}"
                let output = (call.output ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(8_000)
                return """
                - \(call.name) [\(status)]
                  input: \(args)
                  output: \(output)
                """
            }.joined(separator: "\n")
            text += "\n\n[tool trace]\n\(trail)"
        }
        return ChatAPIMessage(role: role.rawValue, content: .text(text))
    }

    /// The text an attached document adds to a user turn: a "# name" header line and the
    /// extracted text, capped like `composeWireContent`.
    static func attachmentTextBlocks(_ attachments: [Attachment]?) -> [(header: String, text: String)] {
        (attachments ?? []).compactMap { item in
            guard item.kind == .text, let body = item.textContent else { return nil }
            let header = "# \(item.name)\n\n"
            return (header, header + String(body.prefix(80_000)))
        }
    }

    /// What the bubble shows for a saved user message: the prompt without the attached
    /// documents' text, which the row stores inline after it. The text stays in the history
    /// through `api`.
    static func displayText(persisted: String, attachments: [Attachment]?) -> String {
        guard let first = attachmentTextBlocks(attachments).first,
              let range = persisted.range(of: "\n\n" + first.header) else { return persisted }
        let prompt = persisted[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? persisted : prompt
    }
}
