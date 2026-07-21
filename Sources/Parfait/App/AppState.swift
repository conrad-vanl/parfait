import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

/// Progressive-summary phase for a meeting, driving the Notes tab badge.
enum SummaryProgress {
    /// The notes are streaming in (a draft, or the sole pass when there's no live transcript).
    case streaming
    /// A draft is on screen and the improvement pass is running.
    case improving
    /// A targeted speaker-name update pass is rewriting the saved notes.
    case updatingNames
}

@MainActor
final class AppState: NSObject, ObservableObject {
    static let shared = AppState()

    let store = MeetingStore()
    let templates = TemplateStore()

    @Published private(set) var session: RecordingSession?
    @Published private(set) var recordingMeeting: Meeting?
    /// The floating recording card is hidden because the user closed it. Reset on
    /// each new recording; re-openable from the menu bar.
    @Published var recordingCardDismissed = false
    /// meeting id → human-readable pipeline stage, while processing.
    @Published private(set) var processingStage: [UUID: String] = [:]
    /// meeting id → notes being streamed in right now. The Notes tab shows this in
    /// place of the saved summary while present (draft or sole pass).
    @Published private(set) var streamingSummaries: [UUID: String] = [:]
    /// meeting id → progressive-summary phase, for the Notes tab badge.
    @Published private(set) var summaryProgress: [UUID: SummaryProgress] = [:]
    /// A meeting-ish app started using the mic and we're waiting on the user.
    @Published private(set) var detectedAppName: String?
    @Published var lastError: String?
    /// Set by the menu bar to steer the main window's selection.
    @Published var openMeetingID: UUID?
    /// Apps currently holding the mic open, live and independent of recording
    /// state — feeds auto-stop (any recording, not just auto-started ones) and
    /// the Settings "currently hearing" diagnostic row.
    @Published private(set) var activeMicApps: [pid_t: String] = [:]
    @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    var activeMicAppNames: [String] { Array(Set(activeMicApps.values)).sorted() }

    private let detector = MeetingDetector()
    /// The detection currently surfaced to the user (menu-bar glyph + banner + notification).
    private var pendingDetection: MicEvent?
    /// Every mic app detected but not yet decided, keyed by pid. When the surfaced app releases,
    /// the next entry is promoted so a still-live meeting keeps prompting — the detector only
    /// emits on transitions, so an already-running app never re-announces itself.
    private var pendingDetections: [pid_t: MicEvent] = [:]
    /// Last time we announced (notification + chime) a detection per pid, to suppress a repeat
    /// announce on a quick mic reconnect while still allowing a genuinely new later meeting.
    private var lastDetectionAnnounce: [pid_t: ContinuousClock.Instant] = [:]
    private static let announceCooldown: Duration = .seconds(15)
    private var pendingAutoStop: Task<Void, Never>?
    /// Retains the detection chime while it plays — a temporary NSSound can be
    /// deallocated mid-play. Replaced on each detection.
    private var detectionChime: NSSound?
    private static let autoStopGrace: Duration = .seconds(8)
    private let log = Logger(subsystem: "io.github.conrad-vanl.Parfait", category: "detection")
    /// Closes the reentrancy window between startRecording's guard and its
    /// `session =` assignment (mic-permission dialog, calendar lookup).
    private var isStartingRecording = false
    private var cancellables = Set<AnyCancellable>()

    var isRecording: Bool { session != nil }

    private override init() {
        super.init()
        AppSettings.registerDefaults()
        // Views observe AppState; meeting data lives on the nested store.
        // Forward its change signal or store-only mutations never refresh UI.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func bootstrap() {
        configureNotifications()
        finalizeOrphans()
        Task.detached { _ = ClaudeCLI.resolveBlocking() } // warm the CLI probe off-main
        // Clear a "System Audio Recording" indicator left stuck by a previously hard-killed
        // process. Off-main (coreaudiod IPC can stall at launch), but gated BEFORE detection
        // starts so the name-based sweep can never race a live tap of ours and destroy it.
        Task { @MainActor in
            await Task.detached { SystemAudioTap.destroyLeftoverAggregates() }.value
            if AppSettings.detectMeetings { startDetection() }
        }
    }

    /// Called from applicationShouldTerminate: finalize audio files so the
    /// recording survives, and let the next launch pick it up as an orphan.
    func prepareForTermination() {
        guard let session, let meeting = recordingMeeting else { return }
        session.stop()
        if var fresh = store.meeting(id: meeting.id) ?? recordingMeeting {
            fresh.duration = session.elapsed
            fresh.state = .processing
            store.upsert(fresh)
        }
        self.session = nil
        recordingMeeting = nil
    }

