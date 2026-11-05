//
//  OgentConsoleDock.swift
//  OasesChat
//
//  The Ogent "console": the activity rail (what Ogent is doing on its Linux
//  computer right now, and what the last run produced) sitting on top of the
//  composer card, drawn as one card with one outline.
//
//  Every piece is a small standalone struct: AIChatView's body sits close to
//  the runtime type-metadata depth that crashed in
//  `__swift_instantiateConcreteTypeFromMangledNameV2`, so nothing here is
//  built inline in that body.
//

import BorderBeamKit
import SwiftUI
import UIKit

// MARK: - Console shell

/// The console card's single silhouette: fill, hairline, shadow and the
/// streaming border beam. Drawn as the composer card's background; when the
/// activity rail sits on the card it is stretched up behind the rail by
/// `extendsTop`, so rail + composer read as one card.
struct OgentConsoleShell: View {
    /// Height of the activity rail above the composer card (0 without one).
    var extendsTop: CGFloat
    var isProcessing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The compact console's corner radius (the text-chat composer keeps its own).
    static let radius: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        shape
            .fill(OasesColor.card.opacity(0.92))
            .overlay(shape.strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5))
            .oasesShadow(.overlay)
            // Same beam the Oases chat composer shows while a reply streams.
            .borderBeam(
                .md,
                colorVariant: .colorful,
                theme: .auto,
                active: isProcessing && !reduceMotion,
                borderRadius: Double(Self.radius),
                strength: 0.8
            )
            .padding(.top, -extendsTop)
            .allowsHitTesting(false)
    }
}

/// 36pt bare icon for the compact composer's bottom row.
struct OgentComposerIconLabel: View {
    let systemName: String
    var tint: Color = OasesColor.mutedForeground
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }
}

/// 32pt primary circle: send, queue (while a run is going and there is text)
/// or stop (while a run is going and the composer is empty). The 36pt row
/// around it keeps the tap area.
struct OgentSendButton: View {
    enum Mode: Equatable {
        case send, enqueue, stop
    }

    let mode: Mode
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: mode == .stop ? 11 : 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isEnabled ? OasesColor.primary : OasesColor.primary.opacity(0.4)))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .keyboardShortcut(mode == .stop ? nil : KeyboardShortcut(.return, modifiers: .command))
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(mode == .stop ? "ogent.composer.stop" : "ogent.composer.send")
    }

    private var accessibilityText: String {
        switch mode {
        case .send: return String(localized: "发送")
        case .enqueue: return String(localized: "排队发送")
        case .stop: return String(localized: "停止")
        }
    }
}

/// Top line of the composer card while this session waits for another
/// session's task to release the shared Linux runtime.
struct OgentSuspendedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(OasesColor.mutedForeground)
            Text(String(localized: "正在等待其他任务完成…"))
                .font(.system(size: 12))
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ogent.composer.suspended")
    }
}

// MARK: - Activity rail

/// Decides which run the rail describes, and re-decides whenever the latest
/// assistant message changes: tool blocks are appended to an existing message
/// (and flip status) without the view model publishing, so observing the
/// message is what keeps the rail live. Renders nothing — zero height — when
/// the session has never called a tool.
struct OgentActivityRailHost: View {
    /// The latest assistant message; its `blocks` grow during a run.
    @ObservedObject var tail: ChatMessage
    let messages: [ChatMessage]
    let isProcessing: Bool
    /// All session deliverables (`AIChatViewModel.deliverables`).
    let deliverables: [OgentDeliverable]
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    var onOpenDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onShareDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onRevealDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onOpenAllFiles: () -> Void = {}

    var body: some View {
        if let run = OgentDeliverableLedger.latestRun(in: messages, isProcessing: isProcessing) {
            OgentActivityRail(
                run: run,
                isProcessing: isProcessing,
                deliverables: OgentDeliverableLedger.deliverables(deliverables, inRun: run.runIndex),
                toolSnapshots: toolSnapshots,
                browserPool: browserPool,
                onBrowserTakeover: onBrowserTakeover,
                onTakeoverDone: onTakeoverDone,
                onOpenDeliverable: onOpenDeliverable,
                onShareDeliverable: onShareDeliverable,
                onRevealDeliverable: onRevealDeliverable,
                onOpenAllFiles: onOpenAllFiles
            )
        }
    }
}

