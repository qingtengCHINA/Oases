import SwiftUI

/// Settings → 自动化 (Automation).
///
/// Background automations — scheduled Ogent tasks and Shortcuts / App
/// Intents — run with nobody to answer an "Ask Once" prompt, so under Ask Once
/// the gate denies what would need one. Here the user decides, per native
/// command, whether it may run unattended. A switch is a view of the same
/// stored level the Permissions page edits (`OffloadPermissionManager`): on is
/// "始终允许" (`.bypass`), off returns it to "询问一次" (`.askOnce`); see
/// `OffloadAutomationPolicy`.
struct AutomationPermissionSettingsView: View {
    @ObservedObject private var manager = OffloadPermissionManager.shared
    /// A switch the user just turned on, waiting for the confirmation alert.
    @State private var pendingEnable: OffloadCommandInfo?

    var body: some View {
        List {
            introSection

            Section {
                ForEach(OffloadAutomationPolicy.commands(in: .privacy), id: \.name) { command in
                    commandRow(command)
                }
            } header: {
                Text(SettingsCopy.t("隐私数据", "Private Data"))
            } footer: {
                Text(SettingsCopy.t(
                    "打开后，这些命令读取你的数据时不再询问；能修改数据的（日历、提醒事项、照片等）修改时也不再询问。后台自动化和快捷指令中同样如此。",
                    "When on, these commands read your data without asking, and the ones that can change it (Calendar, Reminders, Photos, …) change it without asking too — including in background automations and Shortcuts."
                ))
            }

            Section {
                ForEach(OffloadAutomationPolicy.commands(in: .externalActions), id: \.name) { command in
                    commandRow(command)
                }
            } header: {
                Text(SettingsCopy.t("对外操作", "Actions Outside the App"))
            } footer: {
                Text(SettingsCopy.t(
                    "打开后，这些操作会直接执行，不再询问，后台自动化和快捷指令中也一样。「调用其他模型」可能产生费用。",
                    "When on, these actions run without asking — including in background automations and Shortcuts. Model Use may cost money."
                ))
            }

            Section {
            } footer: {
                Text(SettingsCopy.t(
                    "这里和「权限」页是同一套设置：打开即「始终允许」，关闭即改回「询问一次」。打开后，这个命令在任何地方使用都不再询问，包括聊天和 Ogent 会话。",
                    "This page and Permissions share one setting: on means Bypass, off returns the command to Ask Once. Once on, the command never asks anywhere, chats and Ogent sessions included."
                ))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(SettingsCopy.t("自动化", "Automation"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pendingEnable.map { alertTitle(for: $0) } ?? "",
            isPresented: Binding(
                get: { pendingEnable != nil },
                set: { if !$0 { pendingEnable = nil } }
            ),
            presenting: pendingEnable
        ) { command in
            Button(SettingsCopy.t("始终允许", "Always Allow")) {
                manager.setRunsUnattended(true, for: command.name)
            }
            Button(SettingsCopy.t("取消", "Cancel"), role: .cancel) {}
        } message: { command in
            Text(alertMessage(for: command))
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            introRow(
                "clock.arrow.2.circlepath",
                SettingsCopy.t("定时任务", "Scheduled tasks"),
                SettingsCopy.t(
                    "Ogent 按计划自动运行的任务：每小时、每天、按间隔或开机时。",
                    "Ogent tasks that run on a schedule: hourly, daily, at an interval, or at startup."
                )
            )
            introRow(
                "bolt.fill",
                SettingsCopy.t("快捷指令", "Shortcuts"),
                SettingsCopy.t(
                    "通过「快捷指令」或 Siri 触发的 Oases 操作（App Intents）。",
                    "Oases actions run from the Shortcuts app or Siri (App Intents)."
                )
            )
            introRow(
                "hand.raised",
                SettingsCopy.t("没人能点「允许」", "Nobody to tap Allow"),
                SettingsCopy.t(
                    "这些任务常在 App 不在前台时运行，无法弹出确认。命令设为「询问一次」时，需要确认的调用会被直接拒绝；修改数据或对外的操作只在 App 打开时运行。",
                    "These often run while the app isn't open, so no prompt can be shown. Under Ask Once, a call that needs your approval is refused, and anything that changes data or acts outside the app only runs while the app is open."
                )
            )
        }
    }

    private func introRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OasesColor.foreground.opacity(0.82))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OasesColor.muted.opacity(0.55))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func commandRow(_ command: OffloadCommandInfo) -> some View {
        let level = manager.permissionLevel(for: command.name)
        return Toggle(isOn: unattendedBinding(for: command)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: command))
                Text(Self.detail(for: command))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if level == .notAllowed {
                    Text(SettingsCopy.t("在「权限」中为「不允许」", "Set to Not Allowed in Permissions"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityHint(SettingsCopy.t(
            "打开后，这个命令在后台自动化和快捷指令中也不再询问。",
            "When on, this command runs without asking, including in background automations and Shortcuts."
        ))
    }

    /// Off → back to Ask Once right away. On → confirm first; the switch
    /// flips once the alert is accepted (it reads the stored level).
    private func unattendedBinding(for command: OffloadCommandInfo) -> Binding<Bool> {
        Binding(
            get: { manager.runsUnattended(command.name) },
            set: { enabled in
                if enabled {
                    pendingEnable = command
                } else {
                    manager.setRunsUnattended(false, for: command.name)
                }
            }
        )
    }

    // MARK: - Copy

    private func alertTitle(for command: OffloadCommandInfo) -> String {
        let name = Self.title(for: command)
        return SettingsCopy.t("让「\(name)」始终允许？", "Always allow \(name)?")
    }

    private func alertMessage(for command: OffloadCommandInfo) -> String {
        SettingsCopy.t(
            "「\(Self.title(for: command))」将不再询问你：\(Self.detail(for: command))。在后台自动化、快捷指令、聊天和 Ogent 会话中都一样。之后可以在这里或「权限」页关闭。",
            "\(Self.title(for: command)) will stop asking: \(Self.detail(for: command)). This applies in background automations, Shortcuts, chats and Ogent sessions. You can turn it off here or in Permissions at any time."
        )
    }

    /// Names and what the command can do, for the commands listed on this
    /// page. The English copy matches the registry's label and description,
    /// which other commands fall back to.
    static func title(for command: OffloadCommandInfo) -> String {
        switch command.name {
        case "apple-calendar": return SettingsCopy.t("日历", "Calendar")
        case "apple-reminders": return SettingsCopy.t("提醒事项", "Reminders")
        case "apple-photos": return SettingsCopy.t("照片", "Photos")
        case "apple-location": return SettingsCopy.t("位置", "Location")
        case "apple-clipboard": return SettingsCopy.t("剪贴板", "Clipboard")
        case "apple-weather": return SettingsCopy.t("天气", "Weather")
        case "apple-bluetooth": return SettingsCopy.t("蓝牙", "Bluetooth")
        case "apple-nfc": return "NFC"
        case "apple-speech": return SettingsCopy.t("语音识别", "Speech")
        case "minis-sessions-cli": return SettingsCopy.t("其他对话", "Chat Sessions")
        case "minis-browser-use": return SettingsCopy.t("浏览器 Cookie", "Browser Cookies")
        case "apple-media": return SettingsCopy.t("媒体与播放", "Media")
        case "apple-notification": return SettingsCopy.t("通知", "Notification")
        case "apple-alarm": return SettingsCopy.t("闹钟与计时器", "Alarm")
        case "apple-open": return SettingsCopy.t("打开链接", "Open URL")
        case "minis-model-use": return SettingsCopy.t("调用其他模型", "Model Use")
        default: return command.displayLabel
        }
    }

    static func detail(for command: OffloadCommandInfo) -> String {
        switch command.name {
        case "apple-calendar": return SettingsCopy.t("读取日程，新建、修改或删除日历事件", "Events, schedules, and calendar details")
        case "apple-reminders": return SettingsCopy.t("读取提醒，新建、修改、完成或删除提醒", "Tasks, due dates, and reminder lists")
        case "apple-photos": return SettingsCopy.t("读取和导出照片、视频与相簿，存入照片、建相簿、收藏或删除", "Photos, videos, and album metadata")
        case "apple-location": return SettingsCopy.t("获取你当前所在的位置", "Current GPS coordinates and location history")
        case "apple-clipboard": return SettingsCopy.t("读取或改写剪贴板，其中可能有密码和验证码", "Text and images copied to the clipboard")
        case "apple-weather": return SettingsCopy.t("按你当前的位置查天气（指定经纬度时本来就不用确认）", "Weather for your current location (explicit coordinates never ask)")
        case "apple-bluetooth": return SettingsCopy.t("扫描、连接附近的蓝牙设备并收发数据", "Scan, connect to, and exchange data with nearby Bluetooth devices")
        case "apple-nfc": return SettingsCopy.t("读取和写入 NFC 标签与卡片", "Read and write NFC tags and cards")
        case "apple-speech": return SettingsCopy.t("用麦克风录音并转成文字", "Record from the microphone and transcribe it")
        case "minis-sessions-cli": return SettingsCopy.t("读取你的其他对话，并在其中发送消息", "Read your other chat sessions and send prompts in them")
        case "minis-browser-use": return SettingsCopy.t("读取或写入内置浏览器的 Cookie，包括网站登录状态", "Read or set cookies in the in-app browser")
        case "apple-media": return SettingsCopy.t("查看正在播放的内容、搜索音乐资料库、控制播放和音量", "Now playing, music library search, and playback control")
        case "apple-notification": return SettingsCopy.t("安排或取消本地通知", "Schedule and cancel local notifications")
        case "apple-alarm": return SettingsCopy.t("创建或取消闹钟和计时器", "Create and cancel alarms and timers")
        case "apple-open": return SettingsCopy.t("打开网页链接，或通过 URL Scheme 打开其他 App", "Open links and other apps through URL schemes")
        case "minis-model-use": return SettingsCopy.t("用你配置的服务商调用其他 AI 模型，可能产生费用", "Call other AI models with your configured providers (may cost money)")
        default: return command.description
        }
    }
}
