import Foundation
import Observation
import UIKit

/// Notes and translation runs for meetings, owned by the app rather than by the page that
/// started them: leaving the page, or the app, does not lose a run. A request is written to
/// the meeting (`notesRequestedAt`, `translationRequestedTo`) before it starts and cleared when
/// it ends, so a run the app was killed in resumes the next time meetings are shown. The result
/// is saved to the meeting as soon as it lands. While the app is in the background the run
/// keeps going for as long as iOS allows (a background task).
@MainActor
@Observable
final class MeetingNotesJobs {
    static let shared = MeetingNotesJobs()

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var generating: Set<String> = []
    private(set) var translating: [String: Progress] = [:]
    /// The last failure per meeting, shown once on the page and cleared when read.
    private var failures: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let logger = AppLogger(category: "Meeting")

    private init() {}

    func isGenerating(_ meetingID: String) -> Bool { generating.contains(meetingID) }
    func translation(for meetingID: String) -> Progress? { translating[meetingID] }
    func isBusy(_ meetingID: String) -> Bool { generating.contains(meetingID) || translating[meetingID] != nil }

    /// The failure recorded for the meeting, if any, and forgets it.
    func takeFailure(for meetingID: String) -> String? {
        failures.removeValue(forKey: meetingID)
    }

    // MARK: Notes

    /// Writes the notes for the meeting in the notes language, unless a run is under way.
    func generateNotes(for meetingID: String) {
        guard !generating.contains(meetingID), MeetingStore.shared.meeting(meetingID) != nil else { return }
        MeetingStore.shared.update(meetingID, immediately: true) { $0.notesRequestedAt = Date() }
        generating.insert(meetingID)
        let language = MeetingSettings.notesLanguageEnglish
        let key = "notes:\(meetingID)"
        tasks[key] = AIRequestGate.startRun { [weak self] in
            guard let self else { return }
            let background = Self.beginBackgroundTask("meeting-notes")
            defer {
                Self.endBackgroundTask(background)
                self.generating.remove(meetingID)
                self.tasks[key] = nil
                MeetingStore.shared.update(meetingID, immediately: true) { $0.notesRequestedAt = nil }
            }
            guard let meeting = MeetingStore.shared.meeting(meetingID) else { return }
            do {
                let result = try await MeetingNotesEngine.generate(for: meeting, language: language)
                MeetingStore.shared.update(meetingID, immediately: true) { m in
                    m.notes = result.notes
                    m.notesModel = result.model
                }
                Haptics.success()
                SoundEffects.shared.play(.taskDone)
            } catch MeetingNotesEngine.Failure.quota(let denial) {
                MembershipCenter.shared.present(denial)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("meeting notes failed: \(error.localizedDescription)")
                self.failures[meetingID] = error.localizedDescription
                Haptics.error()
            }
        }
    }

    func cancelNotes(for meetingID: String) {
        tasks["notes:\(meetingID)"]?.cancel()
        tasks["notes:\(meetingID)"] = nil
        generating.remove(meetingID)
        MeetingStore.shared.update(meetingID, immediately: true) { $0.notesRequestedAt = nil }
    }

    // MARK: Translation

    func translate(_ meetingID: String, to languageCode: String) {
        guard translating[meetingID] == nil, MeetingStore.shared.meeting(meetingID) != nil else { return }
        MeetingStore.shared.update(meetingID, immediately: true) { $0.translationRequestedTo = languageCode }
        translating[meetingID] = Progress(done: 0, total: 0)
        let key = "translate:\(meetingID)"
        tasks[key] = AIRequestGate.startRun { [weak self] in
            guard let self else { return }
            let background = Self.beginBackgroundTask("meeting-translation")
            defer {
                Self.endBackgroundTask(background)
                self.translating[meetingID] = nil
                self.tasks[key] = nil
                MeetingStore.shared.update(meetingID, immediately: true) { $0.translationRequestedTo = nil }
            }
            do {
                try await MeetingTranslator.translate(meetingID: meetingID, to: languageCode) { done, total in
                    self.translating[meetingID] = Progress(done: done, total: total)
                }
                Haptics.success()
            } catch MeetingNotesEngine.Failure.quota(let denial) {
                MembershipCenter.shared.present(denial)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("meeting translation failed: \(error.localizedDescription)")
                self.failures[meetingID] = error.localizedDescription
                Haptics.error()
            }
        }
    }

    func cancelTranslation(for meetingID: String) {
        tasks["translate:\(meetingID)"]?.cancel()
        tasks["translate:\(meetingID)"] = nil
        translating[meetingID] = nil
        MeetingStore.shared.update(meetingID, immediately: true) { $0.translationRequestedTo = nil }
    }

    // MARK: Resume

    /// Restarts runs the app was killed in (needs the consent; otherwise they wait).
    func resumePending() {
        guard AIDataSharingConsent.isAccepted else { return }
        for meeting in MeetingStore.shared.meetings where !meeting.isRecording {
            if meeting.notesRequestedAt != nil, !generating.contains(meeting.id) {
                generateNotes(for: meeting.id)
            }
            if let code = meeting.translationRequestedTo, translating[meeting.id] == nil {
                translate(meeting.id, to: code)
            }
        }
    }

    // MARK: Background time

    private static func beginBackgroundTask(_ name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {}
    }

    private static func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