/// Replaces the OpenMinis `FloatingToolBar`. Running: the current step (icon,
/// title, live output tail) plus a step track. Idle: the run summary and the
/// files it produced. Tapping the rail opens `ToolLiveSheet` on the selected
/// step; tapping a track segment selects that step.
struct OgentActivityRail: View {
    let run: OgentRun
    let isProcessing: Bool
    /// Files produced by `run`, newest first.
    let deliverables: [OgentDeliverable]
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    var onOpenDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onShareDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onRevealDeliverable: (OgentDeliverable) -> Void = { _ in }
    var onOpenAllFiles: () -> Void = {}

    /// A step the user picked on the track; nil follows the live step.
    @State private var selectedStepID: UUID?
    @State private var showsSteps = false
    @AppStorage("toolPreviewEnabled") private var toolPreviewEnabled: Bool = true

    static let maxDeliverableCards = 12

    private var displayedIndex: Int? {
        if let id = selectedStepID, let i = run.steps.firstIndex(where: { $0.id == id }) {
            return i
        }
        return OgentDeliverableLedger.defaultStepIndex(in: run.steps)
    }

    var body: some View {
        let steps = run.steps
        let outcome = OgentDeliverableLedger.outcome(of: run, isProcessing: isProcessing)
        let index = displayedIndex
        let followsStep = selectedStepID != nil || outcome == .active
        // The thinking "mind" lives in the conversation (`OgentThinkingIndicator`); the rail
        // keeps to the step, its track and the files.
        VStack(alignment: .leading, spacing: 9) {
            header(steps: steps, outcome: outcome, index: index, followsStep: followsStep, showsIcon: true)
            OgentStepTrack(
                steps: steps,
                highlightedIndex: followsStep ? index : nil,
                onSelect: select
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !steps.isEmpty else { return }
            showsSteps = true
        }
        .overlay(alignment: .bottom) {
            // Seam between the rail and the composer below it.
            Rectangle()
                .fill(OasesColor.border.opacity(0.6))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ogent.activity.rail")
        .sheet(isPresented: $showsSteps) {
            ToolLiveSheet(
                toolBlocks: steps,
                initialIdx: index ?? max(0, steps.count - 1),
                toolSnapshots: toolSnapshots,
                browserPool: browserPool,
                onBrowserTakeover: onBrowserTakeover,
                onTakeoverDone: onTakeoverDone
            )
        }
        // A new step (or a new run) returns the rail to following live work.
        .onChange(of: steps.count) { selectedStepID = nil }
        .onChange(of: run.runIndex) { selectedStepID = nil }
    }

    @ViewBuilder
    private func header(steps: [AssistantBlock], outcome: OgentRun.Outcome, index: Int?, followsStep: Bool, showsIcon: Bool) -> some View {
        if steps.isEmpty {
            OgentThinkingHeader(showsIcon: showsIcon)
        } else if followsStep, let index {
            OgentStepHeader(
                block: steps[index],
                position: index + 1,
                total: steps.count,
                showsTail: toolPreviewEnabled,
                showsIcon: showsIcon
            )
        } else {
            OgentRunSummaryHeader(
                outcome: outcome,
                stepCount: steps.count,
                duration: OgentDeliverableLedger.duration(of: steps),
                fallbackLine: steps.last.map(OgentStepText.title(of:)) ?? "",
                deliverables: Array(deliverables.prefix(Self.maxDeliverableCards)),
                hiddenDeliverableCount: max(0, deliverables.count - Self.maxDeliverableCards),
                onOpen: onOpenDeliverable,
                onShare: onShareDeliverable,
                onReveal: onRevealDeliverable,
                onOpenAllFiles: onOpenAllFiles
            )
        }
    }

    private func select(_ index: Int) {
        guard run.steps.indices.contains(index) else { return }
        let id = run.steps[index].id
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedStepID = (selectedStepID == id) ? nil : id
        }
    }
}

// MARK: - Rail headers

/// One step: kind icon, title, live tail (or path / URL), `3/7` counter.
struct OgentStepHeader: View {
    @ObservedObject var block: AssistantBlock
    let position: Int
    let total: Int
    /// `toolPreviewEnabled`: off shows the title line only.
    let showsTail: Bool
    /// False while the thinking mind stands in for the icon.
    var showsIcon: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsIcon {
                OgentToolIconTile(
                    symbol: OgentStepText.symbol(for: block.kind),
                    tint: OgentStepText.tint(for: block.toolStatus),
                    isLive: OgentStepText.isLive(block.toolStatus)
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: OgentStepText.title(of: block))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    OgentRailCounter(position: position, total: total)
                }
                if showsTail, let detail = OgentStepText.detail(of: block) {
                    Text(verbatim: detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(minHeight: 32)
        }
    }
}

/// Processing, but the run has not called a tool yet.
struct OgentThinkingHeader: View {
    var showsIcon: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsIcon {
                OgentToolIconTile(symbol: "sparkles", tint: OasesColor.primary, isLive: true)
            }
            Text(String(localized: "正在思考…"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OasesColor.foreground)
                .lineLimit(1)
                .frame(minHeight: 32)
            Spacer(minLength: 0)
        }
    }
}

