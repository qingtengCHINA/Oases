import Foundation
import Observation

/// Runs cloud transcription for recorded chunks, one chunk at a time, in the order they were
/// recorded. A chunk joins the queue when it closes during recording, when a meeting that was
/// left with pending chunks is opened again, or when the user asks to redo a meeting. Its result
/// replaces the live on-device lines of that stretch; on failure the live lines stay and the
/// chunk is marked so the user can retry.
@MainActor
@Observable
final class MeetingCloudQueue {
    static let shared = MeetingCloudQueue()

    private struct Job: Equatable {
        let meetingID: String
        let file: String
    }

    private var queue: [Job] = []
    private var running: Job?
    private var worker: Task<Void, Never>?
    private let logger = AppLogger(category: "Meeting")

    private init() {}

    /// Whether `meetingID` has chunks queued or being transcribed.
    func isWorking(on meetingID: String) -> Bool {
        running?.meetingID == meetingID || queue.contains { $0.meetingID == meetingID }
    }

    /// The meeting's chunks done in the cloud so far, and how many it has.
    func progress(for meeting: Meeting) -> (done: Int, total: Int) {
        (meeting.chunks.filter { $0.cloud == .done }.count, meeting.chunks.count)
    }

    /// Queues one chunk that just closed (no-op when the meeting doesn't use the cloud).
    func enqueue(meetingID: String, chunk: MeetingChunk) {
        guard let meeting = MeetingStore.shared.meeting(meetingID), meeting.cloudTranscription == true,
              chunk.cloud == nil else { return }
        add(Job(meetingID: meetingID, file: chunk.file))
    }

    /// Queues every chunk of `meetingID` that hasn't been transcribed in the cloud, failed ones
    /// included. Turns cloud transcription on for the meeting when `enable` is set.
    func transcribeRemaining(of meetingID: String, enable: Bool = false) {
        if enable {
            MeetingStore.shared.update(meetingID, immediately: true) { m in
                m.cloudTranscription = true
                for i in m.chunks.indices where m.chunks[i].cloud == .failed { m.chunks[i].cloud = nil }
            }
        } else {
            MeetingStore.shared.update(meetingID) { m in
                for i in m.chunks.indices where m.chunks[i].cloud == .failed { m.chunks[i].cloud = nil }
            }
        }
        guard let meeting = MeetingStore.shared.meeting(meetingID) else { return }
        for chunk in meeting.pendingCloudChunks { add(Job(meetingID: meetingID, file: chunk.file)) }
    }

    /// Picks up chunks left pending when the app was closed (not the meeting being recorded:
    /// its chunks come in as they close).
    func resumePending() {
        for meeting in MeetingStore.shared.meetings where meeting.id != MeetingStore.shared.recordingID {
            for chunk in meeting.pendingCloudChunks { add(Job(meetingID: meeting.id, file: chunk.file)) }
        }
    }

    /// Stops the meeting's work (it is being deleted).
    func cancel(meetingID: String) {
        queue.removeAll { $0.meetingID == meetingID }
        if running?.meetingID == meetingID {
            worker?.cancel()
        }
    }

    private func add(_ job: Job) {
        guard running != job, !queue.contains(job) else { return }
        queue.append(job)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            worker = nil
            running = nil
            // Cancelling one meeting's job ends this worker; other meetings' jobs carry on.
            if !queue.isEmpty { startIfNeeded() }
        }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            running = job
            // Each chunk is a run with its own ticket: taking the consent back stops its
            // remaining segments, and a later consent doesn't revive them.
            await AIRequestGate.$ticket.withValue(AIRequestGate.issueTicket()) {
                await run(job)
            }
            if Task.isCancelled { return }
        }
    }

    private func run(_ job: Job) async {
        guard let meeting = MeetingStore.shared.meeting(job.meetingID),
              let chunk = meeting.chunks.first(where: { $0.file == job.file }),
              chunk.cloud == nil else { return }
        // Without the AI data sharing consent the audio stays on the device; the chunk stays
        // pending so it runs once the user agrees and reopens the meeting.
        guard AIDataSharingConsent.isAccepted else { return }
        let url = MeetingStore.audioFolder(for: job.meetingID).appendingPathComponent(job.file)
        do {
            let lines = try await MeetingCloudASR.transcribe(chunkAt: url, chunkStart: chunk.start, language: meeting.language)
            try Task.checkCancellation()
            MeetingStore.shared.update(job.meetingID, immediately: true) { m in
                Self.merge(lines, chunk: chunk, into: &m)
            }
        } catch is CancellationError {
            return
        } catch APIError.transport(let inner) where (inner as? URLError)?.code == .cancelled {
            // Stopped at the transport (consent taken back): left pending, not failed.
            return
        } catch {
            logger.error("cloud transcription failed for \(job.file): \(error.localizedDescription)")
            MeetingStore.shared.update(job.meetingID, immediately: true) { m in
                if let i = m.chunks.firstIndex(where: { $0.file == job.file }) { m.chunks[i].cloud = .failed }
            }
        }
    }

    /// Replaces the chunk's live lines with the cloud lines. Lines are matched by start time,
    /// so a live line that began in this chunk goes even if it ran past its end. An empty cloud
    /// result for a chunk that had live text keeps the live text (MiMo returned nothing, which
    /// is more likely a failure than real silence the live recogniser filled in).
    static func merge(_ cloudLines: [MeetingLine], chunk: MeetingChunk, into meeting: inout Meeting) {
        guard let index = meeting.chunks.firstIndex(where: { $0.file == chunk.file }) else { return }
        let live = meeting.lines.filter { chunk.contains($0.t) && $0.cloud != true }
        if cloudLines.isEmpty, !live.isEmpty {
            meeting.chunks[index].cloud = .failed
            return
        }
        meeting.lines.removeAll { chunk.contains($0.t) }
        meeting.lines.append(contentsOf: cloudLines)
        meeting.lines.sort { $0.t < $1.t }
        meeting.chunks[index].cloud = .done
        meeting.cloudModel = MeetingCloudASR.model
    }
}
