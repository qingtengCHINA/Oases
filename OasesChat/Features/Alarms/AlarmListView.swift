import SwiftUI

// MARK: - Alarm Item

struct AlarmItem: Identifiable {
    let id: String
    let label: String
    let scheduleType: String  // "fixed", "relative", "timer"
    let fireDate: Date?
    let relativeTime: String?
    let countdownSeconds: Int?
    let state: String
    let repeatDays: [String]?

    init(dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.label = dict["label"] as? String ?? ""
        let rawType = dict["schedule_type"] as? String
        if let rawType {
            self.scheduleType = rawType
        } else if dict["countdown_seconds"] != nil {
            self.scheduleType = "timer"
        } else {
            self.scheduleType = "fixed"
        }
        if let iso = dict["fire_date"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fireDate = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        } else {
            self.fireDate = nil
        }
        self.relativeTime = dict["time"] as? String
        self.countdownSeconds = dict["countdown_seconds"] as? Int
        self.state = dict["state"] as? String ?? "unknown"
        self.repeatDays = dict["repeat_days"] as? [String]
    }

    var displayTime: String {
        switch scheduleType {
        case "fixed":
            guard let d = fireDate else { return "--:--" }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        case "relative":
            return relativeTime ?? "--:--"
        case "timer":
            guard let secs = countdownSeconds, secs >= 0 else { return "0:00" }
            let h = secs / 3600
            let m = (secs % 3600) / 60
            let s = secs % 60
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%02d:%02d", m, s)
        default:
            return "--:--"
        }
    }

    var subtitle: String {
        switch scheduleType {
        case "fixed":
            guard let d = fireDate else { return "" }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: d)
        case "relative":
            return String(localized: "Daily")
        case "timer":
            return String(localized: "Timer")
        default:
            return ""
        }
    }

    var weekdayLabel: String? {
        let allDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri"]
        if scheduleType == "relative", let days = repeatDays, !days.isEmpty {
            if days.count == 7 { return String(localized: "Everyday") }
            if days == weekdays { return String(localized: "Weekdays") }
            if days == ["Sat", "Sun"] || days == ["Sun", "Sat"] { return String(localized: "Weekends") }
            if days.count == 1 { return Self.shortDayName(days[0]) }
            return allDays.filter { days.contains($0) }.map(Self.shortDayName).joined(separator: ", ")
        } else if scheduleType == "fixed", let d = fireDate {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: d)
        }
        return nil
    }

    /// `repeat_days` holds English day codes; show them in the UI language.
    private static func shortDayName(_ code: String) -> String {
        switch code {
        case "Sun": return String(localized: "Sun", comment: "Short weekday name")
        case "Mon": return String(localized: "Mon", comment: "Short weekday name")
        case "Tue": return String(localized: "Tue", comment: "Short weekday name")
        case "Wed": return String(localized: "Wed", comment: "Short weekday name")
        case "Thu": return String(localized: "Thu", comment: "Short weekday name")
        case "Fri": return String(localized: "Fri", comment: "Short weekday name")
        case "Sat": return String(localized: "Sat", comment: "Short weekday name")
        default: return code
        }
    }
}

// MARK: - View Model

@MainActor
final class AlarmListViewModel: ObservableObject {
    @Published var alarms: [AlarmItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var isAuthorized: Bool?
    @Published var unsupportedReason: String?

    var isAlarmKitAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func load() {
        guard #available(iOS 26.0, *) else {
            unsupportedReason = String(localized: "Alarms require iOS 26 or later (AlarmKit).")
            return
        }
        unsupportedReason = nil
        isLoading = true
        error = nil
        _loadImpl()
    }