/// A finished run: outcome, step count and time, then the files it made.
struct OgentRunSummaryHeader: View {
    let outcome: OgentRun.Outcome
    let stepCount: Int
    let duration: TimeInterval
    /// Shown when the run produced no files: the last step's title.
    let fallbackLine: String
    let deliverables: [OgentDeliverable]
    let hiddenDeliverableCount: Int
    let onOpen: (OgentDeliverable) -> Void
    let onShare: (OgentDeliverable) -> Void
    let onReveal: (OgentDeliverable) -> Void
    let onOpenAllFiles: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            OgentToolIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: deliverables.isEmpty ? 2 : 6) {
                HStack(spacing: 6) {
                    Text(verbatim: OgentConsoleFormat.summary(outcome: outcome, stepCount: stepCount, duration: duration))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                if deliverables.isEmpty {
                    Text(verbatim: fallbackLine)
                        .font(.system(size: 11))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                } else {
                    OgentDeliverableStrip(
                        deliverables: deliverables,
                        hiddenCount: hiddenDeliverableCount,
                        onOpen: onOpen,
                        onShare: onShare,
                        onReveal: onReveal,
                        onOpenAllFiles: onOpenAllFiles
                    )
                }
            }
            .frame(minHeight: 32)
        }
    }

    private var symbol: String {
        switch outcome {
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "stop.circle"
        case .active, .success: return "checkmark.seal"
        }
    }

    private var tint: Color {
        switch outcome {
        case .failed: return OasesColor.destructive
        case .cancelled: return OasesColor.mutedForeground
        case .active, .success: return OasesColor.emerald
        }
    }
}

/// `3/7` + expand chevron.
struct OgentRailCounter: View {
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(position)/\(total)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(OasesColor.mutedForeground)
        .fixedSize()
    }
}

