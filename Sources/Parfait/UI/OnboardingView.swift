import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.didCompleteOnboarding) private var didCompleteOnboarding = false
    @AppStorage(SettingsKey.systemAudioConfirmed) private var systemAudioConfirmed = false
    @State private var systemAudioStatus = SystemAudioPermission.status()

    @State private var micStatus = MicRecorder.permissionGranted
    @State private var calendarStatus = CalendarMatcher.isAuthorized
    @State private var claudeInstalled = ClaudeCLI.isInstalled
    @State private var claudeLoggedIn = false
    @State private var claudeDesktopInstalled = ClaudeDesktop.isInstalled
    @State private var ghAvailable = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ParfaitStripes()
                Text("Welcome to Parfait").font(.parfait(20, .bold))
                Text("A quick, optional setup — you can change any of this later in Settings.")
                    .font(.parfait(12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(.top, 28).padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 12) {
                    micRow
                    systemAudioRow
                    notificationsRow
                    calendarRow
                    claudeRow
                    claudeDesktopRow
                    githubRow
                }
                .padding(.horizontal, 24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.raspberry)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
        .background(Theme.surface(scheme))
        .onAppear {
            systemAudioStatus = SystemAudioPermission.status()
            micStatus = MicRecorder.permissionGranted
            calendarStatus = CalendarMatcher.isAuthorized
            claudeInstalled = ClaudeCLI.isInstalled
            claudeDesktopInstalled = ClaudeDesktop.isInstalled
            Task { await app.refreshNotificationStatus() }
            Task.detached {
                let loggedIn = ClaudeCLI.isLoggedIn()
                let gh = GitHubGist.isAvailable // shells out; keep off-main here
                await MainActor.run { claudeLoggedIn = loggedIn; ghAvailable = gh }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemAudioStatus = SystemAudioPermission.status()
        }
    }

    private func finish() {
        didCompleteOnboarding = true
        dismissWindow(id: "onboarding")
    }

    // MARK: - Steps

    private var micRow: some View {
        OnboardingStepRow(
            icon: "mic.fill", title: "Microphone", required: true,
            detail: "Records your side of the call.", ok: micStatus
        ) {
            if !micStatus {
                Button("Grant…") { Task { micStatus = await MicRecorder.requestPermission() } }
                    .controlSize(.small)
            }
        }
    }

    private var systemAudioRow: some View {
        OnboardingStepRow(
            icon: "waveform", title: "System Audio Recording", required: true,
            detail: systemAudioDetail,
            ok: systemAudioOK
        ) {
            switch systemAudioStatus {
            case .unknown:
                Button("Grant…") {
                    Task {
                        await SystemAudioPermission.request()
                        systemAudioStatus = SystemAudioPermission.status()
                    }
                }
                .controlSize(.small)
            case .denied:
                Button("Open Settings") {
                    NSWorkspace.shared.open(SystemAudioPermission.privacySettingsURL)
                }
                .controlSize(.small)
            case .authorized:
                EmptyView()
            }
        }
    }

    private var systemAudioOK: Bool? {
        if systemAudioConfirmed || systemAudioStatus == .authorized { return true }
        if systemAudioStatus == .denied { return false }
        return nil
    }

    private var systemAudioDetail: String {
        if systemAudioConfirmed {
            return "Confirmed — captured system audio in a previous recording."
        }
        switch systemAudioStatus {
        case .authorized:
            return "Allowed — records the other participants on calls."
        case .denied:
            return "Denied — enable Parfait under System Audio Recording Only in Settings."
        case .unknown:
            return "Records the other participants. Click Grant — macOS will ask to allow system audio recording."
        }
    }

    private var notificationsRow: some View {
        let status = app.notificationAuthStatus
        return OnboardingStepRow(
            icon: "bell.badge.fill", title: "Notifications", required: false,
            detail: status == .denied
                ? "Denied — Parfait can't tell you when your notes are ready. Turn it on in System Settings → Notifications → Parfait."
                : status == .authorized
                    ? "On — Parfait will let you know when your meeting notes are ready."
                    : "Lets Parfait notify you when a recording finishes processing and your notes are ready.",
            ok: status == .authorized ? true : (status == .denied ? false : nil)
        ) {
            if status == .notDetermined {
                Button("Grant…") { Task { await app.requestNotificationAuthorization() } }
                    .controlSize(.small)
            } else if status != .authorized {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                }.controlSize(.small)
            }
        }
    }

    private var calendarRow: some View {
        OnboardingStepRow(
            icon: "calendar", title: "Calendar", required: false,
            detail: "Matches your current meeting for titles and attendees.", ok: calendarStatus
        ) {
            if !calendarStatus {
                Button("Grant…") { Task { calendarStatus = await CalendarMatcher.requestAccess() } }
                    .controlSize(.small)
            }
        }
    }

    private var claudeRow: some View {
        OnboardingStepRow(
            icon: "sparkles", title: "Claude access", required: false,
            detail: claudeInstalled
                ? (claudeLoggedIn ? "Connected — unlocks long-meeting summaries." : "Installed but not logged in — open Claude Code and log in once.")
                : "Optional — unlocks long-meeting summaries, billed to your own Claude plan.",
            ok: claudeInstalled && claudeLoggedIn
        ) {
            if !claudeInstalled {
                Button("Learn more") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
                    .controlSize(.small)
            }
        }
    }

    private var claudeDesktopRow: some View {
        OnboardingStepRow(
            icon: "message.badge.filled.fill", title: "Claude Desktop", required: false,
            detail: claudeDesktopInstalled
                ? "Installed — Chat and \"Ask your meetings\" open here. Add the parfait connector in Settings → Connect Claude if you haven't."
                : "Required for chat — Parfait's Chat and \"Ask your meetings\" screens open a pre-filled prompt in Claude Desktop.",
            ok: claudeDesktopInstalled
        ) {
            if !claudeDesktopInstalled {
                Button("Get Claude Desktop") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
                }.controlSize(.small)
            }
        }
    }

    private var githubRow: some View {
        OnboardingStepRow(
            icon: "chevron.left.forwardslash.chevron.right", title: "GitHub access", required: false,
            detail: ghAvailable ? "Ready — publishes meeting pages as secret gists on your own account." : "Optional — needed only to publish meeting pages.",
            ok: ghAvailable
        ) {
            if !ghAvailable {
                Button("Set it up with Claude") { ClaudeCode.setUpGitHubCLI() }
                    .controlSize(.small)
                    .disabled(!claudeDesktopInstalled)
            }
        }
    }
}

private struct OnboardingStepRow<Action: View>: View {
    let icon: String
    let title: String
    let required: Bool
    let detail: String
    let ok: Bool?          // nil = informational, no pass/fail
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(ok: ok)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(Theme.raspberry).font(.parfait(12))
                    Text(title).font(.parfait(13, .semibold))
                    if !required { Chip(text: "Optional") }
                }
                Text(detail).font(.parfait(11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            action()
        }
        .cardStyle()
    }
}
