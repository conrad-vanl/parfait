import Foundation
import SwiftUI

/// Owns the two capture paths for one meeting. Either side may fail to start
/// (missing permission, no tap grant) — a session is viable with at least one.
@MainActor
final class RecordingSession: ObservableObject {
    let meetingID: UUID
    let startedAt = Date()

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    /// Rolling live transcript (finalized segments) + the current in-progress
    /// fragment, updated in real time while recording. A convenience surface — the
    /// accurate, diarized transcript is still produced post-hoc by the batch pipeline.
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var volatileText: String = ""
    private(set) var micStarted = false
    private(set) var systemStarted = false

    private let mic = MicRecorder()
    private let tap = SystemAudioTap()
    private let archive: MeetingArchive
    private var liveTranscriber: LiveTranscriber?
    private var screenshotSampler: ScreenshotSampler?
    private var lastLivePersist = Date.distantPast
    private var ticker: Timer?

    enum SessionError: LocalizedError {
        case nothingStarted(String)
        var errorDescription: String? {
            if case .nothingStarted(let detail) = self {
                return "Could not start recording: \(detail)"
            }
            return nil
        }
    }

    init(meetingID: UUID, archive: MeetingArchive) {
        self.meetingID = meetingID
        self.archive = archive
    }

    func start(micURL: URL, systemURL: URL) throws {
        var problems: [String] = []

        // Live transcription runs alongside capture. Set the buffer sinks BEFORE
        // starting the recorders so no early audio is missed; it's best-effort —
        // any failure here never affects the recording itself.
        let live = LiveTranscriber(startDate: startedAt)
        live.onUpdate = { [weak self] segments, volatile in
            Task { @MainActor in self?.applyLive(segments, volatile) }
        }
        liveTranscriber = live

        mic.levelHandler = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        mic.bufferSink = { [weak live] buffer in live?.feedMic(buffer) }
        do {
            try mic.start(writingTo: micURL)
            micStarted = true
        } catch {
            problems.append("microphone: \(error.localizedDescription)")
        }
        tap.signalDetectedHandler = { AppSettings.markSystemAudioConfirmed() }
        tap.bufferSink = { [weak live] buffer in live?.feedSystem(buffer) }
        do {
            try tap.start(writingTo: systemURL)
            systemStarted = true
        } catch {
            problems.append("system audio: \(error.localizedDescription)")
        }
        guard micStarted || systemStarted else {
            throw SessionError.nothingStarted(problems.joined(separator: "; "))
        }

        // Model/asset setup is async; buffers fed before it's ready are dropped.
        Task { try? await live.start(locale: .current) }

        // Opt-in experimental capture: a few screenshots across the meeting,
        // mined afterwards for participant names. Best-effort — a missing
        // Screen Recording permission (or any capture failure) degrades to
        // "no screenshots" and never affects the recording.
        if AppSettings.captureScreenshots {
            let sampler = ScreenshotSampler(directory: archive.screenshotsDir(for: meetingID))
            sampler.start()
            screenshotSampler = sampler
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    /// Applies a live-transcript update on the main actor: refreshes the observable
    /// state and persists to live.json at most every ~1.5 s (throttled so the MCP
    /// process sees a fresh file without thrashing the disk).
    private func applyLive(_ segments: [TranscriptSegment], _ volatile: String) {
        volatileText = volatile
        // The finalized transcript only ever grows, so a count change is a cheap,
        // exact "did it actually change?" test. Interim (volatile) updates arrive
        // several times a second and leave the finalized list untouched — skipping
        // the republish + full re-render + disk write on those is what keeps a
        // multi-hour meeting from getting steadily heavier as the transcript grows.
        guard segments.count != liveSegments.count else { return }
        liveSegments = segments
        let now = Date()
        if now.timeIntervalSince(lastLivePersist) >= 1.5 {
            lastLivePersist = now
            archive.saveLiveTranscript(segments, for: meetingID)
        }
    }

    /// Returns the parts that had problems starting, for the meeting notice.
    var startupNotice: String? {
        switch (micStarted, systemStarted) {
        case (true, true): return nil
        case (false, true): return "Microphone wasn't recorded (permission missing?) — only the other side of the call was captured."
        case (true, false): return "System audio wasn't recorded — only your microphone was captured. Grant System Audio Recording in Privacy & Security."
        case (false, false): return nil
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        screenshotSampler?.stop()
        screenshotSampler = nil
        if micStarted { mic.stop() }
        if systemStarted { tap.stop() }
        if let live = liveTranscriber {
            liveTranscriber = nil
            // This Task inherits the main actor. After the transcribers finalize,
            // flush the last live.json; the pipeline removes it once the durable
            // transcript.json lands.
            Task {
                await live.stop()
                archive.saveLiveTranscript(liveSegments, for: meetingID)
            }
        }
    }
}
