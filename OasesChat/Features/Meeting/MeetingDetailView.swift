import SwiftUI

/// One finished meeting: its recording, its notes (or the action that writes them) and its
/// transcript. Typographic rather than boxed: text, hairlines and small tinted actions; the
/// only filled surfaces are the player and the summary.
struct MeetingDetailView: View {
    let meetingID: String

    private let store = MeetingStore.shared
    private let cloudQueue = MeetingCloudQueue.shared
    private let jobs = MeetingNotesJobs.shared
    private let assembler = MeetingRecordingAssembler.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var errorText: String?
    @State private var inlineFailure: String?
    @State private var shareURL: URL?
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmDelete = false
    @State private var showTranslation = true
    @State private var seekRequest: Double?

    private var meeting: Meeting? { store.meeting(meetingID) }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ContentUnavailableView(String(localized: "这场会议已不在了", comment: "Meeting notes: the meeting was deleted"),
                                       systemImage: "trash")
            }
        }
        .background(OasesColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .onAppear {
            assembler.ensure(meetingID)
            inlineFailure = jobs.takeFailure(for: meetingID)
            if let meeting, !meeting.pendingCloudChunks.isEmpty, AIDataSharingConsent.isAccepted,
               !cloudQueue.isWorking(on: meetingID) {
                cloudQueue.transcribeRemaining(of: meetingID)
            }
        }
        .onChange(of: jobs.isBusy(meetingID)) { was, now in
            if was, !now { inlineFailure = jobs.takeFailure(for: meetingID) }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            OasesShareSheet(url: item.url)
        }
        .alert(String(localized: "重命名", comment: "Meeting notes: rename the meeting"), isPresented: $renaming) {
            TextField(String(localized: "会议名称", comment: "Meeting notes: meeting title field"), text: $draftTitle)
            Button(String(localized: "完成", comment: "Profile editor: save changes")) {
                let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                store.update(meetingID, immediately: true) { $0.customTitle = title.isEmpty ? nil : title }
            }
            Button(String(localized: "取消", comment: "Profile editor: discard changes"), role: .cancel) {}
        }
        .confirmationDialog(String(localized: "删除这场会议？", comment: "Meeting notes: confirm deleting a meeting"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "移入最近删除", comment: "Sound effects preview: the cue played when a file moves to Recently Deleted"), role: .destructive) {
                do {
                    cloudQueue.cancel(meetingID: meetingID)
                    jobs.cancelNotes(for: meetingID)
                    jobs.cancelTranslation(for: meetingID)
                    try store.delete(meetingID)
                    SoundEffects.shared.play(.trash)
                    dismiss()
                } catch {
                    errorText = error.localizedDescription
                }
            }
        } message: {
            Text(String(localized: "录音、文字记录和纪要会在“最近删除”里保留 30 天。", comment: "Meeting notes: deleted meetings stay in Recently Deleted for 30 days"))
        }
        .alert(String(localized: "出错了", comment: "Meeting notes: error alert title"),
               isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(String(localized: "好", comment: "Meeting notes: dismiss an alert"), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OasesSpacing.lg) {
                VStack(alignment: .leading, spacing: OasesSpacing.xs) {
                    Text(verbatim: meeting.displayTitle)
                        .font(.oasesTitle())
                        .foregroundStyle(OasesColor.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    metaRow(meeting)
                }
                if let url = MeetingRecordingAssembler.recordingURL(for: meeting) {
                    MeetingPlayerView(url: url, duration: meeting.duration, seekRequest: $seekRequest)
                } else if assembler.isAssembling(meeting.id) {
                    MeetingStatusLine(symbol: nil, text: String(localized: "正在整理录音文件…", comment: "Meeting notes: the recording file is being joined from its parts"))
                }
                Picker("", selection: $tab) {
                    Text(String(localized: "纪要", comment: "Meeting notes: notes heading")).tag(0)
                    Text(String(localized: "文字记录", comment: "Meeting notes: transcript heading")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if tab == 0 {
                    notesSection(meeting)
                } else {
                    transcriptSection(meeting)
                }
            }
            .padding(.horizontal, OasesSpacing.lg)
            .padding(.top, OasesSpacing.sm)
            .padding(.bottom, OasesSpacing.xxl)
        }
        .scrollIndicators(.hidden)
    }

    /// When, how long, in what language, and how big the recording is.
    private func metaRow(_ meeting: Meeting) -> some View {
        let minutes = Int(meeting.duration / 60)
        let length = minutes < 1
            ? String(localized: "不到 1 分钟", comment: "Meeting notes: duration under a minute")
            : String(localized: "\(minutes) 分钟", comment: "Meeting notes: duration in minutes")
        return HStack(spacing: OasesSpacing.sm) {
            Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            Label(length, systemImage: "clock")
            Label(MeetingSettings.displayName(spoken: meeting.language), systemImage: "waveform")
            if let bytes = meeting.recordingBytes, bytes > 0 {
                Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "externaldrive")
            }
        }
        .font(.oasesCaption())
        .foregroundStyle(OasesColor.mutedForeground)
        .labelStyle(MetaLabelStyle())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private struct MetaLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.font(.system(size: 11, weight: .medium)).foregroundStyle(OasesColor.textTertiary)
                configuration.title
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private func notesSection(_ meeting: Meeting) -> some View {
        let generating = jobs.isGenerating(meeting.id)
        if let notes = meeting.notes, !notes.isEmpty {
            MeetingNotesContent(notes: notes)
            Divider().overlay(OasesColor.border.opacity(0.6))
            HStack(spacing: OasesSpacing.sm) {
                if generating {
                    generatingRow(meeting)
                } else {
                    Button {
                        AIConsentGate.perform { jobs.generateNotes(for: meeting.id) }
                    } label: {
                        Label(String(localized: "重新生成纪要", comment: "Meeting notes: write the notes again"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(MeetingTintedButtonStyle(prominent: false))
                    .disabled(cloudQueue.isWorking(on: meeting.id))
                }
                Spacer(minLength: 0)
            }
            if let inlineFailure { failureLine(inlineFailure) }
        } else {
            VStack(alignment: .leading, spacing: OasesSpacing.sm) {
                HStack(spacing: OasesSpacing.xs) {
                    Image(systemName: meeting.lines.isEmpty ? "waveform.slash" : "sparkles")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OasesColor.mutedForeground)
                    Text(meeting.lines.isEmpty
                         ? String(localized: "没有文字记录", comment: "Meeting notes: card title when nothing was transcribed")
                         : String(localized: "还没有纪要", comment: "Meeting notes: card title before notes are written"))
                        .font(.oasesHeadline())
                        .foregroundStyle(OasesColor.foreground)
                }
                Text(meeting.lines.isEmpty
                     ? String(localized: "这场会议没有文字记录，无法生成纪要。", comment: "Meeting notes: no transcript, so no notes")
                     : String(localized: "把文字记录整理成纪要：摘要、议题、结论和待办，每一条都标出原话。",
                              comment: "Meeting notes: what generating notes does"))
                    .font(.oasesCallout())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                if !meeting.lines.isEmpty {
                    if generating {
                        generatingRow(meeting)
                            .padding(.top, OasesSpacing.xxs)
                    } else {
                        Button {
                            AIConsentGate.perform { jobs.generateNotes(for: meeting.id) }
                        } label: {
                            Label(String(localized: "生成纪要", comment: "Meeting notes: write the notes"), systemImage: "sparkles")
                        }
                        .buttonStyle(MeetingTintedButtonStyle(prominent: true))
                        .disabled(cloudQueue.isWorking(on: meeting.id))
                        .padding(.top, OasesSpacing.xxs)
                    }
                    if cloudQueue.isWorking(on: meeting.id) {
                        Text(String(localized: "正在云端转写，完成后再生成纪要会更准确。", comment: "Meeting notes: notes wait for cloud transcription"))
                            .font(.oasesCaption())
                            .foregroundStyle(OasesColor.textTertiary)
                    }
                    if let inlineFailure { failureLine(inlineFailure) }
                }
            }
            .padding(.top, OasesSpacing.xs)
        }
    }

    /// The run in progress, with a way to stop it. It keeps going when the page is left.
    private func generatingRow(_ meeting: Meeting) -> some View {
        HStack(spacing: OasesSpacing.sm) {
            ProgressView().controlSize(.small)
            Text(String(localized: "正在生成纪要…", comment: "Meeting notes: notes are being written"))
                .font(.oasesCallout())
                .foregroundStyle(OasesColor.mutedForeground)
            Button(String(localized: "取消", comment: "Profile editor: discard changes")) {
                jobs.cancelNotes(for: meeting.id)
            }
            .font(.oasesCalloutBold())
            .foregroundStyle(OasesColor.primaryText)
            .buttonStyle(.plain)
        }
    }

    private func failureLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.oasesCaption())
            .foregroundStyle(OasesColor.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Transcript

    private func transcriptSection(_ meeting: Meeting) -> some View {
        LazyVStack(alignment: .leading, spacing: OasesSpacing.sm) {
            cloudStatus(meeting)
            if !meeting.lines.isEmpty { translationBar(meeting) }
            if let inlineFailure, tab == 1 { failureLine(inlineFailure) }
            if meeting.lines.isEmpty {
                Text(String(localized: "没有文字记录。", comment: "Meeting notes: the meeting has no transcript"))
                    .font(.oasesCallout())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            let translated = showTranslation && meeting.translationLanguage != nil
            let playable = MeetingRecordingAssembler.recordingURL(for: meeting) != nil
            ForEach(meeting.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.sm) {
                    Button {
                        seekRequest = meeting.recordingTime(forMeetingTime: line.t)
                        Haptics.tap()
                    } label: {
                        Text(verbatim: MeetingExport.clock(line.t))
                            .font(.oasesCaption().monospacedDigit())
                            .foregroundStyle(playable ? OasesColor.primaryText : OasesColor.textTertiary)
                            .frame(minWidth: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!playable)
                    .accessibilityLabel(Text(String(localized: "从 \(MeetingExport.clock(line.t)) 播放", comment: "Meeting notes: play the recording from this line's time; argument is the time")))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: line.text)
                            .font(.oasesBody())
                            .foregroundStyle(OasesColor.foreground)
                            .textSelection(.enabled)
                        if translated, let translation = line.translation, !translation.isEmpty {
                            Text(verbatim: translation)
                                .font(.oasesCallout())
                                .foregroundStyle(OasesColor.mutedForeground)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Where cloud transcription stands, with the action that moves it on.
    @ViewBuilder
    private func cloudStatus(_ meeting: Meeting) -> some View {
        let progress = cloudQueue.progress(for: meeting)
        if cloudQueue.isWorking(on: meeting.id) {
            MeetingStatusLine(symbol: nil,
                              text: String(localized: "正在云端转写 · \(progress.done)/\(progress.total) 段",
                                           comment: "Meeting notes: cloud transcription progress; arguments are chunks done and total"))
        } else if !meeting.pendingCloudChunks.isEmpty {
            MeetingStatusLine(symbol: "icloud.and.arrow.up",
                              text: AIDataSharingConsent.isAccepted
                                ? String(localized: "还有 \(meeting.pendingCloudChunks.count) 段录音没有云端转写。", comment: "Meeting notes: chunks still waiting for cloud transcription; argument is the count")
                                : String(localized: "云端转写需要先同意 AI 数据共享。", comment: "Meeting notes: cloud transcription waits for the AI data sharing consent"),
                              action: String(localized: "开始云端转写", comment: "Meeting notes: start cloud transcription")) {
                AIConsentGate.perform { cloudQueue.transcribeRemaining(of: meeting.id) }
            }
        } else if !meeting.failedCloudChunks.isEmpty {
            MeetingStatusLine(symbol: "exclamationmark.triangle",
                              text: String(localized: "有 \(meeting.failedCloudChunks.count) 段云端转写失败，这些段落保留了实时转写的文字。",
                                           comment: "Meeting notes: some chunks failed cloud transcription; argument is the count"),
                              action: String(localized: "重试", comment: "Meeting notes: retry cloud transcription")) {
                AIConsentGate.perform { cloudQueue.transcribeRemaining(of: meeting.id) }
            }
        }
    }

    /// Translate into the notes language, show or hide the translation, finish missing lines.
    @ViewBuilder
    private func translationBar(_ meeting: Meeting) -> some View {
        let target = MeetingSettings.notesLanguageCode
        let targetName = MeetingSettings.displayName(notes: target)
        let missing = meeting.translationLanguage == target
            ? meeting.lines.filter { ($0.translation ?? "").isEmpty }.count : meeting.lines.count
        HStack(spacing: OasesSpacing.sm) {
            if let progress = jobs.translation(for: meeting.id) {
                ProgressView().controlSize(.small)
                Text(String(localized: "正在翻译 \(progress.done)/\(progress.total) 行", comment: "Meeting notes: translation progress; arguments are lines done and total"))
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                Button(String(localized: "取消", comment: "Profile editor: discard changes")) {
                    jobs.cancelTranslation(for: meeting.id)
                }
                .font(.oasesCaptionBold())
                .foregroundStyle(OasesColor.primaryText)
                .buttonStyle(.plain)
            } else {
                if meeting.translationLanguage != nil {
                    Button {
                        showTranslation.toggle()
                    } label: {
                        Label(showTranslation
                              ? String(localized: "隐藏译文", comment: "Meeting notes: hide the transcript translation")
                              : String(localized: "显示译文", comment: "Meeting notes: show the transcript translation"),
                              systemImage: showTranslation ? "eye.slash" : "eye")
                    }
                    .buttonStyle(MeetingTintedButtonStyle(prominent: false))
                }
                if missing > 0 {
                    Button {
                        showTranslation = true
                        AIConsentGate.perform { jobs.translate(meeting.id, to: target) }
                    } label: {
                        Label(meeting.translationLanguage == target
                              ? String(localized: "翻译剩余的 \(missing) 行", comment: "Meeting notes: translate the lines without a translation; argument is the count")
                              : String(localized: "翻译成\(targetName)", comment: "Meeting notes: translate the transcript; argument is the language name"),
                              systemImage: "translate")
                    }
                    .buttonStyle(MeetingTintedButtonStyle(prominent: false))
                    .disabled(cloudQueue.isWorking(on: meeting.id))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            if let meeting {
                Section(String(localized: "导出", comment: "Meeting notes: export menu section")) {
                    Button { export(meeting, ext: "md", MeetingExport.markdown(meeting)) } label: {
                        Label { Text(verbatim: "Markdown") } icon: { Image(systemName: "doc.richtext") }
                    }
                    Button {
                        let url = Self.exportURL(meeting, ext: "pdf")
                        do {
                            try MeetingPDF.render(meeting).write(to: url, options: .atomic)
                            shareURL = url
                        } catch {
                            errorText = error.localizedDescription
                        }
                    } label: {
                        Label { Text(verbatim: "PDF") } icon: { Image(systemName: "doc") }
                    }
                    Button { export(meeting, ext: "txt", MeetingExport.plainText(meeting)) } label: {
                        Label(String(localized: "纯文本", comment: "Meeting notes: export as plain text"), systemImage: "text.alignleft")
                    }
                    Button { export(meeting, ext: "srt", MeetingExport.srt(meeting)) } label: {
                        Label(String(localized: "字幕（SRT）", comment: "Meeting notes: export as SRT subtitles"), systemImage: "captions.bubble")
                    }
                    if let url = MeetingRecordingAssembler.recordingURL(for: meeting) {
                        Button { shareURL = url } label: {
                            Label(String(localized: "录音（M4A）", comment: "Meeting notes: export the recording as an M4A file"), systemImage: "waveform")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = MeetingExport.markdown(meeting)
                        Haptics.tap()
                        SoundEffects.shared.play(.copy)
                    } label: {
                        Label(String(localized: "复制全部", comment: "Meeting notes: copy notes and transcript"), systemImage: "doc.on.doc")
                    }
                }
                if MeetingCloudASR.supports(language: meeting.language), !meeting.chunks.isEmpty,
                   meeting.chunks.contains(where: { $0.cloud != .done }), !meeting.isRecording,
                   !cloudQueue.isWorking(on: meeting.id) {
                    Button {
                        AIConsentGate.perform { cloudQueue.transcribeRemaining(of: meeting.id, enable: true) }
                    } label: {
                        Label(String(localized: "用云端转写", comment: "Meeting notes: transcribe the recording in the cloud"),
                              systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                Button {
                    draftTitle = meeting.customTitle ?? meeting.displayTitle
                    renaming = true
                } label: {
                    Label(String(localized: "重命名", comment: "Meeting notes: rename the meeting"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(String(localized: "删除", comment: "Meeting notes: delete the meeting"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func export(_ meeting: Meeting, ext: String, _ text: String) {
        let url = Self.exportURL(meeting, ext: ext)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func exportURL(_ meeting: Meeting, ext: String) -> URL {
        let safe = meeting.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(safe.prefix(60)).\(ext)")
    }

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}

// MARK: - Shared pieces

/// A small action: tinted text on a soft accent fill (prominent) or a hairline (quiet).
/// Rounded 10, never a capsule.
struct MeetingTintedButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.oasesCalloutBold())
            .foregroundStyle(prominent ? OasesColor.primaryText : OasesColor.foreground)
            .padding(.horizontal, OasesSpacing.sm + 2)
            .frame(minHeight: 36)
            .background(prominent ? OasesColor.primary.opacity(0.14) : OasesColor.muted,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.1) : .spring(duration: 0.3, bounce: 0),
                       value: configuration.isPressed)
    }
}

/// One line of status with an optional action, no box around it.
struct MeetingStatusLine: View {
    var symbol: String?
    var text: String
    var action: String?
    var perform: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: OasesSpacing.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OasesColor.mutedForeground)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: text)
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let perform {
                Button(action, action: perform)
                    .font(.oasesCaptionBold())
                    .foregroundStyle(OasesColor.primaryText)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The notes as a document: summary, conclusions, to-dos, then topics in time order.
private struct MeetingNotesContent: View {
    let notes: MeetingNotes

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.lg) {
            if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: OasesSpacing.xs) {
                    sectionLabel(String(localized: "摘要", comment: "Meeting notes: summary card label"))
                    Text(verbatim: notes.summary)
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                        .textSelection(.enabled)
                }
                .padding(OasesSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OasesColor.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: OasesRadius.sm, style: .continuous))
            }
            if !notes.conclusions.isEmpty {
                list(String(localized: "结论", comment: "Meeting notes: conclusions heading"), items: notes.conclusions.map(\.text), symbol: "checkmark")
            }
            if !notes.todos.isEmpty {
                list(String(localized: "待办", comment: "Meeting notes: to-dos heading"),
                     items: notes.todos.map { $0.text + ($0.owner.map { "（\($0)）" } ?? "") }, symbol: "circle")
            }
            ForEach(notes.topics) { topic in
                VStack(alignment: .leading, spacing: OasesSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.xs) {
                        Text(verbatim: MeetingExport.clock(topic.start))
                            .font(.oasesCaptionBold().monospacedDigit())
                            .foregroundStyle(OasesColor.mutedForeground)
                        Text(verbatim: topic.title)
                            .font(.oasesHeadline())
                            .foregroundStyle(OasesColor.foreground)
                    }
                    if !topic.summary.isEmpty {
                        Text(verbatim: topic.summary)
                            .font(.oasesCallout())
                            .foregroundStyle(OasesColor.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(topic.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.xs) {
                            Text(verbatim: "·").foregroundStyle(OasesColor.textTertiary)
                            Text(verbatim: point).foregroundStyle(OasesColor.foreground)
                        }
                        .font(.oasesCallout())
                    }
                    if let fish = topic.fishbone {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: fish.question).font(.oasesCalloutBold()).foregroundStyle(OasesColor.foreground)
                            ForEach(fish.branches) { b in
                                Text(verbatim: "– \(b.label)：\(b.detail)")
                                    .font(.oasesCallout())
                                    .foregroundStyle(b.support == 0 ? OasesColor.textTertiary : OasesColor.mutedForeground)
                            }
                        }
                        .padding(.leading, OasesSpacing.sm)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(OasesColor.border).frame(width: 2)
                        }
                    }
                }
            }
            if !notes.terms.isEmpty {
                list(String(localized: "人名和术语", comment: "Meeting notes: names and terms heading"),
                     items: NoteTerm.ordered(notes.terms).map { "\($0.name) · \($0.note)" }, symbol: "tag")
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.oasesCaptionBold())
            .foregroundStyle(OasesColor.textTertiary)
            .textCase(.uppercase)
    }

    private func list(_ title: String, items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(title).padding(.bottom, OasesSpacing.xs)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.sm) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OasesColor.mutedForeground)
                        .frame(width: 16)
                    Text(verbatim: item)
                        .font(.oasesCallout())
                        .foregroundStyle(OasesColor.foreground)
                        .textSelection(.enabled)
                }
                .padding(.vertical, OasesSpacing.xs)
                if index < items.count - 1 {
                    Divider().overlay(OasesColor.border.opacity(0.5)).padding(.leading, 16 + OasesSpacing.sm)
                }
            }
        }
    }
}