    // MARK: - Detection

    func startDetection() {
        detector.start { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func stopDetection() {
        detector.stop()
        detectedAppName = nil
        pendingDetection = nil
        pendingDetections.removeAll()
        lastDetectionAnnounce.removeAll()
        // detector.stop() drops its listeners without emitting closing false events,
        // so any still-running pid would linger here and permanently block auto-stop.
        activeMicApps.removeAll()
        pendingAutoStop?.cancel()
        pendingAutoStop = nil
    }

    private func handle(_ event: MicEvent) {
        guard !MeetingDetector.isIgnored(bundleID: event.bundleID) else { return }
        let name = MeetingDetector.displayName(for: event)
        log.debug("mic \(name, privacy: .public) pid=\(event.pid) running=\(event.isRunningInput)")

        if event.isRunningInput {
            activeMicApps[event.pid] = name
            pendingAutoStop?.cancel(); pendingAutoStop = nil // any live meeting app cancels a pending stop

            if isRecording { return }
            guard !isStartingRecording else { return }
            if AppSettings.autoRecord {
                Task { await startRecording(sourceApp: name, trigger: event) }
            } else {
                // A mic reconnect blip (drop + re-grab, which the auto-stop path below also
                // debounces) shouldn't re-fire the chime for a meeting we just announced. Still
                // re-surface the prompt (card + glyph) visually; only gate the chime.
                let now = ContinuousClock.now
                let recentlyAnnounced = lastDetectionAnnounce[event.pid]
                    .map { now - $0 < Self.announceCooldown } ?? false
                lastDetectionAnnounce[event.pid] = now
                pendingDetections[event.pid] = event
                detectedAppName = name
                pendingDetection = event
                if !recentlyAnnounced { chime() }
            }
        } else {
            activeMicApps.removeValue(forKey: event.pid)
            pendingDetections.removeValue(forKey: event.pid)
            if !isRecording, event.pid == pendingDetection?.pid {
                // The app we were prompting for released. Surface the next still-undecided app so
                // an ongoing meeting keeps prompting instead of the prompt vanishing for good.
                if let next = pendingDetections.values.first {
                    detectedAppName = MeetingDetector.displayName(for: next)
                    pendingDetection = next
                } else {
                    detectedAppName = nil
                    pendingDetection = nil
                }
            }
            // All detected mic apps quiet — debounced (apps drop and re-grab
            // during reconnects) — before treating the meeting as over. Applies
            // to any recording, not just auto/accepted-start ones.
            guard isRecording, AppSettings.autoStopRecording, activeMicApps.isEmpty else { return }
            log.debug("all detected mic apps quiet — arming \(Self.autoStopGrace)s auto-stop")
            pendingAutoStop = Task { [weak self] in
                try? await Task.sleep(for: Self.autoStopGrace)
                guard !Task.isCancelled else { return }
                await self?.autoStop()
            }
        }
    }

    private func autoStop() async {
        // Re-check everything: the recording may have ended, the mic reconnected, or
        // the user disabled auto-stop during the grace window.
        guard isRecording, AppSettings.autoStopRecording, activeMicApps.isEmpty else { return }
        log.info("auto-stopping — meeting app released the mic")
        await stopRecording()
    }

    // MARK: - Recording

    /// User accepted a detection (menu banner or notification action).
    func acceptDetection() async {
        let event = pendingDetection
        let name = detectedAppName ?? event.map(MeetingDetector.displayName)
        await startRecording(sourceApp: name, trigger: event)
    }

    func startRecording(sourceApp: String? = nil, trigger: MicEvent? = nil) async {
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        pendingAutoStop?.cancel()
        pendingAutoStop = nil
        detectedAppName = nil
        pendingDetection = nil
        pendingDetections.removeAll() // one recording covers the whole meeting, whatever grabbed the mic
        lastError = nil

        if !MicRecorder.permissionGranted {
            _ = await MicRecorder.requestPermission()
        }

        var meeting = Meeting(title: Meeting.placeholderTitle(for: Date()), createdAt: Date())
        meeting.sourceApp = sourceApp
        meeting.templateName = AppSettings.defaultTemplate

        if AppSettings.useCalendar, CalendarMatcher.isAuthorized,
           let event = await CalendarMatcher.currentEvent() {
            meeting.title = event.title
            meeting.calendarEventTitle = event.title
            meeting.attendees = event.attendees
        }

        // A competing start may have won while we awaited the dialogs above.
        guard !isRecording else { return }

        let archive = store.archive
        do {
            try archive.createFolder(for: meeting.id)
        } catch {
            lastError = error.localizedDescription
            return
        }

        let newSession = RecordingSession(meetingID: meeting.id, archive: archive)
        do {
            try newSession.start(
                micURL: archive.micURL(for: meeting.id),
                systemURL: archive.systemURL(for: meeting.id))
        } catch {
            lastError = error.localizedDescription
            try? FileManager.default.removeItem(at: archive.folder(for: meeting.id))
            return
        }
        meeting.notice = newSession.startupNotice
        store.upsert(meeting)
        recordingMeeting = meeting
        recordingCardDismissed = false // a fresh recording shows the card
        session = newSession
    }

    func stopRecording() async {
        guard let session, let meeting = recordingMeeting else { return }
        clearRecordingState()
        session.stop()
        // Re-fetch: the user may have retitled the meeting while it recorded.
        var fresh = store.meeting(id: meeting.id) ?? meeting
        fresh.duration = session.elapsed
        store.upsert(fresh)
        // Detached on purpose: an auto-stop runs *inside* the pendingAutoStop task, which
        // clearRecordingState() just cancelled — awaiting process() here would run the whole
        // transcription pipeline in a cancelled task and every await would throw
        // CancellationError. A fresh task keeps processing independent of how we stopped.
        Task { await self.process(fresh) }
    }

    func discardRecording() {
        guard let session, let meeting = recordingMeeting else { return }
        clearRecordingState()
        session.stop()
        store.delete(id: meeting.id)
    }

    private func clearRecordingState() {
        pendingAutoStop?.cancel()
        pendingAutoStop = nil
        session = nil
        recordingMeeting = nil
    }

    func dismissDetection() {
        // Declining means "don't record this meeting" — drop every undecided app so a second
        // one (a browser tab alongside Zoom) doesn't immediately re-prompt.
        detectedAppName = nil
        pendingDetection = nil
        pendingDetections.removeAll()
    }

    // MARK: - Processing

    func process(_ meeting: Meeting) async {
        let id = meeting.id
        processingStage[id] = "Starting…"
        var entry = store.meeting(id: id) ?? meeting
        entry.state = .processing
        // Surface the live transcript immediately so the Transcript tab isn't blank
        // while the accurate, diarized version is still being built. The batch pass
        // overwrites both the transcript and the speakers when it finishes.
        let live = store.archive.liveTranscript(for: id)
        if !live.isEmpty, store.transcript(for: id).isEmpty {
            try? store.archive.saveTranscript(live, for: id)
            entry.speakers = LiveTranscriber.speakers
        }
        store.upsert(entry)
        let titleAtEntry = entry.title

        let outcome = await ProcessingPipeline.run(
            meeting: entry, archive: store.archive,
            onProgress: { stage in
                Task { @MainActor in AppState.shared.processingStage[id] = stage }
            },
            onSummary: { update in
                // Ordered main-thread delivery (FIFO) so streamed deltas and the
                // draftSaved/done markers never arrive out of order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppState.shared.applySummaryUpdate(update, for: id) }
                }
            })
        processingStage[id] = nil
        streamingSummaries[id] = nil
        summaryProgress[id] = nil
        // The durable transcript now supersedes the live one (if any was written).
        store.archive.removeLiveTranscript(for: id)

        // Merge only pipeline-owned fields onto the CURRENT meeting; nil means
        // it was deleted mid-run — let it stay deleted.
        guard var fresh = store.meeting(id: id) else { return }
        fresh.state = outcome.state
        fresh.notice = outcome.notice
        if let speakers = outcome.speakers {
            fresh.speakers = Self.merging(pipelineSpeakers: speakers, userSpeakers: fresh.speakers)
        }
        if let provider = outcome.summaryProvider { fresh.summaryProvider = provider }
        if let title = outcome.generatedTitle, fresh.title == titleAtEntry {
            fresh.title = title
        }
        store.upsert(fresh)
        if fresh.state == .ready {
            notifyReady(fresh)
        }
    }

    /// Applies a progressive-summary signal from the pipeline. Deltas replace the
    /// streamed text; `draftSaved`/`done` drop it so the Notes tab reads the saved file.
    private func applySummaryUpdate(_ update: ProcessingPipeline.SummaryUpdate, for id: UUID) {
        switch update {
        case .streaming(let text):
            summaryProgress[id] = .streaming
            streamingSummaries[id] = text
        case .draftSaved:
            summaryProgress[id] = .improving
            streamingSummaries[id] = nil // the saved draft now backs the view
        case .done:
            summaryProgress[id] = nil
            streamingSummaries[id] = nil
        }
    }

    /// Pipeline speaker set wins structurally, but a rename the user made while
    /// the pipeline was still running is kept.
    private static func merging(pipelineSpeakers: [Speaker], userSpeakers: [Speaker]) -> [Speaker] {
        pipelineSpeakers.map { pipelineSpeaker in
            if let renamed = userSpeakers.first(where: { $0.id == pipelineSpeaker.id }) {
                var kept = pipelineSpeaker
                kept.name = renamed.name
                return kept
            }
            return pipelineSpeaker
        }
    }

    /// Failed meetings re-run the whole pipeline; ready ones just get a new
    /// summary + title.
    func retry(meetingID: UUID) async {
        guard var meeting = store.meeting(id: meetingID) else { return }
        if meeting.state == .failed || store.transcript(for: meetingID).isEmpty {
            meeting.notice = nil
            store.upsert(meeting)
            await process(meeting)
        } else {
            await regenerateSummary(meetingID: meetingID)
        }
    }

    /// Re-run summary+title only (transcript already exists), e.g. after the user
    /// edited the transcript, switched template, or fixed an AI backend.
    func regenerateSummary(meetingID: UUID, templateName: String? = nil) async {
        guard var entry = store.meeting(id: meetingID) else { return }
        if let templateName {
            entry.templateName = templateName
            store.upsert(entry)
        }
        processingStage[meetingID] = "Summarizing…"
        summaryProgress[meetingID] = .streaming
        streamingSummaries[meetingID] = ""
        let segments = store.transcript(for: meetingID)
        let text = TranscriptFormatter.plainText(segments, speakers: entry.speakers)
        let titleAtEntry = entry.title
        let outcome = await ProcessingPipeline.summarize(meeting: entry, transcript: text) { delta in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppState.shared.streamingSummaries[meetingID] = delta }
            }
        }

