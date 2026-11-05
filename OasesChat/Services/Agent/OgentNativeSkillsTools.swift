import Foundation
import EventKit
import Contacts
import Photos
import CoreLocation

/// The Swift-native personal-data tools pass the same gate as the guest offloads of the same
/// capability (`OffloadPermissionManager`): the user's choice in Settings → Permissions and
/// Settings → Automation applies to them too, and "Ask Once" prompts once per session. The iOS
/// system permission is asked afterwards, as before.
enum NativeToolPermission {
    /// nil when the call may run; otherwise the denial text for the model.
    static func denial(command: String, arguments: [String]) async -> String? {
        let result = await OffloadPermissionManager.shared.authorizeOffload(
            command: command,
            arguments: arguments,
            sessionId: OasesPathResolver.ActiveSession.id
        )
        if case .denied(let message) = result { return message }
        return nil
    }
}

// MARK: - Calendar

/// Read calendar events from EventKit. Requires
/// `NSCalendarsUsageDescription` in Info.plist. The first invocation
/// triggers iOS's standard permission sheet.
final class CalendarReadTool: NSObject, AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "calendar_read",
        summary: """
        List the user's calendar events in a date range. Use to answer "what's on my schedule", \
        "am I free tomorrow", or to gather context before suggesting a meeting time.
        """,
        displayName: "读取日历", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "读取日历", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{"days":{"type":"integer","description":"Number of days forward to fetch (default 7).","default":7}}}
        """,
        surfaces: [.chat, .project],
        requiresPermission: true
    )

    private let store = EKEventStore()

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let days = (args["days"] as? Int) ?? 7
        if let denied = await NativeToolPermission.denial(command: "apple-calendar", arguments: ["list"]) {
            return .textOnly("⚠️ \(denied)")
        }
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        // i18n-ignore: tool result the model reads
        guard granted else { return .textOnly("⚠️ 用户拒绝了日历访问。") }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        if events.isEmpty {
            // i18n-ignore: tool result the model reads
            return .textOnly("接下来 \(days) 天没有日历事件。")
        }
        let df = ISO8601DateFormatter()
        let lines = events.map { e -> String in
            let s = df.string(from: e.startDate)
            let t = df.string(from: e.endDate)
            // i18n-ignore: tool result the model reads
            return "- [\(s) → \(t)] \(e.title ?? "(无标题)")"
        }
        return .textOnly(lines.joined(separator: "\n"))
    }
}

// MARK: - Reminders

/// Add a reminder to the system Reminders app. Requires
/// `NSRemindersUsageDescription`.
final class ReminderCreateTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "reminder_create",
        summary: """
        Create a reminder in the system Reminders app. Use when the user asks you to remember to \
        do something, or to set a follow-up. Optionally include a due date as an ISO 8601 string.
        """,
        displayName: "新建提醒事项", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "新建提醒事项", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["title"],"properties":{"title":{"type":"string"},"dueISO":{"type":"string","description":"Optional ISO-8601 date-time."},"notes":{"type":"string"}}}
        """,
        surfaces: [.chat, .project],
        requiresPermission: true
    )

    private let store = EKEventStore()

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let title = (args["title"] as? String) ?? ""
        let dueISO = args["dueISO"] as? String
        let notes = args["notes"] as? String
        // i18n-ignore: tool result the model reads
        guard !title.isEmpty else { return .textOnly("⚠️ reminder_create 需要 title。") }
        if let denied = await NativeToolPermission.denial(command: "apple-reminders", arguments: ["create"]) {
            return .textOnly("⚠️ \(denied)")
        }

        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
        // i18n-ignore: tool result the model reads
        guard granted else { return .textOnly("⚠️ 用户拒绝了提醒事项访问。") }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let dueISO, let date = ISO8601DateFormatter().date(from: dueISO) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date
            )
        }
        try store.save(reminder, commit: true)
        // i18n-ignore: tool result the model reads
        return .textOnly("✓ 已添加提醒：\(title)\(dueISO.map { "（\($0)）" } ?? "")")
    }
}

// MARK: - Contacts

