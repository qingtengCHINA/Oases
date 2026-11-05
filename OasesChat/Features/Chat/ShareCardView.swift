//
//  ShareCardView.swift
//  OasesChat
//
//  会话分享卡片：把当前会话的最近若干条消息渲染成一张竖版长图，
//  经系统分享面板发出。普通聊天轨道（ChatView / ChatViewModel）专用。
//
//  主题策略：卡片固定为深色。分享图会被发到任何背景上，固定深色保证
//  对比度与观感一致；通过 `.preferredColorScheme(.dark)` 让 OasesColor
//  资源目录颜色解析到 Dark 变体，全程仍走设计 token，不硬编码颜色。
//

import SwiftUI
import UIKit
import BotAvatarsKit

// MARK: - Layout constants

/// 画布宽度（pt）。@3x 下输出 1260px 宽，适合社交平台长图。
private enum ShareCardLayout {
    static let canvasWidth: CGFloat = 420
    static let horizontalPadding: CGFloat = 28
    static let headerAvatarSize: Double = 44
    static let footerAvatarSize: Double = 18
    static let messageSpacing: CGFloat = 20
    /// 单张图片的最大显示高度（pt）。超长竖图按比例缩窄，不再把画布撑到上万 pt。
    static let maxImageHeight: CGFloat = 480
    /// 图片可用的最窄列宽（用户气泡一侧：画布宽 − 两侧内边距 − 48pt 留白）。
    static let narrowestImageColumn: CGFloat = canvasWidth - horizontalPadding * 2 - 48
    /// 输出位图的像素预算（约 64MB RGBA）。画布过高时自动降低渲染倍率。
    static let maxRenderPixels: CGFloat = 16_000_000
}

// MARK: - Card model

struct ShareCardMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    /// 已做 markdown 轻量清洗 + 长度截断的纯文本。
    let text: String
    /// 图片按消息中的顺序保存。图片本体不放进 Equatable 模型，导出前
    /// 由 ShareCardImageResolver 预取为 UIImage 后交给 ImageRenderer。
    let media: [ShareCardMedia]

    init(id: String, role: Role, text: String, media: [ShareCardMedia] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.media = media
    }
}

struct ShareCardMedia: Identifiable, Equatable {
    let id: String
    /// data URL、file URL 或远端 URL。GeneratedImageLoader 统一负责解析。
    let source: String
    let caption: String?
}

struct ShareCardModel: Equatable {
    let brandName: String
    /// 会话标题；nil 时不展示（空标题或默认"新对话"）。
    let conversationTitle: String?
    let generatedAt: Date
    /// 因超出条数上限而被略过的消息数；0 时不显示"前文省略"。
    let omittedMessageCount: Int
    let messages: [ShareCardMessage]
}

// MARK: - Builder（过滤 / 截断 / 清洗）

enum ShareCardBuilder {
    /// 卡片最多展示的消息条数，取最近 N 条。
    static let maxMessages = 12
    /// 单条消息最多保留的字符数，超出截断加省略号。
    static let maxCharactersPerMessage = 600
    /// 整张卡片最多展示的图片数，保留最近的；更早的图片略去。
    static let maxImages = 8

