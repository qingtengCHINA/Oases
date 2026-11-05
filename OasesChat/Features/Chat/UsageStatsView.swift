import SwiftUI
import SwiftData
import WidgetKit

/// Real token counts returned by the model API. Older replies have no row
/// here because the app did not ask for usage yet.
enum UsageLedger {
    struct Entry: Codable {
        var modelId: String
        var input: Int
        var output: Int
        var at: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Entry]?

    static func record(modelId: String, input: Int, output: Int) {
        guard input > 0 || output > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var items = loadLocked()
        items.append(Entry(modelId: modelId, input: input, output: output, at: Date()))
        cache = items
        persist(items)
    }

    static func record(json: Data, modelId: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let usage = obj["usage"] as? [String: Any] else { return }
        let input = intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"]) ?? 0
        let output = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"]) ?? 0
        record(modelId: modelId, input: input, output: output)
    }

    static func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func loadLocked() -> [Entry] {
        if let cache { return cache }
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        let items = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        cache = items
        return items
    }

    private static func persist(_ items: [Entry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("oases-usage-ledger.json")
    }
}

// MARK: - ViewModel

@MainActor
class UsageStatsViewModel: ObservableObject {
    struct ModelStats {
        let modelId: String
        let displayName: String
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTokens: Int = 0
        var cacheReadTokens: Int = 0
        var distinctDays: Set<String> = []
        var distinctSessions: Set<String> = []

        var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
        var dailyAvgTokens: Int {
            let days = max(distinctDays.count, 1)
            return totalTokens / days
        }
        var sessionAvgTokens: Int {
            let sessions = max(distinctSessions.count, 1)
            return totalTokens / sessions
        }
    }

    struct ProviderGroup: Identifiable {
        let id: String // provider name
        var models: [ModelStats]
        var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
    }