    @available(iOS 26.0, *)
    private func _loadImpl() {
        AlarmOffloadBridge.listAlarms { [weak self] arr, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                if let err {
                    self.error = err.localizedDescription
                    return
                }
                let dicts = arr as? [[String: Any]] ?? []
                self.alarms = dicts.map { AlarmItem(dict: $0) }
            }
        }
    }

    func requestAccess(completion: ((Bool) -> Void)? = nil) {
        guard #available(iOS 26.0, *) else {
            completion?(false)
            return
        }
        AlarmOffloadBridge.requestAuthorization { [weak self] ok, err in
            DispatchQueue.main.async {
                self?.isAuthorized = ok
                if !ok {
                    self?.error = err?.localizedDescription
                        ?? String(localized: "Alarm permission was not granted. Enable it in Settings → Apps → Oases Chat.")
                }
                completion?(ok)
            }
        }
    }

    func delete(id: String) {
        alarms.removeAll { $0.id == id }
        guard #available(iOS 26.0, *) else { return }
        AlarmOffloadBridge.cancelAlarm(withId: id) { _, _ in }
    }

    func clearAll() {
        let ids = alarms.map(\.id)
        alarms.removeAll()
        guard #available(iOS 26.0, *) else { return }
        for id in ids {
            AlarmOffloadBridge.cancelAlarm(withId: id) { _, _ in }
        }
    }

    func scheduleAlarm(date: Date, label: String, repeatMode: String, completion: @escaping (Bool) -> Void) {
        guard #available(iOS 26.0, *) else {
            completion(false)
            return
        }
        let id = UUID().uuidString
        AlarmOffloadBridge.scheduleAlarm(
            withId: id,
            fireDate: date,
            label: label.isEmpty ? String(localized: "Alarm") : label,
            repeatMode: repeatMode
        ) { [weak self] _, err in
            DispatchQueue.main.async {
                if let err {
                    self?.error = err.localizedDescription
                    completion(false)
                    return
                }
                self?.load()
                completion(true)
            }
        }
    }

    func scheduleTimer(seconds: Int, label: String, completion: @escaping (Bool) -> Void) {
        guard #available(iOS 26.0, *) else {
            completion(false)
            return
        }
        let id = UUID().uuidString
        AlarmOffloadBridge.scheduleTimer(
            withId: id,
            duration: TimeInterval(max(1, seconds)),
            label: label.isEmpty ? String(localized: "Timer") : label
        ) { [weak self] _, err in
            DispatchQueue.main.async {
                if let err {
                    self?.error = err.localizedDescription
                    completion(false)
                    return
                }
                self?.load()
                completion(true)
            }
        }
    }

    var groupedByWeek: [(title: String, alarms: [AlarmItem])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfThisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        var dated: [AlarmItem] = []
        var undated: [AlarmItem] = []
        for alarm in alarms {
            if alarm.fireDate != nil { dated.append(alarm) } else { undated.append(alarm) }
        }
        dated.sort { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
        var weekBuckets: [Date: [AlarmItem]] = [:]
        for alarm in dated {
            guard let date = alarm.fireDate,
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            weekBuckets[weekStart, default: []].append(alarm)
        }
        let sortedWeeks = weekBuckets.keys.sorted()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M/d"
        var sections: [(title: String, alarms: [AlarmItem])] = []
        if !undated.isEmpty {
            sections.append((title: String(localized: "Repeating & Timers"), alarms: undated))
        }
        for weekStart in sortedWeeks {
            guard let items = weekBuckets[weekStart] else { continue }
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            let title: String
            if weekStart == startOfThisWeek {
                title = String(localized: "This Week")
            } else if weekStart == calendar.date(byAdding: .weekOfYear, value: 1, to: startOfThisWeek) {
                title = String(localized: "Next Week")
            } else {
                title = "\(dateFormatter.string(from: weekStart)) – \(dateFormatter.string(from: weekEnd))"
            }
            sections.append((title: title, alarms: items))
        }
        return sections
    }
}

// MARK: - Alarm List View

struct AlarmListView: View {
    @StateObject private var vm = AlarmListViewModel()
    @State private var showClearConfirm = false
    @State private var showCreate = false

