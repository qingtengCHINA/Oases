import Foundation

/// Time-of-day greeting copy mirrored from Web (src/pages/Home.tsx).
/// Web maintains 5 slots × 5-8 variants each — we reproduce the full zh-Hans set here.
enum GreetingCopy {
    enum Slot: String {
        case lateNight, morning, noon, afternoon, evening
    }

    static func currentSlot(now: Date = .now, calendar: Calendar = .current) -> Slot {
        switch calendar.component(.hour, from: now) {
        case 0..<6: return .lateNight
        case 6..<12: return .morning
        case 12..<14: return .noon
        case 14..<19: return .afternoon
        default: return .evening
        }
    }

    /// Stable random per-day pick — same day shows the same line so the empty
    /// state doesn't flicker between renders.
    static func line(for slot: Slot = currentSlot(), seed: Date = .now) -> String {
        let pool = pool(for: slot)
        guard !pool.isEmpty else { return fallbackLine }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: seed) ?? 0
        return pool[day % pool.count]
    }

    /// Mirrors Web `getEmptyStateGreeting` + `stableIndex`: picks a greeting
    /// deterministically from `(today, slot, conversationId)` so each new
    /// conversation shows a different line, refreshing across conversations
    /// while staying stable within one. Pass a fresh id per empty state.
    static func line(forConversation conversationId: String, now: Date = .now) -> String {
        let slot = currentSlot(now: now)
        let pool = pool(for: slot)
        guard !pool.isEmpty else { return fallbackLine }
        let today = Self.dayKey(now)
        let seed = "\(today):\(slot.rawValue):\(conversationId)"
        return pool[stableIndex(seed, length: pool.count)]
    }

    /// A purely random pick from the current slot — used when there's no
    /// conversation yet, so each fresh empty state varies.
    static func randomLine(now: Date = .now) -> String {
        let pool = pool(for: currentSlot(now: now))
        guard !pool.isEmpty else { return fallbackLine }
        return pool.randomElement() ?? fallbackLine
    }

    private static var fallbackLine: String {
        String(localized: "你好。", comment: "Empty-state greeting fallback")
    }

    private static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    /// 1:1 port of Web's `stableIndex`: djb-style hash over the seed string.
    private static func stableIndex(_ seed: String, length: Int) -> Int {
        guard length > 0 else { return 0 }
        var hash: UInt32 = 0
        for char in seed.unicodeScalars {
            hash = (hash &* 31 &+ char.value) & 0xFFFFFFFF
        }
        return Int(hash) % length
    }

    private static func pool(for slot: Slot) -> [String] {
        switch slot {
        case .lateNight: return lateNightPool
        case .morning: return morningPool
        case .noon: return noonPool
        case .afternoon: return afternoonPool
        case .evening: return eveningPool
        }
    }

    private static var lateNightPool: [String] {
        [
            String(localized: "夜深了。今天最后一局？", comment: "Empty-state greeting, late night (0–6h)"),
            String(localized: "夜深了。慢慢说，我不困。", comment: "Empty-state greeting, late night (0–6h)"),
            String(localized: "夜深了。把乱想法倒出来吧。", comment: "Empty-state greeting, late night (0–6h)"),
            String(localized: "夜深了。适合悄悄变厉害。", comment: "Empty-state greeting, late night (0–6h)"),
            String(localized: "夜深了。我们小声搞定它。", comment: "Empty-state greeting, late night (0–6h)")
        ]
    }

    private static var morningPool: [String] {
        [
            String(localized: "早上好。今天先赢哪一件？", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。咖啡到了吗？", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。脑袋开机没？", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。先热身一下想法？", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。今天也别太乖。", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。来个漂亮开局？", comment: "Empty-state greeting, morning (6–12h)"),
            String(localized: "早上好。把想法叫醒吧。", comment: "Empty-state greeting, morning (6–12h)")
        ]
    }

    private static var noonPool: [String] {
        [
            String(localized: "中午好。准备吃什么？", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。先吃饭还是先开工？", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。今天午饭有着落吗？", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。脑子要不要也加餐？", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。半天过去，咱们还能翻盘。", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。饭点到了，想法也饿了。", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。先把问题切小块？", comment: "Empty-state greeting, noon (12–14h)"),
            String(localized: "中午好。要不要来点精神甜点？", comment: "Empty-state greeting, noon (12–14h)")
        ]
    }

    private static var afternoonPool: [String] {
        [
            String(localized: "下午好。困了吗？我扶你一把。", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。精神续杯了吗？", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。把难题放桌上吧。", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。今天还没结束呢。", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。来点不困的想法？", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。适合往前推一小步。", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。要不要把事情理顺？", comment: "Empty-state greeting, afternoon (14–19h)"),
            String(localized: "下午好。我们把它变简单点。", comment: "Empty-state greeting, afternoon (14–19h)")
        ]
    }

    private static var eveningPool: [String] {
        [
            String(localized: "晚上好。今天收个漂亮尾？", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。要不要清一下脑内桌面？", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。白天没说完的继续。", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。适合整理，也适合灵感突袭。", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。今天还可以再赢一小局。", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。慢慢来，但别停。", comment: "Empty-state greeting, evening (19–24h)"),
            String(localized: "晚上好。把想法放松地讲出来。", comment: "Empty-state greeting, evening (19–24h)")
        ]
    }
}