    static func make(messages: [ChatUIMessage],
                     conversationTitle: String?,
                     generatedAt: Date) -> ShareCardModel {
        // 与聊天页一致的可分享集合：保留用户/助手的文字或图片消息，
        // 跳过 pending 占位（"正在生成图片…"等）与系统消息。
        let eligible = messages.filter { msg in
            guard msg.role == .user || msg.role == .assistant else { return false }
            let messageMedia = media(for: msg)
            // An empty string is also the generic pending marker. It must not
            // hide a completed media-only message, while an actively
            // streaming placeholder must still stay out of the card.
            if msg.isStreaming && AssistantPendingView.isPending(msg.content) {
                return false
            }
            let hasText = !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if messageMedia.isEmpty && AssistantPendingView.isPending(msg.content) {
                return false
            }
            return hasText || !messageMedia.isEmpty
        }
        let window = eligible.suffix(maxMessages)
        let windowItems = window.map { msg -> ShareCardMessage in
            let cleaned = ShareCardMarkdownCleaner.plainText(msg.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = cleaned.count > maxCharactersPerMessage
                ? String(cleaned.prefix(maxCharactersPerMessage)) + "…"
                : cleaned
            return ShareCardMessage(
                id: msg.id,
                role: msg.role == .user ? .user : .assistant,
                text: text,
                media: media(for: msg)
            )
        }
        let (items, droppedForMedia) = cappingMedia(windowItems)
        let omitted = max(0, eligible.count - maxMessages) + droppedForMedia
        let trimmedTitle = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (trimmedTitle?.isEmpty == false && trimmedTitle != "新对话") // i18n-ignore: persisted default-title sentinel
            ? trimmedTitle
            : nil
        return ShareCardModel(
            brandName: OasesBrand.appName,
            conversationTitle: title,
            generatedAt: generatedAt,
            omittedMessageCount: omitted,
            messages: items
        )
    }

    /// 只保留最近的 `maxImages` 张图片（从最新消息往前数）；图片被略去后
    /// 既无文字也无图片的消息整条略去，计入"前文省略"。
    private static func cappingMedia(_ items: [ShareCardMessage]) -> (messages: [ShareCardMessage], dropped: Int) {
        var budget = maxImages
        var kept: [ShareCardMessage] = []
        var dropped = 0
        for item in items.reversed() {
            let media = Array(item.media.prefix(max(0, budget)))
            budget -= media.count
            if item.text.isEmpty && media.isEmpty && !item.media.isEmpty {
                dropped += 1
                continue
            }
            kept.append(media.count == item.media.count
                ? item
                : ShareCardMessage(id: item.id, role: item.role, text: item.text, media: media))
        }
        return (kept.reversed(), dropped)
    }

    private static func media(for message: ChatUIMessage) -> [ShareCardMedia] {
        var result: [ShareCardMedia] = []
        if let source = message.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty {
            result.append(
                ShareCardMedia(
                    id: "\(message.id)-generated-image",
                    source: source,
                    caption: String(localized: "生成的图片", comment: "Share card caption for an AI-generated image")
                )
            )
        }
        for attachment in message.attachments ?? [] {
            guard attachment.kind == .image,
                  let source = attachment.dataUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty else { continue }
            result.append(
                ShareCardMedia(
                    id: "\(message.id)-attachment-\(attachment.id)",
                    source: source,
                    caption: attachment.name.isEmpty ? nil : attachment.name
                )
            )
        }
        return result
    }
}

// MARK: - Markdown 轻量清洗

/// 把 markdown 文本降级为适合分享卡片的纯文本：去掉围栏代码标记、
/// 标题/引用/分隔线前缀、强调符号与链接语法（保留链接文字与 URL），
/// 列表符号保留（纯文本下仍然可读）。不引入新依赖，仅用 Foundation
/// 正则；模式为静态字面量，force_try 与项目内 MarkdownPrepRegex 一致。
enum ShareCardMarkdownCleaner {
    private static let fencedCode = try! NSRegularExpression(
        pattern: #"```[^\n]*\n([\s\S]*?)```"#, options: []
    )
    private static let imageWithAlt = try! NSRegularExpression(
        pattern: #"!\[([^\]]+)\]\([^)]+\)"#, options: []
    )
    private static let imageBare = try! NSRegularExpression(
        pattern: #"!\[\]\([^)]+\)"#, options: []
    )
    private static let link = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, options: []
    )
    private static let heading = try! NSRegularExpression(
        pattern: #"^#{1,6}\s+"#, options: [.anchorsMatchLines]
    )
    private static let blockquote = try! NSRegularExpression(
        pattern: #"^>\s?"#, options: [.anchorsMatchLines]
    )
    private static let horizontalRule = try! NSRegularExpression(
        pattern: #"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, options: [.anchorsMatchLines]
    )
    private static let strongStrike = try! NSRegularExpression(
        pattern: #"\*\*|__|~~"#, options: []
    )
    private static let residualMarker = try! NSRegularExpression(
        pattern: #"[\*`]"#, options: []
    )

    static func plainText(_ markdown: String) -> String {
        var text = markdown
        text = replace(fencedCode, in: text, with: "$1")
        text = replace(imageWithAlt, in: text, with: String(localized: "[图片：$1]", comment: "Share card text for a markdown image; keep $1 (the image alt text)"))
        text = replace(imageBare, in: text, with: String(localized: "[图片]", comment: "Share card text for a markdown image without alt text"))
        text = replace(link, in: text, with: "$1 ($2)")
        text = replace(heading, in: text, with: "")
        text = replace(blockquote, in: text, with: "")
        text = replace(horizontalRule, in: text, with: "")
        text = replace(strongStrike, in: text, with: "")
        text = replace(residualMarker, in: text, with: "")
        return text
    }

