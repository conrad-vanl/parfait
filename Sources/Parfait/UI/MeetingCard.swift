import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating floating panel so the meeting card can appear on
/// its own (SwiftUI's MenuBarExtra popover can't be opened programmatically) without stealing
/// focus from whatever the user is doing. canBecomeKey stays true so the SwiftUI buttons inside
/// react to clicks; nonactivatingPanel keeps the app itself from coming forward.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What the single floating meeting card shows. Derived — never stored — from
/// AppState's publishers with recording > detected > upcoming priority, so the
/// states can't fight over the one panel.
private enum MeetingCardState {
    case hidden
    /// A calendar meeting starts in the next few minutes.
    case upcoming(UpcomingEvent)
    /// "Record this meeting?" — a meeting app grabbed the mic. Deliberately NOT
    /// enriched with the ride-along upcoming event: that's just "the next
    /// calendar event", with no tie to the app holding the mic, and a title the
    /// card shows must match what accepting actually records.
    case detected(appName: String)
    case recording(RecordingSession)
}

extension MeetingCardState: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden): true
        case (.upcoming(let a), .upcoming(let b)): a == b
        case (.detected(let a), .detected(let b)): a == b
        // Sessions are reference types; the card is "the same" per meeting.
        case (.recording(let a), .recording(let b)): a.meetingID == b.meetingID
        default: false
        }
    }
}

/// Bridges the controller's derived state into the one persistent SwiftUI root
/// so state changes animate inside a live view tree (swapping the panel's root
/// view per state would defeat the crossfade).
@MainActor
private final class MeetingCardModel: ObservableObject {
    @Published var state: MeetingCardState = .hidden
}

/// The one floating meeting card: upcoming calendar meetings, "Record this
/// meeting?" detection, and the live recording view morph through a single
/// persistent top-right panel. Owned by the AppDelegate for the app's lifetime.
@MainActor
final class MeetingCardController {
    private var panel: FloatingPanel?
    private var host: NSHostingController<MeetingCardRoot>?
    private let model = MeetingCardModel()
    private var cancellable: AnyCancellable?

    init() {
        // The priority in derive() is the single place the "one card"
        // invariant lives: detection clears the moment recording starts, and
        // both consume the upcoming event, so higher states win cleanly.
        cancellable = AppState.shared.$session
            .combineLatest(AppState.shared.$recordingCardDismissed,
                           AppState.shared.$detectedAppName,
                           AppState.shared.$upcomingMeeting)
            .map { Self.derive(session: $0.0, dismissed: $0.1, appName: $0.2, upcoming: $0.3) }
            .combineLatest(AppState.shared.$isStartingRecording)
            .removeDuplicates(by: ==)
            .sink { [weak self] state, starting in
                guard let self else { return }
                // startRecording clears detection/upcoming at its top but only
                // lands the session at its end (mic dialog, calendar lookup,
                // engine spin-up). Freeze the visible card across that whole
                // gap — the intermediate derived states (upcoming, then hidden)
                // are artifacts of the teardown order, and applying any of them
                // would show a wrong card or blink the panel out. The unstick
                // is guaranteed: isStartingRecording resets on every exit path,
                // re-emitting the final state with starting == false.
                if starting, self.model.state != .hidden { return }
                self.apply(state)
            }
    }

    private static func derive(
        session: RecordingSession?, dismissed: Bool, appName: String?, upcoming: UpcomingEvent?
    ) -> MeetingCardState {
        if let session { return dismissed ? .hidden : .recording(session) }
        if let appName { return .detected(appName: appName) }
        if let upcoming { return .upcoming(upcoming) }
        return .hidden
    }

    private func apply(_ state: MeetingCardState) {
        guard state != .hidden else {
            model.state = .hidden
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        // Morph (spring + crossfade) only between on-screen states; a fresh
        // appearance just shows in place at its final size.
        let morph = panel.isVisible
        withAnimation(morph ? .spring(response: 0.35, dampingFraction: 0.85) : nil) {
            model.state = state
        }
        if !morph {
            fit(host?.view.fittingSize ?? panel.frame.size)
        }
        panel.orderFrontRegardless() // show without activating the app
    }

    private func ensurePanel() -> FloatingPanel {
        if let panel { return panel }
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Meeting apps are often full-screen; ride along over them and across every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the card draws its own rounded shadow
        let host = NSHostingController(rootView: MeetingCardRoot(
            model: model,
            onResize: { [weak self] size in self?.fit(size) }))
        panel.contentViewController = host
        self.host = host
        self.panel = panel
        return panel
    }

    /// Keeps the panel glued to the card's size, top-right just under the menu
    /// bar. During a morph SwiftUI drives the spring and reports each frame of
    /// the animated size through onResize — the panel just follows. The +8
    /// nudges account for the card's transparent shadow padding so the visible
    /// card hugs the corner rather than floating off it.
    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(
            x: visible.maxX - size.width + 8,
            y: visible.maxY - size.height + 8,
            width: size.width,
            height: size.height), display: true)
    }
}

/// One continuous card surface; only the inner state bodies crossfade, so a
/// state change reads as the card morphing rather than two cards swapping.
private struct MeetingCardRoot: View {
    @ObservedObject var model: MeetingCardModel
    let onResize: (CGSize) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .upcoming(let event):
                UpcomingStateView(event: event)
                    .transition(.opacity)
            case .detected(let appName):
                DetectedStateView(appName: appName)
                    .transition(.opacity)
            case .recording(let session):
                RecordingStateView(session: session)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(20) // transparent margin so the shadow isn't clipped by the panel bounds
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { onResize($0) }
    }

    private var width: CGFloat {
        // The recording state carries the transcript and a wider action row.
        if case .recording = model.state { return 340 }
        return 300
    }
}