/// 28pt rounded tile with the step's symbol; a soft expanding halo while live.
struct OgentToolIconTile: View {
    let symbol: String
    let tint: Color
    var isLive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay {
                if isLive && !reduceMotion {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tint, lineWidth: 1.5)
                        .phaseAnimator([false, true]) { ring, expanded in
                            ring
                                .opacity(expanded ? 0 : 0.5)
                                .scaleEffect(expanded ? 1.35 : 1)
                        } animation: { expanded in
                            expanded ? .easeOut(duration: 1.4) : nil
                        }
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Step track

/// One 3pt capsule per tool call, coloured by status. The latest 24 are
/// shown; earlier ones fold into a leading `+N`.
struct OgentStepTrack: View {
    let steps: [AssistantBlock]
    let highlightedIndex: Int?
    let onSelect: (Int) -> Void

    static let maxVisible = 24

    var body: some View {
        let hidden = max(0, steps.count - Self.maxVisible)
        HStack(spacing: 3) {
            if steps.isEmpty {
                Capsule(style: .continuous)
                    .fill(OasesColor.muted)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
            } else {
                if hidden > 0 {
                    Text(verbatim: "+\(hidden)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .padding(.trailing, 2)
                        .fixedSize()
                }
                ForEach(Array(steps.enumerated().dropFirst(hidden)), id: \.element.id) { pair in
                    OgentStepSegment(block: pair.element, isHighlighted: pair.offset == highlightedIndex)
                        .onTapGesture { onSelect(pair.offset) }
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

struct OgentStepSegment: View {
    @ObservedObject var block: AssistantBlock
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        capsule
            .frame(height: isHighlighted ? 5 : 3)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .contentShape(Rectangle())
    }

    /// Running steps shimmer; finished ones are solid.
    @ViewBuilder
    private var capsule: some View {
        let shape = Capsule(style: .continuous).fill(OgentStepText.tint(for: block.toolStatus))
        if OgentStepText.isLive(block.toolStatus) && !reduceMotion {
            shape.phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        } else {
            shape.opacity(isHighlighted ? 1 : 0.6)
        }
    }
}

// MARK: - Deliverables

/// Horizontally scrolling file cards plus the trailing "all files" card.
struct OgentDeliverableStrip: View {
    let deliverables: [OgentDeliverable]
    let hiddenCount: Int
    let onOpen: (OgentDeliverable) -> Void
    let onShare: (OgentDeliverable) -> Void
    let onReveal: (OgentDeliverable) -> Void
    let onOpenAllFiles: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(deliverables) { item in
                    OgentDeliverableChip(
                        deliverable: item,
                        onOpen: { onOpen(item) },
                        onShare: { onShare(item) },
                        onReveal: { onReveal(item) }
                    )
                }
                OgentAllFilesChip(extraCount: hiddenCount, action: onOpenAllFiles)
            }
        }
        .frame(height: 28)
    }
}

struct OgentDeliverableChip: View {
    let deliverable: OgentDeliverable
    let onOpen: () -> Void
    let onShare: () -> Void
    let onReveal: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                OgentDeliverableIcon(deliverable: deliverable)
                Text(verbatim: deliverable.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .padding(.leading, 2)
            .padding(.trailing, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(OasesColor.muted.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onShare) {
                Label(String(localized: "分享"), systemImage: "square.and.arrow.up")
            }
            Button(action: onReveal) {
                Label(String(localized: "在文件中显示"), systemImage: "folder")
            }
            Button {
                UIPasteboard.general.string = deliverable.linuxPath ?? deliverable.minisURL
            } label: {
                Label(String(localized: "复制路径"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel(Text(verbatim: deliverable.fileName))
        .accessibilityIdentifier("ogent.deliverable.\(deliverable.fileName)")
    }
}

/// 24pt kind icon; images show a thumbnail of the file itself.
struct OgentDeliverableIcon: View {
    let deliverable: OgentDeliverable
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OasesColor.primary.opacity(0.12))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: Self.symbol(for: deliverable.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OasesColor.primary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: deliverable.minisURL) {
            guard deliverable.kind == .image else { return }
            await loadThumbnail()
        }
    }

    static func symbol(for kind: OgentDeliverable.Kind) -> String {
        switch kind {
        case .video: return "play.rectangle.fill"
        case .image: return "photo"
        case .audio: return "waveform"
        case .html: return "safari"
        case .pdf: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    private func loadThumbnail() async {
        guard let url = URL(string: deliverable.minisURL) else { return }
        // Fingerprinted key: a regenerated file at the same path reloads.
        let key = "ogent.deliverable.thumb:" + minisMediaCacheKey(for: url)
        if let cached = NativeMediaImageCache.shared.image(for: key) {
            thumbnail = cached
            return
        }
        guard let fileURL = resolveMinisFileURLCached(url: url) else { return }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return downsampleImageData(data, maxPixelSize: 96)
        }.value
        guard let image, !Task.isCancelled else { return }
        NativeMediaImageCache.shared.set(image, for: key)
        thumbnail = image
    }
}

/// Opens this session's file browser.
struct OgentAllFilesChip: View {
    let extraCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "全部文件"))
                    .font(.system(size: 12, weight: .medium))
                if extraCount > 0 {
                    Text(verbatim: "+\(extraCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
            .foregroundStyle(OasesColor.mutedForeground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.8), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ogent.deliverable.all")
    }
}

// MARK: - Text & formatting

enum OgentStepText {
    static func title(of block: AssistantBlock) -> String {
        let summary = block.toolSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = summary.isEmpty ? block.toolDescription : summary
        return raw.replacingOccurrences(of: "\n", with: " ")
    }

    /// Second line: the shell's latest output line, or the path / URL the
    /// tool works on.
    static func detail(of block: AssistantBlock) -> String? {
        switch block.kind {
        case .shellTool(let command):
            if let line = OgentConsoleText.lastMeaningfulLine(of: block.content) { return line }
            let cmd = (command.isEmpty ? block.toolDescription : command)
                .replacingOccurrences(of: "\n", with: " ")
            // Without a summary the title already is the command.
            return title(of: block) == cmd ? nil : "$ " + cmd
        case .fileReadTool(let path), .fileWriteTool(let path), .fileEditTool(let path), .readImageTool(let path):
            return path.isEmpty ? nil : path
        case .browserTool(let action):
            if let url = block.browserURL, !url.isEmpty { return url }
            return action.isEmpty ? nil : action
        case .memoryTool(let action):
            return action.isEmpty ? nil : action
        case .text, .thinking, .info:
            return nil
        }
    }

    static func symbol(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return "terminal"
        case .browserTool: return "globe"
        case .fileReadTool: return "doc.text"
        case .fileWriteTool: return "square.and.pencil"
        case .fileEditTool: return "pencil.line"
        case .readImageTool: return "photo"
        case .memoryTool: return "brain"
        case .text, .thinking, .info: return "sparkles"
        }
    }

    static func isLive(_ status: ToolBlockStatus?) -> Bool {
        switch status {
        case .streaming, .running: return true
        default: return false
        }
    }

    static func tint(for status: ToolBlockStatus?) -> Color {
        switch status {
        case .streaming, .running: return OasesColor.primary
        case .success: return OasesColor.emerald
        case .failed: return OasesColor.destructive
        case .cancelled, .none: return OasesColor.mutedForeground
        }
    }
}

enum OgentConsoleFormat {
    static func steps(_ count: Int) -> String {
        String(localized: "\(count) 步")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded())
        if total < 60 {
            return String(localized: "\(total) 秒")
        }
        if total < 3600 {
            let minutes = total / 60
            let secs = total % 60
            return secs == 0 ? String(localized: "\(minutes) 分") : String(localized: "\(minutes) 分 \(secs) 秒")
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? String(localized: "\(hours) 小时") : String(localized: "\(hours) 小时 \(minutes) 分")
    }

    /// `完成 7 步 · 42 秒` / `出错 · 3 步 · 12 秒` / `已停止 · 2 步 · 5 秒`.
    static func summary(outcome: OgentRun.Outcome, stepCount: Int, duration seconds: TimeInterval) -> String {
        let stepsText = steps(stepCount)
        let timeText = duration(seconds)
        switch outcome {
        case .failed: return String(localized: "出错 · \(stepsText) · \(timeText)")
        case .cancelled: return String(localized: "已停止 · \(stepsText) · \(timeText)")
        case .active, .success: return String(localized: "完成 \(stepsText) · \(timeText)")
        }
    }
}
