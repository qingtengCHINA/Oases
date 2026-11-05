import SwiftUI
import UIKit
import ThinkingOrbsKit

/// Grouped action trail for the project agent. It gives shell/tool
/// calls a visible "Ogent is working" lane instead
/// of scattering generic pills through the assistant bubble.
struct OgentActivityStack: View {
    let calls: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OasesColor.foreground)
                Text("Ogent")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(OasesColor.foreground)
            }

            HStack(spacing: 8) {
                Label("深度思考", systemImage: "brain.head.profile")
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.primary)
                Text("\(calls.count) tools")
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.primary.opacity(0.82))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OasesColor.primary.opacity(0.82))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.02, green: 0.06, blue: 0.09).opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(OasesColor.primary.opacity(0.28), lineWidth: 0.6)
            )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(calls) { call in
                    ToolCallPill(call: call, compactShellStyle: true)
                }
            }
        }
    }
}

/// Inline pill rendered above the assistant's text when the agent
/// loop invoked one or more tools. Tracks the five `ToolCallStatus`
/// states with distinct icon + colour so the user can see what the
/// model is currently doing without diving into details. Tools that
/// produced an openable file (file_write) get a tap-to-preview /
/// share affordance — see `openableFilePath`.
struct ToolCallPill: View {
    let call: ToolCall
    var compactShellStyle: Bool = false
    @State private var showingFilePreview = false
    @State private var showingShellTerminal = false

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: compactShellStyle ? 17 : 14, weight: .bold, design: .rounded))
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    if let durationText {
                        Text(durationText)
                            .font(.system(size: compactShellStyle ? 13 : 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(OasesColor.mutedForeground.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                if let detail = subtitle {
                    Text(detail)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Exported/written file → preview/share. Shell-only calls
            // keep the terminal detail sheet.
            if openableFilePath != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OasesColor.primary)
            } else if isShellLike {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OasesColor.mutedForeground.opacity(0.65))
            }
        }
        .padding(.horizontal, compactShellStyle ? 18 : 12)
        .padding(.vertical, compactShellStyle ? 12 : 8)
        .background(
            Capsule(style: .continuous)
                .fill(pillFill)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.5))
        .frame(maxWidth: 380, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if openableFilePath != nil {
                showingFilePreview = true
            } else if isShellLike {
                showingShellTerminal = true
            }
        }
        .sheet(isPresented: $showingFilePreview) {
            if let path = openableFilePath {
                ToolFilePreviewSheet(filePath: path)
            }
        }
        .sheet(isPresented: $showingShellTerminal) {
            ShellLiveTerminalView(call: call)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    /// Parse any exported-file marker returned by tool bridges. Most
    /// tools emit `[oases:open]<abs>`, but older artifact paths can show
    /// up as `ios=<abs>` / `ios:<abs>`; treat all of them as openable.
    private var openableFilePath: String? {
        guard let out = call.output else { return nil }
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes = ["[oases:open]", "ios=", "ios:"]
            for prefix in prefixes where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { return path }
            }
        }
        return nil
    }

    private var subtitle: String? {
        if isShellLike {
            switch call.status {
            case .pending: return isOgentAgentTool ? String(localized: "排队等待工程代理 runtime") : String(localized: "排队等待本机 Linux 沙箱")
            case .running: return commandPreview ?? String(localized: "正在 iSH Alpine 中执行")
            case .completed:
                if let filename = openableFilePath.map({ ($0 as NSString).lastPathComponent }) {
                    return String(localized: "已导出 · \(filename)", comment: "Tool pill subtitle; %@ is the exported file name")
                }
                return commandPreview
            case .error, .canceled: return commandPreview
            }
        }
        switch call.status {
        case .pending: return String(localized: "排队中", comment: "Tool call status")
        case .running: return String(localized: "执行中…", comment: "Tool call status")
        case .completed:
            if let out = call.output, !out.isEmpty {
                // Strip the `[oases:open]…` marker before showing
                let cleaned = out
                    .replacingOccurrences(
                        of: #"\n?\[oases:open\][^\n]*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .replacingOccurrences(
                        of: #"\n?\s*ios[:=][^\n]*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.prefix(60).description
            }
            return String(localized: "已完成", comment: "Tool call status")
        case .error:
            return call.output ?? String(localized: "失败", comment: "Tool call status")
        case .canceled:
            return String(localized: "已取消", comment: "Tool call status")
        }
    }

    private var displayTitle: String {
        if isShellTool { return String(localized: "Shell command", comment: "Tool pill title") }
        if isOgentAgentTool { return ogentAgentTitle }
        // Prefer model-supplied tool_title (OpenMinis convention).
        if let title = toolTitleFromInput { return title }
        return call.displayName ?? call.name
    }

    private var commandPreview: String? {
        if isOgentAgentTool { return ogentAgentPreview }
        guard isShellTool,
              let json = call.inputJSON?.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let command = dict["command"] as? String,
              !command.isEmpty else {
            return nil
        }
        return "$ " + String(command.replacingOccurrences(of: "\n", with: " ").prefix(70))
    }

    private var toolTitleFromInput: String? {
        guard let dict = inputDictionary,
              let title = dict["tool_title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isShellTool: Bool {
        call.name == "shell_execute" || call.name == "shell_local"
    }

    private var ogentAgentTitle: String {
        guard let dict = inputDictionary else { return String(localized: "工程代理", comment: "Tool pill title for the Ogent agent tool") }
        switch dict["action"] as? String {
        case "run_script": return String(localized: "Shell command", comment: "Tool pill title")
        case "workspace_snapshot": return String(localized: "Workspace", comment: "Ogent tool pill title")
        case "plan_write", "plan_read": return String(localized: "Plan", comment: "Ogent tool pill title")
        case "note_append": return String(localized: "Notes", comment: "Ogent tool pill title")
        case "inbox_add", "inbox_read": return String(localized: "Inbox", comment: "Ogent tool pill title")
        case "artifact_list": return String(localized: "Artifacts", comment: "Ogent tool pill title")
        case "artifact_export": return String(localized: "Export", comment: "Ogent tool pill title")
        case "remember", "recall", "memory_add", "memory_search", "wiki_summary", "wiki_graph", "rag_rebuild", "rag_search": return String(localized: "Memory", comment: "Ogent tool pill title")
        case "task_log": return String(localized: "Task log", comment: "Ogent tool pill title")
        case "skill_list": return String(localized: "Skills", comment: "Ogent tool pill title")
        case "subagent_create", "subagent_list", "subagent_task", "subagent_run": return String(localized: "Subagents", comment: "Ogent tool pill title")
        case "automation_create", "automation_list", "automation_due", "automation_run", "automation_run_due": return String(localized: "Automations", comment: "Ogent tool pill title")
        default: return String(localized: "工程代理", comment: "Tool pill title for the Ogent agent tool")
        }
    }

    private var ogentAgentPreview: String? {
        guard let dict = inputDictionary else { return nil }
        let action = (dict["action"] as? String) ?? "status"
        if action == "run_script" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "run_script · \(String(title.prefix(70)))"
            }
            if let script = dict["script"] as? String {
                let line = script
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .first
                    .map(String.init) ?? ""
                return "$ " + String(line.prefix(70))
            }
        }
        if action == "plan_write" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "plan_write · \(String(title.prefix(70)))"
            }
            return "plan_write"
        }
        if action == "note_append", let note = dict["note"] as? String, !note.isEmpty {
            return "note · \(String(note.replacingOccurrences(of: "\n", with: " ").prefix(70)))"
        }
        if action == "inbox_add", let message = dict["message"] as? String, !message.isEmpty {
            return "inbox · \(String(message.replacingOccurrences(of: "\n", with: " ").prefix(70)))"
        }
        if action == "remember", let key = dict["memoryKey"] as? String {
            return "remember · \(key)"
        }
        if action == "recall", let key = dict["memoryKey"] as? String, !key.isEmpty {
            return "recall · \(key)"
        }
        if action == "memory_add" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "memory_add · \(String(title.prefix(70)))"
            }
            return "memory_add"
        }
        if action == "memory_search" {
            if let query = (dict["query"] as? String) ?? (dict["memoryKey"] as? String), !query.isEmpty {
                return "memory_search · \(String(query.prefix(70)))"
            }
            return "memory_search"
        }
        if action == "rag_search" {
            if let query = (dict["query"] as? String) ?? (dict["memoryKey"] as? String), !query.isEmpty {
                return "rag_search · \(String(query.prefix(70)))"
            }
            return "rag_search"
        }
        if action == "rag_rebuild" {
            return "rag_rebuild"
        }
        if action == "wiki_summary" {
            return "wiki_summary"
        }
        if action == "wiki_graph" {
            return "wiki_graph"
        }
        if action == "artifact_export", let path = dict["artifactPath"] as? String, !path.isEmpty {
            return "export · \((path as NSString).lastPathComponent)"
        }
        if action == "subagent_create" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "subagent_create · \(String(title.prefix(70)))"
            }
            return "subagent_create"
        }
        if action == "subagent_task" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "subagent_task · \(String(title.prefix(70)))"
            }
            return "subagent_task"
        }
        if action == "subagent_run" {
            if let title = dict["title"] as? String, !title.isEmpty {
                return "subagent_run · \(String(title.prefix(70)))"
            }
            return "subagent_run"
        }
        if action == "subagent_list" {
            return "subagent_list"
        }
        if action == "automation_create" {
            let title = (dict["title"] as? String) ?? "automation"
            let trigger = (dict["trigger"] as? String) ?? "manual"
            return "automation_create · \(String(title.prefix(50))) · \(trigger)"
        }
        if action == "automation_run", let automationID = dict["automationID"] as? String, !automationID.isEmpty {
            return "automation_run · \(automationID)"
        }
        if action == "automation_list" {
            return "automation_list"
        }
        if action == "automation_due" {
            return "automation_due"
        }
        if action == "automation_run_due" {
            return "automation_run_due"
        }
        return "ogent-agent \(action)"
    }

    private var inputDictionary: [String: Any]? {
        guard let json = call.inputJSON?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    private var durationText: String? {
        if let startedAt = call.startedAt, let endedAt = call.endedAt {
            return String(format: "%.1fs", endedAt.timeIntervalSince(startedAt))
        }
        guard let output = call.output,
              let match = output.range(of: #"duration=([0-9.]+s)"#, options: .regularExpression) else {
            return nil
        }
        let token = output[match]
        return token
            .replacingOccurrences(of: "duration=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "]"))
    }

    /// Map the tool onto an orb animation: retrieval tools (web search /
    /// browse / fetch) "search", code-exec / math / debug tools "solve",
    /// everything else just "works". Tool names arrive from the model and
    /// MCP servers, so this matches on name substrings.
    private var orbState: OrbState {
        let name = call.name.lowercased()
        if name.contains("search") || name.contains("browse") || name.contains("fetch")
            || name.contains("retriev") || name.contains("crawl") || name.contains("scrape")
            || name.contains("web") || name.contains("reach") {
            return .searching
        }
        if name.contains("code") || name.contains("exec") || name.contains("repl")
            || name.contains("python") || name.contains("math") || name.contains("calcul")
            || name.contains("debug") {
            return .solving
        }
        return .working
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case .pending:
            shellIcon(color: Color(red: 0.98, green: 0.82, blue: 0.05))
        case .running:
            if isShellLike {
                shellIcon(color: Color(red: 1.0, green: 0.22, blue: 0.25))
            } else {
                ThinkingOrb(state: orbState, size: .px20)
            }
        case .completed:
            if isShellLike {
                shellIcon(color: Color(red: 0.98, green: 0.82, blue: 0.05))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(OasesColor.emerald)
            }
        case .error:
            shellIcon(color: Color(red: 1.0, green: 0.22, blue: 0.25))
        case .canceled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(OasesColor.mutedForeground)
        }
    }

    private func shellIcon(color: Color) -> some View {
        Image(systemName: "terminal")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.6)
            )
    }

    private var borderColor: Color {
        if isShellLike {
            return Color.white.opacity(0.04)
        }
        switch call.status {
        case .completed: return OasesColor.emerald.opacity(0.4)
        case .error: return Color.red.opacity(0.4)
        case .running: return OasesColor.primary.opacity(0.4)
        default: return OasesColor.border.opacity(0.4)
        }
    }

    private var pillFill: Color {
        if isShellLike {
            return Color(red: 0.12, green: 0.12, blue: 0.13).opacity(compactShellStyle ? 0.96 : 0.78)
        }
        return OasesColor.card.opacity(0.55)
    }

    private var isShellLike: Bool {
        isShellTool || isOgentAgentTool
    }

    private var isOgentAgentTool: Bool {
        call.name == "ogent_agent"
    }
}
