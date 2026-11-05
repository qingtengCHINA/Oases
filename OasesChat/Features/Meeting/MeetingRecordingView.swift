import SwiftUI

/// The meeting while it is recorded.
///
/// Top: when it started and how it is transcribed, the elapsed time as the one display number,
/// and the last half minute of sound as a bar timeline. Middle: the live transcript. Bottom:
/// three round controls with labels, the pause/resume one largest and in the accent, End in
/// red, and Hide (the recording carries on in the background) as the quiet third.
struct MeetingRecordingView: View {
    /// Called with the finished meeting's id (nil when closed without finishing).
    let onClose: (String?) -> Void

    private let recorder = MeetingRecorder.shared
    private let store = MeetingStore.shared
    @State private var showEndSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meeting: Meeting? { recorder.meetingID.flatMap(store.meeting) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, OasesSpacing.lg)
                .padding(.top, OasesSpacing.lg)
                .padding(.bottom, OasesSpacing.md)
            transcript
            controls
                .padding(.horizontal, OasesSpacing.lg)
                .padding(.top, OasesSpacing.md)
                .padding(.bottom, OasesSpacing.xs)
                .background(alignment: .top) {
                    ProgressiveBlur(edge: .bottom, wash: 1)
                        .frame(height: 160)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                }
        }
        .background(OasesColor.background.ignoresSafeArea())
        // Ending is a short form from the bottom: what was recorded, a name for the meeting,
        // Save or keep going. Recording carries on underneath until Save.
        .sheet(isPresented: $showEndSheet) {
            MeetingEndSheet(
                recordedTime: recorder.recordedTime,
                lineCount: meeting?.lines.count ?? 0,
                suggestedTitle: meeting?.customTitle ?? "",
                onSave: { title in
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = recorder.meetingID, !trimmed.isEmpty {
                        store.update(id, immediately: true) { $0.customTitle = trimmed }
                    }
                    let id = recorder.stop()
                    showEndSheet = false
                    Haptics.success()
                    onClose(id)
                },
                onContinue: { showEndSheet = false }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .presentationBackground(OasesColor.background)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: OasesSpacing.md) {
            HStack(spacing: OasesSpacing.xs) {
                RecordingDot(active: recorder.state == .recording)
                Text(verbatim: statusText)
                    .font(.oasesCaptionBold())
                    .foregroundStyle(recorder.state == .interrupted ? OasesColor.warning : OasesColor.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let meeting {
                    Text(verbatim: MeetingSettings.displayName(spoken: meeting.language))
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.textTertiary)
                        .padding(.horizontal, OasesSpacing.xs)
                        .padding(.vertical, 4)
                        .background(OasesColor.muted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(verbatim: MeetingExport.clock(recorder.recordedTime))
                    .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(OasesColor.foreground)
                    .contentTransition(.numericText())
            }
            .accessibilityLabel(Text(String(localized: "已录音时长", comment: "Meeting notes: accessibility label for the elapsed recording time")))

            LevelTimeline(level: recorder.state == .recording ? recorder.level : 0,
                          running: recorder.state == .recording, still: reduceMotion)
                .frame(height: 36)

            if let note = recorder.transcriptionNote {
                Text(verbatim: note)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .recording:
            return String(localized: "正在录音 · 锁屏或切到其他 App 也会继续", comment: "Meeting notes: recording keeps going in the background")
        case .paused:
            return String(localized: "已暂停", comment: "Meeting notes: recording paused")
        case .interrupted:
            return String(localized: "录音被系统打断（例如来电），点继续恢复", comment: "Meeting notes: recording was interrupted by the system")
        case .idle:
            return ""
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OasesSpacing.sm) {
                    if (meeting?.lines.isEmpty ?? true), recorder.volatileText.isEmpty, recorder.transcriptionNote == nil {
                        Text(String(localized: "说话后，文字会出现在这里。", comment: "Meeting notes: transcript placeholder while nothing has been heard"))
                            .font(.oasesCallout())
                            .foregroundStyle(OasesColor.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, OasesSpacing.xl)
                    }
                    ForEach(meeting?.lines ?? []) { line in
                        HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.sm) {
                            Text(verbatim: MeetingExport.clock(line.t))
                                .font(.oasesCaption().monospacedDigit())
                                .foregroundStyle(OasesColor.textTertiary)
                                .frame(minWidth: 40, alignment: .leading)
                            Text(verbatim: line.text)
                                .font(.oasesBody())
                                .foregroundStyle(OasesColor.foreground)
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                    if !recorder.volatileText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: OasesSpacing.sm) {
                            Color.clear.frame(width: 40, height: 1)
                            Text(verbatim: recorder.volatileText)
                                .font(.oasesBody())
                                .foregroundStyle(OasesColor.mutedForeground)
                        }
                        .id("volatile")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, OasesSpacing.lg)
                .padding(.top, OasesSpacing.md)
                .padding(.bottom, OasesSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                ProgressiveBlur(edge: .top, wash: 0.9).frame(height: 44)
            }
            .onChange(of: meeting?.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: recorder.volatileText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Controls

    /// Three round controls: End, Pause/Resume (largest, in the accent), Hide. The circles
    /// share one centre line and the labels one baseline, whatever the circle sizes.
    private var controls: some View {
        let items: [RecordingControlItem] = [
            RecordingControlItem(
                id: "end", symbol: "stop.fill", size: 56, fill: OasesColor.destructive, foreground: .white,
                label: String(localized: "结束", comment: "Meeting notes: finish the meeting"),
                accessibility: nil
            ) {
                Haptics.tap()
                showEndSheet = true
            },
            RecordingControlItem(
                id: "pause", symbol: recorder.state == .recording ? "pause.fill" : "play.fill", size: 72,
                fill: OasesColor.primary, foreground: .white,
                label: recorder.state == .recording
                    ? String(localized: "暂停", comment: "Meeting notes: pause recording")
                    : String(localized: "继续", comment: "Meeting notes: resume recording"),
                accessibility: nil
            ) {
                if recorder.state == .recording { recorder.pause() } else { recorder.resume() }
                Haptics.select()
            },
            RecordingControlItem(
                id: "hide", symbol: "chevron.down", size: 56, fill: OasesColor.muted, foreground: OasesColor.foreground,
                label: String(localized: "收起", comment: "Meeting notes: hide the recording screen"),
                accessibility: String(localized: "收起，继续在后台录音", comment: "Meeting notes: hide the recording screen, keep recording")
            ) {
                onClose(nil)
            },
        ]
        return VStack(spacing: OasesSpacing.xs) {
            HStack(alignment: .center, spacing: 0) {
                ForEach(items) { item in
                    Button(action: item.action) {
                        Image(systemName: item.symbol)
                            .font(.system(size: item.size * 0.36, weight: .semibold))
                            .foregroundStyle(item.foreground)
                            .frame(width: item.size, height: item.size)
                            .background(item.fill, in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                            .contentShape(Circle())
                    }
                    .buttonStyle(OasesPressStyle(scale: 0.94))
                    .accessibilityLabel(Text(item.accessibility ?? item.label))
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(items) { item in
                    Text(verbatim: item.label)
                        .font(.oasesCaptionBold())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity)
    }
}

private struct RecordingControlItem: Identifiable {
    let id: String
    let symbol: String
    let size: CGFloat
    let fill: Color
    let foreground: Color
    let label: String
    let accessibility: String?
    let action: () -> Void
}

/// The form that ends a meeting: what was recorded, an optional name, Save or keep going.
private struct MeetingEndSheet: View {
    let recordedTime: Double
    let lineCount: Int
    let suggestedTitle: String
    let onSave: (String) -> Void
    let onContinue: () -> Void

    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "结束会议", comment: "Meeting notes: end-of-meeting sheet title"))
                    .font(.oasesTitle())
                    .foregroundStyle(OasesColor.foreground)
                Text(verbatim: summary)
                    .font(.oasesCallout())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            TextField(String(localized: "会议名称（可不填）", comment: "Meeting notes: optional meeting name field in the end sheet"), text: $title)
                .font(.oasesBody())
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($titleFocused)
                .onSubmit { onSave(title) }
                .padding(.horizontal, OasesSpacing.sm)
                .frame(minHeight: 44)
                .background(OasesColor.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(String(localized: "录音、文字记录都保存在本机；纪要可以之后再生成。", comment: "Meeting notes: what happens to the recording when the meeting ends"))
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: OasesSpacing.sm) {
                Button(String(localized: "继续录音", comment: "Meeting notes: keep recording instead of ending"), action: onContinue)
                    .buttonStyle(MeetingTintedButtonStyle(prominent: false))
                Button {
                    onSave(title)
                } label: {
                    Text(String(localized: "保存", comment: "Meeting notes: end the meeting and keep it"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MeetingTintedButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, OasesSpacing.lg)
        .padding(.top, OasesSpacing.lg)
        .padding(.bottom, OasesSpacing.md)
        .onAppear { title = suggestedTitle }
    }

    private var summary: String {
        let clock = MeetingExport.clock(recordedTime)
        return lineCount == 0
            ? String(localized: "已录 \(clock)", comment: "Meeting notes: end sheet summary without transcript; argument is the duration")
            : String(localized: "已录 \(clock) · \(lineCount) 句文字记录", comment: "Meeting notes: end sheet summary; arguments are the duration and the line count")
    }
}

/// The last ~36 s of sound as bars that march leftward, newest at the right (the way the
/// meeting-recorder apps draw a timeline). Pausing freezes the bars where they are.
private struct LevelTimeline: View {
    let level: Float
    let running: Bool
    let still: Bool

    private static let count = 48
    @State private var history: [Float] = Array(repeating: 0, count: LevelTimeline.count)
    @State private var lastSample: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !running)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.count, id: \.self) { i in
                    let v = CGFloat(history[i])
                    Capsule()
                        .fill(OasesColor.foreground.opacity(i == Self.count - 1 ? 0.9 : 0.3 + 0.5 * v))
                        .frame(width: 3)
                        .frame(height: max(3, 36 * max(0.08, v)))
                }
            }
            .frame(maxWidth: .infinity)
            .onChange(of: now) { _, t in
                // Sample at 4 Hz: 48 bars cover the last 12 s. Reads only; the history is
                // the view's own state.
                guard running, t - lastSample >= 0.25 else { return }
                lastSample = t
                history.removeFirst()
                history.append(level)
            }
        }
        .accessibilityHidden(true)
    }
}
