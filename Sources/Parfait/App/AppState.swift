import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI
import UserNotifications

@MainActor
final class AppState: NSObject, ObservableObject {
    static let shared = AppState()

    let store = MeetingStore()
    let templates = TemplateStore()

    @Published private(set) var session: RecordingSession?
    @Published private(set) var recordingMeeting: Meeting?
    /// meeting id → human-readable pipeline stage, while processing.
    @Published private(set) var processingStage: [UUID: String] = [:]
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
    private var pendingDetection: MicEvent?
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
                detectedAppName = name
                pendingDetection = event
                notifyMeetingDetected(app: name)
            }
        } else {
            activeMicApps.removeValue(forKey: event.pid)
            if !isRecording, event.pid == pendingDetection?.pid {
                detectedAppName = nil
                pendingDetection = nil
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

        let newSession = RecordingSession(meetingID: meeting.id)
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
        detectedAppName = nil
        pendingDetection = nil
    }

    // MARK: - Processing

    func process(_ meeting: Meeting) async {
        let id = meeting.id
        processingStage[id] = "Starting…"
        var entry = store.meeting(id: id) ?? meeting
        entry.state = .processing
        store.upsert(entry)
        let titleAtEntry = entry.title

        let outcome = await ProcessingPipeline.run(meeting: entry, archive: store.archive) { stage in
            Task { @MainActor in AppState.shared.processingStage[id] = stage }
        }
        processingStage[id] = nil

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
        let segments = store.transcript(for: meetingID)
        let text = TranscriptFormatter.plainText(segments, speakers: entry.speakers)
        let titleAtEntry = entry.title
        let outcome = await ProcessingPipeline.summarize(meeting: entry, transcript: text)

        var generatedTitle: String?
        if case .success(let summary, let provider) = outcome,
           entry.calendarEventTitle == nil {
            processingStage[meetingID] = "Naming the meeting…"
            generatedTitle = await ProcessingPipeline.generateTitle(summary: summary, provider: provider)
        }
        processingStage[meetingID] = nil

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

        let record = UNNotificationAction(
            identifier: "RECORD", title: "Record", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "MEETING_DETECTED", actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
        // Plain [.alert, .sound] so the "Record it?" alert can appear as a live, tappable
        // banner. (.provisional would skip the prompt but only grant quiet, Notification-
        // Center-only delivery — the Record action would never surface during a call.)
        // A denied state is surfaced by the Notifications row in Settings.
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
    /// reliable half of "make the prompt apparent" (the menu-bar glyph is the visible half).
    private func chime() {
        guard Bundle.main.bundleIdentifier != nil else { return } // silent under bare `swift run`/tests
        // Two meetings starting within a second shouldn't clobber the first still-playing
        // NSSound (deallocating it mid-play) or stack into a double-ping — one clean chime.
        if detectionChime?.isPlaying == true { return }
        let sound = NSSound(named: NSSound.Name("Ping"))
        detectionChime = sound
        sound?.play()
    }

    private func notifyMeetingDetected(app: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(app) started using the microphone. Record it?"
        content.categoryIdentifier = "MEETING_DETECTED"
        // Sound is played separately (chime()) rather than on the notification: breaking a
        // notification through Focus/Do Not Disturb needs the Time Sensitive entitlement, which
        // requires an Apple provisioning profile and would break the ad-hoc build. A plain
        // NSSound plays regardless of Focus or even whether notifications are authorized at all.
        content.sound = nil
        chime()
        let request = UNNotificationRequest(
            identifier: "detected-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { self.log.error("notification add failed: \(error.localizedDescription, privacy: .public)") }
        }
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
        let id = response.actionIdentifier
        guard id == "RECORD" || id == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            Task { await AppState.shared.acceptDetection() }
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
