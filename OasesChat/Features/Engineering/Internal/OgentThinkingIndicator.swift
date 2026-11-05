import SwiftUI

/// What Ogent shows at the bottom of the reply while it works: the dithered "mind" turning
/// into the object for the current kind of work (a laptop while a command runs, a globe on
/// the web, a pencil while writing…), with one status line and the elapsed time. Replaces
/// the old "Ogent is thinking…" text.
struct OgentThinkingIndicator: View {
    @ObservedObject var message: ChatMessage
    let signals: AgentLiveSignals?
    /// When the run started (`AIChatViewModel.commandStartTime`).
    let startedAt: Date?

    static let mindSide: CGFloat = 104

    @State private var soulName: String = Self.currentSoulName()

    var body: some View {
        let live = message.blocks.last { OgentStepText.isLive($0.toolStatus) }
        HStack(alignment: .center, spacing: 12) {
            DitherMindView(shape: live.map { DitherMindShape.forStep($0.kind) }, signals: signals)
                .frame(width: Self.mindSide, height: Self.mindSide)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status(for: live))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .modifier(TrailShimmer(active: true))
                detailLine(for: live)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ogent.thinking")
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulName = Self.currentSoulName()
        }
    }

    @ViewBuilder
    private func detailLine(for live: AssistantBlock?) -> some View {
        let title = live.map(OgentStepText.title(of:))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = OgentConsoleFormat.duration(context.date.timeIntervalSince(startedAt))
                Text(verbatim: title.isEmpty ? elapsed : "\(title) · \(elapsed)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(ChatColors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if !title.isEmpty {
            Text(verbatim: title)
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func status(for live: AssistantBlock?) -> String {
        guard let live else {
            return String(localized: "\(soulName) is thinking")
        }
        switch live.kind {
        case .shellTool: return String(localized: "正在运行命令", comment: "Ogent thinking line: a shell command is running")
        case .browserTool: return String(localized: "正在浏览网页", comment: "Ogent thinking line: the browser is in use")
        case .fileReadTool: return String(localized: "正在读取文件", comment: "Ogent thinking line: a file is being read")
        case .fileWriteTool: return String(localized: "正在写入文件", comment: "Ogent thinking line: a file is being written")
        case .fileEditTool: return String(localized: "正在修改文件", comment: "Ogent thinking line: a file is being edited")
        case .readImageTool: return String(localized: "正在查看图片", comment: "Ogent thinking line: an image is being looked at")
        case .memoryTool: return String(localized: "正在查看记忆", comment: "Chat tool trail: saved memories are being read")
        case .text, .thinking, .info: return String(localized: "\(soulName) is thinking")
        }
    }

    private static func currentSoulName() -> String {
        let name = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? OasesBrand.assistantFallbackName : name
    }
}