/// Search the address book. Returns name + phone + email for matches.
/// Requires `NSContactsUsageDescription`.
final class ContactSearchTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "contact_search",
        summary: """
        Search the user's address book by name. Returns matching contacts with phone numbers and emails. \
        Use when the user asks to call/message/email someone whose contact info you need.
        """,
        displayName: "搜索联系人", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "搜索联系人", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["query"],"properties":{"query":{"type":"string","description":"Name or partial name to search for."}}}
        """,
        surfaces: [.chat, .project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let query = (args["query"] as? String) ?? ""
        // i18n-ignore: tool result the model reads
        guard !query.isEmpty else { return .textOnly("⚠️ contact_search 需要 query。") }
        if let denied = await NativeToolPermission.denial(command: "apple-contacts", arguments: ["search"]) {
            return .textOnly("⚠️ \(denied)")
        }
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            // i18n-ignore: tool result the model reads
            return .textOnly("⚠️ 用户拒绝了通讯录访问。")
        }
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        // i18n-ignore: tool result the model reads
        if matches.isEmpty { return .textOnly("没找到匹配 “\(query)” 的联系人。") }
        let rows = matches.prefix(10).map { c -> String in
            let name = [c.givenName, c.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
            let emails = c.emailAddresses.map { $0.value as String }.joined(separator: ", ")
            return "- \(name) · 📱 \(phones.isEmpty ? "—" : phones) · ✉️ \(emails.isEmpty ? "—" : emails)"
        }
        return .textOnly(rows.joined(separator: "\n"))
    }
}

// MARK: - Photos (metadata)

/// List recent photos with basic metadata (date, location). Doesn't
/// return image data — that would be too large for a tool result.
/// Requires `NSPhotoLibraryUsageDescription`.
final class PhotoListTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "photo_list",
        summary: """
        List the user's most recent photo assets with capture date and optional GPS location. \
        Use as a discovery step before asking the user which photo to attach.
        """,
        displayName: "列出近期照片", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "列出近期照片", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{"limit":{"type":"integer","default":10}}}
        """,
        surfaces: [.chat, .project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let limit = (args["limit"] as? Int) ?? 10
        if let denied = await NativeToolPermission.denial(command: "apple-photos", arguments: ["list"]) {
            return .textOnly("⚠️ \(denied)")
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .denied else {
            // i18n-ignore: tool result the model reads
            return .textOnly("⚠️ 用户拒绝了照片库访问。")
        }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = max(1, min(limit, 50))
        let fetch = PHAsset.fetchAssets(with: .image, options: opts)
        // i18n-ignore: tool result the model reads
        if fetch.count == 0 { return .textOnly("照片库为空。") }
        let df = ISO8601DateFormatter()
        var lines: [String] = []
        fetch.enumerateObjects { asset, _, _ in
            let date = asset.creationDate.map { df.string(from: $0) } ?? "?"
            let coord = asset.location.map { "(\(String(format: "%.4f", $0.coordinate.latitude)), \(String(format: "%.4f", $0.coordinate.longitude)))" } ?? "—"
            lines.append("- \(date)  \(asset.pixelWidth)×\(asset.pixelHeight)  loc=\(coord)  id=\(asset.localIdentifier.prefix(12))")
        }
        return .textOnly(lines.joined(separator: "\n"))
    }
}

// MARK: - Location

/// Current device location. One-shot — doesn't subscribe to updates.
/// Requires `NSLocationWhenInUseUsageDescription`.
final class LocationTool: NSObject, AgentTool, CLLocationManagerDelegate, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "location_current",
        summary: """
        Return the device's current GPS location (latitude, longitude, optional address). \
        Use when the user asks "where am I", or to enrich location-relevant answers.
        """,
        displayName: "当前位置", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "当前位置", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","properties":{}}
        """,
        surfaces: [.chat, .project],
        requiresPermission: true
    )

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        if let denied = await NativeToolPermission.denial(command: "apple-location", arguments: ["current"]) {
            return .textOnly("⚠️ \(denied)")
        }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
            // i18n-ignore: tool result the model reads
            return .textOnly("⚠️ 用户拒绝了位置访问。")
        }
        let loc: CLLocation? = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            manager.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.resumeContinuation(with: nil)
            }
        }
        // i18n-ignore: tool result the model reads
        guard let loc else { return .textOnly("⚠️ 定位请求超时。") }
        let lat = String(format: "%.5f", loc.coordinate.latitude)
        let lon = String(format: "%.5f", loc.coordinate.longitude)
        let acc = String(format: "%.0fm", loc.horizontalAccuracy)
        // i18n-ignore: tool result the model reads
        return .textOnly("当前位置：\(lat), \(lon)（精度 \(acc)）")
    }

    private func resumeContinuation(with location: CLLocation?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: location)
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resumeContinuation(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resumeContinuation(with: nil)
    }
}

// MARK: - Registration

enum OgentNativeSkills {
    static func registerAll() {
        ToolRegistry.shared.register(CalendarReadTool())
        ToolRegistry.shared.register(ReminderCreateTool())
        ToolRegistry.shared.register(ContactSearchTool())
        ToolRegistry.shared.register(PhotoListTool())
        ToolRegistry.shared.register(LocationTool())
    }
}
