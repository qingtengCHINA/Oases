import SwiftUI

/// What text chat shows for the tools a reply used: one quiet line above the
/// answer ("已搜索网页 · 5 个来源 ›"). While a tool runs the line names it with
/// a soft shimmer; tapping a finished line unfolds the steps and the sources.
/// No cards or capsules — the answer stays the main thing on screen.
struct ChatToolTrail: View {
    let calls: [ToolCall]

    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    private var running: ToolCall? {
        calls.last { $0.status == .running || $0.status == .pending }
    }

    private var sources: [WebSource] {
        var seen = Set<String>()
        return calls
            .filter { Self.isWebTool($0.name) && $0.status == .completed }
            .flatMap { WebSource.parse(searchOutput: $0.output ?? "") }
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let running {
                summaryLine(icon: Self.icon(for: running.name), text: Self.activeLabel(for: running), shimmering: true)
                    .accessibilityElement(children: .combine)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.24)) { expanded.toggle() }
                } label: {
                    summaryLine(icon: summaryIcon, text: summaryText, shimmering: false, showsChevron: true)
                }
                .buttonStyle(TrailButtonStyle())
                .accessibilityHint(expanded ? Text("收起步骤", comment: "Chat tool trail: accessibility hint to fold the steps") : Text("展开步骤", comment: "Chat tool trail: accessibility hint to show the steps"))

                if expanded {
                    detail
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Summary line

    private func summaryLine(icon: String, text: String, shimmering: Bool, showsChevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 14)
            Text(text)
                .font(.oasesCallout())
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .foregroundStyle(OasesColor.mutedForeground)
        .modifier(TrailShimmer(active: shimmering))
        .contentShape(Rectangle())
    }

    private var failedAll: Bool {
        !calls.isEmpty && calls.allSatisfy { $0.status == .error || $0.status == .canceled }
    }

    private var summaryIcon: String {
        if failedAll { return "exclamationmark.circle" }
        if !sources.isEmpty { return "globe" }
        return calls.count == 1 ? Self.icon(for: calls[0].name) : "checklist"
    }

    private var summaryText: String {
        if failedAll {
            if calls.count == 1 {
                return String(localized: "\(Self.toolName(calls[0]))未完成", comment: "Chat tool trail: one tool failed; argument is the tool name")
            }
            return String(localized: "步骤未完成", comment: "Chat tool trail: every tool step failed")
        }
        let headline = calls.contains { Self.isWebTool($0.name) }
            ? Self.doneLabel(for: calls.first { Self.isWebTool($0.name) } ?? calls[0])
            : (calls.count == 1 ? Self.doneLabel(for: calls[0]) : String(localized: "已完成 \(calls.count) 个步骤", comment: "Chat tool trail: several tool steps finished; argument is the count"))
        if !sources.isEmpty {
            return String(localized: "\(headline) · \(sources.count) 个来源", comment: "Chat tool trail summary; arguments are what was done and how many sources were found")
        }
        return headline
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(calls) { call in
                    stepRow(call)
                }
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(index: index + 1, source: source)
                    }
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(OasesColor.border)
                .frame(width: 1)
                .padding(.leading, 6)
        }
    }

    private func stepRow(_ call: ToolCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.icon(for: call.name))
                .font(.system(size: 11))
                .frame(width: 14)
            Text(Self.stepText(for: call))
                .font(.oasesCaption())
                .lineLimit(2)
            if call.status == .error {
                Text("未完成", comment: "Chat tool trail: this step failed")
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.destructive)
            } else if let seconds = Self.seconds(for: call) {
                Text(verbatim: seconds)
                    .font(.oasesFootnote())
                    .monospacedDigit()
                    .foregroundStyle(OasesColor.textTertiary)
            }
        }
        .foregroundStyle(OasesColor.mutedForeground)
    }

    private func sourceRow(index: Int, source: WebSource) -> some View {
        Button {
            openURL(source.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(index)")
                    .font(.oasesFootnote())
                    .monospacedDigit()
                    .foregroundStyle(OasesColor.textTertiary)
                    .frame(width: 14, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: source.title)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Text(verbatim: source.host)
                        .font(.oasesFootnote())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TrailButtonStyle())
    }

    // MARK: Labels

    static func isWebTool(_ name: String) -> Bool {
        name == "web_search" || name == "web_read"
    }

    private static func toolName(_ call: ToolCall) -> String {
        ToolRegistry.shared.tool(named: call.name)?.descriptor.localizedDisplayName
            ?? call.displayName
            ?? call.name
    }

    private static func input(_ call: ToolCall) -> [String: Any] {
        guard let data = call.inputJSON?.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    static func activeLabel(for call: ToolCall) -> String {
        switch call.name {
        case "web_search": return String(localized: "正在搜索网页", comment: "Chat tool trail: a web search is running")
        case "web_read": return String(localized: "正在读取网页", comment: "Chat tool trail: a web page is being read")
        case "image_gen": return String(localized: "正在生成图片", comment: "Chat tool trail: an image is being generated")
        case "speech_synth": return String(localized: "正在合成语音", comment: "Chat tool trail: speech is being synthesized")
        case "calendar_read": return String(localized: "正在查看日历", comment: "Chat tool trail: the calendar is being read")
        case "reminder_create": return String(localized: "正在创建提醒", comment: "Chat tool trail: a reminder is being created")
        case "contact_search": return String(localized: "正在查找联系人", comment: "Chat tool trail: contacts are being searched")
        case "photo_list": return String(localized: "正在查看照片", comment: "Chat tool trail: the photo library is being read")
        case "location_current": return String(localized: "正在获取位置", comment: "Chat tool trail: the current location is being read")
        case "apple_clipboard": return String(localized: "正在读取剪贴板", comment: "Chat tool trail: the clipboard is being used")
        case "memory_write": return String(localized: "正在记下", comment: "Chat tool trail: a memory is being saved")
        case "memory_get": return String(localized: "正在查看记忆", comment: "Chat tool trail: saved memories are being read")
        default: return String(localized: "正在使用\(toolName(call))", comment: "Chat tool trail: a tool is running; argument is the tool name")
        }
    }

    static func doneLabel(for call: ToolCall) -> String {
        switch call.name {
        case "web_search": return String(localized: "已搜索网页", comment: "Chat tool trail: the web was searched")
        case "web_read": return String(localized: "已读取网页", comment: "Chat tool trail: a web page was read")
        case "image_gen": return String(localized: "已生成图片", comment: "Chat tool trail: an image was generated")
        case "speech_synth": return String(localized: "已合成语音", comment: "Chat tool trail: speech was synthesized")
        case "calendar_read": return String(localized: "已查看日历", comment: "Chat tool trail: the calendar was read")
        case "reminder_create": return String(localized: "已创建提醒", comment: "Chat tool trail: a reminder was created")
        case "contact_search": return String(localized: "已查找联系人", comment: "Chat tool trail: contacts were searched")
        case "photo_list": return String(localized: "已查看照片", comment: "Chat tool trail: the photo library was read")
        case "location_current": return String(localized: "已获取位置", comment: "Chat tool trail: the current location was read")
        case "apple_clipboard": return String(localized: "已使用剪贴板", comment: "Chat tool trail: the clipboard was used")
        case "memory_write": return String(localized: "已记下", comment: "Chat tool trail: a memory was saved")
        case "memory_get": return String(localized: "已查看记忆", comment: "Chat tool trail: saved memories were read")
        default: return String(localized: "已使用\(toolName(call))", comment: "Chat tool trail: a tool finished; argument is the tool name")
        }
    }

    private static func stepText(for call: ToolCall) -> String {
        let args = input(call)
        switch call.name {
        case "web_search":
            if let query = args["query"] as? String, !query.isEmpty {
                return String(localized: "搜索“\(query)”", comment: "Chat tool trail step: the search words; argument is the query")
            }
        case "web_read":
            if let raw = args["url"] as? String, let url = URL(string: raw),
               let host = url.host(percentEncoded: false) {
                return String(localized: "读取 \(host)", comment: "Chat tool trail step: a page was read; argument is the site")
            }
        default:
            break
        }
        return toolName(call)
    }

    private static func seconds(for call: ToolCall) -> String? {
        guard let start = call.startedAt, let end = call.endedAt else { return nil }
        let value = end.timeIntervalSince(start)
        guard value >= 0.05 else { return nil }
        return value.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    static func icon(for name: String) -> String {
        switch name {
        case "web_search": return "magnifyingglass"
        case "web_read": return "doc.text"
        case "image_gen": return "photo"
        case "speech_synth": return "waveform"
        case "calendar_read": return "calendar"
        case "reminder_create": return "checklist"
        case "contact_search": return "person.crop.circle"
        case "photo_list": return "photo.on.rectangle"
        case "location_current": return "location"
        case "apple_clipboard": return "doc.on.clipboard"
        case "memory_write", "memory_get": return "bookmark"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// Opacity press feedback for the trail's text buttons (no scale: it is a
/// line of text, not a control surface).
private struct TrailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A light band that sweeps across a running step's label (also Ogent's thinking line).
struct TrailShimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let period = 1.8
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let x = phase * 2.4 - 0.7
                content.overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: OasesColor.foreground.opacity(0.9), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: UnitPoint(x: x - 0.35, y: 0.5),
                        endPoint: UnitPoint(x: x + 0.35, y: 0.5)
                    )
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
        } else if active {
            content.opacity(0.85)
        } else {
            content
        }
    }
}
