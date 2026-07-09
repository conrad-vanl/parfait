import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(SettingsKey.didCompleteOnboarding) private var didCompleteOnboarding = false

    @State private var micStatus = MicRecorder.permissionGranted
    @State private var calendarStatus = CalendarMatcher.isAuthorized
    @State private var claudeInstalled = ClaudeCLI.isInstalled
    @State private var claudeLoggedIn = false
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
                    calendarRow
                    claudeRow
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
        .background(Theme.cream)
        .onAppear {
            micStatus = MicRecorder.permissionGranted
            calendarStatus = CalendarMatcher.isAuthorized
            claudeInstalled = ClaudeCLI.isInstalled
            Task.detached {
                let loggedIn = ClaudeCLI.isLoggedIn()
                let gh = GitHubGist.isAvailable // shells out; keep off-main here
                await MainActor.run { claudeLoggedIn = loggedIn; ghAvailable = gh }
            }
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
        // No public preflight/request API exists for kTCCServiceAudioCapture — macOS
        // prompts the first time a recording actually starts. Mirror SettingsView's
        // informational (neutral-dot) row.
        OnboardingStepRow(
            icon: "waveform", title: "System Audio Recording", required: true,
            detail: "Records the other participants. macOS will ask the first time you record; you can also enable it under Privacy & Security → Screen & System Audio Recording.",
            ok: nil
        ) {
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
            }.controlSize(.small)
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
                ? (claudeLoggedIn ? "Connected — unlocks long-meeting summaries and cross-meeting chat." : "Installed but not logged in. Run `claude` in a terminal once.")
                : "Optional — unlocks long-meeting summaries and cross-meeting chat, billed to your own Claude plan.",
            ok: claudeInstalled && claudeLoggedIn
        ) {
            if !claudeInstalled {
                Button("Learn more") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
                    .controlSize(.small)
            }
        }
    }

    private var githubRow: some View {
        OnboardingStepRow(
            icon: "chevron.left.forwardslash.chevron.right", title: "GitHub access", required: false,
            detail: ghAvailable ? "Ready — publishes meeting pages as secret gists on your own account." : "Optional — needed only to publish meeting pages. Install with Homebrew, then `gh auth login`.",
            ok: ghAvailable
        ) {
            if !ghAvailable {
                Button("Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install gh && gh auth login", forType: .string)
                }.controlSize(.small)
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
