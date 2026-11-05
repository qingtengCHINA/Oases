import SwiftUI
import WidgetKit

@main
struct AgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        OasesAskWidget()
        OasesUsageWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            AgentLiveActivityWidget()
        }
    }
}

// MARK: - Ask

private struct AskEntry: TimelineEntry {
    let date: Date
}

private struct AskProvider: TimelineProvider {
    func placeholder(in context: Context) -> AskEntry { AskEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (AskEntry) -> Void) {
        completion(AskEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AskEntry>) -> Void) {
        completion(Timeline(entries: [AskEntry(date: Date())], policy: .never))
    }
}

private struct OasesAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OasesAsk", provider: AskProvider()) { _ in
            OasesAskWidgetView()
        }
        .configurationDisplayName("Oases Chat")
        .description(Text("打开聊天、相机或语音", comment: "Widget gallery description of the Ask widget"))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

private struct OasesAskWidgetView: View {
    private let ask = URL(string: "oases://ask")!
    private let camera = URL(string: "oases://camera")!
    private let voice = URL(string: "oases://voice")!

    var body: some View {
        VStack(spacing: 10) {
            Link(destination: ask) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Ask")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
            HStack(spacing: 10) {
                Link(destination: camera) { roundButton("camera") }
                Link(destination: voice) { roundButton("waveform") }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .containerBackground(Color(red: 0.07, green: 0.07, blue: 0.08), for: .widget)
    }

    private func roundButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.10), in: Circle())
    }
}

// MARK: - Usage

private struct UsageEntry: TimelineEntry {
    let date: Date
    let days: [String: Int]
}

private struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), days: [:])
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [load()], policy: .after(next)))
    }

    private func load() -> UsageEntry {
        let defaults = UserDefaults(suiteName: "group.dev.oases.chat.ios")
        let data = defaults?.data(forKey: "oases.widget.dayTokens") ?? Data()
        let days = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        return UsageEntry(date: Date(), days: days)
    }
}

private struct OasesUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OasesUsage", provider: UsageProvider()) { entry in
            OasesUsageWidgetView(days: entry.days)
        }
        .configurationDisplayName(Text("用量", comment: "Widget gallery name of the usage heat-map widget"))
        .description(Text("最近的 token 用量", comment: "Widget gallery description of the usage heat-map widget"))
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

private struct OasesUsageWidgetView: View {
    var days: [String: Int]
    private let weeks = 16

    var body: some View {
        let columns = weekColumns()
        let maxValue = max(columns.flatMap { $0 }.map(\.value).max() ?? 1, 1)
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(week) { day in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: day.value, max: maxValue, future: day.future))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .padding(16)
        .containerBackground(Color(red: 0.05, green: 0.06, blue: 0.07), for: .widget)
    }

    private struct DayDot: Identifiable {
        let id: String
        let value: Int
        let future: Bool
    }

    private func weekColumns() -> [[DayDot]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -mondayOffset, to: today) ?? today
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisMonday) ?? thisMonday
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<weeks).map { week in
            (0..<7).map { day in
                let date = cal.date(byAdding: .day, value: week * 7 + day, to: start) ?? start
                let key = formatter.string(from: date)
                return DayDot(id: key, value: days[key] ?? 0, future: date > today)
            }
        }
    }

    private func color(for value: Int, max: Int, future: Bool) -> Color {
        if future { return Color(red: 0.08, green: 0.09, blue: 0.10) }
        if value <= 0 { return Color(red: 0.11, green: 0.13, blue: 0.15) }
        let t = min(1, log(1 + Double(value)) / log(1 + Double(max)))
        return Color(red: 0.08 + 0.10 * t, green: 0.28 + 0.42 * t, blue: 0.16 + 0.10 * t)
    }
}
