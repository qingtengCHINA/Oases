//
//  OgentToolboxSheet.swift
//  OasesChat
//
//  "Ogent 工具" panel opened from the composer's toolbox button. Under the
//  Oases chrome the old "…" navigation menu is not built, so this panel is the
//  entry point for session skills, MCPs, memory, the terminal, the browser,
//  the session files, token usage, thinking intensity and renaming.
//

import SwiftUI

enum OgentToolboxAction: String, CaseIterable, Identifiable {
    case skills, mcp, memory
    case terminal, browser, files
    case usage, thinking, rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skills: return String(localized: "技能")
        case .mcp: return String(localized: "MCP")
        case .memory: return String(localized: "记忆")
        case .terminal: return String(localized: "终端")
        case .browser: return String(localized: "浏览器")
        case .files: return String(localized: "文件")
        case .usage: return String(localized: "用量")
        case .thinking: return String(localized: "思考强度")
        case .rename: return String(localized: "重命名")
        }
    }

    var symbol: String {
        switch self {
        case .skills: return "puzzlepiece.extension"
        case .mcp: return "wrench.and.screwdriver"
        case .memory: return "brain.head.profile"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .files: return "folder"
        case .usage: return "chart.bar"
        case .thinking: return "lightbulb"
        case .rename: return "character.cursor.ibeam"
        }
    }
}

struct OgentToolboxSheet: View {
    /// Current thinking level's name; nil when the model has no levels.
    let thinkingLevelName: String?
    /// Renaming needs a persisted session (a draft has none yet).
    let canRename: Bool
    let onSelect: (OgentToolboxAction) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "Ogent 工具"))
                    .font(.oasesHeadline())
                    .foregroundStyle(OasesColor.foreground)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(OgentToolboxAction.allCases) { action in
                        OgentToolboxCell(
                            action: action,
                            subtitle: action == .thinking ? thinkingLevelName : nil,
                            isEnabled: isEnabled(action)
                        ) {
                            onSelect(action)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(OasesColor.background)
        .accessibilityIdentifier("ogent.toolbox")
    }

    private func isEnabled(_ action: OgentToolboxAction) -> Bool {
        switch action {
        case .thinking: return thinkingLevelName != nil
        case .rename: return canRename
        default: return true
        }
    }
}

private struct OgentToolboxCell: View {
    let action: OgentToolboxAction
    let subtitle: String?
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(OasesColor.foreground)
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(OasesColor.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5)
                    )
                Text(verbatim: action.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(1)
                // Reserved line so every cell has the same height.
                Text(verbatim: subtitle ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(OasesColor.mutedForeground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier("ogent.tools.\(action.rawValue)")
    }
}

// MARK: - Console sheets

/// Sheets owned by the console: the toolbox, the thinking-intensity picker it
/// opens, and "show in Files" for a deliverable. One modifier so AIChatView's
/// body gains a single layer. A toolbox choice runs after the toolbox has
/// finished dismissing, so the sheet it opens can present.
struct OgentConsoleSheets: ViewModifier {
    @Binding var showsToolbox: Bool
    let thinkingLevelName: String?
    let canRename: Bool
    let onToolboxAction: (OgentToolboxAction) -> Void

    @Binding var showsThinking: Bool
    let thinkingLevel: ThinkingLevel
    let availableThinkingLevels: [ThinkingLevel]
    let onSetThinkingLevel: (ThinkingLevel) -> Void

    @Binding var revealTarget: OgentDeliverable?
    let sessionId: String?

    @State private var pendingAction: OgentToolboxAction?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsToolbox, onDismiss: runPendingAction) {
                OgentToolboxSheet(thinkingLevelName: thinkingLevelName, canRename: canRename) { action in
                    pendingAction = action
                    showsToolbox = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(OasesColor.background)
            }
            .sheet(isPresented: $showsThinking) {
                ThinkingLevelSheetView(
                    currentLevel: thinkingLevel,
                    availableLevels: availableThinkingLevels,
                    onSelect: { level in
                        onSetThinkingLevel(level)
                        showsThinking = false
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $revealTarget) { target in
                OgentRevealInFilesView(deliverable: target, sessionId: sessionId)
            }
    }

    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        onToolboxAction(action)
    }
}

/// This session's file browser, opened on the deliverable's folder with the
/// file highlighted.
struct OgentRevealInFilesView: View {
    let deliverable: OgentDeliverable
    let sessionId: String?

    var body: some View {
        NavigationStack {
            if let sid = sessionId,
               let parts = OgentDeliverableLedger.components(ofMinisURL: deliverable.minisURL) {
                let root = AIChatViewModel.prepareFileBrowserRoot(for: sid)
                let folder = (parts.path as NSString).deletingLastPathComponent
                let namespaceRoot = root.appendingPathComponent(parts.namespace, isDirectory: true)
                FileBrowserView(
                    rootPath: root,
                    initialPath: folder.isEmpty ? namespaceRoot : namespaceRoot.appendingPathComponent(folder, isDirectory: true),
                    rootLabel: "/var/minis",
                    highlightFileName: deliverable.fileName
                )
            } else {
                ContentUnavailableView(
                    String(localized: "文件不可用"),
                    systemImage: "doc.questionmark"
                )
            }
        }
    }
}
