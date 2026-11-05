import SwiftUI

/// Live terminal view. Shown when the user taps a
/// `shell_local` tool pill. Renders the command + streaming output
/// in a monospaced, dark, mock-terminal frame; the output area auto-
/// scrolls as new lines arrive. Useful as a "show the agent's
/// actual work" affordance for power users — the chat bubble shows
/// the pill, this sheet shows the full live transcript.
struct ShellLiveTerminalView: View {
    let call: ToolCall
    @Environment(\.dismiss) private var dismiss

    private var commandText: String {
        guard let json = call.inputJSON?.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return ""
        }
        if isOgentAgentTool {
            let action = (dict["action"] as? String) ?? "status"
            if action == "run_script" {
                let title = (dict["title"] as? String) ?? "工程任务" // i18n-ignore: command-line text mirroring the ogent-agent tool default
                return "ogent-agent run --title \(title)"
            }
            if action == "remember", let key = dict["memoryKey"] as? String {
                return "ogent-agent remember \(key)"
            }
            if action == "recall", let key = dict["memoryKey"] as? String, !key.isEmpty {
                return "ogent-agent recall \(key)"
            }
            if action == "memory_add" {
                let title = (dict["title"] as? String) ?? "工程记忆" // i18n-ignore: command-line text mirroring the ogent-agent tool default
                return "ogent-agent memory-add --title \(title)"
            }
            if action == "memory_search" {
                let query = (dict["query"] as? String) ?? (dict["memoryKey"] as? String) ?? ""
                return "ogent-agent memory-search \(query)"
            }
            if action == "rag_search" {
                let query = (dict["query"] as? String) ?? (dict["memoryKey"] as? String) ?? ""
                return "ogent-agent rag-search \(query)"
            }
            if action == "rag_rebuild" {
                return "ogent-agent rag-rebuild"
            }
            if action == "wiki_summary" {
                return "ogent-agent wiki-summary"
            }
            if action == "wiki_graph" {
                return "ogent-agent wiki-graph"
            }
            if action == "plan_write" {
                let title = (dict["title"] as? String) ?? "工程计划" // i18n-ignore: command-line text mirroring the ogent-agent tool default
                return "ogent-agent plan write --title \(title)"
            }
            if action == "plan_read" {
                return "ogent-agent plan read"
            }
            if action == "workspace_snapshot" {
                return "ogent-agent workspace snapshot"
            }
            if action == "note_append" {
                return "ogent-agent notes append"
            }
            if action == "inbox_add" {
                return "ogent-agent inbox add"
            }
            if action == "inbox_read" {
                return "ogent-agent inbox read"
            }
            if action == "artifact_list" {
                return "ogent-agent artifacts list"
            }
            if action == "subagent_create" {
                let title = (dict["title"] as? String) ?? "worker"
                return "ogent-agent subagent-create --name \(title)"
            }
            if action == "subagent_list" {
                return "ogent-agent subagent-list"
            }
            if action == "subagent_task" {
                let title = (dict["title"] as? String) ?? "worker"
                return "ogent-agent subagent-task --name \(title)"
            }
            if action == "subagent_run" {
                let title = (dict["title"] as? String) ?? "worker"
                let taskID = (dict["taskID"] as? String) ?? "latest"
                return "ogent-agent subagent-run --name \(title) --task \(taskID.isEmpty ? "latest" : taskID)"
            }
            if action == "automation_create" {
                let title = (dict["title"] as? String) ?? "automation"
                let trigger = (dict["trigger"] as? String) ?? "manual"
                return "ogent-agent automation-create --name \(title) --trigger \(trigger)"
            }
            if action == "automation_list" {
                return "ogent-agent automation-list"
            }
            if action == "automation_due" {
                return "ogent-agent automation-due"
            }
            if action == "automation_run" {
                let automationID = (dict["automationID"] as? String) ?? ""
                return "ogent-agent automation-run \(automationID)"
            }
            if action == "automation_run_due" {
                return "ogent-agent automation-run-due"
            }
            if action == "task_log", let taskID = dict["taskID"] as? String {
                return "ogent-agent log \(taskID)"
            }
            return "ogent-agent \(action)"
        }
        return (dict["command"] as? String) ?? ""
    }

    private var outputBody: String {
        guard let raw = call.output else { return "" }
        // Strip the trailing `[exit=...]` footer for the live view —
        // we render exit code in the bottom status bar instead.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.filter { !$0.hasPrefix("[exit=") }
        return trimmed.joined(separator: "\n")
    }

    private var exitFooter: String? {
        guard let raw = call.output else { return nil }
        let lines = raw.split(separator: "\n")
        return lines.last(where: { $0.hasPrefix("[exit=") }).map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            terminalBody
            statusFooter
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭工程模式终端")

            Spacer(minLength: 0)

            Text("Ogent Shell")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Button {
                UIPasteboard.general.string = outputBody.isEmpty ? commandText : outputBody
                Haptics.tap()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制终端输出")
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var terminalBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    promptLine
                    if outputBody.isEmpty {
                        runningPlaceholder
                    } else {
                        Text(outputBody)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Color(red: 0.76, green: 0.76, blue: 0.78))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: outputBody) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }

    private var promptLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("root@ogent:~#")
                .font(.system(size: 18, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
                .textSelection(.enabled)
            Text(commandText.isEmpty ? " " : commandText)
                .font(.system(size: 18, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if call.status == .running {
                Rectangle()
                    .fill(Color.white.opacity(0.58))
                    .frame(width: 12, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runningPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(promptColor)
            Text(call.status == .running ? String(localized: "等待输出…") : String(localized: "命令完成"))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var statusFooter: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.12))
            HStack(spacing: 12) {
                statusBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ogent is using Shell")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(isOgentAgentTool ? String(localized: "Linux runtime") : String(localized: "Shell command"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
                if let exit = exitFooter {
                    Text(exit)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .pending:
            label("queued", color: .gray)
        case .running:
            label("running", color: promptColor)
        case .completed:
            label("ok", color: .green)
        case .error:
            label("error", color: .red)
        case .canceled:
            label("canceled", color: .orange)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Image(systemName: text == "running" ? "stop.fill" : "terminal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.black)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color))
    }

    // Terminal palette — green-on-near-black for the iSH console.
    private var promptColor: Color { Color(red: 0.32, green: 0.94, blue: 0.52) }

    private var isOgentAgentTool: Bool {
        call.name == "ogent_agent"
    }
}
