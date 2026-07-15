import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let session = app.session {
                RecordingCard(session: session, meeting: app.recordingMeeting)
            } else if let detected = app.detectedAppName {
                detectionBanner(detected)
            } else {
                Button {
                    dismissMenu()
                    Task { await app.startRecording() }
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                        .font(.parfait(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
            }
            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.parfait(11))
                    .foregroundStyle(.orange)
            }
            recent
            Divider()
            HStack {
                Button("Open Parfait") { openMain() }
                    .buttonStyle(.plain)
                    .font(.parfait(12, .medium))
                    .foregroundStyle(Theme.blueberry)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quit Parfait")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(MenuBarExtraWindowHook())
    }

    private var header: some View {
        HStack(spacing: 8) {
            ParfaitStripes().scaleEffect(0.45).frame(width: 20, height: 26)
            Text("Parfait")
                .font(.parfait(16, .bold))
            Spacer()
            Button {
                dismissMenu()
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func detectionBanner(_ appName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(appName) is using the microphone", systemImage: "waveform.badge.mic")
                .font(.parfait(12, .semibold))
            HStack {
                Button {
                    dismissMenu()
                    Task { await app.acceptDetection() }
                } label: {
                    Text("Record meeting").font(.parfait(12, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                Button("Dismiss") { app.dismissDetection() }
                    .buttonStyle(.bordered)
                    .font(.parfait(12))
            }
        }
        .cardStyle()
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !app.store.meetings.isEmpty {
                Text("Recent")
                    .font(.parfait(11, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            ForEach(app.store.meetings.prefix(4)) { meeting in
                Button {
                    app.openMeetingID = meeting.id
                    openMain()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.parfait(12, .medium))
                                .lineLimit(1)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.parfait(10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StateBadge(meeting: meeting, stage: app.processingStage[meeting.id])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private func dismissMenu() {
        MenuBarExtraPanel.dismiss()
    }

    private func openMain() {
        dismissMenu()
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// SwiftUI's MenuBarExtra(.window) has no dismiss API — capture the panel and order it out.
private enum MenuBarExtraPanel {
    private static weak var window: NSWindow?

    static func dismiss() {
        window?.orderOut(nil)
    }

    static func bind(_ window: NSWindow?) {
        Self.window = window
    }
}

private struct MenuBarExtraWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ nsView: HookView, context: Context) {}

    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MenuBarExtraPanel.bind(window)
        }
    }
}

private struct RecordingCard: View {
    @ObservedObject var session: RecordingSession
    let meeting: Meeting?
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RecordDot()
                Text(meeting?.title ?? "Recording")
                    .font(.parfait(13, .semibold))
                    .lineLimit(1)
                Spacer()
                Text(timeString(session.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.raspberry)
            }
            HStack(alignment: .bottom) {
                LevelMeter(level: session.micLevel)
                Spacer()
                if !session.systemStarted {
                    Text("mic only")
                        .font(.parfait(10))
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Button {
                    Task { await app.stopRecording() }
                } label: {
                    Label("Stop & summarize", systemImage: "stop.fill")
                        .font(.parfait(12, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.raspberry)
                Button {
                    app.discardRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Discard this recording")
            }
            if app.recordingCardDismissed {
                Button {
                    app.recordingCardDismissed = false
                } label: {
                    Label("Show live transcript card", systemImage: "rectangle.on.rectangle")
                        .font(.parfait(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.blueberry)
            }
        }
        .cardStyle()
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
