import SwiftUI

/// Renders an `AgentAnnotation` block inside the assistant bubble —
/// plan card, thinking section (collapsible), or short status line.
/// Tool calls have their own `ToolCallPill`; this view handles the
/// non-tool annotations.
struct AgentAnnotationView: View {
    let annotation: AgentAnnotation

    var body: some View {
        switch annotation.payload {
        case .plan(let steps):
            PlanCard(steps: steps)
        case .thinking(let text):
            ThinkingBlock(text: text)
        case .toolCall(let call):
            ToolCallPill(call: call)
        case .permission:
            // Permission UI is presented as a modal sheet by ChatView,
            // not inline. Skip in the bubble.
            EmptyView()
        case .status(let text):
            AgentStatusLine(text: text)
        }
    }
}

// MARK: - PlanCard

private struct PlanCard: View {
    let steps: [PlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OasesColor.primary)
                Text("计划")
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.foreground)
            }
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 8) {
                    statusGlyph(step.status)
                        .frame(width: 14, height: 14)
                    Text(step.title)
                        .font(.oasesBody())
                        .foregroundStyle(stepColor(step.status))
                        .strikethrough(step.status == .skipped)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OasesColor.card.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OasesColor.primary.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func statusGlyph(_ status: PlanStep.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(OasesColor.mutedForeground)
        case .inProgress:
            ProgressView().controlSize(.mini).tint(OasesColor.primary)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(OasesColor.emerald)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(OasesColor.mutedForeground)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
        }
    }

    private func stepColor(_ status: PlanStep.Status) -> Color {
        switch status {
        case .pending, .inProgress: return OasesColor.foreground
        case .completed: return OasesColor.foreground.opacity(0.7)
        case .skipped: return OasesColor.mutedForeground
        case .failed: return .red
        }
    }
}

// MARK: - ThinkingBlock

private struct ThinkingBlock: View {
    let text: String
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                    Text("思考过程")
                        .font(.oasesCaptionBold())
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OasesColor.mutedForeground)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OasesColor.mutedForeground.opacity(0.08))
        )
    }
}

// MARK: - Status line

private struct AgentStatusLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(OasesColor.mutedForeground)
            Text(text)
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