    private static func replace(_ regex: NSRegularExpression,
                                in text: String,
                                with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

// MARK: - ShareCardView

/// 竖版分享长图。布局自上而下：品牌区（BotAvatar + app 名 + 日期）、
/// 可选会话标题、"前文省略"标注、对话内容（用户靠右 / 助手靠左，
/// 气泡样式与聊天页 MessageRow 一致）、底部水印。
struct ShareCardView: View {
    let model: ShareCardModel
    /// ImageRenderer cannot wait for an AsyncImage view. Export callers pass
    /// this fully-resolved dictionary after ShareCardImageResolver finishes.
    let resolvedImages: [String: UIImage]

    init(model: ShareCardModel, resolvedImages: [String: UIImage] = [:]) {
        self.model = model
        self.resolvedImages = resolvedImages
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = .current
        return formatter.string(from: model.generatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let title = model.conversationTitle {
                conversationTitle(title)
                    .padding(.top, 16)
            }
            if model.omittedMessageCount > 0 {
                omittedChip
                    .padding(.top, 20)
            }
            messageList
                .padding(.top, model.conversationTitle == nil && model.omittedMessageCount == 0 ? 24 : 20)
            footerWatermark
                .padding(.top, 36)
        }
        .padding(.horizontal, ShareCardLayout.horizontalPadding)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(width: ShareCardLayout.canvasWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(OasesColor.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // 与 BridgedAssistantHeaderV3 同款配置：clover + 品牌色。
            BotAvatar(
                type: .clover,
                state: .default,
                size: ShareCardLayout.headerAvatarSize,
                color: BotColor(OasesColor.primary),
                paused: true,
                interactive: false
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(model.brandName)
                    .font(.oasesHeadline())
                    .foregroundStyle(OasesColor.foreground)
                Text(dateText)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            Spacer(minLength: 0)
        }
    }

    private func conversationTitle(_ title: String) -> some View {
        Text(title)
            .font(.oasesBodyBold())
            .foregroundStyle(OasesColor.foreground)
            .multilineTextAlignment(.leading)
    }

    // MARK: Omitted notice

    private var omittedChip: some View {
        Text("前文省略 \(model.omittedMessageCount) 条消息")
            .font(.oasesCaption())
            .foregroundStyle(OasesColor.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(OasesColor.surfaceElevated))
            .frame(maxWidth: .infinity)
    }

    // MARK: Messages

    private var messageList: some View {
        VStack(spacing: ShareCardLayout.messageSpacing) {
            ForEach(model.messages) { item in
                messageRow(item)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ item: ShareCardMessage) -> some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 10) {
                    if !item.text.isEmpty {
                        // 与聊天页用户气泡同款：品牌色淡底 + 细描边 + 大圆角。
                        Text(item.text)
                            .font(.oasesBody())
                            .foregroundStyle(OasesColor.foreground)
                            .padding(.horizontal, OasesSpacing.sm)
                            .padding(.vertical, OasesSpacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: OasesRadius.userBubble, style: .continuous)
                                    .fill(OasesColor.primary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: OasesRadius.userBubble, style: .continuous)
                                    .strokeBorder(OasesColor.primary.opacity(0.16), lineWidth: 0.5)
                            )
                    }
                    mediaList(item.media, alignment: .trailing, frameAlignment: .trailing)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !item.text.isEmpty {
                    // 与聊天页助手消息一致：无气泡纯文本，靠左。
                    Text(item.text)
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                mediaList(item.media, alignment: .leading, frameAlignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func mediaList(_ media: [ShareCardMedia],
                           alignment: HorizontalAlignment,
                           frameAlignment: Alignment) -> some View {
        if !media.isEmpty {
            VStack(alignment: alignment, spacing: 10) {
                ForEach(media) { item in
                    if let image = resolvedImages[item.source] {
                        ShareCardImageView(image: image, caption: item.caption)
                    } else {
                        // This branch is useful in an in-app preview. The
                        // exporter rejects the same missing source before
                        // ImageRenderer, so a missing image can never produce
                        // a successful share file.
                        ShareCardMissingImageView(caption: item.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    // MARK: Footer watermark

    private var footerWatermark: some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(OasesColor.border.opacity(0.6))
                .frame(height: 0.5)
            HStack(spacing: 8) {
                BotAvatar(
                    type: .clover,
                    state: .default,
                    size: ShareCardLayout.footerAvatarSize,
                    color: BotColor(OasesColor.primary),
                    paused: true,
                    interactive: false
                )
                Text("由 \(model.brandName) 生成")
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ShareCardImageView: View {
    let image: UIImage
    let caption: String?

    /// 超长竖图（按最窄列宽铺满会超过 `maxImageHeight`）给定固定尺寸：
    /// 高度封顶、宽度按比例缩小。
    private var cappedSize: CGSize? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let ratio = image.size.width / image.size.height
        guard ShareCardLayout.narrowestImageColumn / ratio > ShareCardLayout.maxImageHeight else { return nil }
        return CGSize(width: ShareCardLayout.maxImageHeight * ratio, height: ShareCardLayout.maxImageHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: cappedSize?.width, height: cappedSize?.height)
                .frame(maxWidth: cappedSize == nil ? .infinity : nil)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
                )
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
    }
}

private struct ShareCardMissingImageView: View {
    let caption: String?

    var body: some View {
        Label(caption ?? String(localized: "图片加载失败"), systemImage: "exclamationmark.triangle")
            .font(.oasesCaption())
            .foregroundStyle(OasesColor.mutedForeground)
            .padding(.vertical, 12)
    }
}

// MARK: - Image prefetch

enum ShareCardImageResolutionError: LocalizedError {
    case failed(source: String, caption: String?, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .failed(_, caption, _):
            if let caption, !caption.isEmpty {
                return String(localized: "图片“\(caption)”未能加载，请检查网络后重试")
            }
            return String(localized: "分享卡片中的图片未能加载，请检查网络后重试")
        }
    }
}

/// Resolves every image before ImageRenderer starts. This is deliberately a
/// separate step from ShareCardView: an asynchronous SwiftUI image view has
/// no guarantee of being ready when ImageRenderer snapshots its body.
@MainActor
enum ShareCardImageResolver {
    static func resolve(model: ShareCardModel) async throws -> [String: UIImage] {
        var images: [String: UIImage] = [:]
        for media in model.mediaItems {
            let source = media.source
            guard images[source] == nil else { continue }
            if let cached = GeneratedImageLoader.cached(source: source) {
                images[source] = cached
                continue
            }
            do {
                images[source] = try await GeneratedImageLoader.load(source: source)
            } catch {
                throw ShareCardImageResolutionError.failed(
                    source: source,
                    caption: media.caption,
                    underlying: error
                )
            }
        }
        return images
    }
}

extension ShareCardModel {
    var mediaItems: [ShareCardMedia] {
        var items: [ShareCardMedia] = []
        var seen = Set<String>()
        for media in messages.flatMap(\.media) where seen.insert(media.source).inserted {
            items.append(media)
        }
        return items
    }

    var mediaSources: [String] {
        mediaItems.map(\.source)
    }
}

// MARK: - Renderer (ImageRenderer)

enum ShareCardRenderer {
    private static let logger = AppLogger(category: "ShareCard")

    /// 渲染为 UIImage。ImageRenderer 的 init / scale / cgImage 均为
    /// @MainActor（见 SDK swiftinterface），因此整个渲染必须留在主线程；
    /// 卡片内容有条数与字数上限，渲染耗时可控。重编码与写盘在
    /// `ShareCardExporter` 里后台执行。
    @MainActor
    static func render(model: ShareCardModel,
                       resolvedImages: [String: UIImage] = [:]) -> UIImage? {
        guard !model.messages.isEmpty else { return nil }
        guard model.mediaSources.allSatisfy({ resolvedImages[$0] != nil }) else {
            logger.warning("render refused because one or more media sources were not resolved")
            return nil
        }
        let content = ShareCardView(model: model, resolvedImages: resolvedImages)
            .preferredColorScheme(.dark)
            .frame(width: ShareCardLayout.canvasWidth)
            .fixedSize(horizontal: false, vertical: true)
        // 先量画布高度，再按像素预算定倍率：长卡片不再以 3x 渲染出上百 MB 的位图。
        let measured = UIHostingController(rootView: content).sizeThatFits(
            in: CGSize(width: ShareCardLayout.canvasWidth, height: .greatestFiniteMagnitude)
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = renderScale(for: measured, screenScale: UIScreen.main.scale)
        renderer.isOpaque = true
        guard let image = renderer.uiImage else {
            logger.warning("render returned nil uiImage")
            return nil
        }
        return image
    }
}

extension ShareCardRenderer {
    /// 屏幕倍率与像素预算中较小者，不低于 1x。
    static func renderScale(for size: CGSize, screenScale: CGFloat) -> CGFloat {
        let points = size.width * size.height
        guard points.isFinite, points > 0 else { return screenScale }
        let budgetScale = (ShareCardLayout.maxRenderPixels / points).squareRoot()
        return max(1, min(screenScale, budgetScale))
    }
}

enum ShareCardGenerationError: LocalizedError {
    case noShareableMessages
    case renderFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noShareableMessages:
            return String(localized: "当前对话没有可分享的文字或图片")
        case .renderFailed:
            return String(localized: "分享卡片渲染失败，未生成文件")
        case .exportFailed:
            return String(localized: "分享卡片写入失败，未生成文件")
        }
    }
}

// MARK: - Exporter（后台 PNG 编码 + 写临时文件）

/// 项目内分享图片的统一模式（见 ChatTurnScreenshot.shareImage）：
/// PNG 写入 tmp 后拿文件 URL 走 UIActivityViewController。
enum ShareCardExporter {
    static func writeToTemporaryPNG(_ image: UIImage) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("share-card-\(UUID().uuidString).png")
                guard let data = image.pngData(), (try? data.write(to: url)) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}

// MARK: - Share sheet item

struct ShareCardFile: Identifiable {
    let id = UUID()
    let url: URL
}