    @Published var providers: [ProviderGroup] = []
    @Published var grandTotalInput: Int = 0
    @Published var grandTotalOutput: Int = 0
    @Published var grandTotalCacheCreation: Int = 0
    @Published var grandTotalCacheRead: Int = 0
    @Published var dayTokens: [String: Int] = [:]
    @Published var isLoaded = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func load() async {
        let records = await ChatStore.shared.fetchUsageStats()

        // Resolve each model id to a PROVIDER-TYPE group (what the user sees in
        // the Providers list — OpenAI + its compatibles, Anthropic, Gemini, xAI,
        // OpenRouter, …). We group by ProviderType, NOT by the model's own
        // `provider` string (which is inconsistent: "Gemini"/"OpenRouter"/"doubao"
        // …). Priority for a given model id:
        //   1) a configured provider instance that owns this model → its
        //      providerType.displayName (an OpenAI-compatible vendor like DeepSeek/
        //      Groq/Doubao/Azure all correctly fold into "OpenAI").
        //   2) a static built-in model → its provider, normalized.
        //   3) neither (a since-deleted instance / renamed model) → "Other".
        let store = ProviderConfigStore.shared
        // modelId → providerType.displayName, from configured instances.
        let instanceMap = Dictionary(store.instances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var modelIdToProviderGroup: [String: String] = [:]
        for entry in store.modelEntries {
            if let inst = instanceMap[entry.providerInstanceId] {
                modelIdToProviderGroup[entry.model.id] = inst.providerType.displayName
            }
        }
        // Fallback map + display names from static built-in models.
        let staticLookup = Dictionary(LLMModel.allModels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func providerGroup(for modelId: String) -> String {
            if Models.option(for: modelId) != nil { return "Oases" }
            if let g = modelIdToProviderGroup[modelId] { return g }
            if let p = staticLookup[modelId]?.provider {
                // Normalize built-in provider strings to ProviderType display names.
                switch p {
                case "Google", "Gemini", "Google Gemini": return ProviderType.gemini.displayName
                case "xAI":       return ProviderType.xAI.displayName
                case "OpenRouter": return ProviderType.openRouter.displayName
                default:          return BrandNeutralCopy.providerName(p)
                }
            }
            return String(localized: "Other", comment: "Usage stats: unknown provider group")
        }
        let modelLookup = staticLookup.merging(
            Dictionary(store.modelEntries.map { ($0.model.id, $0.model) }, uniquingKeysWith: { a, _ in a }),
            uniquingKeysWith: { _, configured in configured })

        // Group by modelId. Ledger rows are replies that returned usage
        // after this build; ChatStore rows are Ogent messages that stored it.
        var statsByModel: [String: ModelStats] = [:]
        var byDay: [String: Int] = [:]
        func addDay(_ date: Date, _ tokens: Int) {
            guard tokens > 0 else { return }
            let key = Self.dayFormatter.string(from: date)
            byDay[key, default: 0] += tokens
        }
        for entry in UsageLedger.entries() {
            var stats = statsByModel[entry.modelId] ?? ModelStats(
                modelId: entry.modelId,
                displayName: Models.label(for: entry.modelId)
            )
            stats.inputTokens += entry.input
            stats.outputTokens += entry.output
            stats.distinctDays.insert(Self.dayFormatter.string(from: entry.at))
            stats.distinctSessions.insert("ledger")
            statsByModel[entry.modelId] = stats
            addDay(entry.at, entry.input + entry.output)
        }
        for record in records {
            let displayName = Models.label(for: record.modelId)

            var stats = statsByModel[record.modelId] ?? ModelStats(
                modelId: record.modelId, displayName: displayName
            )
            stats.inputTokens += record.usage.inputTokens
            stats.outputTokens += record.usage.outputTokens
            stats.cacheCreationTokens += record.usage.cacheCreationTokens
            stats.cacheReadTokens += record.usage.cacheReadTokens
            stats.distinctDays.insert(Self.dayFormatter.string(from: record.date))
            stats.distinctSessions.insert(record.sessionId)
            statsByModel[record.modelId] = stats
            addDay(record.date, record.usage.inputTokens + record.usage.outputTokens + record.usage.cacheCreationTokens + record.usage.cacheReadTokens)
        }

        // Group by PROVIDER TYPE (the Providers-list grouping).
        var providerMap: [String: [ModelStats]] = [:]
        for (modelId, stats) in statsByModel {
            providerMap[providerGroup(for: modelId), default: []].append(stats)
        }

        // Emit every group — a preferred ProviderType order first, then any
        // remaining groups (e.g. "Other") appended so NOTHING is silently dropped.
        let preferredOrder = ProviderType.allCases.map(\.displayName)
        var groups: [ProviderGroup] = []
        var emitted = Set<String>()
        func emit(_ provider: String) {
            guard !emitted.contains(provider), var models = providerMap[provider] else { return }
            emitted.insert(provider)
            models.sort { $0.totalTokens > $1.totalTokens }
            groups.append(ProviderGroup(id: provider, models: models))
        }
        for p in preferredOrder { emit(p) }
        for p in providerMap.keys.sorted() { emit(p) }   // leftovers (incl. "Other")

        grandTotalInput = statsByModel.values.reduce(0) { $0 + $1.inputTokens }
        grandTotalOutput = statsByModel.values.reduce(0) { $0 + $1.outputTokens }
        grandTotalCacheCreation = statsByModel.values.reduce(0) { $0 + $1.cacheCreationTokens }
        grandTotalCacheRead = statsByModel.values.reduce(0) { $0 + $1.cacheReadTokens }
        providers = groups
        dayTokens = byDay
        isLoaded = true
        UsageWidgetSnapshot.publish(byDay)
    }
}

enum UsageWidgetSnapshot {
    static let appGroup = "group.dev.oases.chat.ios"
    static let key = "oases.widget.dayTokens"

    static func publish(_ dayTokens: [String: Int]) {
        let defaults = UserDefaults(suiteName: appGroup) ?? .standard
        if let data = try? JSONEncoder().encode(dayTokens) {
            defaults.set(data, forKey: key)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "OasesUsage")
    }
}

// MARK: - View

struct UsageStatsView: View {
    @StateObject private var vm = UsageStatsViewModel()
    @ObservedObject private var membership = MembershipCenter.shared
    @Query(sort: \ConversationModel.updatedAt, order: .reverse) private var conversations: [ConversationModel]

    private var messageCount: Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    private var tokenTotal: Int { vm.grandTotalInput + vm.grandTotalOutput }
    @State private var activityMode: UsageActivityMode = .daily

    var body: some View {
        List {
            if vm.isLoaded {
                Section {
                    usageSummary
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)

                quotaSection

                Section {
                    tokenActivity
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                if tokenTotal > 0 {
                    Section(SettingsCopy.t("输入与输出", "Input and output")) {
                        inputOutputBar
                    }
                    Section(SettingsCopy.t("模型占比", "By model")) {
                        modelShareChart
                    }
                }

                Section(SettingsCopy.t("用量", "Usage")) {
                    LabeledContent(SettingsCopy.t("对话", "Conversations"), value: "\(conversations.count)")
                    LabeledContent(SettingsCopy.t("消息", "Messages"), value: "\(messageCount)")
                    LabeledContent(SettingsCopy.t("输入 token", "Input tokens"), value: formatCount(vm.grandTotalInput))
                    LabeledContent(SettingsCopy.t("输出 token", "Output tokens"), value: formatCount(vm.grandTotalOutput))
                    if tokenTotal == 0 {
                        Text(SettingsCopy.t(
                            "更早的回复没有记下 token。从下一条回复开始，这里会显示接口返回的真实用量。",
                            "No token usage yet. Counts appear after the next reply."
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if vm.isLoaded && !vm.providers.isEmpty {
                // Grand totals
                Section(SettingsCopy.t("合计", "Total")) {
                    let grandTotalAllInput = vm.grandTotalInput + vm.grandTotalCacheRead + vm.grandTotalCacheCreation
                    LabeledContent("Total Input (incl. Cache)", value: formatCount(grandTotalAllInput))
                    LabeledContent("Output Tokens", value: formatCount(vm.grandTotalOutput))
                    if vm.grandTotalCacheRead > 0 {
                        LabeledContent("Cache Read", value: formatCount(vm.grandTotalCacheRead))
                    }
                    if vm.grandTotalCacheCreation > 0 {
                        LabeledContent("Cache Creation", value: formatCount(vm.grandTotalCacheCreation))
                    }
                    if grandTotalAllInput > 0 && vm.grandTotalCacheRead > 0 {
                        let grandHitRate = Double(vm.grandTotalCacheRead) / Double(grandTotalAllInput) * 100
                        LabeledContent("Cache Hit Rate", value: String(format: "%.1f%%", grandHitRate))
                    }
                }

                // Per-provider sections
                ForEach(vm.providers) { provider in
                    Section(provider.id) {
                        ForEach(provider.models, id: \.modelId) { model in
                            DisclosureGroup {
                                modelDetailRows(model)
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                    Spacer()
                                    let totalInputLabel = model.inputTokens + model.cacheReadTokens + model.cacheCreationTokens
                                    Text("\(formatCount(totalInputLabel)) / \(formatCount(model.outputTokens))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(SettingsCopy.t("用量", "Usage"))
        .task {
            await vm.load()
        }
    }

    @ViewBuilder
    private func modelDetailRows(_ model: UsageStatsViewModel.ModelStats) -> some View {
        Group {
            LabeledContent("Input", value: formatCount(model.inputTokens))
            LabeledContent("Output", value: formatCount(model.outputTokens))
            if model.cacheReadTokens > 0 {
                LabeledContent("Cache Read", value: formatCount(model.cacheReadTokens))
            }
            if model.cacheCreationTokens > 0 {
                LabeledContent("Cache Creation", value: formatCount(model.cacheCreationTokens))
            }
            let totalInputForRate = model.inputTokens + model.cacheReadTokens + model.cacheCreationTokens
            if totalInputForRate > 0 && model.cacheReadTokens > 0 {
                let hitRate = Double(model.cacheReadTokens) / Double(totalInputForRate) * 100
                LabeledContent("Cache Hit Rate", value: String(format: "%.1f%%", hitRate))
            }
            LabeledContent("Daily Avg", value: formatCount(model.dailyAvgTokens))
            LabeledContent("Per-Session Avg", value: formatCount(model.sessionAvgTokens))
            LabeledContent("Sessions", value: "\(model.distinctSessions.count)")
            LabeledContent("Active Days", value: "\(model.distinctDays.count)")
        }
        .font(.subheadline)
    }

    private var longestChat: TimeInterval {
        conversations.map(\.span).max() ?? 0
    }

    private var peakDayTokens: Int { vm.dayTokens.values.max() ?? 0 }

    private var streaks: (current: Int, longest: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func tokens(on day: Date) -> Int {
            vm.dayTokens[Self.dayKey.string(from: day)] ?? 0
        }
        var current = 0
        var cursor = today
        while tokens(on: cursor) > 0 {
            current += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        let active = vm.dayTokens.keys.compactMap { Self.dayKey.date(from: $0) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for day in active {
            if let previous, cal.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        return (current, longest)
    }

    private var usageSummary: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                summaryCell(formatCount(tokenTotal), SettingsCopy.t("累计 Token 数", "Total tokens"))
                summaryDivider
                summaryCell(formatCount(peakDayTokens), SettingsCopy.t("峰值 Token 数", "Peak day"))
                summaryDivider
                summaryCell(formatDuration(longestChat), SettingsCopy.t("最长聊天时长", "Longest chat"))
                summaryDivider
                summaryCell(SettingsCopy.t("\(streaks.current) 天", "\(streaks.current)d"), SettingsCopy.t("当前连续天数", "Current streak"))
                summaryDivider
                summaryCell(SettingsCopy.t("\(streaks.longest) 天", "\(streaks.longest)d"), SettingsCopy.t("最长连续天数", "Longest streak"))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(OasesColor.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(OasesColor.border.opacity(0.45))
            .frame(width: 0.5, height: 36)
    }

    private func summaryCell(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OasesColor.foreground)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(1)
        }
        .frame(minWidth: 88)
        .padding(.horizontal, 8)
    }

    /// 今日额度：当前会员等级各项上限的实时剩余（MembershipCenter 的计数器
    /// 驱动，升级/降级会员后随 tier 即时变化）。
    private var quotaSection: some View {
        // 依赖注册：计数器累加时重建本节，做到实时。
        let _ = membership.usageRevision
        return Section {
            ForEach(membership.quotas) { q in
                quotaRow(q)
            }
        } header: {
            Text(SettingsCopy.t("今日额度", "Today's quota"))
        } footer: {
            Text(SettingsCopy.t(
                "按日历日重置，随会员等级实时变化。",
                "Resets daily. Adjusts instantly with your membership tier."
            ))
        }
    }

    private func quotaRow(_ q: MembershipCenter.QuotaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(q.title)
                Spacer()
                if let limit = q.limit, let remaining = q.remaining {
                    Text(String(format: SettingsCopy.t("剩 %1$d / %2$d", "%1$d / %2$d left"), remaining, limit))
                        .font(.subheadline)
                        .foregroundStyle(remaining == 0 ? OasesColor.destructive : OasesColor.mutedForeground)
                } else {
                    Text(SettingsCopy.t("不限量", "Unlimited"))
                        .font(.subheadline)
                        .foregroundStyle(OasesColor.mutedForeground)
                }
            }
            if let limit = q.limit {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(OasesColor.muted.opacity(0.6))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(q.remaining == 0 ? OasesColor.destructive : OasesColor.accent)
                            .frame(width: geo.size.width * CGFloat(min(q.used, limit)) / CGFloat(max(limit, 1)))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 2)
    }

    private var tokenActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(SettingsCopy.t("Token 活动", "Token activity"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("", selection: $activityMode) {
                    Text(SettingsCopy.t("每日", "Day")).tag(UsageActivityMode.daily)
                    Text(SettingsCopy.t("每周", "Week")).tag(UsageActivityMode.weekly)
                    Text(SettingsCopy.t("累计", "Total")).tag(UsageActivityMode.cumulative)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            UsageHeatmap(dayTokens: vm.dayTokens, mode: activityMode)
        }
    }

    private var inputOutputBar: some View {
        let input = vm.grandTotalInput
        let output = vm.grandTotalOutput
        let total = max(input + output, 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(red: 0.55, green: 0.38, blue: 0.95))
                        .frame(width: geo.size.width * CGFloat(input) / CGFloat(total))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(red: 0.78, green: 0.62, blue: 1))
                        .frame(width: geo.size.width * CGFloat(output) / CGFloat(total))
                }
            }
            .frame(height: 14)
            HStack {
                Text(SettingsCopy.t("输入 \(formatCount(input))", "In \(formatCount(input))"))
                Spacer()
                Text(SettingsCopy.t("输出 \(formatCount(output))", "Out \(formatCount(output))"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var modelShareChart: some View {
        let models = vm.providers.flatMap(\.models).sorted { $0.totalTokens > $1.totalTokens }
        let peak = max(models.map(\.totalTokens).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(models.prefix(6), id: \.modelId) { model in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(formatCount(model.totalTokens))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(red: 0.55, green: 0.38, blue: 0.95).opacity(0.85))
                            .frame(width: max(4, geo.size.width * CGFloat(model.totalTokens) / CGFloat(peak)))
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes <= 0 { return SettingsCopy.t("0 分", "0m") }
        let hours = minutes / 60
        let remain = minutes % 60
        if hours > 0 {
            return SettingsCopy.t("\(hours) 小时 \(remain) 分", "\(hours)h \(remain)m")
        }
        return SettingsCopy.t("\(remain) 分", "\(remain)m")
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: "%.1fM", m)
        }
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))k"
                : String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    fileprivate static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension ConversationModel {
    var span: TimeInterval {
        let times = messages.map(\.createdAt)
        guard let first = times.min(), let last = times.max() else { return 0 }
        return last.timeIntervalSince(first)
    }
}

private enum UsageActivityMode: Hashable {
    case daily, weekly, cumulative
}

private struct UsageHeatmap: View {
    var dayTokens: [String: Int]
    var mode: UsageActivityMode

    private let weeks = 53
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        let columns = weekColumns()
        let painted = paint(columns)
        let maxValue = max(painted.flatMap { $0 }.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(painted.enumerated()), id: \.offset) { _, week in
                                VStack(spacing: gap) {
                                    ForEach(week) { day in
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(color(for: day.value, max: maxValue, future: day.future))
                                            .frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                        monthLabels(columns)
                    }
                }
                // 默认停在最右端——今天和最近几周，过去的历史向左滑查看。
                .onAppear { proxy.scrollTo(painted.count - 1, anchor: .trailing) }
            }
        }
    }

    private struct DayDot: Identifiable {
        let id: String
        let date: Date
        let value: Int
        let future: Bool
    }

    private func weekColumns() -> [[Date]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -mondayOffset, to: today) ?? today
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisMonday) ?? thisMonday
        return (0..<weeks).map { week in
            (0..<7).map { day in
                cal.date(byAdding: .day, value: week * 7 + day, to: start) ?? start
            }
        }
    }

    private func paint(_ columns: [[Date]]) -> [[DayDot]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let formatter = UsageStatsView.dayKey
        var running = 0
        let flat = columns.flatMap { $0 }.sorted()
        var cumulative: [String: Int] = [:]
        for date in flat where date <= today {
            let key = formatter.string(from: date)
            running += dayTokens[key] ?? 0
            cumulative[key] = running
        }
        var weekTotals: [String: Int] = [:]
        for week in columns {
            let sum = week.reduce(0) { partial, date in
                partial + (dayTokens[formatter.string(from: date)] ?? 0)
            }
            let stamp = formatter.string(from: week[0])
            weekTotals[stamp] = sum
        }
        return columns.map { week in
            let weekKey = formatter.string(from: week[0])
            return week.map { date in
                let key = formatter.string(from: date)
                let value: Int
                switch mode {
                case .daily: value = dayTokens[key] ?? 0
                case .weekly: value = weekTotals[weekKey] ?? 0
                case .cumulative: value = cumulative[key] ?? 0
                }
                return DayDot(id: key, date: date, value: value, future: date > today)
            }
        }
    }

    private func color(for value: Int, max: Int, future: Bool) -> Color {
        if future { return Color.primary.opacity(0.04) }
        if value <= 0 { return Color.primary.opacity(0.10) }
        let t = min(1, log(1 + Double(value)) / log(1 + Double(max)))
        return Color(red: 0.45 + 0.35 * t, green: 0.28 + 0.15 * t, blue: 0.85)
            .opacity(0.35 + 0.65 * t)
    }

    private func monthLabels(_ columns: [[Date]]) -> some View {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        let cal = Calendar.current
        return HStack(alignment: .top, spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                let show = index == 0 || cal.component(.month, from: week[0]) != cal.component(.month, from: columns[index - 1][0])
                Text(show ? formatter.string(from: week[0]) : " ")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: cell, alignment: .leading)
                    .fixedSize()
            }
        }
    }
}