private struct UpcomingStateView: View {
    let event: UpcomingEvent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.blueberry)
                Text(event.title)
                    .font(.parfait(15, .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(1)
            }
            // Counts down live; past the start (the card lingers ~10 minutes
            // for late joiners) it flips to how long ago it started.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if context.date < event.startDate {
                        Text("Starts in \(Text(event.startDate, style: .relative))")
                    } else {
                        Text("Started \(Text(event.startDate, style: .relative)) ago")
                    }
                }
                .font(.parfait(12))
                .foregroundStyle(.secondary)
            }
            if let attendees = attendeeSummary {
                Text(attendees)
                    .font(.parfait(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button {
                    // The frozen card stays clickable through the async start —
                    // don't re-open the link or race a second start.
                    guard !AppState.shared.isStartingRecording else { return }
                    if let link = event.link { NSWorkspace.shared.open(link) }
                    Task {
                        await AppState.shared.startRecording(
                            calendarEvent: (title: event.title, attendees: event.attendees))
                    }
                } label: {
                    Text(event.link != nil ? "Join & record" : "Start recording")
                        .font(.parfait(13, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                Button("Dismiss") { AppState.shared.dismissUpcoming() }
                    .font(.parfait(13))
                    .buttonStyle(.bordered)
            }
            Button {
                ClaudeLink.openScoop(eventTitle: event.title)
            } label: {
                Label("Get the scoop", systemImage: "sparkles")
                    .font(.parfait(11, .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Have Claude brief you before this meeting")
        }
    }

    private var attendeeSummary: String? {
        guard !event.attendees.isEmpty else { return nil }
        let names = event.attendees.prefix(3).joined(separator: ", ")
        let extra = event.attendees.count - 3
        return extra > 0 ? "With \(names) +\(extra)" : "With \(names)"
    }
}

private struct DetectedStateView: View {
    let appName: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill").foregroundStyle(Theme.raspberry)
                Text("Record this meeting?")
                    .font(.parfait(15, .semibold))
                    .foregroundStyle(Theme.ink(scheme))
            }
            Text("\(appName) is using your microphone.")
                .font(.parfait(12))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    // startRecording picks the title itself: the in-progress
                    // calendar event first, else the imminent upcoming one.
                    Task { await AppState.shared.acceptDetection() }
                } label: {
                    Text("Record")
                        .font(.parfait(13, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                Button("Dismiss") {
                    // The frozen card stays clickable through an async start —
                    // a late dismiss must not re-arm the decline suppression.
                    guard !AppState.shared.isStartingRecording else { return }
                    AppState.shared.dismissDetection()
                }
                .font(.parfait(13))
                .buttonStyle(.bordered)
            }
            // No title passed: which meeting the mic app belongs to is a guess
            // here, and the scoop skill finds the upcoming event itself.
            Button {
                ClaudeLink.openScoop(eventTitle: nil)
            } label: {
                Label("Get the scoop", systemImage: "sparkles")
                    .font(.parfait(11, .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Have Claude brief you before this meeting")
        }
    }
}

private struct RecordingStateView: View {
    @ObservedObject var session: RecordingSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordDot()
                Text("Recording")
                    .font(.parfait(14, .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer()
                Text(timeString(session.elapsed))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    AppState.shared.recordingCardDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide this card — reopen it from the menu bar")
            }
            transcript
            HStack(spacing: 8) {
                Button {
                    ClaudeLink.open(prompt: ClaudeLink.livePrompt())
                } label: {
                    Label("Ask Claude live", systemImage: "sparkles")
                        .font(.parfait(12, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                Button {
                    // recordingMeeting is a start-time snapshot; a mid-meeting
                    // retitle lives only in the store, so re-read before asking.
                    let snapshot = AppState.shared.recordingMeeting
                    let meeting = snapshot.flatMap { AppState.shared.store.meeting(id: $0.id) } ?? snapshot
                    ClaudeLink.openScoop(
                        eventTitle: meeting?.calendarEventTitle ?? meeting?.title)
                } label: {
                    Text("Get the scoop")
                        .font(.parfait(12))
                }
                .buttonStyle(.bordered)
                .help("Have Claude brief you on this meeting's people and history")
                Button("Stop") {
                    Task { await AppState.shared.stopRecording() }
                }
                .font(.parfait(12))
                .buttonStyle(.bordered)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if session.liveSegments.isEmpty, session.volatileText.isEmpty {
                        Text("Listening…")
                            .font(.parfait(12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(LiveTranscriber.turns(from: session.liveSegments)) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LiveTranscriber.name(for: turn.speakerID))
                                .font(.parfait(10, .bold))
                                .foregroundStyle(turn.speakerID == LiveTranscriber.youSpeakerID
                                                 ? Theme.blueberry : Theme.raspberry)
                            Text(turn.text)
                                .font(.parfait(12))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !session.volatileText.isEmpty {
                        Text(session.volatileText)
                            .font(.parfait(12))
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("card-bottom")
                }
                .padding(10)
            }
            .frame(height: 190)
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 8))
            .liveTranscriptPinning(
                anchor: "card-bottom",
                segmentCount: session.liveSegments.count,
                volatileText: session.volatileText,
                proxy: proxy)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