        var generatedTitle: String?
        if case .success(let summary, let provider) = outcome,
           ProcessingPipeline.titleStep(for: entry, summary: summary) != .keep {
            processingStage[meetingID] = "Naming the meeting…"
            generatedTitle = await ProcessingPipeline.resolveTitle(
                meeting: entry, summary: summary, provider: provider)
        }
        processingStage[meetingID] = nil
        streamingSummaries[meetingID] = nil
        summaryProgress[meetingID] = nil

        guard var fresh = store.meeting(id: meetingID) else { return }
        switch outcome {
        case .success(let summary, let provider):
            store.saveSummary(summary, for: meetingID)
            fresh.summaryProvider = provider
            fresh.notice = nil
            if let generatedTitle, fresh.title == titleAtEntry {
                fresh.title = generatedTitle
            }
        case .failure(let why):
            fresh.notice = why
        }
        store.upsert(fresh)
    }

    // MARK: - Speaker-name updates in the notes

    /// Per-meeting old-name → new-name map accumulated from renames/merges,
    /// applied to the saved notes by one debounced background pass.
    private var pendingNameUpdates: [UUID: [String: String]] = [:]
    private var nameUpdateTasks: [UUID: Task<Void, Never>] = [:]
    /// Meetings with a pass currently running — a rename landing mid-pass
    /// reschedules the debounce instead of racing the in-flight pass.
    private var nameUpdatesInFlight: Set<UUID> = []
    private static let nameUpdateDebounce: Duration = .seconds(4)

    /// Called by the rename/merge UI after a speaker's display name changed.
    /// Debounces a few seconds past the last change, then runs ONE targeted
    /// LLM pass that swaps the names inside the already-written notes — never
    /// a full regeneration.
    func noteSpeakerRename(meetingID: UUID, from oldName: String, to newName: String) {
        let map = SummaryNameUpdater.coalescing(
            pendingNameUpdates[meetingID] ?? [:], renaming: oldName, to: newName)
        pendingNameUpdates[meetingID] = map.isEmpty ? nil : map
        guard !map.isEmpty else {
            // The renames cancelled out (back to the original name) — nothing to do.
            nameUpdateTasks[meetingID]?.cancel()
            nameUpdateTasks[meetingID] = nil
            return
        }
        scheduleNameUpdate(meetingID)
    }

    private func scheduleNameUpdate(_ meetingID: UUID) {
        nameUpdateTasks[meetingID]?.cancel()
        nameUpdateTasks[meetingID] = Task { [weak self] in
            try? await Task.sleep(for: Self.nameUpdateDebounce)
            guard !Task.isCancelled else { return }
            await self?.runNameUpdate(meetingID)
        }
    }

    private func runNameUpdate(_ meetingID: UUID) async {
        // A pass is already running for this meeting: let it finish, then debounce again.
        guard !nameUpdatesInFlight.contains(meetingID) else {
            scheduleNameUpdate(meetingID)
            return
        }
        guard let renames = pendingNameUpdates[meetingID], !renames.isEmpty else { return }
        guard let meeting = store.meeting(id: meetingID) else {
            pendingNameUpdates[meetingID] = nil
            return
        }
        let summary = store.summary(for: meetingID)
        let busy = summaryProgress[meetingID] != nil || processingStage[meetingID] != nil
        guard SummaryNameUpdater.shouldRun(
            meetingState: meeting.state, summary: summary, summaryBusy: busy)
        else {
            // Drop, don't defer: any summary written later (pipeline or regenerate)
            // is generated from the current, already-renamed speakers.
            pendingNameUpdates[meetingID] = nil
            return
        }
        pendingNameUpdates[meetingID] = nil
        nameUpdatesInFlight.insert(meetingID)
        summaryProgress[meetingID] = .updatingNames
        defer {
            nameUpdatesInFlight.remove(meetingID)
            if summaryProgress[meetingID] == .updatingNames { summaryProgress[meetingID] = nil }
        }

        let updated = await SummaryNameUpdater.rewrite(
            summary: summary, renames: renames, provider: meeting.summaryProvider ?? "apple")

        // Fail closed on a bad pass, and abort if the notes changed while it ran
        // (a user edit or regeneration must never be clobbered — aborting is the
        // simpler-but-safe option; a follow-up rename retriggers cleanly).
        guard let updated,
              store.meeting(id: meetingID) != nil,
              SummaryNameUpdater.canCommit(original: summary, current: store.summary(for: meetingID))
        else { return }
        store.saveSummary(updated, for: meetingID)
    }

    /// Meetings left mid-flight by a crash or quit get pushed back through the
    /// pipeline. After a hard crash the m4a may be unreadable (AAC finalizes on
    /// close) — those land in .failed with an honest notice rather than vanishing.
    private func finalizeOrphans() {
        for meeting in store.meetings where meeting.state == .recording || meeting.state == .processing {
            var m = meeting
            if m.duration == 0 {
                m.duration = audioDuration(archive: store.archive, id: m.id)
                store.upsert(m) // persist before process() re-fetches, or it's lost
            }
            Task { await process(m) }
        }
    }

    private nonisolated func audioDuration(archive: MeetingArchive, id: UUID) -> TimeInterval {
        for url in [archive.micURL(for: id), archive.systemURL(for: id)] {
            if let seconds = try? AVAudioFileLength(url), seconds > 0 { return seconds }
        }
        return 0
    }

    // MARK: - Notifications

    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return } // bare `swift run` has no bundle
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Meeting detection is surfaced by the floating card + chime + menu-bar glyph, not a
        // notification (that only buried the prompt in Notification Center). The only notification
        // left is "notes are ready", so we just need alert+sound authorization for that.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.log.info("notification auth granted=\(granted) error=\(error?.localizedDescription ?? "none", privacy: .public)")
            Task { await self.refreshNotificationStatus() }
        }
        Task { await refreshNotificationStatus() }
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
    }

    /// Explicit request from onboarding / Settings. macOS shows the system dialog only while
    /// the status is .notDetermined; once decided this just refreshes our cached status.
    func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        log.info("notification auth (from UI) granted=\(granted)")
        await refreshNotificationStatus()
    }

    /// A short, Focus-proof audible cue for a detected meeting. NSSound plays through the
    /// default output device regardless of notification permission or Do Not Disturb — the
    /// audible half of the prompt (the floating card + menu-bar glyph are the visible half).
    private func chime() {
        guard Bundle.main.bundleIdentifier != nil else { return } // silent under bare `swift run`/tests
        // Two meetings starting within a second shouldn't clobber the first still-playing
        // NSSound (deallocating it mid-play) or stack into a double-ping — one clean chime.
        if detectionChime?.isPlaying == true { return }
        let sound = NSSound(named: NSSound.Name("Ping"))
        detectionChime = sound
        sound?.play()
    }

    private func notifyReady(_ meeting: Meeting) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = "Your meeting notes are ready."
        let request = UNNotificationRequest(
            identifier: "ready-\(meeting.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension AppState: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Only the "notes are ready" notification remains (detection uses the floating card now).
        // Tapping it surfaces that meeting — it must never start a recording.
        let identifier = response.notification.request.identifier
        guard identifier.hasPrefix("ready-"),
              let id = UUID(uuidString: String(identifier.dropFirst("ready-".count))) else { return }
        await MainActor.run {
            AppState.shared.openMeetingID = id
            NSApp.activate()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private func AVAudioFileLength(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}