    var body: some View {
        content
            .navigationTitle(SettingsCopy.t("闹钟", "Alarms"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if !vm.alarms.isEmpty {
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Text(String(localized: "Clear All"))
                            }
                        }
                        if vm.isAlarmKitAvailable {
                            Button {
                                showCreate = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(Text(String(localized: "Add Alarm")))
                        }
                    }
                }
            }
            .alert(String(localized: "Clear All Alarms?"), isPresented: $showClearConfirm) {
                    Button(String(localized: "Clear All"), role: .destructive) { vm.clearAll() }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "All \(vm.alarms.count) alarm(s) will be removed. This cannot be undone."))
                }
                .sheet(isPresented: $showCreate) {
                    AlarmCreateSheet(vm: vm) {
                        showCreate = false
                    }
                }
            .onAppear {
                if vm.isAlarmKitAvailable {
                    vm.requestAccess { _ in vm.load() }
                } else {
                    vm.load()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let reason = vm.unsupportedReason {
            ContentUnavailableView(
                String(localized: "Alarms Unavailable"),
                systemImage: "alarm",
                description: Text(reason)
            )
        } else if vm.isLoading && vm.alarms.isEmpty {
            ProgressView(String(localized: "Loading alarms…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.alarms.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Couldn’t Load Alarms"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try Again")) { vm.load() }
                Button(String(localized: "Request Permission")) { vm.requestAccess { ok in if ok { vm.load() } } }
            }
        } else if vm.alarms.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Alarms"), systemImage: "alarm")
            } description: {
                Text(String(localized: "Create an alarm or timer for Ogent, or ask the agent via apple-alarm."))
            } actions: {
                if vm.isAlarmKitAvailable {
                    Button(String(localized: "Add Alarm")) { showCreate = true }
                }
            }
        } else {
            List {
                let sections = vm.groupedByWeek
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        ForEach(section.alarms) { alarm in
                            AlarmRowView(alarm: alarm)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                vm.delete(id: section.alarms[idx].id)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { vm.load() }
        }
    }
}

// MARK: - Create Sheet

private struct AlarmCreateSheet: View {
    @ObservedObject var vm: AlarmListViewModel
    var onDone: () -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case alarm, timer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .alarm: return String(localized: "Alarm")
            case .timer: return String(localized: "Timer")
            }
        }
    }

    enum RepeatMode: String, CaseIterable, Identifiable {
        case once, daily, weekdays
        var id: String { rawValue }
        var title: String {
            switch self {
            case .once: return String(localized: "Once")
            case .daily: return String(localized: "Every day")
            case .weekdays: return String(localized: "Weekdays")
            }
        }
        var bridgeValue: String {
            switch self {
            case .once: return "once"
            case .daily: return "daily"
            case .weekdays: return "weekdays"
            }
        }
    }

    @State private var kind: Kind = .alarm
    @State private var fireDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
    @State private var timerMinutes: Int = 5
    @State private var label: String = ""
    @State private var repeatMode: RepeatMode = .once
    @State private var isSaving = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker(String(localized: "Type"), selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if kind == .alarm {
                    DatePicker(
                        String(localized: "Time"),
                        selection: $fireDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Picker(String(localized: "Repeat"), selection: $repeatMode) {
                        ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    Stepper(value: $timerMinutes, in: 1...180) {
                        Text(String(localized: "Duration: \(timerMinutes) min"))
                    }
                }

                TextField(String(localized: "Label"), text: $label)

                if let localError {
                    Text(localError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "Add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        isSaving = true
        localError = nil
        let finish: (Bool) -> Void = { ok in
            isSaving = false
            if ok { onDone() }
            else if let err = vm.error { localError = err }
        }
        if kind == .alarm {
            vm.scheduleAlarm(date: fireDate, label: label, repeatMode: repeatMode.bridgeValue, completion: finish)
        } else {
            vm.scheduleTimer(seconds: timerMinutes * 60, label: label, completion: finish)
        }
    }
}

// MARK: - Alarm Row

private struct AlarmRowView: View {
    let alarm: AlarmItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.displayTime)
                    .font(.system(size: 34, weight: .thin, design: .default))
                    .monospacedDigit()
                if !alarm.label.isEmpty {
                    Text(alarm.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                if !alarm.subtitle.isEmpty {
                    Text(alarm.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                stateIndicator
                if let day = alarm.weekdayLabel {
                    Text(day)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch alarm.state {
        case "alerting":
            if #available(iOS 17.0, *) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
            } else {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.orange)
            }
        case "countdown":
            Image(systemName: "timer")
                .foregroundStyle(.blue)
        default:
            EmptyView()
        }
    }
}
