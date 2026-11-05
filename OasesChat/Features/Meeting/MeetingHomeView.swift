import SwiftUI

/// Meeting Notes: every meeting recorded so far, and one way to start a new one.
///
/// The list is typographic: rows under small day headings, hairlines between them, a glyph
/// at the end of a row for its state. The record control sits at the bottom the way the
/// system's recorder places it: a red circle in a ring, nothing else to decide. While a
/// meeting records, that spot shows the live row (red dot, elapsed time) that reopens it.
struct MeetingHomeView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = MeetingStore.shared
    private let recorder = MeetingRecorder.shared
    private let cloudQueue = MeetingCloudQueue.shared
    private let jobs = MeetingNotesJobs.shared
    @State private var path: [String] = []
    @State private var showRecording = false
    @State private var showSettings = false
    @State private var showReminder = false
    @State private var errorText: String?
    @State private var starting = false
    @State private var pendingDelete: Meeting?

    private var finished: [Meeting] { store.meetings.filter { !$0.isRecording } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if finished.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: OasesSpacing.lg) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: group.title)
                                    .font(.oasesCaptionBold())
                                    .foregroundStyle(OasesColor.textTertiary)
                                    .textCase(.uppercase)
                                    .padding(.bottom, OasesSpacing.xxs)
                                ForEach(Array(group.meetings.enumerated()), id: \.element.id) { index, meeting in
                                    NavigationLink(value: meeting.id) {
                                        MeetingRow(meeting: meeting,
                                                   cloudWorking: cloudQueue.isWorking(on: meeting.id),
                                                   notesWorking: jobs.isGenerating(meeting.id))
                                    }
                                    .buttonStyle(MeetingRowPressStyle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            pendingDelete = meeting
                                        } label: {
                                            Label(String(localized: "删除", comment: "Meeting notes: delete the meeting"), systemImage: "trash")
                                        }
                                    }
                                    if index < group.meetings.count - 1 {
                                        Divider().overlay(OasesColor.border.opacity(0.5))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, OasesSpacing.lg)
                    .padding(.top, OasesSpacing.xs)
                    .padding(.bottom, OasesSpacing.md)
                }
            }
            .scrollIndicators(.hidden)
            .background(OasesColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { actionTray }
            .navigationTitle(String(localized: "会议纪要", comment: "Meeting notes: page title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭", comment: "Profile: close the page")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(Text(String(localized: "会议纪要设置", comment: "Meeting settings: page title")))
                }
            }
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(meetingID: id)
            }
        }
        .fullScreenCover(isPresented: $showRecording) {
            MeetingRecordingView { finishedID in
                showRecording = false
                if let finishedID { path = [finishedID] }
            }
        }
        .sheet(isPresented: $showSettings) { MeetingSettingsView() }
        .onAppear {
            // Work the app was closed in the middle of carries on: cloud chunks, notes and
            // translation runs, and the joined recording file.
            if AIDataSharingConsent.isAccepted { MeetingCloudQueue.shared.resumePending() }
            jobs.resumePending()
            for meeting in finished { MeetingRecordingAssembler.shared.ensure(meeting.id) }
        }
        .alert(String(localized: "录音前请告知与会者", comment: "Meeting notes: recording reminder title"), isPresented: $showReminder) {
            Button(String(localized: "开始录音", comment: "Meeting notes: start recording")) {
                UserDefaults.standard.set(true, forKey: MeetingSettings.reminderShownKey)
                startRecording()
            }
            Button(String(localized: "取消", comment: "Profile editor: discard changes"), role: .cancel) {}
        } message: {
            Text(String(localized: "录音会记下其他人的声音。请先征得与会者同意，并遵守当地法律。",
                        comment: "Meeting notes: recording reminder message"))
        }
        .alert(String(localized: "无法开始录音", comment: "Meeting notes: start failed title"),
               isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(String(localized: "好", comment: "Meeting notes: dismiss an alert"), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .confirmationDialog(String(localized: "删除这场会议？", comment: "Meeting notes: confirm deleting a meeting"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { meeting in
            Button(String(localized: "移入最近删除", comment: "Sound effects preview: the cue played when a file moves to Recently Deleted"), role: .destructive) {
                do {
                    cloudQueue.cancel(meetingID: meeting.id)
                    jobs.cancelNotes(for: meeting.id)
                    jobs.cancelTranslation(for: meeting.id)
                    try store.delete(meeting.id)
                    SoundEffects.shared.play(.trash)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        } message: { _ in
            Text(String(localized: "录音、文字记录和纪要会在“最近删除”里保留 30 天。", comment: "Meeting notes: deleted meetings stay in Recently Deleted for 30 days"))
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: OasesSpacing.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OasesColor.textTertiary)
                .padding(.bottom, OasesSpacing.xs)
            Text(String(localized: "还没有会议", comment: "Meeting notes: empty list title"))
                .font(.oasesHeadline())
                .foregroundStyle(OasesColor.foreground)
            Text(String(localized: "面对面开会时把手机放在桌上，结束后一键生成纪要。", comment: "Meeting notes: empty list description"))
                .font(.oasesCallout())
                .foregroundStyle(OasesColor.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, OasesSpacing.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: Action tray

    /// The record control above the home indicator, over a progressive blur.
    private var actionTray: some View {
        VStack(spacing: OasesSpacing.xs) {
            if recorder.state == .idle {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: MeetingSettings.displayName(spoken: MeetingSettings.spokenLanguage))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.textTertiary)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "会议语言", comment: "Meeting settings: language spoken in the meeting")))

                Button {
                    if UserDefaults.standard.bool(forKey: MeetingSettings.reminderShownKey) {
                        startRecording()
                    } else {
                        showReminder = true
                    }
                } label: {
                    RecordGlyph(busy: starting)
                }
                .buttonStyle(OasesPressStyle(scale: 0.92))
                .disabled(starting)
                .accessibilityLabel(Text(String(localized: "开始记录会议", comment: "Meeting notes: start button title")))
                .accessibilityIdentifier("oases.meeting.record")
            } else {
                liveRow
            }
        }
        .padding(.horizontal, OasesSpacing.lg)
        .padding(.top, OasesSpacing.sm)
        .padding(.bottom, OasesSpacing.xs)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            ProgressiveBlur(edge: .bottom, wash: 1)
                .frame(height: 150)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// A meeting is being recorded: one row that reopens the recording screen.
    private var liveRow: some View {
        Button {
            showRecording = true
        } label: {
            HStack(spacing: OasesSpacing.sm) {
                RecordingDot(active: recorder.state == .recording)
                Text(recorder.state == .recording
                     ? String(localized: "正在录音", comment: "Meeting notes: a meeting is being recorded")
                     : String(localized: "录音已暂停", comment: "Meeting notes: the recording is paused"))
                    .font(.oasesBodyBold())
                    .foregroundStyle(OasesColor.foreground)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(verbatim: MeetingExport.clock(recorder.recordedTime))
                        .font(.oasesBody().monospacedDigit())
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OasesColor.textTertiary)
            }
            .padding(.vertical, OasesSpacing.sm)
            .overlay(alignment: .top) { Divider().overlay(OasesColor.border.opacity(0.6)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(MeetingRowPressStyle())
        .accessibilityIdentifier("oases.meeting.live")
    }

    private func startRecording() {
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                _ = try await recorder.start(language: MeetingSettings.spokenLanguage)
                Haptics.medium()
                showRecording = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: Groups

    private struct Group {
        let title: String
        let meetings: [Meeting]
    }

    private var groups: [Group] {
        let calendar = Calendar.current
        var result: [Group] = []
        for meeting in finished {
            let title: String
            if calendar.isDateInToday(meeting.startedAt) {
                title = String(localized: "今天", comment: "Meeting notes: list section for today")
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                title = String(localized: "昨天", comment: "Meeting notes: list section for yesterday")
            } else {
                title = meeting.startedAt.formatted(.dateTime.year().month(.wide))
            }
            if let i = result.firstIndex(where: { $0.title == title }) {
                result[i] = Group(title: title, meetings: result[i].meetings + [meeting])
            } else {
                result.append(Group(title: title, meetings: [meeting]))
            }
        }
        return result
    }
}

/// The record control: a red disc in a thin ring, as the system's recorder draws it.
private struct RecordGlyph: View {
    var busy: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(OasesColor.foreground.opacity(0.5), lineWidth: 2)
                .frame(width: 66, height: 66)
            Circle()
                .fill(OasesColor.destructive)
                .frame(width: 54, height: 54)
            if busy {
                ProgressView().tint(.white)
            }
        }
        .frame(width: 72, height: 72)
        .contentShape(Circle())
    }
}

/// One meeting: title, when and how long, and a glyph for where it stands.
private struct MeetingRow: View {
    let meeting: Meeting
    let cloudWorking: Bool
    let notesWorking: Bool

    private var state: (symbol: String?, label: String?) {
        if notesWorking {
            return (nil, String(localized: "正在生成纪要", comment: "Meeting notes: short status, notes being written"))
        }
        if cloudWorking {
            return (nil, String(localized: "正在云端转写", comment: "Meeting notes: short status, cloud transcription running"))
        }
        if let notes = meeting.notes, !notes.isEmpty {
            return ("doc.text", nil)
        }
        if meeting.lines.isEmpty {
            return ("waveform", String(localized: "只有录音", comment: "Meeting notes: short status, audio only"))
        }
        return ("text.quote", String(localized: "待生成纪要", comment: "Meeting notes: short status, transcript ready, notes not written"))
    }

    var body: some View {
        HStack(alignment: .center, spacing: OasesSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: meeting.displayTitle)
                    .font(.oasesBodyBold())
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(verbatim: MeetingExport.header(meeting))
                    if let label = state.label {
                        Text(verbatim: "·")
                        Text(verbatim: label)
                    }
                }
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let symbol = state.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OasesColor.textTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OasesColor.textTertiary)
        }
        .padding(.vertical, OasesSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Press feedback for a row: a background highlight, never a scale.
struct MeetingRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OasesColor.muted.opacity(configuration.isPressed ? 0.8 : 0))
                    .padding(.horizontal, -OasesSpacing.xs)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The red recording dot, breathing while recording and still while paused.
struct RecordingDot: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = active && !reduceMotion ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.4)) : 1
            Circle()
                .fill(OasesColor.destructive)
                .frame(width: 10, height: 10)
                .opacity(active ? pulse : 0.6)
        }
        .accessibilityHidden(true)
    }
}
